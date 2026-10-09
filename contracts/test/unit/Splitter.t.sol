// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {Splitter} from "../../src/core/Splitter.sol";
import {SplitterFactory} from "../../src/core/SplitterFactory.sol";
import {DividendAccumulator} from "../../src/core/DividendAccumulator.sol";
import {PToken} from "../../src/core/PToken.sol";
import {DToken} from "../../src/core/DToken.sol";
import {IDividendAdapter} from "../../src/interfaces/IDividendAdapter.sol";
import {AirdropDividendAdapter} from "../../src/adapters/AirdropDividendAdapter.sol";
import {MockERC20, MockDistributor, EvilDistributor, MockFeeOnTransfer} from "../mocks/Mocks.sol";

contract SplitterTest is Base {
    // ------------------------------------------------------------------ split / merge / redeem

    function test_SplitMintsEqualPAndD() public {
        uint256 units = _split(alice, 10e18);
        assertEq(units, 10e18);
        assertEq(pToken.balanceOf(alice), 10e18);
        assertEq(dToken.balanceOf(alice), 10e18);
        assertEq(stock.balanceOf(address(splitter)), 10e18);
        assertEq(splitter.principal(), 10e18);
        assertEq(pToken.symbol(), "pAAPL-20270101");
        assertEq(dToken.name(), "Divsplit Dividend AAPL-20270101");
        assertEq(pToken.decimals(), 18);
    }

    function test_MergeReturnsExactlyOneStockPerPair() public {
        _split(alice, 1e18);
        vm.prank(alice);
        uint256 out = splitter.merge(1e18, alice);
        assertEq(out, 1e18);
        assertEq(stock.balanceOf(alice), 1e18);
        assertEq(pToken.totalSupply(), 0);
        assertEq(dToken.totalSupply(), 0);
    }

    function test_SplitRevertsAfterExpiry() public {
        vm.warp(expiry);
        stock.mint(alice, 1e18);
        vm.startPrank(alice);
        stock.approve(address(splitter), 1e18);
        vm.expectRevert(Splitter.Expired.selector);
        splitter.split(1e18, alice);
        vm.stopPrank();
    }

    function test_SplitRevertsOnZero() public {
        vm.expectRevert(Splitter.ZeroAmount.selector);
        splitter.split(0, alice);
        vm.expectRevert(Splitter.ZeroAddress.selector);
        splitter.split(1, address(0));
    }

    function test_MergeRevertsAfterExpiry() public {
        _split(alice, 1e18);
        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(Splitter.Expired.selector);
        splitter.merge(1e18, alice);
    }

    function test_MergeZeroReverts() public {
        vm.expectRevert(Splitter.ZeroAmount.selector);
        splitter.merge(0, alice);
        vm.expectRevert(Splitter.ZeroAddress.selector);
        splitter.merge(1, address(0));
    }

    function test_RedeemAfterExpiry() public {
        _split(alice, 5e18);
        vm.prank(alice);
        vm.expectRevert(Splitter.NotExpired.selector);
        splitter.redeem(1e18, alice);

        vm.warp(expiry);
        assertTrue(splitter.isExpired());
        vm.prank(alice);
        uint256 out = splitter.redeem(5e18, bob);
        assertEq(out, 5e18);
        assertEq(stock.balanceOf(bob), 5e18);
        assertEq(pToken.totalSupply(), 0);
        assertEq(dToken.balanceOf(alice), 5e18); // D survives as a claim ticket

        vm.expectRevert(Splitter.ZeroAmount.selector);
        splitter.redeem(0, alice);
        vm.expectRevert(Splitter.ZeroAddress.selector);
        splitter.redeem(1, address(0));
    }

    function test_RejectsFeeOnTransferStock() public {
        MockFeeOnTransfer fot = new MockFeeOnTransfer();
        factory.listStock(address(fot), _stockCfg(rebaseAdapter));
        SplitterFactory.Market memory m = factory.createMarket(address(fot), expiry);
        fot.mint(alice, 1e18);
        vm.startPrank(alice);
        fot.approve(m.splitter, 1e18);
        vm.expectRevert(Splitter.TransferAmountMismatch.selector);
        Splitter(m.splitter).split(1e18, alice);
        vm.stopPrank();
    }

    function test_OnlySplitterMintsAndHookOnlyFromD() public {
        vm.expectRevert(PToken.OnlySplitter.selector);
        pToken.mint(alice, 1);
        vm.expectRevert(DToken.OnlySplitter.selector);
        dToken.mint(alice, 1);
        vm.expectRevert(PToken.OnlySplitter.selector);
        pToken.burn(alice, 1);
        vm.expectRevert(DToken.OnlySplitter.selector);
        dToken.burn(alice, 1);
        vm.expectRevert(Splitter.OnlyDToken.selector);
        splitter.onDTokenTransfer(alice, bob);
    }

    function test_CannotReinitialize() public {
        vm.expectRevert();
        splitter.initialize(address(factory), address(stock), expiry, 0, address(pToken), address(dToken));
    }

    // ------------------------------------------------------------------ multiplier dividends (Robinhood mechanism)

    function test_MultiplierDividendGoesToDHolders() public {
        _split(alice, 100e18);
        _bumpMultiplier(100); // 1% dividend reinvested
        splitter.harvest();

        // scale drops so P still represents the same number of shares
        assertApproxEqAbs(splitter.scale(), uint256(1e18) * 1e18 / 1.01e18, 1);
        (, uint256[] memory amounts) = splitter.claimable(alice);
        assertApproxEqAbs(amounts[0], 100e18 - splitter.principal(), 1);

        vm.prank(alice);
        uint256[] memory paid = splitter.claimDividends(alice);
        assertApproxEqAbs(paid[0], 0.990099009900990099e18, 1e3);
        assertEq(stock.balanceOf(alice), paid[0]);
        assertLe(splitter.totalPaid(address(stock)), splitter.totalDistributed(address(stock)));

        // merge after the dividend returns the post-dividend principal; pair + dividend == 1 stock
        vm.prank(alice);
        uint256 out = splitter.merge(100e18, alice);
        assertApproxEqAbs(out + paid[0], 100e18, 1);
    }

    function test_DividendsFollowDTokenNotP() public {
        _split(alice, 100e18);
        vm.prank(alice);
        dToken.transfer(bob, 50e18);
        _bumpMultiplier(200);
        splitter.harvest();
        (, uint256[] memory a) = splitter.claimable(alice);
        (, uint256[] memory b) = splitter.claimable(bob);
        assertApproxEqAbs(a[0], b[0], 2);

        // transferring after accrual does not move accrued dividends
        vm.prank(bob);
        dToken.transfer(carol, 50e18);
        (, uint256[] memory b2) = splitter.claimable(bob);
        (, uint256[] memory c2) = splitter.claimable(carol);
        assertEq(b2[0], b[0]);
        assertEq(c2[0], 0);
    }

    function test_FlashSplitAfterDividendGetsNothing() public {
        _split(alice, 100e18);
        _bumpMultiplier(100); // dividend lands, nobody harvested yet
        // attacker splits a huge amount hoping to dilute alice — split harvests first
        _split(carol, 10_000e18);
        splitter.harvest();
        (, uint256[] memory c) = splitter.claimable(carol);
        (, uint256[] memory a) = splitter.claimable(alice);
        assertEq(c[0], 0);
        assertApproxEqAbs(a[0], uint256(100e18) - uint256(100e18) * 1e18 / 1.01e18, 1e3);
    }

    function test_ForwardSplitViaMultiplierIsNeutral() public {
        _split(alice, 10e18);
        stock.setMultiplier(stock.uiMultiplier() * 2); // 2:1 split
        splitter.harvest();
        assertFalse(splitter.corporateActionPending());
        assertEq(splitter.scale(), 1e18);
        assertEq(splitter.adapterState(), 2e18);
        vm.prank(alice);
        assertEq(splitter.merge(10e18, alice), 10e18);
    }

    function test_ReverseSplitViaMultiplierIsNeutral() public {
        _split(alice, 10e18);
        stock.setMultiplier(stock.uiMultiplier() / 10);
        splitter.harvest();
        assertFalse(splitter.corporateActionPending());
        assertEq(splitter.scale(), 1e18);
    }

    function test_AmbiguousMultiplierChangeHalts() public {
        _split(alice, 10e18);
        _bumpMultiplier(2_000); // +20%: too big for a dividend, too small for a split
        splitter.harvest();
        assertTrue(splitter.corporateActionPending());

        stock.mint(alice, 1e18);
        vm.startPrank(alice);
        stock.approve(address(splitter), 1e18);
        vm.expectRevert(Splitter.CorporateActionIsPending.selector);
        splitter.split(1e18, alice);
        vm.expectRevert(Splitter.CorporateActionIsPending.selector);
        splitter.claimDividends(alice);
        vm.stopPrank();

        // harvest is a no-op while pending
        assertEq(uint8(splitter.harvest()), uint8(Splitter.HarvestStatus.CorporateAction));

        // only the timelock/admin can resolve
        uint256 m = stock.uiMultiplier();
        vm.prank(guardian);
        vm.expectRevert(Splitter.NotAdmin.selector);
        splitter.resolveCorporateAction(1e18, m);

        splitter.resolveCorporateAction(1e18, m);
        assertFalse(splitter.corporateActionPending());
        vm.expectRevert(Splitter.NoCorporateAction.selector);
        splitter.resolveCorporateAction(1e18, 0);
    }

    function test_ResolveRejectsZeroScale() public {
        _bumpMultiplier(2_000);
        splitter.harvest();
        vm.expectRevert(Splitter.ZeroAmount.selector);
        splitter.resolveCorporateAction(0, 0);
    }

    function test_SmallMultiplierDecreaseHalts() public {
        _split(alice, 10e18);
        stock.setMultiplier(0.99e18);
        splitter.harvest();
        assertTrue(splitter.corporateActionPending());
    }

    function test_ZeroMultiplierHalts() public {
        _split(alice, 10e18);
        stock.setMultiplier(0);
        splitter.harvest();
        assertTrue(splitter.corporateActionPending());
    }

    function test_IssuerOraclePauseDefers() public {
        _split(alice, 10e18);
        stock.setOraclePaused(true);
        assertEq(uint8(splitter.harvest()), uint8(Splitter.HarvestStatus.Deferred));
        stock.mint(alice, 1e18);
        vm.startPrank(alice);
        stock.approve(address(splitter), 1e18);
        vm.expectRevert(Splitter.IssuerUpdateInProgress.selector);
        splitter.split(1e18, alice);
        vm.expectRevert(Splitter.IssuerUpdateInProgress.selector);
        splitter.merge(1e18, alice);
        vm.stopPrank();
        stock.setOraclePaused(false);
        assertEq(uint8(splitter.harvest()), uint8(Splitter.HarvestStatus.Ok));
    }

    function test_StockDonationAboveThresholdHalts() public {
        _split(alice, 100e18);
        stock.mint(address(splitter), 6e18); // 6% > 5% max dividend
        splitter.harvest();
        assertTrue(splitter.corporateActionPending());
    }

    function test_StockShortfallHalts() public {
        _split(alice, 100e18);
        stock.burn(address(splitter), 1e18); // issuer clawback / reverse rebase
        splitter.harvest();
        assertTrue(splitter.corporateActionPending());
        // governance resolves with the reduced scale
        splitter.resolveCorporateAction(0.99e18, stock.uiMultiplier());
        vm.prank(alice);
        assertEq(splitter.merge(100e18, alice), 99e18);
    }

    function test_DividendWithNoHoldersIsSwept() public {
        stock.mint(address(splitter), 5e18);
        splitter.harvest();
        assertEq(stock.balanceOf(address(feeCollector)), 5e18);
    }

    function test_AdapterCannotIncreaseScale() public {
        BadAdapter bad = new BadAdapter();
        factory.updateStockConfig(address(stock), _stockCfg(IDividendAdapter(address(bad))));
        stock.mint(alice, 1e18);
        vm.startPrank(alice);
        stock.approve(address(splitter), 1e18);
        vm.expectRevert(Splitter.CorporateActionIsPending.selector);
        splitter.split(1e18, alice);
        vm.stopPrank();
        splitter.harvest();
        assertTrue(splitter.corporateActionPending());
    }

    // ------------------------------------------------------------------ rebase + airdrop adapters

    function test_RebaseDividends() public {
        factory.updateStockConfig(address(stock), _stockCfg(rebaseAdapter));
        _split(alice, 100e18);
        stock.mint(address(splitter), 2e18); // 2% rebase
        splitter.harvest();
        vm.prank(alice);
        uint256[] memory paid = splitter.claimDividends(alice);
        assertApproxEqAbs(paid[0], 2e18, 1e3);
        vm.prank(alice);
        assertEq(splitter.merge(100e18, alice), 100e18); // merge still returns exactly one stock per pair
    }

    function test_RebaseSplitHaltsAndResolves() public {
        factory.updateStockConfig(address(stock), _stockCfg(rebaseAdapter));
        _split(alice, 100e18);
        stock.mint(address(splitter), 100e18); // 2:1 rebasing split
        splitter.harvest();
        assertTrue(splitter.corporateActionPending());
        splitter.resolveCorporateAction(2e18, 0);
        vm.prank(alice);
        assertEq(splitter.merge(100e18, alice), 200e18);
    }

    function test_AirdropDividendsAndPull() public {
        MockERC20 cash = new MockERC20("Cash", "CASH", 6);
        MockDistributor dist = new MockDistributor(cash);
        cash.mint(address(dist), 1_000e6);
        airdropAdapter.configure(address(stock), address(cash), address(dist));
        factory.updateStockConfig(address(stock), _stockCfg(airdropAdapter));

        _split(alice, 60e18);
        _split(bob, 40e18);
        assertTrue(splitter.isRewardToken(address(cash)));

        // pushed airdrop
        cash.mint(address(splitter), 100e6);
        // pulled airdrop
        vm.prank(keeper);
        splitter.pullDividends(abi.encodeCall(MockDistributor.claim, (address(splitter), 50e6)));
        splitter.harvest();

        vm.prank(alice);
        uint256[] memory a = splitter.claimDividends(alice);
        vm.prank(bob);
        uint256[] memory b = splitter.claimDividends(bob);
        assertEq(a[1], 90e6);
        assertEq(b[1], 60e6);
    }

    function test_PullDividendsGuards() public {
        vm.prank(alice);
        vm.expectRevert(Splitter.NotKeeper.selector);
        splitter.pullDividends("");

        // multiplier adapter has no claim target
        vm.prank(keeper);
        vm.expectRevert(Splitter.InvalidTarget.selector);
        splitter.pullDividends("");

        MockERC20 cash = new MockERC20("Cash", "CASH", 6);
        MockDistributor dist = new MockDistributor(cash);
        airdropAdapter.configure(address(stock), address(cash), address(dist));
        factory.updateStockConfig(address(stock), _stockCfg(airdropAdapter));
        vm.prank(keeper);
        vm.expectRevert(Splitter.PullFailed.selector);
        splitter.pullDividends(abi.encodeCall(MockDistributor.fail, ()));
    }

    function test_PullCannotDrainStock() public {
        MockERC20 cash = new MockERC20("Cash", "CASH", 6);
        EvilDistributor evil = new EvilDistributor();
        airdropAdapter.configure(address(stock), address(cash), address(evil));
        factory.updateStockConfig(address(stock), _stockCfg(airdropAdapter));
        _split(alice, 1e18);
        // splitter never approves anyone, so transferFrom fails -> PullFailed
        vm.prank(keeper);
        vm.expectRevert(Splitter.PullFailed.selector);
        splitter.pullDividends(abi.encodeCall(EvilDistributor.steal, (stock, address(splitter), keeper)));
    }

    function test_AirdropAdapterConfig() public {
        vm.prank(alice);
        vm.expectRevert();
        airdropAdapter.configure(address(stock), address(usdg), address(0));
        vm.expectRevert(AirdropDividendAdapter.ZeroAddress.selector);
        airdropAdapter.configure(address(stock), address(stock), address(0));
        assertEq(airdropAdapter.mechanism(), keccak256("AIRDROP"));
        assertEq(rebaseAdapter.mechanism(), keccak256("REBASE"));
        assertEq(multAdapter.mechanism(), keccak256("MULTIPLIER"));
        assertEq(noneAdapter.mechanism(), keccak256("NONE"));
        assertEq(noneAdapter.payoutToken(address(stock)), address(0));
        assertEq(noneAdapter.claimTarget(address(stock)), address(0));
        assertEq(noneAdapter.initialState(address(stock)), 0);
        assertEq(rebaseAdapter.payoutToken(address(stock)), address(0));
        assertEq(rebaseAdapter.claimTarget(address(stock)), address(0));
        assertEq(rebaseAdapter.initialState(address(stock)), 0);
        assertEq(airdropAdapter.initialState(address(stock)), 0);
        assertEq(multAdapter.payoutToken(address(stock)), address(0));
        assertEq(multAdapter.claimTarget(address(stock)), address(0));
        IDividendAdapter.Assessment memory a = noneAdapter.assess(address(stock), 1e18, 7, 500);
        assertEq(a.newScale, 1e18);
        assertEq(a.newState, 7);
    }

    function test_NoDividendAdapterKeepsDividendsUnassigned() public {
        factory.updateStockConfig(address(stock), _stockCfg(noneAdapter));
        _split(alice, 10e18);
        stock.mint(address(splitter), 0.1e18);
        splitter.harvest(); // balance increases are still measured generically
        (, uint256[] memory a) = splitter.claimable(alice);
        assertApproxEqAbs(a[0], 0.1e18, 10);
    }

    // ------------------------------------------------------------------ cutoff / post-cutoff

    function test_TrailingWindowThenPostCutoffToP() public {
        _split(alice, 100e18);
        vm.prank(alice);
        pToken.transfer(bob, 100e18); // bob holds P, alice holds D
        vm.warp(expiry + 1 days);
        _bumpMultiplier(100); // trailing dividend -> D
        splitter.harvest();
        (, uint256[] memory a) = splitter.claimable(alice);
        assertGt(a[0], 0);

        vm.warp(splitter.dividendCutoff());
        uint256 scaleBefore = splitter.scale();
        _bumpMultiplier(100); // after cutoff -> stays with P
        splitter.harvest();
        assertApproxEqAbs(splitter.scale(), scaleBefore, 1e3);
        (, uint256[] memory a2) = splitter.claimable(alice);
        assertEq(a2[0], a[0]);

        vm.prank(bob);
        uint256 out = splitter.redeem(100e18, bob);
        assertApproxEqAbs(out, uint256(100e18) * 1e18 / 1.01e18, 1e4);
    }

    function test_PostCutoffAirdropPaidOnRedeem() public {
        MockERC20 cash = new MockERC20("Cash", "CASH", 6);
        airdropAdapter.configure(address(stock), address(cash), address(0));
        factory.updateStockConfig(address(stock), _stockCfg(airdropAdapter));
        _split(alice, 100e18);
        vm.prank(alice);
        pToken.transfer(bob, 60e18);
        vm.warp(splitter.dividendCutoff() + 1);
        cash.mint(address(splitter), 100e6);
        splitter.harvest();
        vm.prank(bob);
        splitter.redeem(60e18, bob);
        assertEq(cash.balanceOf(bob), 60e6);
        vm.prank(alice);
        splitter.redeem(40e18, alice);
        assertEq(cash.balanceOf(alice), 40e6);
        assertEq(splitter.reserved(address(cash)), 0);
    }

    function test_PostCutoffWithNoPSweeps() public {
        _split(alice, 1e18);
        vm.warp(splitter.dividendCutoff());
        vm.prank(alice);
        splitter.redeem(1e18, alice);
        stock.mint(address(splitter), 1e15);
        splitter.harvest();
        assertEq(stock.balanceOf(address(feeCollector)), 1e15);
    }

    function test_PostCutoffDustStockStays() public {
        _split(alice, 10e18);
        vm.warp(splitter.dividendCutoff());
        // amount so small that the per-unit increment rounds to zero
        stock.mint(address(splitter), 1);
        splitter.harvest();
        assertEq(splitter.scale(), 1e18);
    }

    // ------------------------------------------------------------------ blackout / keeper

    function test_BlackoutBlocksSplitOnly() public {
        _split(alice, 10e18);
        uint64 ex = uint64(block.timestamp + 5 days);
        vm.prank(keeper);
        splitter.announceDividend(ex, ex + 10 days, 0.26e6);
        assertEq(splitter.noticeCount(), 1);
        assertEq(splitter.notice(0).exDate, ex);

        vm.warp(ex - 1 days);
        assertTrue(splitter.inBlackout());
        stock.mint(bob, 1e18);
        vm.startPrank(bob);
        stock.approve(address(splitter), 1e18);
        vm.expectRevert(Splitter.InBlackout.selector);
        splitter.split(1e18, bob);
        vm.stopPrank();
        // merge still allowed
        vm.prank(alice);
        splitter.merge(1e18, alice);

        vm.warp(ex + 10 days);
        assertFalse(splitter.inBlackout());
    }

    function test_BlackoutExtendsAndGuards() public {
        uint64 ex = uint64(block.timestamp + 5 days);
        vm.startPrank(keeper);
        splitter.announceDividend(ex, ex + 10 days, 0);
        splitter.announceDividend(ex + 5 days, ex + 20 days, 0); // overlapping -> union
        assertEq(splitter.blackoutEnd(), ex + 20 days);
        vm.expectRevert(Splitter.InvalidNotice.selector);
        splitter.announceDividend(ex + 6 days, ex + 50 days, 0); // too long
        vm.expectRevert(Splitter.InvalidNotice.selector);
        splitter.announceDividend(uint64(block.timestamp), uint64(block.timestamp) + 1, 0); // ex in past
        vm.expectRevert(Splitter.InvalidNotice.selector);
        splitter.announceDividend(ex, ex - 1, 0);
        vm.stopPrank();

        // union may not exceed the cap either
        vm.prank(keeper);
        vm.expectRevert(Splitter.InvalidNotice.selector);
        splitter.announceDividend(ex + 21 days, ex + 60 days, 0);

        vm.prank(alice);
        vm.expectRevert(Splitter.NotKeeper.selector);
        splitter.announceDividend(ex, ex, 0);

        vm.prank(alice);
        vm.expectRevert(Splitter.NotGuardian.selector);
        splitter.clearBlackout();
        vm.prank(guardian);
        splitter.clearBlackout();
        assertEq(splitter.blackoutEnd(), 0);
    }

    function test_SeparateBlackoutReplaces() public {
        uint64 ex = uint64(block.timestamp + 5 days);
        vm.prank(keeper);
        splitter.announceDividend(ex, ex + 2 days, 0);
        vm.warp(ex + 3 days);
        vm.prank(keeper);
        splitter.announceDividend(ex + 30 days, ex + 32 days, 0);
        assertEq(splitter.blackoutStart(), ex + 29 days);
    }

    // ------------------------------------------------------------------ pause / admin

    function test_PauseFlow() public {
        _split(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(Splitter.NotGuardian.selector);
        splitter.pause();
        vm.prank(guardian);
        splitter.pause();
        vm.prank(alice);
        vm.expectRevert(Splitter.IsPaused.selector);
        splitter.merge(1e18, alice);
        // claims still work while paused
        vm.prank(alice);
        splitter.claimDividends(alice);

        vm.prank(guardian);
        vm.expectRevert(Splitter.NotAdmin.selector);
        splitter.unpause();
        splitter.unpause();
        vm.prank(alice);
        splitter.merge(1e18, alice);
    }

    function test_GlobalPause() public {
        vm.prank(guardian);
        factory.pauseAll();
        stock.mint(alice, 1e18);
        vm.startPrank(alice);
        stock.approve(address(splitter), 1e18);
        vm.expectRevert(Splitter.IsPaused.selector);
        splitter.split(1e18, alice);
        vm.stopPrank();
        factory.unpauseAll();
        _split(alice, 1e18);
    }

    function test_AddRewardTokenAndRescue() public {
        MockERC20 junk = new MockERC20("Junk", "J", 18);
        junk.mint(address(splitter), 5);
        vm.expectRevert(Splitter.ProtectedToken.selector);
        splitter.rescueToken(address(stock), alice, 1);
        vm.expectRevert(Splitter.ProtectedToken.selector);
        splitter.rescueToken(address(pToken), alice, 1);
        splitter.rescueToken(address(junk), alice, 5);
        assertEq(junk.balanceOf(alice), 5);

        vm.expectRevert(Splitter.ProtectedToken.selector);
        splitter.addRewardToken(address(dToken));
        splitter.addRewardToken(address(junk));
        vm.expectRevert(Splitter.ProtectedToken.selector);
        splitter.rescueToken(address(junk), alice, 1);
        splitter.addRewardToken(address(usdg));
        splitter.addRewardToken(address(new MockERC20("a", "a", 18)));
        address extra = address(new MockERC20("b", "b", 18));
        vm.expectRevert(DividendAccumulator.TooManyRewardTokens.selector);
        splitter.addRewardToken(extra);
        assertEq(splitter.rewardTokens().length, 4);

        vm.prank(alice);
        vm.expectRevert(Splitter.NotAdmin.selector);
        splitter.addRewardToken(address(1));
    }

    function test_ClaimZeroAddressReverts() public {
        vm.expectRevert(Splitter.ZeroAddress.selector);
        splitter.claimDividends(address(0));
    }

    function test_PendingStockDividendView() public {
        _split(alice, 100e18);
        stock.mint(address(splitter), 1e18);
        assertEq(splitter.pendingStockDividend(), 1e18);
        stock.burn(address(splitter), 2e18);
        assertEq(splitter.pendingStockDividend(), 0);
    }

    // ------------------------------------------------------------------ compliance

    function test_ComplianceGatesSplitButNotRedeem() public {
        _split(alice, 2e18);
        compliance.setEnabled(true);
        stock.mint(alice, 1e18);
        vm.startPrank(alice);
        stock.approve(address(splitter), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SplitterFactory.NotCompliant.selector, alice, keccak256("SPLIT")));
        splitter.split(1e18, alice);
        vm.expectRevert(abi.encodeWithSelector(SplitterFactory.NotCompliant.selector, alice, keccak256("MERGE")));
        splitter.merge(1e18, alice);
        vm.stopPrank();

        address[] memory list = new address[](1);
        list[0] = alice;
        compliance.setAllowed(list, true);
        vm.prank(alice);
        splitter.split(1e18, alice);

        compliance.setAllowed(list, false);
        vm.warp(expiry);
        vm.prank(alice);
        splitter.redeem(3e18, alice); // exits never gated
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_SplitMergeRoundTrip(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        uint256 units = _split(alice, amount);
        assertEq(units, amount);
        assertEq(pToken.totalSupply(), dToken.totalSupply());
        assertEq(stock.balanceOf(address(splitter)), pToken.totalSupply());
        vm.prank(alice);
        assertEq(splitter.merge(units, alice), amount);
    }

    function testFuzz_DividendsProRata(uint256 a, uint256 b, uint256 bps) public {
        a = bound(a, 1e12, 1e27);
        b = bound(b, 1e12, 1e27);
        bps = bound(bps, 1, 500);
        _split(alice, a);
        _split(bob, b);
        _bumpMultiplier(bps);
        splitter.harvest();
        vm.prank(alice);
        uint256 pa = splitter.claimDividends(alice)[0];
        vm.prank(bob);
        uint256 pb = splitter.claimDividends(bob)[0];
        uint256 distributed = splitter.totalDistributed(address(stock));
        assertLe(pa + pb, distributed);
        assertApproxEqAbs(pa + pb, distributed, 2);
        assertGe(stock.balanceOf(address(splitter)), splitter.principal() + splitter.reserved(address(stock)));
    }
}


/// @dev Adapter that illegally tries to increase scale.
contract BadAdapter is IDividendAdapter {
    function mechanism() external pure returns (bytes32) {
        return "BAD";
    }

    function payoutToken(address) external pure returns (address) {
        return address(0);
    }

    function initialState(address) external pure returns (uint256) {
        return 0;
    }

    function claimTarget(address) external pure returns (address) {
        return address(0);
    }

    function assess(address, uint256 scale, uint256, uint256) external pure returns (Assessment memory a) {
        a.newScale = scale + 1;
    }
}
