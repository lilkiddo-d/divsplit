// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {SplitterFactory} from "../../src/core/SplitterFactory.sol";
import {ISplitterFactory} from "../../src/interfaces/ISplitterFactory.sol";
import {IDividendAdapter} from "../../src/interfaces/IDividendAdapter.sol";
import {DateLib} from "../../src/libraries/DateLib.sol";
import {MarketMath} from "../../src/libraries/MarketMath.sol";
import {MockScaledStock} from "../mocks/Mocks.sol";
import {PToken as PToken_} from "../../src/core/PToken.sol";

contract FactoryTest is Base {
    function test_MarketRegistered() public view {
        assertEq(factory.splitterOf(address(stock), expiry), address(splitter));
        SplitterFactory.Market memory m = factory.market(address(splitter));
        assertEq(m.pPool, address(pPool));
        assertEq(m.dPool, address(dPool));
        assertEq(factory.splitterCount(), 1);
        assertEq(factory.listedStockCount(), 1);
        assertEq(factory.getMarkets(0, 10).length, 1);
        assertEq(factory.getMarkets(5, 10).length, 0);
        assertTrue(factory.isAdmin(admin));
        assertTrue(factory.isGuardian(guardian));
        assertTrue(factory.isKeeper(keeper));
    }

    function test_CreateMarketGuards() public {
        vm.expectRevert(SplitterFactory.MarketExists.selector);
        factory.createMarket(address(stock), expiry);
        vm.expectRevert(SplitterFactory.InvalidExpiry.selector);
        factory.createMarket(address(stock), expiry + 1 days); // not a quarter start
        vm.expectRevert(SplitterFactory.InvalidExpiry.selector);
        factory.createMarket(address(stock), uint64(DateLib.timestampFromDate(2029, 1, 1))); // beyond horizon
        vm.expectRevert(SplitterFactory.InvalidExpiry.selector);
        factory.createMarket(address(stock), uint64(DateLib.timestampFromDate(2026, 10, 1))); // past
        vm.expectRevert(SplitterFactory.NotListed.selector);
        factory.createMarket(alice, expiry);

        // permissionless for listed stocks; yearly + quarterly expiries
        vm.prank(alice);
        factory.createMarket(address(stock), uint64(DateLib.timestampFromDate(2027, 4, 1)));
        vm.prank(alice);
        factory.createMarket(address(stock), uint64(DateLib.timestampFromDate(2028, 1, 1)));
        assertEq(factory.splitterCount(), 3);
    }

    function test_ListingAdmin() public {
        MockScaledStock s2 = new MockScaledStock("Tesla Token", "TSLA");
        vm.prank(alice);
        vm.expectRevert();
        factory.listStock(address(s2), _stockCfg(multAdapter));

        ISplitterFactory.StockConfig memory bad = _stockCfg(multAdapter);
        bad.maxDividendBps = 0;
        vm.expectRevert(SplitterFactory.InvalidParams.selector);
        factory.listStock(address(s2), bad);
        bad = _stockCfg(IDividendAdapter(address(0)));
        vm.expectRevert(SplitterFactory.ZeroAddress.selector);
        factory.listStock(address(s2), bad);
        bad = _stockCfg(multAdapter);
        bad.initialAnchor = 0.9e18;
        vm.expectRevert(SplitterFactory.InvalidParams.selector);
        factory.listStock(address(s2), bad);
        bad = _stockCfg(multAdapter);
        bad.trailingWindow = 200 days;
        vm.expectRevert(SplitterFactory.InvalidParams.selector);
        factory.listStock(address(s2), bad);
        vm.expectRevert(SplitterFactory.ZeroAddress.selector);
        factory.listStock(address(0), _stockCfg(multAdapter));

        factory.listStock(address(s2), _stockCfg(multAdapter));
        vm.expectRevert(SplitterFactory.AlreadyListed.selector);
        factory.listStock(address(s2), _stockCfg(multAdapter));

        factory.delistStock(address(s2));
        vm.expectRevert(SplitterFactory.NotListed.selector);
        factory.createMarket(address(s2), expiry);
        vm.expectRevert(SplitterFactory.NotListed.selector);
        factory.delistStock(address(s2));
        vm.expectRevert(SplitterFactory.NotListed.selector);
        factory.updateStockConfig(address(s2), _stockCfg(multAdapter));
    }

    function test_ConfigSetters() public {
        factory.setOracle(alice);
        assertEq(address(factory.oracle()), alice);
        vm.expectRevert(SplitterFactory.ZeroAddress.selector);
        factory.setOracle(address(0));
        factory.setStable(bob);
        assertEq(factory.stable(), bob);
        vm.expectRevert(SplitterFactory.ZeroAddress.selector);
        factory.setStable(address(0));
        factory.setFeeCollector(bob);
        vm.expectRevert(SplitterFactory.ZeroAddress.selector);
        factory.setFeeCollector(address(0));
        factory.setCompliance(address(0));
        factory.checkCompliance(alice, "X"); // no registry -> allowed
        factory.setFees(100, 10_000);
        vm.expectRevert(SplitterFactory.InvalidParams.selector);
        factory.setFees(101, 0);
        factory.setMaxHorizon(30 days);
        vm.expectRevert(SplitterFactory.InvalidParams.selector);
        factory.setMaxHorizon(1 days);
        vm.prank(alice);
        vm.expectRevert();
        factory.pauseAll();
        vm.prank(alice);
        vm.expectRevert();
        factory.unpauseAll();
        factory.pauseAll(); // admin can pause too
        assertTrue(factory.globalPaused());
    }

    function test_ConstructorGuards() public {
        SplitterFactory.InitParams memory p = SplitterFactory.InitParams({
            admin: admin,
            guardian: address(0),
            oracle: address(oracle),
            stable: address(usdg),
            feeCollector: address(feeCollector),
            compliance: address(0),
            swapFeeBps: 30,
            protocolFeeShareBps: 2_000,
            maxHorizon: 365 days,
            splitterImpl: factory.splitterImpl(),
            pTokenImpl: factory.pTokenImpl(),
            dTokenImpl: factory.dTokenImpl(),
            ammImpl: factory.ammImpl()
        });
        new SplitterFactory(p);
        p.swapFeeBps = 1_000;
        vm.expectRevert(SplitterFactory.InvalidParams.selector);
        new SplitterFactory(p);
        p.swapFeeBps = 30;
        p.ammImpl = address(0);
        vm.expectRevert(SplitterFactory.ZeroAddress.selector);
        new SplitterFactory(p);
        p.ammImpl = factory.ammImpl();
        p.admin = address(0);
        vm.expectRevert(SplitterFactory.ZeroAddress.selector);
        new SplitterFactory(p);
    }

    function test_SymbolFallback() public {
        NoMeta nm = new NoMeta();
        factory.listStock(address(nm), _stockCfg(rebaseAdapter));
        SplitterFactory.Market memory m = factory.createMarket(address(nm), expiry);
        assertEq(PToken_(m.pToken).symbol(), "pSTOCK-20270101");
    }
}

contract NoMeta {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

contract DateLibTest is Base {
    function test_KnownDates() public pure {
        assertEq(DateLib.timestampFromDate(1970, 1, 1), 0);
        assertEq(DateLib.timestampFromDate(2027, 1, 1), 1_798_761_600);
        assertEq(DateLib.timestampFromDate(2024, 2, 29), 1_709_164_800);
        (uint256 y, uint256 m, uint256 d) = DateLib.dateFromTimestamp(1_709_164_800);
        assertEq(y, 2024);
        assertEq(m, 2);
        assertEq(d, 29);
        assertTrue(DateLib.isQuarterlyExpiry(1_798_761_600));
        assertTrue(DateLib.isYearlyExpiry(1_798_761_600));
        assertFalse(DateLib.isYearlyExpiry(DateLib.timestampFromDate(2027, 4, 1)));
        assertTrue(DateLib.isQuarterlyExpiry(DateLib.timestampFromDate(2027, 7, 1)));
        assertTrue(DateLib.isQuarterlyExpiry(DateLib.timestampFromDate(2027, 10, 1)));
        assertFalse(DateLib.isQuarterlyExpiry(DateLib.timestampFromDate(2027, 2, 1)));
        assertFalse(DateLib.isQuarterlyExpiry(1_798_761_601));
        assertFalse(DateLib.isYearlyExpiry(1_798_761_601));
    }

    function testFuzz_RoundTrip(uint256 dayIndex) public pure {
        dayIndex = bound(dayIndex, 0, 100_000);
        uint256 ts = dayIndex * 1 days;
        (uint256 y, uint256 m, uint256 d) = DateLib.dateFromTimestamp(ts);
        assertEq(DateLib.timestampFromDate(y, m, d), ts);
    }
}

contract MarketMathTest is Base {
    function test_Errors() public {
        MathHarness h = new MathHarness();
        vm.expectRevert(MarketMath.MarketExpired.selector);
        h.rateScalar(1e18, 0);
        vm.expectRevert(MarketMath.MarketRateScalarZero.selector);
        h.rateScalar(0, 1 days);
        vm.expectRevert(MarketMath.MarketZeroTotals.selector);
        h.proportion(0, 0);
        vm.expectPartialRevert(MarketMath.MarketExchangeRateBelowOne.selector);
        h.lnImplied(0.5e18, 1 days);
    }
}

contract MathHarness {
    function rateScalar(int256 r, uint256 t) external pure returns (int256) {
        return MarketMath.rateScalar(r, t);
    }

    function proportion(uint256 a, uint256 b) external pure returns (uint256) {
        return MarketMath.proportion(a, b);
    }

    function lnImplied(int256 er, uint256 t) external pure returns (int256) {
        return MarketMath.lnImpliedRateFromExchangeRate(er, t);
    }
}
