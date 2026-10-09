// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base} from "../Base.t.sol";
import {Splitter} from "../../src/core/Splitter.sol";
import {PToken} from "../../src/core/PToken.sol";
import {DToken} from "../../src/core/DToken.sol";
import {MockScaledStock} from "../mocks/Mocks.sol";

contract SplitterHandler is Test {
    Splitter internal splitter;
    PToken internal pToken;
    DToken internal dToken;
    MockScaledStock internal stock;
    uint64 internal expiry;
    address[] internal actors;

    uint256 public ghost_mergeMismatch;
    uint256 public ghost_dividendsInjected;
    uint256 public ghost_claimed;
    uint256 public ghost_calls;

    constructor(Splitter s, MockScaledStock st, uint64 exp) {
        splitter = s;
        pToken = s.pToken();
        dToken = s.dToken();
        stock = st;
        expiry = exp;
        actors.push(makeAddr("a1"));
        actors.push(makeAddr("a2"));
        actors.push(makeAddr("a3"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function split(uint256 seed, uint256 amount) external {
        if (block.timestamp >= expiry) return;
        amount = bound(amount, 1, 1e24);
        address a = _actor(seed);
        stock.mint(a, amount);
        vm.startPrank(a);
        stock.approve(address(splitter), amount);
        splitter.split(amount, a);
        vm.stopPrank();
        ghost_calls++;
    }

    function merge(uint256 seed, uint256 amount) external {
        if (block.timestamp >= expiry) return;
        address a = _actor(seed);
        uint256 maxU = pToken.balanceOf(a) < dToken.balanceOf(a) ? pToken.balanceOf(a) : dToken.balanceOf(a);
        if (maxU == 0) return;
        amount = bound(amount, 1, maxU);
        splitter.harvest();
        uint256 expected = amount * splitter.scale() / 1e18;
        uint256 before = stock.balanceOf(a);
        vm.prank(a);
        uint256 out = splitter.merge(amount, a);
        if (out != expected || stock.balanceOf(a) - before != expected) ghost_mergeMismatch++;
        // with no reinvested dividends yet, one pair returns exactly one stock
        if (splitter.scale() == 1e18 && out != amount) ghost_mergeMismatch++;
        ghost_calls++;
    }

    function transferD(uint256 from, uint256 to, uint256 amount) external {
        address f = _actor(from);
        uint256 bal = dToken.balanceOf(f);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(f);
        dToken.transfer(_actor(to), amount);
    }

    function transferP(uint256 from, uint256 to, uint256 amount) external {
        address f = _actor(from);
        uint256 bal = pToken.balanceOf(f);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(f);
        pToken.transfer(_actor(to), amount);
    }

    function reinvestDividend(uint256 bps) external {
        if (pToken.totalSupply() == 0) return;
        bps = bound(bps, 1, 300);
        stock.setMultiplier(stock.uiMultiplier() * (10_000 + bps) / 10_000);
        splitter.harvest();
    }

    function rebaseDividend(uint256 amount) external {
        uint256 principal = splitter.principal();
        if (principal < 1e6) return;
        amount = bound(amount, 1, principal / 100);
        stock.mint(address(splitter), amount);
        ghost_dividendsInjected += amount;
        splitter.harvest();
    }

    function claim(uint256 seed) external {
        address a = _actor(seed);
        vm.prank(a);
        uint256[] memory amts = splitter.claimDividends(a);
        ghost_claimed += amts[0];
    }

    function redeem(uint256 seed, uint256 amount) external {
        if (block.timestamp < expiry) return;
        address a = _actor(seed);
        uint256 bal = pToken.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(a);
        splitter.redeem(amount, a);
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 10 days);
        vm.warp(block.timestamp + secs);
    }
}

contract SplitterInvariantTest is Base {
    SplitterHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SplitterHandler(splitter, stock, expiry);
        targetContract(address(handler));
    }

    /// P supply == D supply before expiry.
    function invariant_PSupplyEqualsDSupply() public view {
        if (block.timestamp < expiry) assertEq(pToken.totalSupply(), dToken.totalSupply());
    }

    /// Stock held covers principal owed to P plus dividends owed to D.
    function invariant_StockBacksPrincipal() public view {
        assertFalse(splitter.corporateActionPending());
        assertGe(stock.balanceOf(address(splitter)), splitter.principal() + splitter.reserved(address(stock)));
    }

    /// While no dividend has been reinvested: P supply == D supply == stock held as principal.
    function invariant_UnitsEqualStockWhenScaleOne() public view {
        if (splitter.scale() == 1e18 && block.timestamp < expiry) {
            assertEq(splitter.principal(), pToken.totalSupply());
        }
    }

    /// Total dividends paid never exceed dividends received; bookkeeping is exact.
    function invariant_PaidLeDistributed() public view {
        address s = address(stock);
        assertLe(splitter.totalPaid(s), splitter.totalDistributed(s));
        assertEq(splitter.reserved(s), splitter.totalDistributed(s) - splitter.totalPaid(s));
        assertLe(handler.ghost_claimed(), splitter.totalDistributed(s));
    }

    /// Sum of claimable amounts never exceeds what is reserved for holders.
    function invariant_ClaimableLeReserved() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            (, uint256[] memory amts) = splitter.claimable(handler.actorAt(i));
            sum += amts[0];
        }
        assertLe(sum, splitter.reserved(address(stock)));
    }

    /// Merge always returns exactly `units * scale` (exactly one stock per pair while scale == 1).
    function invariant_MergeExact() public view {
        assertEq(handler.ghost_mergeMismatch(), 0);
    }
}
