# $DIVS project-token integration

Divsplit does **not** write, deploy or mint any project ERC-20. $DIVS will be launched separately on a launchpad.
The protocol works completely without it. Until the Timelock wires it in, every token feature is disabled on-chain
and hidden in the UI.

## What the token does
1. **Fee share for stakers.** The AMM sends 20% of every swap fee (0.30%) to the `FeeCollector`. Anyone can call
   `FeeCollector.distribute(token)`. While $DIVS is live and staked, `stakerShareBps` (default 50%) of that balance
   goes to `ProjectTokenHooks` and streams to stakers over 7 days. The rest goes to the treasury (the Timelock).
   Before the token is set, 100% goes to the treasury.
2. **Staker-weighted listing votes (advisory).** Stakers propose and vote on which stocks and expiries to list.
   Voting weight is your stake at `proposal time − 1s` (checkpointed, so flash-staking gives no votes). A proposal
   passes if `for > against` and `for ≥ quorum` (default 4% of stake at the snapshot). Results are advisory. Execution
   is a normal Timelock operation (`SplitterFactory.listStock` / `createMarket`), which itself waits 48h.

## Contracts involved
| Contract | Role |
|---|---|
| `ProjectTokenHooks` | holds `projectToken`; staking, reward streaming, proposals and votes |
| `FeeCollector` | forwards the staker share to the hooks only when `hooks.isActive()` and the token is an allowlisted reward token |
| `DivsplitTimelock` | the only account that can call `setProjectToken` |

`setProjectToken(address)`:
- callable by `DEFAULT_ADMIN_ROLE` (the Timelock) **exactly once**;
- rejects `address(0)` and addresses without code;
- emits `ProjectTokenSet(token)`.

Until then `stake`, `unstake`, `propose` and `castVote` revert with `TokenFeaturesDisabled()`, `isActive()` returns
false, and the FeeCollector routes everything to the treasury.

USDG is pre-registered as a staking reward token by the deploy script. More reward tokens (≤8) need
`ProjectTokenHooks.addRewardToken` through the Timelock.

## Turning it on (after the launchpad launch)
```bash
# 1) schedule (proposer account; 48h delay)
bash scripts/set-project-token.sh schedule <DIVS_TOKEN_ADDRESS>
# 2) after 48h, anyone can execute
bash scripts/set-project-token.sh execute <DIVS_TOKEN_ADDRESS>
```
The script reads `deployments/4663.json`, ABI-encodes `setProjectToken(<DIVS>)` for `projectTokenHooks` and calls
`schedule` / `execute` on the Timelock. It signs with the Foundry keystore account `divsplit-deployer` (or
`ACCOUNT=<name>`).

Then set `NEXT_PUBLIC_PROJECT_TOKEN=<DIVS>` in Vercel and redeploy the app. The "Stake & Vote" page appears. While the
variable is empty, the page and nav link are hidden. If the variable is set but the on-chain call has not executed
yet, the page shows a banner and disables its buttons.

## Testing
Unit tests use a **mock** ERC-20 (`test/mocks/Mocks.sol: MockERC20`) only:
`ProjectTokenHooksTest` covers the disabled state, one-time set, streaming fee share, reward-token allowlisting,
flash-stake resistance, quorum and advisory states.
