// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDividendAdapter} from "../interfaces/IDividendAdapter.sol";

/// @notice ERC-8056 "Scaled UI Amount" surface used by Robinhood Chain stock tokens.
interface IScaledUiToken {
    function uiMultiplier() external view returns (uint256);
    function oraclePaused() external view returns (bool);
}

/// @title MultiplierDividendAdapter
/// @notice Adapter for stock tokens whose raw balances never change while a share multiplier
///         (`uiMultiplier`, 1e18 = 1 share per token) absorbs reinvested cash dividends and splits.
///         This is the mechanism used by Robinhood Chain stock tokens (see docs/adapters.md).
/// @dev Accounting: a P unit is a claim on a fixed number of underlying SHARES. When the multiplier rises by a
///      dividend-sized step from m0 to m1, the same shares are now represented by fewer tokens, so
///      `scale` drops to scale * m0 / m1 and the freed tokens are distributed to D holders by the splitter.
///
///      Classification of a multiplier change r = m1 / m0:
///        - 1 < r <= 1 + maxDividendBps            => cash dividend reinvested -> carve out for D holders
///        - r >= SPLIT_THRESHOLD or r <= 1/SPLIT_THRESHOLD => forward/reverse split -> value-neutral for the
///          token, scale unchanged, state updated (no halt; balances do not move under this mechanism)
///        - anything else (incl. small decreases)   => ambiguous -> corporate action, splitter halts
///      While the issuer's multiplier oracle is paused the assessment is deferred.
contract MultiplierDividendAdapter is IDividendAdapter {
    bytes32 public constant MECHANISM = keccak256("MULTIPLIER");
    uint256 public constant SPLIT_THRESHOLD_BPS = 15_000; // 1.5x
    uint256 private constant BPS = 10_000;

    function mechanism() external pure returns (bytes32) {
        return MECHANISM;
    }

    function payoutToken(address) external pure returns (address) {
        return address(0);
    }

    function initialState(address stock) external view returns (uint256) {
        return IScaledUiToken(stock).uiMultiplier();
    }

    function claimTarget(address) external pure returns (address) {
        return address(0);
    }

    function assess(address stock, uint256 scale, uint256 state, uint256 maxDividendBps)
        external
        view
        returns (Assessment memory a)
    {
        a.newScale = scale;
        a.newState = state;
        if (_oraclePaused(stock)) {
            a.deferred = true;
            return a;
        }
        uint256 m1 = IScaledUiToken(stock).uiMultiplier();
        uint256 m0 = state;
        if (m1 == m0) return a;
        if (m0 == 0 || m1 == 0) {
            a.corporateAction = true;
            return a;
        }
        if (m1 > m0) {
            // r - 1 <= maxDividendBps  <=>  (m1 - m0) * BPS <= m0 * maxDividendBps
            if ((m1 - m0) * BPS <= m0 * maxDividendBps) {
                a.newScale = (scale * m0) / m1;
                a.newState = m1;
                return a;
            }
            if (m1 * BPS >= m0 * SPLIT_THRESHOLD_BPS) {
                a.newState = m1; // forward split: token value unchanged
                return a;
            }
        } else if (m0 * BPS >= m1 * SPLIT_THRESHOLD_BPS) {
            a.newState = m1; // reverse split: token value unchanged
            return a;
        }
        a.corporateAction = true;
    }

    function _oraclePaused(address stock) private view returns (bool) {
        try IScaledUiToken(stock).oraclePaused() returns (bool p) {
            return p;
        } catch {
            return false;
        }
    }
}
