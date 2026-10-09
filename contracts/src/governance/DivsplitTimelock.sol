// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title DivsplitTimelock
/// @notice 48-hour (minimum) timelock that owns every admin role in the protocol.
/// @dev No self-admin bypass: `admin` is address(0) so role changes on the timelock itself also go through the delay.
contract DivsplitTimelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 48 hours;

    error DelayTooShort();

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY_FLOOR) revert DelayTooShort();
    }
}
