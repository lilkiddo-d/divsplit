import { parseAbi } from "viem";

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function totalSupply() view returns (uint256)",
]);

export const scaledUiAbi = parseAbi(["function uiMultiplier() view returns (uint256)"]);

export const splitterAbi = parseAbi([
  "function split(uint256 amount, address to) returns (uint256)",
  "function merge(uint256 units, address to) returns (uint256)",
  "function redeem(uint256 units, address to) returns (uint256)",
  "function claimDividends(address to) returns (uint256[])",
  "function harvest() returns (uint8)",
  "function claimable(address) view returns (address[] tokens, uint256[] amounts)",
  "function scale() view returns (uint256)",
  "function principal() view returns (uint256)",
  "function expiry() view returns (uint64)",
  "function dividendCutoff() view returns (uint64)",
  "function paused() view returns (bool)",
  "function corporateActionPending() view returns (bool)",
  "function inBlackout() view returns (bool)",
  "function blackoutStart() view returns (uint64)",
  "function blackoutEnd() view returns (uint64)",
  "function noticeCount() view returns (uint256)",
  "function notice(uint256) view returns ((uint64 exDate, uint64 payDate, uint128 amountPerShare))",
  "function totalDistributed(address) view returns (uint256)",
  "function pendingStockDividend() view returns (uint256)",
  "event DividendsDistributed(address indexed token, uint256 amount, uint256 accPerUnit)",
]);

export const ammAbi = parseAbi([
  "function spotPriceInUnits() view returns (uint256)",
  "function spotPriceInStable() view returns (uint256)",
  "function unitPrice() view returns (uint256)",
  "function lnImpliedRate() view returns (int256)",
  "function getReserves() view returns (uint256, uint256)",
  "function previewSell(uint256) view returns (uint256)",
  "function previewBuy(uint256) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function addLiquidity(uint256 tokenDesired, uint256 stableDesired, uint256 minLp, address to, uint256 deadline) returns (uint256, uint256, uint256)",
  "function removeLiquidity(uint256 lp, uint256 minToken, uint256 minStable, address to, uint256 deadline) returns (uint256, uint256)",
  "function swapExactTokenForStable(uint256 amountIn, uint256 minStableOut, address to, uint256 deadline) returns (uint256)",
  "function swapStableForExactToken(uint256 amountOut, uint256 maxStableIn, address to, uint256 deadline) returns (uint256)",
  "event Swap(address indexed sender, address indexed to, int256 tokenToAccount, int256 stableToAccount, uint256 fee, uint256 protocolFee, int256 lnImpliedRate)",
]);

export const routerAbi = parseAbi([
  "function buyExactStable(address pool, uint256 stableIn, uint256 minTokenOut, address to, uint256 deadline) returns (uint256)",
  "function sellExactToken(address pool, uint256 amountIn, uint256 minStableOut, address to, uint256 deadline) returns (uint256)",
  "function splitAndSell(address splitter, uint256 stockAmount, bool sellD, uint256 minStableOut, address to, uint256 deadline) returns (uint256, uint256)",
  "function quoteBuyExactStable(address pool, uint256 stableIn) view returns (uint256)",
]);

export const hooksAbi = parseAbi([
  "function projectToken() view returns (address)",
  "function stake(uint256)",
  "function unstake(uint256)",
  "function claimRewards()",
  "function stakeOf(address) view returns (uint256)",
  "function totalStaked() view returns (uint256)",
  "function earned(address account, address token) view returns (uint256)",
  "function proposalCount() view returns (uint256)",
  "function propose(uint8 kind, address stock, uint64 expiry, string description) returns (uint256)",
  "function castVote(uint256 id, bool support)",
  "function state(uint256 id) view returns (uint8)",
  "function proposal(uint256 id) view returns ((address proposer, uint8 kind, address stock, uint64 expiry, uint48 snapshot, uint48 voteEnd, uint256 forVotes, uint256 againstVotes, bytes32 descriptionHash))",
]);
