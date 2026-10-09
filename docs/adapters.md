# Dividend adapters

Research (docs/research/robinhood-chain.md, 2026-10-08) found that Robinhood Chain stock tokens are ERC-20s
(18 decimals) implementing **ERC-8056 "Scaled UI Amount"**. Raw balances never change. Cash dividends are
**reinvested** by raising `uiMultiplier()` (1e18 = one share per token), and splits/reverse splits are large multiplier
jumps scheduled while `oraclePaused()` is true. There is no stablecoin airdrop and no balance rebasing today.

Divsplit still ships one adapter per mechanism that exists in the tokenized-stock world, so a mechanism change by the
issuer is a Timelock config change (`SplitterFactory.updateStockConfig`), not a redeploy. Existing splitters switch
adapters on their next harvest.

All adapters are stateless strategies. The Splitter holds all funds and per-splitter state and always measures
balances itself, so a buggy adapter can never move tokens.

| Adapter | Mechanism | `scale` behaviour | Payout token | Used for |
|---|---|---|---|---|
| `MultiplierDividendAdapter` | ERC-8056 multiplier rises with each reinvested dividend | dividend step: `scale *= m0/m1`, freed stock goes to D; split-sized step (≥1.5x or ≤1/1.5x): unchanged, state updated; anything else: corporate action (halt) | the stock itself | **All Robinhood Chain listings** |
| `RebaseDividendAdapter` | Holder balances increase (rebase / reinvest by mint) | unchanged; splitter distributes `balance − principal − reserved` | the stock itself | Rebasing stock tokens |
| `AirdropDividendAdapter` | Issuer sends (or lets holders claim) a stablecoin | unchanged; keeper may call the configured distributor via `pullDividends` | configured per stock (Timelock) | Airdrop / claim-based issuers |
| `NoDividendAdapter` | No dividends, or paid off-chain | unchanged | – | Non-payers |

## Multiplier mechanism in detail

A P unit is a claim on a fixed number of underlying **shares**. At split time 1 token = 1 P + 1 D (scale = 1e18).
When the issuer reinvests a dividend, the multiplier moves from `m0` to `m1 > m0`, so the same number of shares is now
`m0/m1` tokens. The splitter lowers `scale` to `scale·m0/m1` and the `1 − m0/m1` fraction of the stock it holds
becomes a dividend credited to D holders through the accumulator. Those holders claim it in the stock token.

Robinhood Chain Chainlink feeds already include the multiplier (price per raw token), so pool pricing values one P+D
pair at `oraclePrice × scale`.

Classification thresholds:

- `1 < m1/m0 ≤ 1 + maxDividendBps` → dividend (default `maxDividendBps` = 5%).
- `m1/m0 ≥ 1.5` or `≤ 1/1.5` → forward or reverse split. This is value-neutral for token holders under a
  multiplier, so `scale` stays unchanged and the market keeps running.
- Anything else, including a small decrease → `corporateActionPending`. Split, merge, redeem, swaps and claims halt
  until the Timelock calls `resolveCorporateAction(newScale, newState)`.
- `oraclePaused()` → harvest is deferred and split/merge revert with `IssuerUpdateInProgress`.

## Generic safety net (all adapters)

- **Shortfall:** stock balance below `principal + reserved` (clawback, reverse rebase) → corporate action.
- **Windfall:** stock excess above `maxDividendBps × principal + dust` (rebasing split, large donation) → corporate
  action, so a split can never be paid to D holders.
- **Ordering:** harvest runs before every split, merge and redeem, so dividends already received go to the holders
  who earned them, never to a new depositor.
