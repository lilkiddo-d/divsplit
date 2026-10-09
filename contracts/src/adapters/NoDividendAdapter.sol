// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDividendAdapter} from "../interfaces/IDividendAdapter.sol";

/// @title NoDividendAdapter
/// @notice For stocks that pay no dividend, or whose dividends are paid off-chain. D tokens of such splitters only
///         receive something if governance later swaps in a real adapter. Balance shortfalls are still detected by
///         the splitter as corporate actions.
contract NoDividendAdapter is IDividendAdapter {
    bytes32 public constant MECHANISM = keccak256("NONE");

    function mechanism() external pure returns (bytes32) {
        return MECHANISM;
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

    function assess(address, uint256 scale, uint256 state, uint256) external pure returns (Assessment memory a) {
        a.newScale = scale;
        a.newState = state;
    }
}
