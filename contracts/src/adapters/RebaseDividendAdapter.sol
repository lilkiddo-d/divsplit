// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDividendAdapter} from "../interfaces/IDividendAdapter.sol";

/// @title RebaseDividendAdapter
/// @notice For stock tokens that pay (or reinvest) dividends by increasing holder balances.
/// @dev The splitter measures `stockBalance - principal - reserved` and distributes it to D holders.
///      Increases above `maxDividendBps` of principal (forward split) or any shortfall (reverse split / clawback)
///      are flagged as corporate actions by the splitter itself, so this adapter never changes `scale`.
contract RebaseDividendAdapter is IDividendAdapter {
    bytes32 public constant MECHANISM = keccak256("REBASE");

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
