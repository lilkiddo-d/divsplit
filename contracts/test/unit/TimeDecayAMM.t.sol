// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {TimeDecayAMM} from "../../src/amm/TimeDecayAMM.sol";
import {MarketMath} from "../../src/libraries/MarketMath.sol";
import {SplitterFactory} from "../../src/core/SplitterFactory.sol";
import {Router} from "../../src/periphery/Router.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract TimeDecayAMMTest is Base {
    uint256 internal constant SEED = 1_000e18;

    function setUp() public override {
        super.setUp();
        _seedPools(SEED);
        usdg.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdg.approve(address(pPool), type(uint256).max);
        usdg.approve(address(dPool), type(uint256).max);
        usdg.approve(address(router), type(uint256).max);
        pToken.approve(address(pPool), type(uint256).max);
        dToken.approve(address(dPool), type(uint256).max);
        pToken.approve(address(router), type(uint256).max);
        dToken.approve(address(router), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
        stock.approve(address(splitter), type(uint256).max);
        vm.stopPrank();
    }

    function test_InitialState() public view {
        assertEq(pPool.lnImpliedRate(), FixedPointMathLib.lnWad(INITIAL_ANCHOR));
        assertEq(dPool.lnImpliedRate(), FixedPointMathLib.lnWad(INITIAL_ANCHOR));
        uint256 p = pPool.spotPriceInUnits();
        uint256 d = dPool.spotPriceInUnits();
        assertApproxEqAbs(p + d, 1e18, 1); // P + D = one unit
        assertLt(p, 1e18);
        assertGt(d, 0);
        assertEq(pPool.unitPrice(), 250e18);
        assertApproxEqRel(pPool.spotPriceInStable(), p * 250, 1e12);
        (uint256 rt, uint256 rs) = pPool.getReserves();
        assertEq(rt, SEED);
        assertEq(rs, 250_000e6);
        assertEq(pPool.balanceOf(address(0xdEaD)), pPool.MINIMUM_LIQUIDITY());
        assertEq(pPool.symbol(), "DLP-pAAPL-20270101");
    }

    function test_SellPAndBuyBack() public {
        _split(alice, 10e18);
        uint256 quote = pPool.previewSell(10e18);
        vm.prank(alice);
        uint256 out = pPool.swapExactTokenForStable(10e18, quote, alice, block.timestamp);
        assertEq(out, quote);
        // roughly price * 250 * 10 minus fee
        assertLt(out, 2_500e6);
        assertGt(out, 2_400e6);

        uint256 cost = pPool.previewBuy(10e18);
        assertGt(cost, out); // spread + fees
        vm.prank(alice);
        uint256 paid = pPool.swapStableForExactToken(10e18, cost, alice, block.timestamp);
        assertEq(paid, cost);
        assertEq(pToken.balanceOf(alice), 10e18);
    }

    function test_ProtocolFeeGoesToCollector() public {
        _split(alice, 10e18);
        vm.prank(alice);
        pPool.swapExactTokenForStable(10e18, 0, alice, block.timestamp);
        uint256 collected = usdg.balanceOf(address(feeCollector));
        assertGt(collected, 0);
        // 0.3% fee * 20% share of ~2,470 USDG ~= 1.48 USDG
        assertApproxEqRel(collected, 1.48e6, 0.05e18);
    }

    function test_BuyingDRaisesImpliedYield() public {
        int256 before = dPool.lnImpliedRate();
        vm.prank(alice);
        dPool.swapStableForExactToken(100e18, type(uint256).max, alice, block.timestamp);
        assertGt(dPool.lnImpliedRate(), before);
        assertEq(dToken.balanceOf(alice), 100e18);

        int256 mid = dPool.lnImpliedRate();
        vm.prank(alice);
        dPool.swapExactTokenForStable(100e18, 0, alice, block.timestamp);
        assertLt(dPool.lnImpliedRate(), mid);
    }

    function test_BuyingPLowersImpliedYield() public {
        int256 before = pPool.lnImpliedRate();
        vm.prank(alice);
        pPool.swapStableForExactToken(100e18, type(uint256).max, alice, block.timestamp);
        assertLt(pPool.lnImpliedRate(), before);
    }

    function test_PriceConvergesTowardExpiry() public {
        uint256 pEarly = pPool.spotPriceInUnits();
        uint256 dEarly = dPool.spotPriceInUnits();
        vm.warp(expiry - 1 days);
        _refreshFeeds();
        uint256 pLate = pPool.spotPriceInUnits();
        uint256 dLate = dPool.spotPriceInUnits();
        assertGt(pLate, pEarly);
        assertLt(dLate, dEarly);
        assertApproxEqRel(pLate, 1e18, 0.0001e18);
        assertLt(dLate, 0.0001e18);

        // a real trade near expiry also prices P at ~1 unit
        _split(alice, 1e18);
        vm.prank(alice);
        uint256 out = pPool.swapExactTokenForStable(1e18, 0, alice, block.timestamp);
        assertApproxEqRel(out, 250e6, 0.005e18);

        vm.warp(expiry);
        assertEq(pPool.spotPriceInUnits(), 1e18);
        assertEq(dPool.spotPriceInUnits(), 0);
    }

    function test_ImpliedRateIsTimeContinuous() public {
        // Without trades, the implied rate is unchanged by the passage of time (Pendle rate-anchor property).
        int256 r0 = pPool.lnImpliedRate();
        vm.warp(block.timestamp + 30 days);
        _refreshFeeds();
        _split(alice, 1e15);
        vm.prank(alice);
        pPool.swapExactTokenForStable(1e15, 0, alice, block.timestamp);
        assertApproxEqRel(pPool.lnImpliedRate(), r0, 0.01e18);
    }

    function test_SwapGuards() public {
        _split(alice, 10e18);
        vm.startPrank(alice);
        vm.expectRevert(TimeDecayAMM.DeadlinePassed.selector);
        pPool.swapExactTokenForStable(1e18, 0, alice, block.timestamp - 1);
        vm.expectRevert(TimeDecayAMM.ZeroAmount.selector);
        pPool.swapExactTokenForStable(0, 0, alice, block.timestamp);
        vm.expectRevert(TimeDecayAMM.ZeroAddress.selector);
        pPool.swapExactTokenForStable(1e18, 0, address(0), block.timestamp);
        vm.expectRevert(TimeDecayAMM.Slippage.selector);
        pPool.swapExactTokenForStable(1e18, type(uint256).max, alice, block.timestamp);
        vm.expectRevert(TimeDecayAMM.Slippage.selector);
        pPool.swapStableForExactToken(1e18, 1, alice, block.timestamp);
        vm.expectRevert(TimeDecayAMM.ZeroAmount.selector);
        pPool.swapStableForExactToken(0, 1, alice, block.timestamp);
        vm.expectRevert(TimeDecayAMM.InsufficientLiquidity.selector);
        pPool.swapStableForExactToken(SEED, type(uint256).max, alice, block.timestamp);
        // pushing the pool past the proportion bound reverts
        vm.expectRevert();
        pPool.swapStableForExactToken(SEED * 99 / 100, type(uint256).max, alice, block.timestamp);
        vm.stopPrank();

        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(TimeDecayAMM.Expired.selector);
        pPool.swapExactTokenForStable(1e18, 0, alice, block.timestamp);
    }

    function test_PausedAndCompliance() public {
        _split(alice, 10e18);
        vm.prank(guardian);
        splitter.pause();
        vm.prank(alice);
        vm.expectRevert(TimeDecayAMM.IsPaused.selector);
        pPool.swapExactTokenForStable(1e18, 0, alice, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(TimeDecayAMM.IsPaused.selector);
        pPool.addLiquidity(1e18, 1e6, 0, alice, block.timestamp);
        // LPs can always exit
        uint256 lpBal = pPool.balanceOf(lp);
        vm.prank(lp);
        pPool.removeLiquidity(lpBal / 2, 0, 0, lp, block.timestamp);
        splitter.unpause();

        compliance.setEnabled(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SplitterFactory.NotCompliant.selector, alice, keccak256("SWAP")));
        pPool.swapExactTokenForStable(1e18, 0, alice, block.timestamp);
        compliance.setActionOpen(keccak256("SWAP"), true);
        vm.prank(alice);
        pPool.swapExactTokenForStable(1e18, 0, alice, block.timestamp);
    }

    function test_StaleOracleBlocksSwaps() public {
        _split(alice, 10e18);
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, address(stock), START));
        pPool.swapExactTokenForStable(1e18, 0, alice, block.timestamp);
    }

    function test_AddAndRemoveLiquidity() public {
        _split(alice, 100e18);
        vm.startPrank(alice);
        (uint256 lpAmt, uint256 tUsed, uint256 sUsed) =
            pPool.addLiquidity(10e18, 10_000e6, 0, alice, block.timestamp);
        assertEq(tUsed, 10e18);
        assertApproxEqAbs(sUsed, 2_500e6, 1);
        assertGt(lpAmt, 0);

        vm.expectRevert(TimeDecayAMM.Slippage.selector);
        pPool.addLiquidity(10e18, 10_000e6, type(uint256).max, alice, block.timestamp);
        vm.expectRevert(TimeDecayAMM.ZeroAmount.selector);
        pPool.addLiquidity(0, 1, 0, alice, block.timestamp);
        vm.expectRevert(TimeDecayAMM.ZeroAddress.selector);
        pPool.addLiquidity(1, 1, 0, address(0), block.timestamp);
        vm.expectRevert(TimeDecayAMM.DeadlinePassed.selector);
        pPool.addLiquidity(1, 1, 0, alice, block.timestamp - 1);

        vm.expectRevert(TimeDecayAMM.Slippage.selector);
        pPool.removeLiquidity(lpAmt, type(uint256).max, 0, alice, block.timestamp);
        vm.expectRevert(TimeDecayAMM.ZeroAmount.selector);
        pPool.removeLiquidity(0, 0, 0, alice, block.timestamp);
        vm.expectRevert(TimeDecayAMM.ZeroAddress.selector);
        pPool.removeLiquidity(1, 0, 0, address(0), block.timestamp);
        vm.expectRevert(TimeDecayAMM.DeadlinePassed.selector);
        pPool.removeLiquidity(1, 0, 0, alice, block.timestamp - 1);
        vm.stopPrank();

        vm.warp(expiry + 1);
        vm.prank(alice);
        vm.expectRevert(TimeDecayAMM.Expired.selector);
        pPool.addLiquidity(1e18, 1e6, 0, alice, block.timestamp);
        vm.prank(alice);
        (uint256 tOut, uint256 sOut) = pPool.removeLiquidity(lpAmt, 0, 0, alice, block.timestamp);
        assertApproxEqAbs(tOut, 10e18, 1e3);
        assertApproxEqAbs(sOut, 2_500e6, 2);
    }

    function test_FirstDepositTooSmallOrUnbalanced() public {
        SplitterFactory.Market memory m = factory.createMarket(address(stock), uint64(expiry + 90 days));
        _useMarket(m);
        _split(alice, 10e18);
        vm.startPrank(alice);
        pToken.approve(address(pPool), type(uint256).max);
        usdg.approve(address(pPool), type(uint256).max);
        vm.expectPartialRevert(MarketMath.MarketProportionOutOfBounds.selector);
        pPool.addLiquidity(1e18, 1e6, 0, alice, block.timestamp); // 99.9996% P: out of bounds
        vm.stopPrank();
    }

    function testFuzz_SellThenBuyNeverProfits(uint256 amount) public {
        amount = bound(amount, 1e12, 200e18);
        _split(alice, amount);
        uint256 balBefore = usdg.balanceOf(alice);
        vm.startPrank(alice);
        pPool.swapExactTokenForStable(amount, 0, alice, block.timestamp);
        pPool.swapStableForExactToken(amount, type(uint256).max, alice, block.timestamp);
        vm.stopPrank();
        assertLe(usdg.balanceOf(alice), balBefore);
        assertEq(pToken.balanceOf(alice), amount);
    }

    function testFuzz_DPoolRoundTrip(uint256 amount) public {
        amount = bound(amount, 1e12, 500e18);
        uint256 balBefore = usdg.balanceOf(alice);
        vm.startPrank(alice);
        dPool.swapStableForExactToken(amount, type(uint256).max, alice, block.timestamp);
        dPool.swapExactTokenForStable(amount, 0, alice, block.timestamp);
        vm.stopPrank();
        assertLe(usdg.balanceOf(alice), balBefore);
    }

    // ------------------------------------------------------------------ Router

    function test_RouterBuyExactStable() public {
        uint256 quote = router.quoteBuyExactStable(pPool, 1_000e6);
        assertGt(quote, 0);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 got = router.buyExactStable(pPool, 1_000e6, quote, alice, block.timestamp);
        assertEq(got, quote);
        assertEq(pToken.balanceOf(alice), got);
        assertLe(before - usdg.balanceOf(alice), 1_000e6);
        assertEq(usdg.balanceOf(address(router)), 0);
    }

    function test_RouterSellExactToken() public {
        _split(alice, 5e18);
        vm.prank(alice);
        uint256 out = router.sellExactToken(dPool, 5e18, 0, alice, block.timestamp);
        assertGt(out, 0);
        assertEq(dToken.balanceOf(alice), 0);
    }

    function test_RouterSplitAndSell() public {
        stock.mint(alice, 10e18);
        vm.prank(alice);
        (uint256 kept, uint256 out) = router.splitAndSell(splitter, 10e18, true, 0, alice, block.timestamp);
        assertEq(kept, 10e18);
        assertEq(pToken.balanceOf(alice), 10e18);
        assertEq(dToken.balanceOf(alice), 0);
        assertGt(out, 0);

        stock.mint(alice, 10e18);
        vm.prank(alice);
        (kept,) = router.splitAndSell(splitter, 10e18, false, 0, alice, block.timestamp);
        assertEq(dToken.balanceOf(alice), 10e18);
    }

    function test_RouterBuyAndMerge() public {
        _split(alice, 5e18);
        vm.prank(alice);
        dToken.transfer(bob, 5e18); // alice keeps only P
        uint256 stockBefore = stock.balanceOf(alice);
        vm.prank(alice);
        (uint256 stockOut, uint256 paid) = router.buyAndMerge(splitter, 5e18, true, 1_000e6, alice, block.timestamp);
        assertEq(stockOut, 5e18);
        assertEq(stock.balanceOf(alice) - stockBefore, 5e18);
        assertGt(paid, 0);
        assertEq(usdg.balanceOf(address(router)), 0);

        // with D, buying P
        _split(alice, 2e18);
        vm.prank(alice);
        pToken.transfer(bob, 2e18);
        vm.prank(alice);
        router.buyAndMerge(splitter, 2e18, false, 1_000e6, alice, block.timestamp);
    }

    function test_RouterGuards() public {
        vm.startPrank(alice);
        vm.expectRevert(Router.DeadlinePassed.selector);
        router.buyExactStable(pPool, 1e6, 0, alice, block.timestamp - 1);
        vm.expectRevert(Router.ZeroAmount.selector);
        router.buyExactStable(pPool, 0, 0, alice, block.timestamp);
        vm.expectRevert(Router.Slippage.selector);
        router.buyExactStable(pPool, 1e6, type(uint256).max, alice, block.timestamp);
        vm.expectRevert(Router.UnknownMarket.selector);
        router.splitAndSell(Splitter_(address(0xBEEF)), 1, true, 0, alice, block.timestamp);
        vm.stopPrank();
    }
}

import {Splitter as Splitter_} from "../../src/core/Splitter.sol";
