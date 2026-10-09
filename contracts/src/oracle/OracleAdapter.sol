// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IOracleAdapter, IAggregatorV3} from "../interfaces/IOracleAdapter.sol";

/// @title OracleAdapter
/// @notice Swappable USD price source with staleness, sanity and deviation checks.
///         Each asset has a primary AggregatorV3-compatible feed (Chainlink on Robinhood Chain) and optionally a
///         secondary feed. With a secondary feed the two must agree within `maxDeviationBps`; without one, the
///         latest round must not jump more than `maxRoundJumpBps` versus the previous round.
///         An optional L2 sequencer-uptime feed is honoured when configured.
/// @dev Robinhood Chain stock-token feeds already include the ERC-8056 multiplier (price per raw token).
contract OracleAdapter is IOracleAdapter, AccessControl {
    struct FeedConfig {
        IAggregatorV3 primary;
        IAggregatorV3 secondary;
        uint32 maxStaleness;
        uint16 maxDeviationBps;
        uint16 maxRoundJumpBps;
    }

    uint256 private constant BPS = 10_000;
    uint32 public constant MAX_STALENESS_LIMIT = 7 days;

    mapping(address asset => FeedConfig) internal _feeds;
    IAggregatorV3 public sequencerUptimeFeed;
    uint32 public sequencerGracePeriod;

    event FeedSet(
        address indexed asset,
        address primary,
        address secondary,
        uint32 maxStaleness,
        uint16 maxDeviationBps,
        uint16 maxRoundJumpBps
    );
    event SequencerFeedSet(address feed, uint32 gracePeriod);

    error NoFeed(address asset);
    error StalePrice(address asset, uint256 updatedAt);
    error InvalidPrice(address asset);
    error PriceDeviation(address asset, uint256 a, uint256 b);
    error SequencerDown();
    error InvalidConfig();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setFeed(address asset, FeedConfig calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            asset == address(0) || address(cfg.primary) == address(0) || cfg.maxStaleness == 0
                || cfg.maxStaleness > MAX_STALENESS_LIMIT || cfg.maxDeviationBps > BPS || cfg.maxRoundJumpBps > BPS
        ) revert InvalidConfig();
        _feeds[asset] = cfg;
        emit FeedSet(
            asset,
            address(cfg.primary),
            address(cfg.secondary),
            cfg.maxStaleness,
            cfg.maxDeviationBps,
            cfg.maxRoundJumpBps
        );
    }

    function setSequencerUptimeFeed(address feed, uint32 gracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sequencerUptimeFeed = IAggregatorV3(feed);
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    function feedConfig(address asset) external view returns (FeedConfig memory) {
        return _feeds[asset];
    }

    function hasFeed(address asset) external view returns (bool) {
        return address(_feeds[asset].primary) != address(0);
    }

    /// @inheritdoc IOracleAdapter
    function getPrice(address asset) external view returns (uint256) {
        FeedConfig memory cfg = _feeds[asset];
        if (address(cfg.primary) == address(0)) revert NoFeed(asset);
        _checkSequencer();

        (uint80 roundId, uint256 p) = _read(asset, cfg.primary, cfg.maxStaleness);
        if (address(cfg.secondary) != address(0)) {
            (, uint256 s) = _read(asset, cfg.secondary, cfg.maxStaleness);
            _checkDeviation(asset, p, s, cfg.maxDeviationBps);
        } else if (cfg.maxRoundJumpBps != 0 && roundId > 1) {
            // slither-disable-next-line unused-return
            try cfg.primary.getRoundData(roundId - 1) returns (uint80, int256 prev, uint256, uint256, uint80) {
                if (prev > 0) {
                    _checkDeviation(asset, p, _toWad(uint256(prev), cfg.primary.decimals()), cfg.maxRoundJumpBps);
                }
            } catch {}
        }
        return p;
    }

    function _read(address asset, IAggregatorV3 feed, uint32 maxStaleness)
        internal
        view
        returns (uint80 roundId, uint256 priceWad)
    {
        // slither-disable-next-line unused-return
        (uint80 rid, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(asset);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxStaleness) {
            revert StalePrice(asset, updatedAt);
        }
        return (rid, _toWad(uint256(answer), feed.decimals()));
    }

    function _checkDeviation(address asset, uint256 a, uint256 b, uint16 maxBps) internal pure {
        uint256 hi = a > b ? a : b;
        uint256 lo = a > b ? b : a;
        if ((hi - lo) * BPS > lo * maxBps) revert PriceDeviation(asset, a, b);
    }

    function _checkSequencer() internal view {
        IAggregatorV3 f = sequencerUptimeFeed;
        if (address(f) == address(0)) return;
        // slither-disable-next-line unused-return
        (, int256 answer, uint256 startedAt,,) = f.latestRoundData();
        if (answer != 0 || startedAt == 0 || block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerDown();
    }

    function _toWad(uint256 v, uint8 dec) internal pure returns (uint256) {
        if (dec == 18) return v;
        if (dec < 18) return v * 10 ** (18 - dec);
        return v / 10 ** (dec - 18);
    }
}
