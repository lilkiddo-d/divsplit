# Threat model

Scope: `contracts/src/**`, the deploy script, and the frontend's transaction paths. Status: unaudited. This document
lists assets, trust assumptions, the top risks named in the brief, and the other risks we identified, each with the
mitigation that exists in code and the test that covers it.

## Assets
- Stock tokens held by each Splitter: principal owed to P holders plus dividends owed to D holders (`reserved`).
- USDG and P/D tokens held by the AMM pools (LP funds).
- Fees in the FeeCollector and staking rewards in ProjectTokenHooks.
- Governance power: the Timelock admin roles.

## Actors and trust
| Actor | Can | Cannot |
|---|---|---|
| Timelock (48h, admin of everything) | list/delist stocks, swap adapters/oracle/fees, resolve corporate actions (set `scale`), unpause, set project token once | act without a 48h public delay; bypass its own delay (no admin role) |
| Proposer (config; a Safe is recommended) | schedule Timelock operations | execute before the delay |
| Guardian | pause a splitter or all markets, clear a keeper blackout | unpause, move funds, change parameters |
| Keeper | announce ex-date blackouts (≤45d each), call the adapter's configured distributor | target any other contract; reduce stock balance (checked) |
| Stock-token issuer | pause, blocklist, upgrade the token (BeaconProxy), change the multiplier | — (fully trusted for the underlying; see R1) |
| Chainlink feeds | set prices | bypass staleness, sanity and round-jump checks |
| Users / LPs / arbitrageurs | everything permissionless | — |

## Top risks from the brief

### R1. The issuer changes the dividend mechanism
*Examples: switches from multiplier to stablecoin airdrop, starts rebasing, or upgrades the token's behaviour.*
- The adapter is resolved from factory config on every harvest. The Timelock swaps it with `updateStockConfig`, and each
  splitter re-initialises adapter state and registers the new payout token automatically.
- Whatever the adapter, the splitter measures balances itself. Unexpected stock inflows above `maxDividendBps`,
  and any shortfall, flag `corporateActionPending` and halt instead of misallocating funds.
- Up to 4 reward tokens per splitter. `addRewardToken` (Timelock) covers a new payout currency.
- Residual risk: the issuer can freeze or blocklist the splitter. That cannot be mitigated on-chain and is disclosed on
  the risk page.
- Tests: `test_AirdropDividendsAndPull`, `test_RebaseDividends`, `test_AdapterCannotIncreaseScale`,
  `test_StockDonationAboveThresholdHalts`, `test_StockShortfallHalts`.

### R2. Splits and reverse splits
- Multiplier tokens: a ≥1.5x or ≤1/1.5x multiplier jump is a split. It is value-neutral for the token, so `scale` is
  unchanged and only adapter state updates. Ambiguous jumps (between dividend size and split size, or small decreases)
  halt the market. While the issuer's `oraclePaused()` is true, split, merge and harvest are deferred.
- Rebasing tokens: a balance doubling exceeds the windfall bound, so the market halts and the Timelock resolves with
  `scale × 2`.
- While halted: split, merge, redeem, swaps, adds and claims revert. LP withdrawals still work.
- Tests: `test_ForwardSplitViaMultiplierIsNeutral`, `test_ReverseSplitViaMultiplierIsNeutral`,
  `test_AmbiguousMultiplierChangeHalts`, `test_RebaseSplitHaltsAndResolves`, `test_IssuerOraclePauseDefers`.

### R3. Flash-split around ex-dates
*Attack: split right before a dividend is captured (or after the record date), take a share of the dividend, merge
right back.*
- **Harvest before mint and burn:** every split, merge and redeem harvests first, so value already received is credited
  to existing D holders before new D exists. Under the multiplier mechanism this makes dividends exactly fair: a D
  holder earns only what its stock earned while deposited. (`test_FlashSplitAfterDividendGetsNothing`)
- **Ex-date blackouts:** for snapshot-based airdrops the keeper announces `(exDate, payDate)`. Splits are disabled
  from ex-date − 1 day until the pay date, so nobody can mint D after the record date and dilute entitled holders.
  Merges stay open; leaving early only forfeits your own dividend. (`test_BlackoutBlocksSplitOnly`)
- **No free dividends:** inflows that arrive while D supply is zero are swept to the FeeCollector, not left for the
  next depositor. (`test_DividendWithNoHoldersIsSwept`)
- **Bounded keeper:** blackouts are capped at 45 days, and the guardian can clear them.

## Other risks

| # | Risk | Mitigation | Evidence |
|---|---|---|---|
| R4 | Accumulator rounding pays out more than received | floor division everywhere; `reserved` tracked exactly; claims bounded by `reserved` | invariants `PaidLeDistributed`, `ClaimableLeReserved`; fuzz `testFuzz_DividendsProRata` |
| R5 | P/D supply drift or under-collateralisation | mint/burn only by the splitter; balance-delta check on deposit; principal uses floor | invariants `PSupplyEqualsDSupply`, `StockBacksPrincipal`, `UnitsEqualStockWhenScaleOne`, `MergeExact` |
| R6 | Reentrancy (stock tokens are upgradeable; D has a transfer hook) | `nonReentrant` on all external mutators; CEI ordering; the D hook only checkpoints | Slither reentrancy detectors clean (see SLITHER section) |
| R7 | Oracle manipulation, staleness or outage | 25h staleness, `answer > 0`, no future timestamps, 20% round-jump guard, optional secondary feed with deviation bound, optional sequencer feed; pools halt on oracle failure, withdrawals do not need the oracle | `OracleAdapterTest` (9 tests), `test_StaleOracleBlocksSwaps` |
| R8 | AMM pricing exploits (round trips, extreme proportions) | post-trade marginal price (always worse than spot), fee on every trade, proportion bounds, `ER ≥ 1`, minimum liquidity burned | fuzz `testFuzz_SellThenBuyNeverProfits`, `testFuzz_DPoolRoundTrip`, `test_SwapGuards` |
| R9 | Sandwiching or stale transactions | every swap/add/remove takes `deadline` plus min-out/max-in; the frontend uses 0.5% slippage and a 20-minute deadline | `test_SwapGuards`, `test_RouterGuards` |
| R10 | Admin key compromise | 48h Timelock owns every admin role; the guardian can only pause; the deploy script asserts the handover | `TimelockTest`, `_assertHandover()` in Deploy.s.sol |
| R11 | Malicious or buggy adapter | adapters are view-only strategies; the splitter refuses `newScale > scale` and measures balances itself | `test_AdapterCannotIncreaseScale` |
| R12 | Keeper `pullDividends` used to drain funds | target fixed by adapter config (Timelock); cannot be the stock, P, D or a reward token; stock balance must not decrease; splitter never approves | `test_PullCannotDrainStock`, `test_PullDividendsGuards` |
| R13 | Staking reward sniping or flash-stake voting | 7-day reward streaming; vote weight = checkpointed stake at proposal time − 1s | `test_StakersEarnStreamedFees`, `test_AdvisoryVoting` |
| R14 | Reward-token list griefing (junk tokens) | hooks only stream allowlisted tokens; anything else goes to the treasury | `test_NonRewardTokenFeesGoToTreasury` |
| R15 | Compliance registry trapping users | gates only split, merge, swap and add; redeem, claim and remove are never gated; off by default | `test_ComplianceGatesSplitButNotRedeem` |
| R16 | Unbounded loops / gas DoS | reward tokens ≤4 per splitter and ≤8 per hooks; allowlist batch ≤200; Router search 64 steps; market list paginated | code review |
| R17 | Clone initialisation front-running | clones are created and initialised in the same `createMarket` transaction; implementations call `_disableInitializers` | `test_CannotReinitialize` |
| R18 | Sequencer downtime (L2) | no uptime feed exists on Robinhood Chain (gap); 25h staleness bounds exposure; feed hook ready | config/chains.ts `gaps` |
| R19 | Issuer blocklists the splitter or pool | not mitigable; disclosed; governance can pause new splits | risk page |

## Out of scope / accepted
- Price-exposure risk for P-pool LPs and rate risk for D-pool LPs (market risk, disclosed).
- Oracle-driven implied-rate drift when the stock price moves (stable reserves are valued through the oracle).
  Arbitrage via split/merge corrects it. Documented in DECISIONS.md.
- Stock-token rebases that happen after a P holder redeems but before the D cutoff go to D holders only on the
  remaining principal (edge case under rebasing mechanisms; not relevant to the multiplier mechanism).

## Static analysis
See the "Slither" section of README.md for the exact command and current result. All high and medium findings were
fixed or triaged there with a written justification.
