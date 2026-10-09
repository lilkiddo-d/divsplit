// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IProjectTokenHooks {
    /// @notice True once the project token is set and at least one unit is staked.
    function isActive() external view returns (bool);

    /// @notice Whether `token` is an allowlisted staking reward token.
    function isRewardToken(address token) external view returns (bool);

    /// @notice Stream `amount` of `token` (already transferred in) to stakers.
    function notifyRewardAmount(address token, uint256 amount) external;
}
