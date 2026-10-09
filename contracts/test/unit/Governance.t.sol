// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ProjectTokenHooks} from "../../src/governance/ProjectTokenHooks.sol";
import {FeeCollector} from "../../src/governance/FeeCollector.sol";
import {ComplianceRegistry} from "../../src/governance/ComplianceRegistry.sol";
import {DivsplitTimelock} from "../../src/governance/DivsplitTimelock.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {IAggregatorV3} from "../../src/interfaces/IOracleAdapter.sol";
import {MockERC20, MockFeed} from "../mocks/Mocks.sol";

contract ProjectTokenHooksTest is Base {
    MockERC20 internal divs; // MOCK project token (tests only)

    function setUp() public override {
        super.setUp();
        divs = new MockERC20("Mock DIVS", "mDIVS", 18);
        divs.mint(alice, 1_000e18);
        divs.mint(bob, 3_000e18);
        vm.prank(alice);
        divs.approve(address(hooks), type(uint256).max);
        vm.prank(bob);
        divs.approve(address(hooks), type(uint256).max);
    }

    function test_DisabledUntilTokenSet() public {
        assertFalse(hooks.isActive());
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.TokenFeaturesDisabled.selector);
        hooks.stake(1e18);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.TokenFeaturesDisabled.selector);
        hooks.unstake(1e18);
        vm.expectRevert(ProjectTokenHooks.TokenFeaturesDisabled.selector);
        hooks.propose(ProjectTokenHooks.ProposalKind.ListStock, address(stock), 0, "x");
        vm.expectRevert(ProjectTokenHooks.TokenFeaturesDisabled.selector);
        hooks.castVote(0, true);

        // fees go 100% to treasury while disabled
        usdg.mint(address(feeCollector), 100e6);
        feeCollector.distribute(address(usdg));
        assertEq(usdg.balanceOf(treasury), 100e6);
    }

    function test_SetProjectTokenOnceByAdminOnly() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        hooks.setProjectToken(address(divs));
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        hooks.setProjectToken(address(0));
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        hooks.setProjectToken(alice); // EOA, no code
        hooks.setProjectToken(address(divs));
        assertEq(address(hooks.projectToken()), address(divs));
        vm.expectRevert(ProjectTokenHooks.ProjectTokenAlreadySet.selector);
        hooks.setProjectToken(address(usdg));
    }

    function test_StakersEarnStreamedFees() public {
        hooks.setProjectToken(address(divs));
        hooks.addRewardToken(address(usdg));
        vm.prank(alice);
        hooks.stake(100e18);
        vm.prank(bob);
        hooks.stake(300e18);
        assertTrue(hooks.isActive());

        usdg.mint(address(feeCollector), 1_000e6);
        (uint256 toStakers, uint256 toTreasury) = feeCollector.distribute(address(usdg));
        assertEq(toStakers, 500e6);
        assertEq(toTreasury, 500e6);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        hooks.claimRewards();
        vm.prank(bob);
        hooks.claimRewards();
        assertApproxEqRel(usdg.balanceOf(alice), 125e6, 1e15);
        assertApproxEqRel(usdg.balanceOf(bob), 375e6, 1e15);

        // second notification mid-stream rolls leftover
        usdg.mint(address(feeCollector), 200e6);
        feeCollector.distribute(address(usdg));
        vm.warp(block.timestamp + 1 days);
        usdg.mint(address(feeCollector), 200e6);
        feeCollector.distribute(address(usdg));
        vm.warp(block.timestamp + 8 days);
        assertApproxEqRel(hooks.earned(alice, address(usdg)) + hooks.earned(bob, address(usdg)), 200e6, 1e15);

        vm.prank(alice);
        hooks.unstake(100e18);
        assertEq(divs.balanceOf(alice), 1_000e18);
        assertEq(hooks.totalStaked(), 300e18);
    }

    function test_NonRewardTokenFeesGoToTreasury() public {
        hooks.setProjectToken(address(divs));
        vm.prank(alice);
        hooks.stake(1e18);
        MockERC20 junk = new MockERC20("J", "J", 18);
        junk.mint(address(feeCollector), 10);
        feeCollector.distribute(address(junk));
        assertEq(junk.balanceOf(treasury), 10);
        (uint256 a, uint256 b) = feeCollector.distribute(address(junk));
        assertEq(a + b, 0);
    }

    function test_NotifyGuards() public {
        vm.expectRevert(ProjectTokenHooks.OnlyFeeCollector.selector);
        hooks.notifyRewardAmount(address(usdg), 1);
        vm.prank(address(feeCollector));
        vm.expectRevert(ProjectTokenHooks.NotRewardToken.selector);
        hooks.notifyRewardAmount(address(usdg), 1);
        hooks.addRewardToken(address(usdg));
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        hooks.addRewardToken(address(usdg));
        for (uint256 i; i < 7; ++i) {
            hooks.addRewardToken(address(new MockERC20("r", "r", 18)));
        }
        address extra = address(new MockERC20("r", "r", 18));
        vm.expectRevert(ProjectTokenHooks.TooManyRewardTokens.selector);
        hooks.addRewardToken(extra);
        assertEq(hooks.rewardTokenCount(), 8);
        hooks.setFeeCollector(alice);
        assertEq(hooks.feeCollector(), alice);
    }

    function test_StakeZeroReverts() public {
        hooks.setProjectToken(address(divs));
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.stake(0);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.unstake(0);
    }

    function test_AdvisoryVoting() public {
        hooks.setProjectToken(address(divs));
        hooks.setGovernanceParams(3 days, 50e18, 1_000);
        vm.prank(alice);
        hooks.stake(100e18);
        vm.prank(bob);
        hooks.stake(300e18);
        vm.warp(block.timestamp + 1);

        vm.prank(carol);
        vm.expectRevert(ProjectTokenHooks.BelowProposalThreshold.selector);
        hooks.propose(ProjectTokenHooks.ProposalKind.ListStock, address(stock), 0, "list");

        vm.prank(alice);
        uint256 id = hooks.propose(ProjectTokenHooks.ProposalKind.AddExpiry, address(stock), expiry, "add Q1");
        assertEq(hooks.proposalCount(), 1);
        assertEq(uint8(hooks.state(id)), uint8(ProjectTokenHooks.ProposalState.Active));

        // flash-stake after snapshot gives no power
        divs.mint(carol, 10_000e18);
        vm.startPrank(carol);
        divs.approve(address(hooks), type(uint256).max);
        hooks.stake(10_000e18);
        vm.expectRevert(ProjectTokenHooks.NoVotingPower.selector);
        hooks.castVote(id, false);
        vm.stopPrank();

        vm.prank(alice);
        hooks.castVote(id, true);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.AlreadyVoted.selector);
        hooks.castVote(id, true);
        vm.prank(bob);
        hooks.castVote(id, false);

        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(hooks.state(id)), uint8(ProjectTokenHooks.ProposalState.Defeated));
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.VotingClosed.selector);
        hooks.castVote(id, true);

        vm.prank(carol);
        hooks.unstake(10_000e18);
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        uint256 id2 = hooks.propose(ProjectTokenHooks.ProposalKind.ListStock, address(usdg), 0, "list");
        vm.prank(bob);
        hooks.castVote(id2, true);
        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(hooks.state(id2)), uint8(ProjectTokenHooks.ProposalState.Succeeded));
        assertEq(hooks.proposal(id2).proposer, bob);
        assertEq(hooks.stakeAt(bob, uint48(block.timestamp)), 300e18);
        assertEq(hooks.totalStakeAt(uint48(block.timestamp)), 400e18);

        vm.expectRevert(ProjectTokenHooks.UnknownProposal.selector);
        hooks.castVote(99, true);
        vm.expectRevert(ProjectTokenHooks.UnknownProposal.selector);
        hooks.state(99);
        vm.expectRevert(ProjectTokenHooks.InvalidParams.selector);
        hooks.setGovernanceParams(1 hours, 0, 0);
    }
}

contract FeeCollectorTest is Base {
    function test_AdminSetters() public {
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        feeCollector.setTreasury(address(0));
        feeCollector.setTreasury(bob);
        assertEq(feeCollector.treasury(), bob);
        vm.expectRevert(FeeCollector.InvalidBps.selector);
        feeCollector.setStakerShareBps(10_001);
        feeCollector.setStakerShareBps(10_000);
        assertEq(feeCollector.stakerShareBps(), 10_000);
        vm.prank(alice);
        vm.expectRevert();
        feeCollector.setHooks(address(0));
    }

    function test_ConstructorGuards() public {
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(address(0), treasury, 0);
        vm.expectRevert(FeeCollector.InvalidBps.selector);
        new FeeCollector(admin, treasury, 10_001);
    }
}

contract ComplianceTest is Base {
    function test_Registry() public {
        bytes32 act = keccak256("SPLIT");
        assertTrue(compliance.isAllowed(alice, act)); // off by default
        compliance.setEnabled(true);
        assertFalse(compliance.isAllowed(alice, act));
        address[] memory a = new address[](1);
        a[0] = alice;
        vm.prank(bob);
        vm.expectRevert();
        compliance.setAllowed(a, true);
        compliance.grantRole(compliance.COMPLIANCE_MANAGER_ROLE(), bob);
        vm.prank(bob);
        compliance.setAllowed(a, true);
        assertTrue(compliance.isAllowed(alice, act));
        compliance.setActionOpen(act, true);
        assertTrue(compliance.isAllowed(carol, act));
        address[] memory big = new address[](201);
        vm.expectRevert(ComplianceRegistry.BatchTooLarge.selector);
        compliance.setAllowed(big, true);
    }
}

contract TimelockTest is Base {
    function test_TimelockFloor() public {
        address[] memory p = new address[](1);
        p[0] = admin;
        vm.expectRevert(DivsplitTimelock.DelayTooShort.selector);
        new DivsplitTimelock(1 days, p, p);
        DivsplitTimelock t = new DivsplitTimelock(48 hours, p, new address[](0));
        assertEq(t.getMinDelay(), 48 hours);
    }

    function test_FactoryAdminThroughTimelock() public {
        address[] memory p = new address[](1);
        p[0] = admin;
        address[] memory e = new address[](1);
        e[0] = address(0);
        DivsplitTimelock t = new DivsplitTimelock(48 hours, p, e);
        factory.grantRole(0x00, address(t));
        factory.renounceRole(0x00, admin);

        vm.expectRevert();
        factory.setFees(10, 0);

        bytes memory data = abi.encodeCall(factory.setFees, (10, 0));
        t.schedule(address(factory), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.expectRevert();
        t.execute(address(factory), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(alice); // open executor
        t.execute(address(factory), 0, data, bytes32(0), bytes32(0));
        assertEq(factory.swapFeeBps(), 10);
    }
}

contract OracleAdapterTest is Base {
    MockFeed internal second;

    function setUp() public override {
        super.setUp();
        second = new MockFeed(18, 251e18);
    }

    function _cfg(address p, address s, uint16 dev, uint16 jump) internal pure returns (OracleAdapter.FeedConfig memory) {
        return OracleAdapter.FeedConfig(IAggregatorV3(p), IAggregatorV3(s), 1 days, dev, jump);
    }

    function test_PrimaryPrice() public view {
        assertEq(oracle.getPrice(address(stock)), 250e18);
        assertTrue(oracle.hasFeed(address(stock)));
        assertEq(address(oracle.feedConfig(address(stock)).primary), address(stockFeed));
    }

    function test_NoFeed() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoFeed.selector, alice));
        oracle.getPrice(alice);
    }

    function test_Stale() public {
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, address(stock), START));
        oracle.getPrice(address(stock));
        stockFeed.setWithTime(1e8, block.timestamp + 1); // future timestamp
        vm.expectPartialRevert(OracleAdapter.StalePrice.selector);
        oracle.getPrice(address(stock));
    }

    function test_InvalidPrice() public {
        stockFeed.set(0);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(stock)));
        oracle.getPrice(address(stock));
    }

    function test_SecondaryDeviation() public {
        oracle.setFeed(address(stock), _cfg(address(stockFeed), address(second), 100, 0));
        assertEq(oracle.getPrice(address(stock)), 250e18); // 0.4% apart, ok
        second.set(260e18);
        vm.expectPartialRevert(OracleAdapter.PriceDeviation.selector);
        oracle.getPrice(address(stock));
    }

    function test_RoundJump() public {
        oracle.setFeed(address(stock), _cfg(address(stockFeed), address(0), 0, 1_000));
        stockFeed.set(260e8); // +4%
        assertEq(oracle.getPrice(address(stock)), 260e18);
        stockFeed.set(320e8); // +23%
        vm.expectPartialRevert(OracleAdapter.PriceDeviation.selector);
        oracle.getPrice(address(stock));
    }

    function test_Sequencer() public {
        MockFeed seq = new MockFeed(0, 0);
        oracle.setSequencerUptimeFeed(address(seq), 1 hours);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        oracle.getPrice(address(stock)); // within grace period
        vm.warp(block.timestamp + 2 hours);
        stockFeed.set(250e8);
        assertEq(oracle.getPrice(address(stock)), 250e18);
        seq.set(1);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        oracle.getPrice(address(stock));
    }

    function test_DecimalsAbove18() public {
        MockFeed f = new MockFeed(20, 250e20);
        oracle.setFeed(alice, _cfg(address(f), address(0), 0, 0));
        assertEq(oracle.getPrice(alice), 250e18);
    }

    function test_ConfigGuards() public {
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(0), _cfg(address(stockFeed), address(0), 0, 0));
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(alice, _cfg(address(0), address(0), 0, 0));
        OracleAdapter.FeedConfig memory c = _cfg(address(stockFeed), address(0), 0, 0);
        c.maxStaleness = 8 days;
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(alice, c);
        vm.prank(alice);
        vm.expectRevert();
        oracle.setFeed(alice, _cfg(address(stockFeed), address(0), 0, 0));
    }
}
