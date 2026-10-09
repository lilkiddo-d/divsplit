// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDividendAdapter
/// @notice Stateless strategy describing how a stock token delivers dividends.
/// @dev The Splitter owns all funds and all per-splitter state. An adapter only:
///      (1) names the extra token dividends arrive in (if any),
///      (2) re-assesses the stock-units-per-P-unit `scale` from token-level signals (e.g. a share multiplier),
///      (3) optionally names a distributor contract the keeper may call to pull an airdrop.
///      Plain balance increases (rebases / reinvested dividends / airdrops) are measured by the Splitter itself.
interface IDividendAdapter {
    struct Assessment {
        uint256 newScale; // stock units owed per 1e18 P units
        uint256 newState; // adapter-specific opaque state persisted by the splitter
        bool corporateAction; // true => signal is outside dividend bounds; splitter halts until governance resolves
        bool deferred; // true => issuer is mid-update (e.g. oracle paused); skip harvest, block split/merge
    }

    /// @notice Short identifier of the mechanism, e.g. keccak256("REBASE").
    function mechanism() external pure returns (bytes32);

    /// @notice Token (other than the stock itself) dividends are paid in, or address(0) if none.
    function payoutToken(address stock) external view returns (address);

    /// @notice Initial adapter state for a splitter that starts using this adapter.
    function initialState(address stock) external view returns (uint256);

    /// @notice Re-assess `scale` given the current token-level signals.
    /// @param maxDividendBps largest per-harvest change that may be treated as a dividend.
    function assess(address stock, uint256 scale, uint256 state, uint256 maxDividendBps)
        external
        view
        returns (Assessment memory);

    /// @notice Contract the keeper may call (with arbitrary calldata) to claim an airdropped dividend, or address(0).
    function claimTarget(address stock) external view returns (address);
}
