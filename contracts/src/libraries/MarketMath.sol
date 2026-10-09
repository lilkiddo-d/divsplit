// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title MarketMath
/// @notice Pendle-V2-style time-decaying logit curve, adapted for split stock tokens.
/// @dev All quantities are 18-decimal fixed point. "asset" is measured in STOCK units (1e18 = one share).
///
///   rateScalar   = scalarRoot * 365d / timeToExpiry            (curve gets steeper as expiry nears)
///   exchangeRate = logit(p) / rateScalar + rateAnchor            (stock per P unit, must be >= 1)
///   rateAnchor   = exp(lnImpliedRate * t / 365d) - logit(p)/rateScalar   (keeps implied rate continuous over time)
///
///   P pool: logit(p) = ln(p / (1-p)), price(P) = 1 / exchangeRate          -> converges to 1 stock at expiry
///   D pool: logit(p) = ln((1-p) / p), price(D) = 1 - 1 / exchangeRate      -> converges to 0 at expiry
///
/// Because P + D = 1 stock before expiry, both pools quote the same "implied rate" (the market's annualised
/// dividend discount) and arbitrage via split/merge keeps them aligned.
library MarketMath {
    using FixedPointMathLib for int256;

    int256 internal constant ONE = 1e18;
    uint256 internal constant YEAR = 365 days;
    /// @dev Token-side proportion bounds. The "cheap" side of each pool (P pool: P-heavy, D pool: D-heavy) may go
    ///      to 96% / 99%; the expensive side is bounded at 1% / 4% for numerical safety.
    uint256 internal constant P_MIN_PROPORTION = 0.01e18;
    uint256 internal constant P_MAX_PROPORTION = 0.96e18;
    uint256 internal constant D_MIN_PROPORTION = 0.04e18;
    uint256 internal constant D_MAX_PROPORTION = 0.99e18;

    error MarketProportionOutOfBounds(uint256 proportion);
    error MarketExchangeRateBelowOne(int256 exchangeRate);
    error MarketExpired();
    error MarketZeroTotals();
    error MarketRateScalarZero();

    struct Curve {
        int256 rateScalar;
        int256 rateAnchor;
    }

    function rateScalar(int256 scalarRoot, uint256 timeToExpiry) internal pure returns (int256 s) {
        if (timeToExpiry == 0) revert MarketExpired();
        s = (scalarRoot * int256(YEAR)) / int256(timeToExpiry);
        if (s <= 0) revert MarketRateScalarZero();
    }

    function proportion(uint256 totalToken, uint256 totalAsset) internal pure returns (uint256) {
        uint256 sum = totalToken + totalAsset;
        if (sum == 0) revert MarketZeroTotals();
        return (totalToken * 1e18) / sum;
    }

    function logit(uint256 p, bool isD) internal pure returns (int256) {
        if (isD ? (p < D_MIN_PROPORTION || p > D_MAX_PROPORTION) : (p < P_MIN_PROPORTION || p > P_MAX_PROPORTION)) {
            revert MarketProportionOutOfBounds(p);
        }
        int256 ratio = (int256(p) * ONE) / (ONE - int256(p));
        int256 l = ratio.lnWad();
        return isD ? -l : l;
    }

    function exchangeRateFromImpliedRate(int256 lnImpliedRate, uint256 timeToExpiry) internal pure returns (int256) {
        int256 rt = (lnImpliedRate * int256(timeToExpiry)) / int256(YEAR);
        return rt.expWad();
    }

    function lnImpliedRateFromExchangeRate(int256 er, uint256 timeToExpiry) internal pure returns (int256) {
        if (er < ONE) revert MarketExchangeRateBelowOne(er);
        return (er.lnWad() * int256(YEAR)) / int256(timeToExpiry);
    }

    function curve(
        uint256 totalToken,
        uint256 totalAsset,
        int256 scalarRoot,
        int256 lastLnImpliedRate,
        uint256 timeToExpiry,
        bool isD
    ) internal pure returns (Curve memory c) {
        c.rateScalar = rateScalar(scalarRoot, timeToExpiry);
        int256 target = exchangeRateFromImpliedRate(lastLnImpliedRate, timeToExpiry);
        int256 l = logit(proportion(totalToken, totalAsset), isD);
        c.rateAnchor = target - (l * ONE) / c.rateScalar;
    }

    function exchangeRate(uint256 totalToken, uint256 totalAsset, Curve memory c, bool isD)
        internal
        pure
        returns (int256 er)
    {
        int256 l = logit(proportion(totalToken, totalAsset), isD);
        er = (l * ONE) / c.rateScalar + c.rateAnchor;
        if (er < ONE) revert MarketExchangeRateBelowOne(er);
    }

    /// @notice Stock units per token for a given exchange rate.
    function priceFromExchangeRate(int256 er, bool isD) internal pure returns (uint256) {
        uint256 inv = uint256((ONE * ONE) / er);
        return isD ? 1e18 - inv : inv;
    }

    /// @notice Executes a trade on the curve. Price is the marginal price at the post-trade token balance,
    ///         which is always worse for the trader than the pre-trade spot (no round-trip profit).
    /// @param netTokenToAccount >0 user buys tokens from pool, <0 user sells tokens to pool.
    /// @return assetToAccount stock-unit value moving to the user (negative = user pays), pre-fee.
    /// @return newLnImpliedRate implied rate to persist after the trade.
    function trade(
        uint256 totalToken,
        uint256 totalAsset,
        int256 netTokenToAccount,
        Curve memory c,
        uint256 timeToExpiry,
        bool isD
    ) internal pure returns (int256 assetToAccount, int256 newLnImpliedRate) {
        int256 newTotalToken = int256(totalToken) - netTokenToAccount;
        if (newTotalToken <= 0) revert MarketZeroTotals();
        // Marginal price at the post-trade token balance with the asset side held fixed. Unlike Pendle's
        // pre-trade denominator this stays inside (0,1) for large sells into token-heavy (D) pools.
        uint256 p = (uint256(newTotalToken) * 1e18) / (uint256(newTotalToken) + totalAsset);
        int256 l = logit(p, isD);
        int256 er = (l * ONE) / c.rateScalar + c.rateAnchor;
        if (er < ONE) revert MarketExchangeRateBelowOne(er);
        int256 price = int256(priceFromExchangeRate(er, isD));
        assetToAccount = -(netTokenToAccount * price) / ONE;

        int256 newTotalAsset = int256(totalAsset) - assetToAccount;
        if (newTotalAsset <= 0) revert MarketZeroTotals();
        int256 erAfter = exchangeRate(uint256(newTotalToken), uint256(newTotalAsset), c, isD);
        newLnImpliedRate = lnImpliedRateFromExchangeRate(erAfter, timeToExpiry);
    }
}
