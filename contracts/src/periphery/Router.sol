// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISplitterFactory} from "../interfaces/ISplitterFactory.sol";
import {Splitter} from "../core/Splitter.sol";
import {TimeDecayAMM} from "../amm/TimeDecayAMM.sol";

/// @title Router
/// @notice Stateless convenience entry point: exact-in buys, split-and-sell (get pure price or pure dividend
///         exposure in one tx) and buy-then-merge. Every function takes a deadline and a slippage bound and never
///         keeps funds between transactions (all dust is refunded to the caller).
/// @dev When the ComplianceRegistry is enabled, governance must allowlist this Router; the Router then checks the
///      real caller itself and the pools/splitter check the recipient.
contract Router is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SEARCH_ITERATIONS = 64;
    bytes32 private constant ACTION_SWAP = keccak256("SWAP");
    bytes32 private constant ACTION_SPLIT = keccak256("SPLIT");

    ISplitterFactory public immutable factory;

    error DeadlinePassed();
    error Slippage();
    error UnknownMarket();
    error ZeroAmount();

    constructor(address factory_) {
        factory = ISplitterFactory(factory_);
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }

    /// @notice Spend exactly `stableIn` to buy as many P/D tokens as possible from `pool`.
    function buyExactStable(TimeDecayAMM pool, uint256 stableIn, uint256 minTokenOut, address to, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 tokenOut)
    {
        if (stableIn == 0) revert ZeroAmount();
        factory.checkCompliance(msg.sender, ACTION_SWAP);
        tokenOut = quoteBuyExactStable(pool, stableIn);
        if (tokenOut == 0 || tokenOut < minTokenOut) revert Slippage();
        IERC20 stable = pool.stable();
        stable.safeTransferFrom(msg.sender, address(this), stableIn);
        stable.forceApprove(address(pool), stableIn);
        uint256 spent = pool.swapStableForExactToken(tokenOut, stableIn, to, deadline);
        stable.forceApprove(address(pool), 0);
        if (stableIn > spent) stable.safeTransfer(msg.sender, stableIn - spent);
    }

    /// @notice Sell exactly `amountIn` P/D tokens.
    function sellExactToken(TimeDecayAMM pool, uint256 amountIn, uint256 minStableOut, address to, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 stableOut)
    {
        factory.checkCompliance(msg.sender, ACTION_SWAP);
        IERC20 token = pool.token();
        token.safeTransferFrom(msg.sender, address(this), amountIn);
        token.forceApprove(address(pool), amountIn);
        stableOut = pool.swapExactTokenForStable(amountIn, minStableOut, to, deadline);
    }

    /// @notice Split `stockAmount` and immediately sell one side.
    ///         sellD = true  -> keep P (pure price exposure, dividends sold upfront)
    ///         sellD = false -> keep D (pure dividend exposure, price sold upfront)
    function splitAndSell(
        Splitter splitter,
        uint256 stockAmount,
        bool sellD,
        uint256 minStableOut,
        address to,
        uint256 deadline
    ) external nonReentrant checkDeadline(deadline) returns (uint256 kept, uint256 stableOut) {
        factory.checkCompliance(msg.sender, ACTION_SPLIT);
        (TimeDecayAMM pPool, TimeDecayAMM dPool) = _pools(address(splitter));
        IERC20 stock = splitter.stock();
        stock.safeTransferFrom(msg.sender, address(this), stockAmount);
        stock.forceApprove(address(splitter), stockAmount);
        kept = splitter.split(stockAmount, address(this));

        TimeDecayAMM sellPool = sellD ? dPool : pPool;
        IERC20 sellToken = sellPool.token();
        sellToken.forceApprove(address(sellPool), kept);
        stableOut = sellPool.swapExactTokenForStable(kept, minStableOut, to, deadline);

        IERC20 keepToken = sellD ? IERC20(address(splitter.pToken())) : IERC20(address(splitter.dToken()));
        keepToken.safeTransfer(to, kept);
    }

    /// @notice Buy the missing side with stable and merge back into stock (before expiry).
    /// @param haveP true if the caller supplies P and buys D; false if the caller supplies D and buys P.
    function buyAndMerge(Splitter splitter, uint256 units, bool haveP, uint256 maxStableIn, address to, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 stockOut, uint256 stableIn)
    {
        factory.checkCompliance(msg.sender, ACTION_SWAP);
        (TimeDecayAMM pPool, TimeDecayAMM dPool) = _pools(address(splitter));
        TimeDecayAMM buyPool = haveP ? dPool : pPool;
        IERC20 have = haveP ? IERC20(address(splitter.pToken())) : IERC20(address(splitter.dToken()));
        have.safeTransferFrom(msg.sender, address(this), units);

        IERC20 stable = buyPool.stable();
        stable.safeTransferFrom(msg.sender, address(this), maxStableIn);
        stable.forceApprove(address(buyPool), maxStableIn);
        stableIn = buyPool.swapStableForExactToken(units, maxStableIn, address(this), deadline);
        stable.forceApprove(address(buyPool), 0);
        if (maxStableIn > stableIn) stable.safeTransfer(msg.sender, maxStableIn - stableIn);

        stockOut = splitter.merge(units, to);
        // Dividends accrued on D while transiting the router are negligible (same tx) but sweep them to the caller.
        // slither-disable-next-line unused-return
        splitter.claimDividends(msg.sender);
    }

    /// @notice Largest token amount `stableIn` can buy (bounded binary search over the pool's exact-out quote).
    function quoteBuyExactStable(TimeDecayAMM pool, uint256 stableIn) public view returns (uint256 best) {
        // slither-disable-next-line unused-return
        (uint256 reserveToken,) = pool.getReserves();
        if (reserveToken < 2) return 0;
        uint256 lo = 0;
        uint256 hi = reserveToken - 1;
        for (uint256 i; i < SEARCH_ITERATIONS && lo < hi; ++i) {
            uint256 mid = (lo + hi + 1) / 2;
            (bool ok, uint256 cost) = _tryPreviewBuy(pool, mid);
            if (ok && cost <= stableIn) lo = mid;
            else hi = mid - 1;
        }
        best = lo;
    }

    function _tryPreviewBuy(TimeDecayAMM pool, uint256 amount) internal view returns (bool, uint256) {
        try pool.previewBuy(amount) returns (uint256 cost) {
            return (true, cost);
        } catch {
            return (false, 0);
        }
    }

    function _pools(address splitter) internal view returns (TimeDecayAMM pPool, TimeDecayAMM dPool) {
        (bool ok, bytes memory data) =
            address(factory).staticcall(abi.encodeWithSignature("market(address)", splitter));
        if (!ok) revert UnknownMarket();
        (address s,,, address p, address d,,) =
            abi.decode(data, (address, address, address, address, address, address, uint64));
        if (s != splitter || s == address(0)) revert UnknownMarket();
        pPool = TimeDecayAMM(p);
        dPool = TimeDecayAMM(d);
    }
}
