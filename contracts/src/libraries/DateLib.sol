// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DateLib
/// @notice Gregorian calendar helpers (UTC) based on Howard Hinnant's civil-from-days algorithms.
/// @dev Valid for timestamps >= 1970-01-01. Expiries are quarter ends: 00:00 UTC on Jan 1, Apr 1, Jul 1 and Oct 1.
// slither-disable-start divide-before-multiply
// Calendar arithmetic relies on intentional floor division (Hinnant's algorithms); verified by DateLibTest fuzzing.
library DateLib {
    uint256 internal constant SECONDS_PER_DAY = 86_400;
    int256 private constant OFFSET19700101 = 719_468;

    function daysFromCivil(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        int256 y = int256(year) - (month <= 2 ? int256(1) : int256(0));
        int256 era = y / 400; // y >= 1970 in practice so no negative rounding concerns
        int256 yoe = y - era * 400;
        int256 mp = int256((month + 9) % 12);
        int256 doy = (153 * mp + 2) / 5 + int256(day) - 1;
        int256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return uint256(era * 146_097 + doe - OFFSET19700101);
    }

    function timestampFromDate(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        return daysFromCivil(year, month, day) * SECONDS_PER_DAY;
    }

    function dateFromTimestamp(uint256 ts) internal pure returns (uint256 year, uint256 month, uint256 day) {
        int256 z = int256(ts / SECONDS_PER_DAY) + OFFSET19700101;
        int256 era = z / 146_097;
        int256 doe = z - era * 146_097;
        int256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        int256 y = yoe + era * 400;
        int256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        int256 mp = (5 * doy + 2) / 153;
        day = uint256(doy - (153 * mp + 2) / 5 + 1);
        month = mp < 10 ? uint256(mp + 3) : uint256(mp - 9);
        year = uint256(month <= 2 ? y + 1 : y);
    }

    /// @notice True if `ts` is 00:00 UTC on the first day of Jan, Apr, Jul or Oct.
    function isQuarterlyExpiry(uint256 ts) internal pure returns (bool) {
        if (ts % SECONDS_PER_DAY != 0) return false;
        (, uint256 month, uint256 day) = dateFromTimestamp(ts);
        return day == 1 && (month - 1) % 3 == 0;
    }

    /// @notice True if `ts` is 00:00 UTC on Jan 1.
    function isYearlyExpiry(uint256 ts) internal pure returns (bool) {
        if (ts % SECONDS_PER_DAY != 0) return false;
        (, uint256 month, uint256 day) = dateFromTimestamp(ts);
        return day == 1 && month == 1;
    }
}
// slither-disable-end divide-before-multiply
