// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MultiplierDividendAdapter} from "../../src/adapters/MultiplierDividendAdapter.sol";
import {IDividendAdapter} from "../../src/interfaces/IDividendAdapter.sol";

/// @dev ERC-8056 token without the issuer `oraclePaused()` extension.
contract PlainScaled {
    uint256 public uiMultiplier = 1e18;

    function set(uint256 m) external {
        uiMultiplier = m;
    }
}

contract MultiplierAdapterTest is Test {
    MultiplierDividendAdapter internal a = new MultiplierDividendAdapter();
    PlainScaled internal t = new PlainScaled();

    function test_WorksWithoutOraclePausedExtension() public {
        assertEq(a.initialState(address(t)), 1e18);
        t.set(1.01e18);
        IDividendAdapter.Assessment memory r = a.assess(address(t), 1e18, 1e18, 500);
        assertFalse(r.deferred);
        assertFalse(r.corporateAction);
        assertEq(r.newState, 1.01e18);
        assertEq(r.newScale, uint256(1e18) * 1e18 / 1.01e18);
    }

    function test_Classification() public {
        // unchanged
        IDividendAdapter.Assessment memory r = a.assess(address(t), 1e18, 1e18, 500);
        assertEq(r.newScale, 1e18);
        // 3:1 forward split
        t.set(3e18);
        r = a.assess(address(t), 1e18, 1e18, 500);
        assertFalse(r.corporateAction);
        assertEq(r.newScale, 1e18);
        // 1:2 reverse split
        t.set(0.5e18);
        r = a.assess(address(t), 1e18, 1e18, 500);
        assertFalse(r.corporateAction);
        // +10% with a 5% dividend bound -> ambiguous
        t.set(1.1e18);
        r = a.assess(address(t), 1e18, 1e18, 500);
        assertTrue(r.corporateAction);
        // zero prior state
        r = a.assess(address(t), 1e18, 0, 500);
        assertTrue(r.corporateAction);
    }

    function testFuzz_DividendKeepsSharesConstant(uint256 bps) public {
        bps = bound(bps, 1, 500);
        uint256 m1 = 1e18 * (10_000 + bps) / 10_000;
        t.set(m1);
        IDividendAdapter.Assessment memory r = a.assess(address(t), 1e18, 1e18, 500);
        // tokens * multiplier (shares) is preserved up to rounding
        assertApproxEqAbs(r.newScale * m1 / 1e18, 1e18, 2); // two floor divisions
    }
}
