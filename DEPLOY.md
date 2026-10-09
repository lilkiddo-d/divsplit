# Deploy

Everything below runs from the repo root on a machine with Foundry, Node 20+ and pnpm 9. No private key is ever
written to disk in plain text, printed, or read by a script. Signing happens only through the encrypted Foundry
keystore account `divsplit-deployer`.

## 0. Before you deploy (one-time edits)

Open `contracts/script/config/4663.json` and set:

| key | what to put |
|---|---|
| `timelockProposer` | the address allowed to schedule Timelock operations. **Use a Safe multisig.** `0x0…0` = the deployer |
| `guardian` | the address allowed to pause (an ops multisig or hot wallet). `0x0…0` = the deployer |
| `keeper` | the bot address that announces ex-date blackouts. `0x0…0` = the deployer |

Every other value (stock tokens, Chainlink feeds, USDG, fees, curve parameters) is already filled in from official
sources (see `config/chains.ts`). Fund the deployer with about 0.005 ETH on Robinhood Chain. The fork run used
~28.2M gas, about 0.0012 ETH at 0.044 gwei.

## 1. Import the deployer key into an encrypted keystore (once)

```bash
cast wallet import divsplit-deployer --interactive
```

You paste the key into the prompt and choose a password. The key is stored encrypted in `~/.foundry/keystores/`.

## 2. Deploy, wire, hand over to the Timelock, and verify (one command)

```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account divsplit-deployer --sender $(cast wallet address --account divsplit-deployer) --broadcast --slow --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

This single command:
- deploys the Timelock (48h), OracleAdapter, FeeCollector, ProjectTokenHooks, ComplianceRegistry (off), the
  Splitter/P/D/AMM implementations, SplitterFactory, Router and the four dividend adapters;
- wires feeds, fee routing and reward tokens, lists AAPL, MSFT, NVDA, GOOGL, META, SPY and QQQ, and opens the next
  two quarterly markets for each (14 markets, 28 pools);
- grants every admin role to the Timelock, renounces the deployer's admin roles, and asserts the handover;
- verifies every contract on Blockscout;
- writes `deployments/4663.json` and `app/src/config/generated/deployments.4663.json`. Commit both.

The keystore password is asked twice: once by `cast wallet address`, once by `forge`.

If Blockscout verification is rate-limited (its API sits behind Cloudflare), re-run verification only:

```bash
cd contracts && forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account divsplit-deployer --sender $(cast wallet address --account divsplit-deployer) --resume --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

**Optional rehearsals** (both already pass, see README):

```bash
# mainnet dry run: simulation only, nothing is sent
cd contracts && forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --sender <ANY_ADDRESS>
```

```bash
# full deploy on a local mainnet fork (two terminals)
bash scripts/fork-up.sh
```

```bash
bash scripts/fork-deploy.sh
```

Note: the fork deploy also writes `deployments/4663.json`. The real deploy overwrites it.

## 3. Later: wire the $DIVS project token (after its launchpad launch)

```bash
bash scripts/set-project-token.sh schedule <DIVS_TOKEN_ADDRESS>
```

After 48 hours (anyone can execute):

```bash
bash scripts/set-project-token.sh execute <DIVS_TOKEN_ADDRESS>
```

The `schedule` call must come from the Timelock proposer. If you set a Safe as proposer, submit the same
`schedule(...)` call from the Safe instead (the script prints nothing secret and shows the exact calldata it uses).
Then set `NEXT_PUBLIC_PROJECT_TOKEN` in Vercel and redeploy the app. See TOKEN_INTEGRATION.md.

## 4. Deploy the frontend to Vercel

1. Push the repo to GitHub (including the generated `app/src/config/generated/deployments.4663.json`).
2. In Vercel: **Add New → Project → import the repo**.
   - Root Directory: `app`
   - Framework preset: Next.js (auto-detected). Install command: `pnpm install`. Build command: `pnpm build`.
   - Keep "Include source files outside of the Root Directory" **enabled**: the app imports `/config/chains.ts`.
3. Environment variables (Production):

| name | value |
|---|---|
| `NEXT_PUBLIC_CHAIN_ID` | `4663` |
| `NEXT_PUBLIC_RPC_URL` | your provider URL (e.g. Alchemy `https://robinhood-mainnet.g.alchemy.com/v2/<key>`); the public RPC is rate-limited |
| `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` | from cloud.walletconnect.com (optional; injected wallets work without it) |
| `NEXT_PUBLIC_PROJECT_TOKEN` | empty until $DIVS is wired on-chain |
| `NEXT_PUBLIC_GEOBLOCK_COUNTRIES` | e.g. `US,CA,GB,CH` to enable the geoblock (empty = off) |

Do **not** set `NEXT_PUBLIC_DEV_IMPERSONATE` in production. It only works with a localhost RPC anyway.

4. Deploy. CLI alternative from the repo root:

```bash
cd app && npx vercel --prod
```

## After deploy: operations checklist
- Move the Timelock proposer to a Safe if you used the deployer (Timelock op: `grantRole(PROPOSER_ROLE, safe)` +
  `revokeRole(PROPOSER_ROLE, deployer)`).
- Run a keeper that calls `harvest()` on each splitter after every issuer corporate action (process dates come from
  the issuer feed shown in the app). Harvest is permissionless, so any account can do it.
- Seed liquidity in each P and D pool. The first deposit sets the opening ratio; the opening implied rate comes from
  `initialAnchor`.
