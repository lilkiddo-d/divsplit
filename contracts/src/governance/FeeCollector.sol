// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IProjectTokenHooks} from "../interfaces/IProjectTokenHooks.sol";

/// @title FeeCollector
/// @notice Receives the protocol share of AMM swap fees (and dividends that arrive while nobody is entitled).
///         `distribute` is permissionless: while the project token is live and staked, `stakerShareBps` of the
///         balance is streamed to stakers via ProjectTokenHooks; everything else goes to the treasury.
///         Until the project token is set, 100% goes to the treasury.
contract FeeCollector is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    address public treasury;
    IProjectTokenHooks public hooks;
    uint16 public stakerShareBps;

    event TreasurySet(address treasury);
    event HooksSet(address hooks);
    event StakerShareSet(uint16 bps);
    event Distributed(address indexed token, uint256 toStakers, uint256 toTreasury);

    error ZeroAddress();
    error InvalidBps();

    constructor(address admin, address treasury_, uint16 stakerShareBps_) {
        if (admin == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (stakerShareBps_ > BPS) revert InvalidBps();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        treasury = treasury_;
        stakerShareBps = stakerShareBps_;
        emit TreasurySet(treasury_);
        emit StakerShareSet(stakerShareBps_);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setHooks(address hooks_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = IProjectTokenHooks(hooks_);
        emit HooksSet(hooks_);
    }

    function setStakerShareBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > BPS) revert InvalidBps();
        stakerShareBps = bps;
        emit StakerShareSet(bps);
    }

    function distribute(address token) external nonReentrant returns (uint256 toStakers, uint256 toTreasury) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        // slither-disable-next-line incorrect-equality
        if (bal == 0) return (0, 0);
        IProjectTokenHooks h = hooks;
        if (address(h) != address(0) && h.isActive() && h.isRewardToken(token)) {
            toStakers = (bal * stakerShareBps) / BPS;
        }
        toTreasury = bal - toStakers;
        if (toStakers != 0) {
            IERC20(token).safeTransfer(address(h), toStakers);
            h.notifyRewardAmount(token, toStakers);
        }
        if (toTreasury != 0) IERC20(token).safeTransfer(treasury, toTreasury);
        emit Distributed(token, toStakers, toTreasury);
    }
}
