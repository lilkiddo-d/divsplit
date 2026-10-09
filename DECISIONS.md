# Decisions

One line of reasoning per decision. Newest decisions are at the bottom of each section.

## Chain and external data
- **Primary dividend mechanism = ERC-8056 multiplier.** Research found that Robinhood Chain stock tokens reinvest cash dividends by raising `uiMultiplier()`. There are no airdrops and no rebases (docs/research/robinhood-chain.md).
- **Ship four adapters anyway** (multiplier, rebase, airdrop, none). An issuer mechanism change then becomes a Timelock config change, not a migration.
- **Quote stablecoin = USDG** (6 dec). It is the only stablecoin in the official docs; USDC on this chain was NOT FOUND.
- **Oracle = Chainlink AggregatorV3 feeds** behind a swappable `OracleAdapter`. Chainlink is the only provider in the docs; Pyth, RedStone and Chronicle were NOT FOUND.
- **No sequencer-uptime feed is configured.** None exists on the chain. The adapter supports one, so it is one Timelock call when one appears.
- **Listed at launch: AAPL, MSFT, NVDA, GOOGL, META, SPY, QQQ.** These are dividend payers with a Chainlink feed. Tokens without a feed (e.g. SCHD) are not listed (documented gap).
- **Staleness = 25h**: the feed heartbeat is 24h, plus a 1h buffer. **Round-jump guard = 20%** on stock feeds, which do not have a secondary feed.

## Core accounting
- **`scale` (stock per P unit) instead of rebasing P/D.** P and D stay plain fixed-supply ERC-20s, and merge returns exactly one stock per pair until a dividend is reinvested.
- **Under the multiplier mechanism, merge returns `scale` tokens** (the same number of shares). Merge + claimed dividend = exactly the tokens deposited; the invariants test this exact identity.
- **D accrues dividends until `expiry + trailingWindow` (30d).** Dividends announced inside the term but processed just after expiry still go to D.
- **After the D cutoff, dividends go to remaining P holders:** stock dividends raise `scale`, cash dividends are paid per P on redeem. This is fair to slow redeemers and needs no new accumulator.
- **Dividends that arrive with no entitled holder** (zero supply) are swept to the FeeCollector. Otherwise a future depositor could capture them, which would make flash-splitting profitable.
- **Accumulator with ≤4 reward tokens and 1e27 precision.** Per-transfer cost is O(reward tokens), never O(holders).
- **Rounding dust tolerance of 1,000 wei** before a windfall counts as a corporate action. Invariant fuzzing found that tiny positions could falsely halt a market.

## Corporate actions and safety
- **Halt-and-resolve through the Timelock for ambiguous changes; auto-handle clean splits under the multiplier.** Splits are value-neutral for multiplier tokens, so halting markets for 48h on every split would be pointless.
- **Guardian can pause but only the Timelock can unpause or resolve.** A compromised guardian can annoy users but cannot steal.
- **Pause blocks split, merge, redeem, swaps and adds. Claims and LP withdrawals stay open.** Users can always take what is already theirs.
- **Exits (redeem, claim, remove liquidity) are never compliance-gated.** An allowlist must never trap funds.
- **Anti flash-split: harvest-before-mint plus keeper-announced ex-date blackouts** (splits disabled from ex-date − 1 day until pay date, max 45 days, guardian can clear). Harvest ordering already makes multiplier dividends fair. Blackouts cover snapshot-based airdrops.
- **`pullDividends` can only target the adapter's configured distributor.** Never the stock, P, D or a reward token, and the stock balance must not decrease.
- **Fee-on-transfer stock tokens are rejected** (`TransferAmountMismatch`) to keep the invariants exact.

## AMM
- **Pendle-V2 logit curve with rate anchor.** It gives time-aware convergence (P → 1 pair, D → 0) and a continuous implied rate that does not drift with time alone.
- **Asset side = USDG valued in "units" via the oracle** (unit = what one P+D redeems for: `price × scale`). The spec asks for P/stable and D/stable pools.
- **Separate `scalarRoot` for the D pool (default 300 vs 50).** D is a leveraged claim on the rate, so with the same curve a 1-logit move would swing the D price by more than 100%.
- **Marginal price at the post-trade token balance with the asset held fixed**, instead of Pendle's pre-trade denominator. Pendle's version went out of range on large sells into D-heavy pools (fuzz found it). The trade is still always worse than spot, so no round-trip profit.
- **Proportion bounds P [1%, 96%], D [4%, 99%].** Each pool's cheap side may be heavy.
- **The first LP sets any ratio; the opening implied rate comes from listing config** (`initialAnchor` = 1 + annual yield, default 1%).
- **Fees: 0.30% swap fee, 20% of it to the protocol.** The protocol share goes to the FeeCollector and is split 50/50 between stakers and the treasury once $DIVS is live.
- **Swaps stop at expiry; remove-liquidity is never blocked.**
- **Exact-in buys use an on-chain 64-step binary search in the Router.** Bounded gas and no off-chain quoting dependency.

## Deployment and governance
- **Clones (EIP-1167) for Splitter, P, D and pools; implementations deployed separately.** This keeps the factory under the size and initcode limits.
- **Expiries = 00:00 UTC on Jan 1 / Apr 1 / Jul 1 / Oct 1.** Jan 1 is the "yearly" term. `createMarket` is permissionless for listed stocks within a 2-year horizon.
- **Deploy opens the next 2 quarterly expiries for every listed stock** (14 markets). Anyone can open more.
- **Timelock: 48h, proposer = config address (defaults to the deployer; a Safe is recommended), executor = anyone, no admin.** Even role changes on the timelock itself are delayed.
- **The deployer is admin only during the deploy transaction batch.** The script grants admin to the Timelock, renounces its own admin, and asserts both.
- **Fork testing uses `anvil --auto-impersonate` + `--unlocked`.** No private key is created, read or printed anywhere.
- **The public RPC is not an archive node**, so fork tests and the fork deploy run at the latest block, right after the fork starts.
- **`cast.exe` is intermittently blocked by Windows Application Control on the build machine.** The scripts use curl JSON-RPC instead.

## Project token
- **No ERC-20 is written or deployed.** `ProjectTokenHooks.setProjectToken` is Timelock-only and can be called once. Every token feature reverts or hides until it is called.
- **Staking rewards stream over 7 days (Synthetix-style)** and **votes use stake checkpoints at proposal time − 1s**. Together these defeat stake-sniping of fee distributions and flash-stake voting.
- **Votes are advisory**, per the spec. Execution is always a separate Timelock proposal.
- **Only allowlisted reward tokens (≤8) can be streamed.** Junk tokens sent to the FeeCollector go to the treasury, so nobody can fill the reward list.

## Frontend
- **Next.js App Router + wagmi/viem + RainbowKit, hand-written CSS.** Few dependencies and fast builds.
- **Ex-dates and historical yield come from the issuer's public corporate-actions API**, proxied server-side (CORS, 1h cache). On-chain keeper notices are a fallback.
- **The implied-yield chart is built from on-chain `Swap.lnImpliedRate`**, so it needs no indexer.
- **A dev-only impersonated connector** (`NEXT_PUBLIC_DEV_IMPERSONATE`) is enabled only when the RPC is localhost. It lets the UI be exercised against the fork without a browser wallet or any key.
- **Geoblock via Vercel `x-vercel-ip-country` middleware**, off by default. The risk page stays reachable.
- **Branding is neutral ("Divsplit"),** with no issuer names or logos. The issuer is called "the stock-token issuer".
