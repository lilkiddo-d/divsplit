// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {SplitterFactory} from "../src/core/SplitterFactory.sol";
import {Splitter} from "../src/core/Splitter.sol";
import {PToken} from "../src/core/PToken.sol";
import {DToken} from "../src/core/DToken.sol";
import {TimeDecayAMM} from "../src/amm/TimeDecayAMM.sol";
import {Router} from "../src/periphery/Router.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {FeeCollector} from "../src/governance/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/governance/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../src/governance/ComplianceRegistry.sol";
import {MultiplierDividendAdapter} from "../src/adapters/MultiplierDividendAdapter.sol";
import {RebaseDividendAdapter} from "../src/adapters/RebaseDividendAdapter.sol";
import {AirdropDividendAdapter} from "../src/adapters/AirdropDividendAdapter.sol";
import {NoDividendAdapter} from "../src/adapters/NoDividendAdapter.sol";
import {ISplitterFactory} from "../src/interfaces/ISplitterFactory.sol";
import {IDividendAdapter} from "../src/interfaces/IDividendAdapter.sol";
import {IAggregatorV3} from "../src/interfaces/IOracleAdapter.sol";
import {DateLib} from "../src/libraries/DateLib.sol";
import {MockERC20, MockScaledStock, MockFeed} from "./mocks/Mocks.sol";

abstract contract Base is Test {
    address internal admin = address(this);
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal lp = makeAddr("lp");

    MockERC20 internal usdg;
    MockScaledStock internal stock;
    MockFeed internal stockFeed;
    MockFeed internal stableFeed;

    OracleAdapter internal oracle;
    FeeCollector internal feeCollector;
    ProjectTokenHooks internal hooks;
    ComplianceRegistry internal compliance;
    SplitterFactory internal factory;
    Router internal router;
    MultiplierDividendAdapter internal multAdapter;
    RebaseDividendAdapter internal rebaseAdapter;
    AirdropDividendAdapter internal airdropAdapter;
    NoDividendAdapter internal noneAdapter;

    Splitter internal splitter;
    PToken internal pToken;
    DToken internal dToken;
    TimeDecayAMM internal pPool;
    TimeDecayAMM internal dPool;

    uint64 internal expiry;
    uint256 internal constant START = 1_791_417_600; // 2026-10-08 00:00:00 UTC
    int256 internal constant SCALAR_ROOT = 50e18;
    int256 internal constant SCALAR_ROOT_D = 300e18;
    int256 internal constant INITIAL_ANCHOR = 1.03e18;

    function setUp() public virtual {
        vm.warp(START);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        stock = new MockScaledStock("Apple Token", "AAPL");
        stockFeed = new MockFeed(8, 250e8);
        stableFeed = new MockFeed(8, 1e8);

        oracle = new OracleAdapter(admin);
        oracle.setFeed(address(stock), _feedCfg(address(stockFeed)));
        oracle.setFeed(address(usdg), _feedCfg(address(stableFeed)));

        feeCollector = new FeeCollector(admin, treasury, 5_000);
        hooks = new ProjectTokenHooks(admin, address(feeCollector));
        feeCollector.setHooks(address(hooks));
        compliance = new ComplianceRegistry(admin);

        factory = new SplitterFactory(
            SplitterFactory.InitParams({
                admin: admin,
                guardian: guardian,
                oracle: address(oracle),
                stable: address(usdg),
                feeCollector: address(feeCollector),
                compliance: address(compliance),
                swapFeeBps: 30,
                protocolFeeShareBps: 2_000,
                maxHorizon: uint32(2 * 365 days),
                splitterImpl: address(new Splitter()),
                pTokenImpl: address(new PToken()),
                dTokenImpl: address(new DToken()),
                ammImpl: address(new TimeDecayAMM())
            })
        );
        factory.grantRole(factory.KEEPER_ROLE(), keeper);
        router = new Router(address(factory));

        multAdapter = new MultiplierDividendAdapter();
        rebaseAdapter = new RebaseDividendAdapter();
        airdropAdapter = new AirdropDividendAdapter(admin);
        noneAdapter = new NoDividendAdapter();

        factory.listStock(address(stock), _stockCfg(multAdapter));
        expiry = uint64(DateLib.timestampFromDate(2027, 1, 1));
        _useMarket(factory.createMarket(address(stock), expiry));

        vm.label(address(splitter), "Splitter");
        vm.label(address(stock), "AAPL");
        vm.label(address(usdg), "USDG");
    }

    function _feedCfg(address feed) internal pure returns (OracleAdapter.FeedConfig memory) {
        return OracleAdapter.FeedConfig({
            primary: IAggregatorV3(feed),
            secondary: IAggregatorV3(address(0)),
            maxStaleness: 2 days,
            maxDeviationBps: 0,
            maxRoundJumpBps: 0
        });
    }

    function _stockCfg(IDividendAdapter adapter) internal pure returns (ISplitterFactory.StockConfig memory) {
        return ISplitterFactory.StockConfig({
            listed: true,
            adapter: adapter,
            maxDividendBps: 500,
            trailingWindow: 30 days,
            scalarRoot: SCALAR_ROOT,
            scalarRootD: SCALAR_ROOT_D,
            initialAnchor: INITIAL_ANCHOR
        });
    }

    function _useMarket(SplitterFactory.Market memory m) internal {
        splitter = Splitter(m.splitter);
        pToken = PToken(m.pToken);
        dToken = DToken(m.dToken);
        pPool = TimeDecayAMM(m.pPool);
        dPool = TimeDecayAMM(m.dPool);
    }

    function _split(address who, uint256 amount) internal returns (uint256 units) {
        stock.mint(who, amount);
        vm.startPrank(who);
        stock.approve(address(splitter), amount);
        units = splitter.split(amount, who);
        vm.stopPrank();
    }

    /// @dev Simulate a reinvested cash dividend of `bps` on an ERC-8056 token.
    function _bumpMultiplier(uint256 bps) internal {
        stock.setMultiplier(stock.uiMultiplier() * (10_000 + bps) / 10_000);
    }

    function _seedPools(uint256 units) internal {
        _split(lp, units * 2);
        usdg.mint(lp, 10_000_000e6);
        vm.startPrank(lp);
        pToken.approve(address(pPool), type(uint256).max);
        dToken.approve(address(dPool), type(uint256).max);
        usdg.approve(address(pPool), type(uint256).max);
        usdg.approve(address(dPool), type(uint256).max);
        // P pool: ~50/50 by count vs units of stable (unit = $250)
        pPool.addLiquidity(units, units * 250 / 1e12, 0, lp, block.timestamp);
        // D pool: D-heavy (D is worth ~1% of a unit)
        dPool.addLiquidity(units, units * 250 / 1e12 / 10, 0, lp, block.timestamp);
        vm.stopPrank();
    }

    function _refreshFeeds() internal {
        (, int256 s,,,) = stockFeed.latestRoundData();
        stockFeed.set(s);
        stableFeed.set(1e8);
    }
}
