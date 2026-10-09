// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SplitterFactory} from "../../src/core/SplitterFactory.sol";
import {Splitter} from "../../src/core/Splitter.sol";
import {PToken} from "../../src/core/PToken.sol";
import {DToken} from "../../src/core/DToken.sol";
import {TimeDecayAMM} from "../../src/amm/TimeDecayAMM.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {FeeCollector} from "../../src/governance/FeeCollector.sol";
import {MultiplierDividendAdapter, IScaledUiToken} from "../../src/adapters/MultiplierDividendAdapter.sol";
import {ISplitterFactory} from "../../src/interfaces/ISplitterFactory.sol";
import {IAggregatorV3} from "../../src/interfaces/IOracleAdapter.sol";
import {DateLib} from "../../src/libraries/DateLib.sol";

/// @notice Fork tests against Robinhood Chain mainnet (chain 4663) with the real AAPL stock token, the real
///         Chainlink AAPL/USD + USDG/USD feeds and real USDG. Skipped unless ROBINHOOD_RPC_URL is set.
///         Addresses: docs/research/robinhood-chain.md / config/chains.ts.
contract RobinhoodForkTest is Test {
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    bool internal forked;
    SplitterFactory internal factory;
    OracleAdapter internal oracle;
    Splitter internal splitter;
    TimeDecayAMM internal pPool;
    TimeDecayAMM internal dPool;
    address internal alice = makeAddr("alice");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blockNo = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNo == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNo);
        forked = true;
        assertEq(block.chainid, 4663, "not Robinhood Chain mainnet");

        oracle = new OracleAdapter(address(this));
        oracle.setFeed(AAPL, _feed(AAPL_FEED));
        oracle.setFeed(USDG, _feed(USDG_FEED));
        FeeCollector fc = new FeeCollector(address(this), address(this), 0);
        factory = new SplitterFactory(
            SplitterFactory.InitParams({
                admin: address(this),
                guardian: address(this),
                oracle: address(oracle),
                stable: USDG,
                feeCollector: address(fc),
                compliance: address(0),
                swapFeeBps: 30,
                protocolFeeShareBps: 2_000,
                maxHorizon: uint32(2 * 365 days),
                splitterImpl: address(new Splitter()),
                pTokenImpl: address(new PToken()),
                dTokenImpl: address(new DToken()),
                ammImpl: address(new TimeDecayAMM())
            })
        );
        factory.listStock(
            AAPL,
            ISplitterFactory.StockConfig({
                listed: true,
                adapter: new MultiplierDividendAdapter(),
                maxDividendBps: 500,
                trailingWindow: 30 days,
                scalarRoot: 50e18,
                scalarRootD: 300e18,
                initialAnchor: 1.01e18
            })
        );
        SplitterFactory.Market memory m = factory.createMarket(AAPL, _nextQuarter());
        splitter = Splitter(m.splitter);
        pPool = TimeDecayAMM(m.pPool);
        dPool = TimeDecayAMM(m.dPool);
    }

    function _feed(address f) internal pure returns (OracleAdapter.FeedConfig memory) {
        return OracleAdapter.FeedConfig(IAggregatorV3(f), IAggregatorV3(address(0)), 4 days, 0, 2_000);
    }

    function _nextQuarter() internal view returns (uint64) {
        (uint256 y, uint256 mo,) = DateLib.dateFromTimestamp(block.timestamp);
        uint256 q = ((mo - 1) / 3) * 3 + 4;
        if (q > 12) {
            q -= 12;
            y++;
        }
        uint256 ts = DateLib.timestampFromDate(y, q, 1);
        if (ts < block.timestamp + 7 days) ts = DateLib.timestampFromDate(q + 3 > 12 ? y + 1 : y, q + 3 > 12 ? q - 9 : q + 3, 1);
        return uint64(ts);
    }

    function test_Fork_RealTokenSurface() public {
        if (!forked) return vm.skip(true);
        uint256 m = IScaledUiToken(AAPL).uiMultiplier();
        assertGe(m, 1e18);
        assertEq(splitter.adapterState(), m);
        uint256 px = oracle.getPrice(AAPL);
        console2.log("AAPL/USD (wad):", px);
        assertGt(px, 1e18);
        assertApproxEqRel(oracle.getPrice(USDG), 1e18, 0.02e18);
    }

    function test_Fork_SplitTradeDividendMergeRedeem() public {
        if (!forked) return vm.skip(true);
        deal(AAPL, alice, 100e18);
        deal(USDG, alice, 1_000_000e6);
        assertEq(IERC20(AAPL).balanceOf(alice), 100e18);

        vm.startPrank(alice);
        IERC20(AAPL).approve(address(splitter), type(uint256).max);
        uint256 units = splitter.split(100e18, alice);
        assertEq(units, 100e18);
        assertEq(IERC20(AAPL).balanceOf(address(splitter)), 100e18);

        // seed both pools with real USDG at the live AAPL price
        uint256 unitPrice = pPool.unitPrice(); // USDG wad per unit
        IERC20 p = IERC20(address(splitter.pToken()));
        IERC20 d = IERC20(address(splitter.dToken()));
        p.approve(address(pPool), type(uint256).max);
        d.approve(address(dPool), type(uint256).max);
        IERC20(USDG).approve(address(pPool), type(uint256).max);
        IERC20(USDG).approve(address(dPool), type(uint256).max);
        pPool.addLiquidity(40e18, 40 * unitPrice / 1e12, 0, alice, block.timestamp);
        dPool.addLiquidity(40e18, 4 * unitPrice / 1e12, 0, alice, block.timestamp);
        uint256 out = pPool.swapExactTokenForStable(1e18, 0, alice, block.timestamp);
        assertApproxEqRel(out, unitPrice / 1e12, 0.03e18);
        dPool.swapStableForExactToken(1e18, type(uint256).max, alice, block.timestamp);
        vm.stopPrank();

        // simulate the issuer reinvesting a 0.3% cash dividend via the ERC-8056 multiplier
        uint256 m0 = IScaledUiToken(AAPL).uiMultiplier();
        vm.mockCall(AAPL, abi.encodeWithSelector(IScaledUiToken.uiMultiplier.selector), abi.encode(m0 * 1003 / 1000));
        splitter.harvest();
        assertLt(splitter.scale(), 1e18);
        (, uint256[] memory owed) = splitter.claimable(alice);
        assertGt(owed[0], 0);

        vm.startPrank(alice);
        uint256[] memory paid = splitter.claimDividends(alice);
        assertGt(paid[0], 0);
        uint256 mergeUnits = p.balanceOf(alice) < d.balanceOf(alice) ? p.balanceOf(alice) : d.balanceOf(alice);
        uint256 got = splitter.merge(mergeUnits, alice);
        assertEq(got, mergeUnits * splitter.scale() / 1e18);
        vm.stopPrank();

        vm.warp(splitter.expiry());
        vm.mockCall(AAPL_FEED, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), abi.encode(1, 300e8, block.timestamp, block.timestamp, 1));
        uint256 lp = pPool.balanceOf(alice);
        vm.startPrank(alice);
        pPool.removeLiquidity(lp, 0, 0, alice, block.timestamp);
        uint256 pb = p.balanceOf(alice);
        splitter.redeem(pb, alice);
        vm.stopPrank();
        assertGe(IERC20(AAPL).balanceOf(address(splitter)), splitter.principal() + splitter.reserved(AAPL));
    }
}
