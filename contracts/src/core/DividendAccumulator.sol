// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title DividendAccumulator
/// @notice Loop-free (per holder) pro-rata reward accounting for D-token holders across a small, bounded set of
///         reward tokens. Classic "reward per unit" accumulator: O(#rewardTokens) per checkpoint, never O(#holders).
/// @dev `reserved[token]` is the amount of `token` held by the contract that is owed to holders and must never be
///      treated as new dividends. Rounding always favours the contract so total paid <= total received.
abstract contract DividendAccumulator {
    uint256 internal constant ACC_PRECISION = 1e27;
    uint256 public constant MAX_REWARD_TOKENS = 4;

    address[] internal _rewardTokens;
    mapping(address token => bool) public isRewardToken;
    mapping(address token => uint256) public accPerUnit; // reward per D unit, scaled by ACC_PRECISION
    mapping(address token => uint256) public reserved; // owed to holders, not yet paid
    mapping(address token => uint256) public totalDistributed; // lifetime amount credited to holders
    mapping(address token => uint256) public totalPaid; // lifetime amount paid out
    mapping(address token => mapping(address user => uint256)) public userIndex;
    mapping(address token => mapping(address user => uint256)) public accrued;

    event RewardTokenAdded(address indexed token);
    event DividendsDistributed(address indexed token, uint256 amount, uint256 accPerUnit);
    event DividendsClaimed(address indexed account, address indexed to, address indexed token, uint256 amount);

    error TooManyRewardTokens();

    function _holderBalance(address account) internal view virtual returns (uint256);
    function _holderSupply() internal view virtual returns (uint256);
    function _payout(address token, address to, uint256 amount) internal virtual;

    function rewardTokens() external view returns (address[] memory) {
        return _rewardTokens;
    }

    function _addRewardToken(address token) internal {
        if (token == address(0) || isRewardToken[token]) return;
        if (_rewardTokens.length >= MAX_REWARD_TOKENS) revert TooManyRewardTokens();
        isRewardToken[token] = true;
        _rewardTokens.push(token);
        emit RewardTokenAdded(token);
    }

    /// @dev Caller guarantees `_holderSupply() > 0` and that `amount` is held and not yet reserved.
    function _distribute(address token, uint256 amount) internal {
        uint256 acc = accPerUnit[token] + Math.mulDiv(amount, ACC_PRECISION, _holderSupply());
        accPerUnit[token] = acc;
        reserved[token] += amount;
        totalDistributed[token] += amount;
        emit DividendsDistributed(token, amount, acc);
    }

    function _checkpoint(address account) internal {
        if (account == address(0)) return;
        uint256 bal = _holderBalance(account);
        uint256 n = _rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = _rewardTokens[i];
            uint256 acc = accPerUnit[token];
            uint256 idx = userIndex[token][account];
            if (acc != idx) {
                if (bal != 0) accrued[token][account] += Math.mulDiv(bal, acc - idx, ACC_PRECISION);
                userIndex[token][account] = acc;
            }
        }
    }

    function _claim(address account, address to) internal returns (uint256[] memory amounts) {
        _checkpoint(account);
        uint256 n = _rewardTokens.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address token = _rewardTokens[i];
            uint256 amt = accrued[token][account];
            if (amt == 0) continue;
            accrued[token][account] = 0;
            reserved[token] -= amt;
            totalPaid[token] += amt;
            amounts[i] = amt;
            emit DividendsClaimed(account, to, token, amt);
        }
        for (uint256 i; i < n; ++i) {
            if (amounts[i] != 0) _payout(_rewardTokens[i], to, amounts[i]);
        }
    }

    function _claimable(address account) internal view returns (address[] memory tokens, uint256[] memory amounts) {
        uint256 bal = _holderBalance(account);
        uint256 n = _rewardTokens.length;
        tokens = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address token = _rewardTokens[i];
            tokens[i] = token;
            amounts[i] =
                accrued[token][account] + Math.mulDiv(bal, accPerUnit[token] - userIndex[token][account], ACC_PRECISION);
        }
    }
}
