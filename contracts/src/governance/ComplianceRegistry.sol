// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";

/// @title ComplianceRegistry
/// @notice Pluggable allowlist hook. OFF by default: while disabled everyone is allowed.
///         When enabled, gated actions (split, merge, swap, add liquidity) require the account to be allowlisted,
///         unless the specific action has been opened to everyone. Exits (redeem, claim, remove liquidity) are
///         never gated by design.
contract ComplianceRegistry is IComplianceRegistry, AccessControl {
    bytes32 public constant COMPLIANCE_MANAGER_ROLE = keccak256("COMPLIANCE_MANAGER_ROLE");
    uint256 public constant MAX_BATCH = 200;

    bool public enabled;
    mapping(address account => bool) public allowed;
    mapping(bytes32 action => bool) public actionOpen;

    event EnabledSet(bool enabled);
    event AllowedSet(address indexed account, bool allowed);
    event ActionOpenSet(bytes32 indexed action, bool open);

    error BatchTooLarge();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setEnabled(bool enabled_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = enabled_;
        emit EnabledSet(enabled_);
    }

    function setActionOpen(bytes32 action, bool open) external onlyRole(DEFAULT_ADMIN_ROLE) {
        actionOpen[action] = open;
        emit ActionOpenSet(action, open);
    }

    function setAllowed(address[] calldata accounts, bool allowed_) external {
        if (!hasRole(COMPLIANCE_MANAGER_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, COMPLIANCE_MANAGER_ROLE);
        }
        uint256 n = accounts.length;
        if (n > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < n; ++i) {
            allowed[accounts[i]] = allowed_;
            emit AllowedSet(accounts[i], allowed_);
        }
    }

    function isAllowed(address account, bytes32 action) external view returns (bool) {
        if (!enabled) return true;
        return allowed[account] || actionOpen[action];
    }
}
