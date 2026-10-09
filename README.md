# Divsplit

Divsplit splits a dividend-paying **stock token** on Robinhood Chain into two tradable parts for a fixed term:

- **P (Price token)**: keeps the price exposure and redeems the stock at expiry.
- **D (Dividend token)**: receives every dividend the stock pays until expiry, then expires worthless.

`1 stock → 1 P + 1 D` (split). `1 P + 1 D → 1 stock` before expiry (merge). After expiry, `P → stock` (redeem).
Built-in time-decay AMM pools (P/USDG and D/USDG, Pendle-style) price both legs and converge correctly as expiry
nears. The dashboard turns the D price into an **implied dividend yield** and compares it with the trailing yield.

> P and D are product tokens. The protocol has no project token of its own. $DIVS launches separately; see
> [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md).

## How dividends work on Robinhood Chain

Stock tokens are ERC-20s with an ERC-8056 `uiMultiplier()`. Cash dividends are **reinvested** by raising the
multiplier; balances never change. Divsplit's `MultiplierDividendAdapter` turns each multiplier step into a carve-out
of stock for D holders, so P keeps representing the same number of shares. Splits are value-neutral jumps, and
ambiguous jumps halt the market for governance. Rebase, airdrop and no-dividend adapters also ship, so an issuer
mechanism change only needs a config update. Details: [docs/adapters.md](docs/adapters.md). Research and sources:
[docs/research/robinhood-chain.md](docs/research/robinhood-chain.md), [config/chains.ts](config/chains.ts).

## Repo layout

```
contracts/   Foundry project (Solidity 0.8.28, OpenZeppelin v5, Solady math)
  src/core        SplitterFactory, Splitter, DividendAccumulator, PToken, DToken
  src/adapters    Multiplier / Rebase / Airdrop / NoDividend adapters
  src/amm         TimeDecayAMM (+ libraries/MarketMath)
  src/periphery   Router
  src/oracle      OracleAdapter (Chainlink AggregatorV3, staleness + deviation checks)
  src/governance  DivsplitTimelock, FeeCollector, ProjectTokenHooks, ComplianceRegistry
  script/         Deploy.s.sol (the one deploy script), SeedFork.s.sol (local fork only), config/4663.json
  test/           unit, fuzz, invariant, fork
app/         Next.js + wagmi/viem + RainbowKit frontend
config/      chains.ts: chain + external addresses with source links
scripts/     fork-up.sh, fork-deploy.sh, set-project-token.sh, slither.sh
docs/        adapters.md, research/robinhood-chain.md
deployments/ <chainId>.json written by the deploy script
```

## Contracts at a glance

| Contract | Purpose |
|---|---|
| `SplitterFactory` | config + roles hub; lists stocks (Timelock); permissionless `createMarket(stock, quarterlyExpiry)` deploys Splitter, P, D and two pools as clones |
| `Splitter` | holds the stock; split/merge/redeem; `harvest()` captures dividends; corporate-action detection; ex-date blackouts |
| `DividendAccumulator` | loop-free reward-per-unit accounting for D holders (≤4 reward tokens) |
| `PToken` / `DToken` | ERC-20 + permit; D checkpoints holders on every transfer |
| `TimeDecayAMM` | logit curve with time-scaled steepness and a rate anchor; LP token; oracle-valued USDG side |
| `Router` | exact-in buys (bounded binary search), split-and-sell, buy-and-merge; deadlines and slippage on everything |
| `OracleAdapter` | per-asset primary/secondary feeds, staleness, round-jump and deviation checks, optional sequencer feed |
| `FeeCollector` | protocol fee share → stakers (when $DIVS is live) and treasury |
| `ProjectTokenHooks` | `setProjectToken` (once, via Timelock), staking with streamed fee rewards, advisory listing votes |
| `ComplianceRegistry` | optional allowlist for split/merge/swap/add (off by default; exits never gated) |
| `DivsplitTimelock` | 48h TimelockController that owns every admin role |

## Quick start

```bash
pnpm install
```

```bash
cd contracts && forge build && forge test
```

```bash
pnpm --filter @divsplit/app build
```

### Run everything against a local mainnet fork

Terminal 1:

```bash
bash scripts/fork-up.sh
```

Terminal 2 (deploys, funds a test account with `anvil_dealERC20`, seeds every pool):

```bash
bash scripts/fork-deploy.sh
```

Then start the app against the fork. "Use fork test account" in the header connects an anvil-impersonated account,
so no wallet or key is needed:

```bash
cd app && NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8555 NEXT_PUBLIC_DEV_IMPERSONATE=0x2000000000000000000000000000000000000d15 pnpm dev
```

Open http://localhost:3100.

### Fork tests against real mainnet tokens

```bash
cd contracts && ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*" -vv
```

These use the real AAPL token, the AAPL/USD and USDG/USD Chainlink feeds, and real USDG. They are skipped when
`ROBINHOOD_RPC_URL` is unset.

## Status (see the "Verification log" below)

## Documents
- [DEPLOY.md](DEPLOY.md): the exact commands to deploy, verify, wire the token later, and ship the app to Vercel
- [DECISIONS.md](DECISIONS.md): every judgement call, with one line of reasoning each
- [THREAT_MODEL.md](THREAT_MODEL.md): assets, trust, top risks (mechanism changes, splits, flash-splits) and mitigations
- [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md): how $DIVS plugs in without the protocol deploying a token
- [docs/adapters.md](docs/adapters.md): dividend mechanisms and adapters
- Risk disclosure: `/risk` in the app

## Compliance
Branding is neutral and uses no issuer names or logos. The app ships an optional geoblock
(`NEXT_PUBLIC_GEOBLOCK_COUNTRIES`), a risk-disclosure page, and an on-chain `ComplianceRegistry` hook that is off
by default.
