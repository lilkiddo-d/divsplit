// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {ISplitterFactory} from "../interfaces/ISplitterFactory.sol";
import {MarketMath} from "../libraries/MarketMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

interface ISplitterView {
    function scale() external view returns (uint256);
    function stock() external view returns (IERC20);
    function paused() external view returns (bool);
    function corporateActionPending() external view returns (bool);
}

/// @title TimeDecayAMM
/// @notice Pendle-style time-aware AMM pairing one split token (P or D) with the stablecoin.
///         The stable reserve is valued in "units" (what one P+D pair redeems for: `scale` stock tokens) through the
///         OracleAdapter, and the logit curve steepens as expiry approaches so that P -> 1 unit and D -> 0.
///         The LP token is this contract. Swaps and adds stop at expiry; removing liquidity is always possible.
/// @dev One implementation, cloned twice per market (isD = false / true).
contract TimeDecayAMM is ERC20Upgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant MINIMUM_LIQUIDITY = 1e3;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant BPS = 10_000;
    bytes32 public constant ACTION_SWAP = keccak256("SWAP");
    bytes32 public constant ACTION_LIQUIDITY = keccak256("LIQUIDITY");

    ISplitterFactory public factory;
    ISplitterView public splitter;
    IERC20 public token;
    IERC20 public stable;
    bool public isD;
    uint64 public expiry;
    uint256 internal tokenToWad;
    uint256 internal stableToWad;
    int256 public scalarRoot;
    int256 public initialAnchor;

    uint256 public reserveToken;
    uint256 public reserveStable;
    int256 public lastLnImpliedRate;

    event Swap(
        address indexed sender,
        address indexed to,
        int256 tokenToAccount,
        int256 stableToAccount,
        uint256 fee,
        uint256 protocolFee,
        int256 lnImpliedRate
    );
    event LiquidityAdded(address indexed sender, address indexed to, uint256 tokenIn, uint256 stableIn, uint256 lp);
    event LiquidityRemoved(address indexed sender, address indexed to, uint256 lp, uint256 tokenOut, uint256 stableOut);
    event ImpliedRateInitialized(int256 lnImpliedRate);

    error Expired();
    error DeadlinePassed();
    error Slippage();
    error ZeroAmount();
    error ZeroAddress();
    error IsPaused();
    error InsufficientLiquidity();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address factory_,
        address splitter_,
        address token_,
        address stable_,
        bool isD_,
        uint64 expiry_,
        int256 scalarRoot_,
        int256 initialAnchor_
    ) external initializer {
        string memory tSym = IERC20Metadata(token_).symbol();
        string memory sSym = IERC20Metadata(stable_).symbol();
        __ERC20_init(string.concat("Divsplit LP ", tSym, "/", sSym), string.concat("DLP-", tSym));
        __ReentrancyGuard_init();
        factory = ISplitterFactory(factory_);
        splitter = ISplitterView(splitter_);
        token = IERC20(token_);
        stable = IERC20(stable_);
        isD = isD_;
        expiry = expiry_;
        scalarRoot = scalarRoot_;
        initialAnchor = initialAnchor_;
        tokenToWad = 10 ** (18 - IERC20Metadata(token_).decimals());
        stableToWad = 10 ** (18 - IERC20Metadata(stable_).decimals());
    }

    // ---------------------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Sell exactly `amountIn` P/D for at least `minStableOut` stable.
    function swapExactTokenForStable(uint256 amountIn, uint256 minStableOut, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 stableOut)
    {
        _checkTrade(deadline, to);
        if (amountIn == 0) revert ZeroAmount();
        uint256 fee;
        uint256 protocolFee;
        int256 newLn;
        (stableOut, fee, protocolFee, newLn) = _quoteSell(amountIn);
        if (stableOut < minStableOut) revert Slippage();
        if (reserveStable < stableOut + protocolFee) revert InsufficientLiquidity();

        reserveToken += amountIn;
        reserveStable -= stableOut + protocolFee;
        lastLnImpliedRate = newLn;

        token.safeTransferFrom(msg.sender, address(this), amountIn);
        stable.safeTransfer(to, stableOut);
        if (protocolFee != 0) stable.safeTransfer(factory.feeCollector(), protocolFee);
        emit Swap(msg.sender, to, -int256(amountIn), int256(stableOut), fee, protocolFee, newLn);
    }

    /// @notice Buy exactly `amountOut` P/D paying at most `maxStableIn` stable.
    function swapStableForExactToken(uint256 amountOut, uint256 maxStableIn, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 stableIn)
    {
        _checkTrade(deadline, to);
        if (amountOut == 0) revert ZeroAmount();
        if (amountOut >= reserveToken) revert InsufficientLiquidity();
        uint256 fee;
        uint256 protocolFee;
        int256 newLn;
        (stableIn, fee, protocolFee, newLn) = _quoteBuy(amountOut);
        if (stableIn > maxStableIn) revert Slippage();

        reserveToken -= amountOut;
        reserveStable += stableIn - protocolFee;
        lastLnImpliedRate = newLn;

        stable.safeTransferFrom(msg.sender, address(this), stableIn);
        token.safeTransfer(to, amountOut);
        if (protocolFee != 0) stable.safeTransfer(factory.feeCollector(), protocolFee);
        emit Swap(msg.sender, to, int256(amountOut), -int256(stableIn), fee, protocolFee, newLn);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------------------------------------------

    function addLiquidity(uint256 tokenDesired, uint256 stableDesired, uint256 minLp, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 lp, uint256 tokenUsed, uint256 stableUsed)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (block.timestamp >= expiry) revert Expired();
        if (to == address(0)) revert ZeroAddress();
        _checkNotPaused();
        factory.checkCompliance(msg.sender, ACTION_LIQUIDITY);
        if (tokenDesired == 0 || stableDesired == 0) revert ZeroAmount();

        uint256 supply = totalSupply();
        if (supply == 0) {
            tokenUsed = tokenDesired;
            stableUsed = stableDesired;
            uint256 liq = Math.sqrt(tokenDesired * tokenToWad * stableDesired * stableToWad);
            if (liq <= MINIMUM_LIQUIDITY) revert InsufficientLiquidity();
            lp = liq - MINIMUM_LIQUIDITY;
            int256 ln = _initialLnImpliedRate(tokenUsed, stableUsed);
            lastLnImpliedRate = ln;
            _mint(DEAD, MINIMUM_LIQUIDITY);
            emit ImpliedRateInitialized(ln);
        } else {
            uint256 lpT = Math.mulDiv(tokenDesired, supply, reserveToken);
            uint256 lpS = Math.mulDiv(stableDesired, supply, reserveStable);
            lp = lpT < lpS ? lpT : lpS;
            tokenUsed = Math.mulDiv(lp, reserveToken, supply, Math.Rounding.Ceil);
            stableUsed = Math.mulDiv(lp, reserveStable, supply, Math.Rounding.Ceil);
        }
        if (lp == 0 || lp < minLp) revert Slippage();

        reserveToken += tokenUsed;
        reserveStable += stableUsed;
        _mint(to, lp);

        token.safeTransferFrom(msg.sender, address(this), tokenUsed);
        stable.safeTransferFrom(msg.sender, address(this), stableUsed);
        emit LiquidityAdded(msg.sender, to, tokenUsed, stableUsed, lp);
    }

    /// @notice Burn LP for the proportional reserves. Never paused, never compliance-gated, works after expiry.
    function removeLiquidity(uint256 lp, uint256 minToken, uint256 minStable, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokenOut, uint256 stableOut)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (lp == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 supply = totalSupply();
        tokenOut = Math.mulDiv(lp, reserveToken, supply);
        stableOut = Math.mulDiv(lp, reserveStable, supply);
        if (tokenOut < minToken || stableOut < minStable) revert Slippage();

        _burn(msg.sender, lp);
        reserveToken -= tokenOut;
        reserveStable -= stableOut;

        if (tokenOut != 0) token.safeTransfer(to, tokenOut);
        if (stableOut != 0) stable.safeTransfer(to, stableOut);
        emit LiquidityRemoved(msg.sender, to, lp, tokenOut, stableOut);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------

    function previewSell(uint256 amountIn) external view returns (uint256 stableOut) {
        (stableOut,,,) = _quoteSell(amountIn);
    }

    function previewBuy(uint256 amountOut) external view returns (uint256 stableIn) {
        (stableIn,,,) = _quoteBuy(amountOut);
    }

    /// @notice Continuous annualised implied rate (wad). For both pools this is the market-implied dividend yield:
    ///         D / unit = 1 - exp(-rate * t).
    function lnImpliedRate() external view returns (int256) {
        return lastLnImpliedRate;
    }

    /// @notice Spot price of one whole P/D token in units (1e18 = one P+D pair) at the current proportion.
    function spotPriceInUnits() public view returns (uint256) {
        if (block.timestamp >= expiry) return isD ? 0 : 1e18;
        int256 er = MarketMath.exchangeRateFromImpliedRate(lastLnImpliedRate, expiry - block.timestamp);
        if (er < 1e18) er = 1e18;
        return MarketMath.priceFromExchangeRate(er, isD);
    }

    /// @notice Spot price of one whole P/D token in stable (wad), using the oracle.
    function spotPriceInStable() external view returns (uint256) {
        return Math.mulDiv(spotPriceInUnits(), _unitPrice(), 1e18);
    }

    /// @notice Stable (wad) per unit = oracle(stock) * scale / oracle(stable).
    function unitPrice() external view returns (uint256) {
        return _unitPrice();
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserveToken, reserveStable);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------

    function _checkTrade(uint256 deadline, address to) internal view {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (block.timestamp >= expiry) revert Expired();
        if (to == address(0)) revert ZeroAddress();
        _checkNotPaused();
        factory.checkCompliance(msg.sender, ACTION_SWAP);
        factory.checkCompliance(to, ACTION_SWAP);
    }

    function _checkNotPaused() internal view {
        if (factory.globalPaused() || splitter.paused() || splitter.corporateActionPending()) revert IsPaused();
    }

    function _unitPrice() internal view returns (uint256) {
        uint256 stockUsd = factory.oracle().getPrice(address(splitter.stock()));
        uint256 stableUsd = factory.oracle().getPrice(address(stable));
        return Math.mulDiv(Math.mulDiv(stockUsd, splitter.scale(), 1e18), 1e18, stableUsd);
    }

    function _totals(uint256 price) internal view returns (uint256 tWad, uint256 aWad) {
        tWad = reserveToken * tokenToWad;
        aWad = Math.mulDiv(reserveStable * stableToWad, 1e18, price);
    }

    function _quoteSell(uint256 amountIn)
        internal
        view
        returns (uint256 stableOut, uint256 fee, uint256 protocolFee, int256 newLn)
    {
        uint256 tte = expiry - block.timestamp;
        uint256 price = _unitPrice();
        (uint256 tWad, uint256 aWad) = _totals(price);
        MarketMath.Curve memory c = MarketMath.curve(tWad, aWad, scalarRoot, lastLnImpliedRate, tte, isD);
        int256 assetToAccount;
        (assetToAccount, newLn) = MarketMath.trade(tWad, aWad, -int256(amountIn * tokenToWad), c, tte, isD);
        uint256 gross = Math.mulDiv(uint256(assetToAccount), price, 1e18) / stableToWad;
        fee = Math.mulDiv(gross, factory.swapFeeBps(), BPS, Math.Rounding.Ceil);
        stableOut = gross - fee;
        protocolFee = Math.mulDiv(fee, factory.protocolFeeShareBps(), BPS);
    }

    function _quoteBuy(uint256 amountOut)
        internal
        view
        returns (uint256 stableIn, uint256 fee, uint256 protocolFee, int256 newLn)
    {
        uint256 tte = expiry - block.timestamp;
        uint256 price = _unitPrice();
        (uint256 tWad, uint256 aWad) = _totals(price);
        MarketMath.Curve memory c = MarketMath.curve(tWad, aWad, scalarRoot, lastLnImpliedRate, tte, isD);
        int256 assetToAccount;
        (assetToAccount, newLn) = MarketMath.trade(tWad, aWad, int256(amountOut * tokenToWad), c, tte, isD);
        uint256 gross =
            Math.mulDiv(Math.mulDiv(uint256(-assetToAccount), price, 1e18, Math.Rounding.Ceil), 1, stableToWad, Math.Rounding.Ceil);
        fee = Math.mulDiv(gross, factory.swapFeeBps(), BPS, Math.Rounding.Ceil);
        stableIn = gross + fee;
        protocolFee = Math.mulDiv(fee, factory.protocolFeeShareBps(), BPS);
    }

    /// @dev The first deposit may use any proportion; the curve is anchored so that the pool starts at the listing's
    ///      initial annual implied rate ln(initialAnchor) (e.g. initialAnchor = 1.03e18 -> ~3%/yr dividend yield).
    function _initialLnImpliedRate(uint256 tokenAmt, uint256 stableAmt) internal view returns (int256) {
        uint256 price = _unitPrice();
        uint256 tWad = tokenAmt * tokenToWad;
        uint256 aWad = Math.mulDiv(stableAmt * stableToWad, 1e18, price);
        // called only for its bounds check on the opening proportion (reverts if out of range)
        // slither-disable-next-line unused-return
        MarketMath.logit(MarketMath.proportion(tWad, aWad), isD);
        return FixedPointMathLib.lnWad(initialAnchor);
    }
}
