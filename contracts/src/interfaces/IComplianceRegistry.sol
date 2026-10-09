// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IComplianceRegistry {
    /// @notice Whether `account` may perform `action`. Must return true for everyone while the registry is disabled.
    function isAllowed(address account, bytes32 action) external view returns (bool);
}
