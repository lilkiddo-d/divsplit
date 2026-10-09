// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracleAdapter {
    /// @notice USD price of one whole `asset` token, scaled to 1e18. Reverts if stale, invalid or deviating.
    function getPrice(address asset) external view returns (uint256 priceWad);
}

/// @notice Minimal Chainlink AggregatorV3 interface (also implemented by most other oracle networks' adapters).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
