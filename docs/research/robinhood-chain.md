# Robinhood Chain (Mainnet) — Research Notes

Researched 2026-10-08. Every address below is either quoted from an official source (link given) or read from an official API, and was then checked on-chain against the public mainnet RPC. Anything I could not source officially is marked **NOT FOUND**.

Source keys such as [S1] point to the Sources section at the end.

---

## 1. Network parameters

| Item | Mainnet | Testnet | Source |
|---|---|---|---|
| Chain ID | **4663** (RPC returned `0x1237`) | **46630** (RPC returned `0xb626`) | [S1], verified live |
| Public RPC (HTTP) | `https://rpc.mainnet.chain.robinhood.com` | `https://rpc.testnet.chain.robinhood.com` | [S1] |
| Provider RPC (HTTP) | `https://robinhood-mainnet.g.alchemy.com/v2/{API_KEY}` | `https://robinhood-testnet.g.alchemy.com/v2/{API_KEY}` | [S1] |
| WebSocket | `wss://robinhood-mainnet.g.alchemy.com/v2/{API_KEY}` (Alchemy, needs a key) | `wss://robinhood-testnet.g.alchemy.com/v2/{API_KEY}` | [S1] |
| Public WS RPC | **NOT FOUND**. The docs list no keyless WS JSON-RPC endpoint. | NOT FOUND | [S1] |
| Sequencer endpoint | `https://sequencer.mainnet.chain.robinhood.com` | `https://sequencer.testnet.chain.robinhood.com` | [S1] |
| Sequencer feed (Nitro feed, not JSON-RPC) | `wss://feed.mainnet.chain.robinhood.com` | `wss://feed.testnet.chain.robinhood.com` | [S1] |
| Block explorer | `https://robinhoodchain.blockscout.com` (Blockscout) | `https://explorer.testnet.chain.robinhood.com` | [S1] |
| Explorer API / verifier URL | `https://robinhoodchain.blockscout.com/api/` | `https://explorer.testnet.chain.robinhood.com/api/` (only a third-party source shows this as a verifier URL; it follows the Blockscout pattern) | [S2] (mainnet); testnet see note |
| Native gas token | ETH | ETH | [S1], [S3] |

The docs say the public endpoints are "rate-limited and not recommended for production use" [S1]. I saw this myself: after about 30 fast sequential calls, the mainnet RPC started returning a Cloudflare "Just a moment..." HTML challenge. Batch your JSON-RPC calls and throttle them, or use Alchemy, Chainstack or QuickNode.

### Contract verification (official, [S2])

```bash
forge verify-contract <contract_address> src/X.sol:X \
  --chain-id 4663 \
  --rpc-url $RH_RPC_URL \
  --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api/
```
Hardhat: `npx hardhat verify --network robinhood <address>` [S2].

- The explorer is Blockscout. I found no Etherscan API v2 support for 4663. A third-party guide also says Etherscan v2 does not support 4663 (unofficial, [S20]).
- Testnet: the official deploy page I fetched shows only mainnet verification. `--chain-id 46630 --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api/` comes from a third-party guide [S20]. The testnet Blockscout `/api/v2/stats` endpoint does respond (HTTP 200).
- **Caveat:** from this machine, `https://robinhoodchain.blockscout.com/api...` returned **HTTP 403 with a Cloudflare challenge** to curl. Verification from CI may be blocked too. Test it before relying on it.

---

## 2. Stock Tokens

### Design (official)
- Standard **ERC-20**, **18 decimals** [S3][S4]. On-chain `decimals()` returned 18 for every token I checked.
- Each token implements **ERC-8056 "Scaled UI Amount"**: `uiMultiplier()`, `newUIMultiplier()`, `effectiveAt()`, `balanceOfUI(address)`, `totalSupplyUI()`, plus the events `UIMultiplierUpdated(oldMultiplier,newMultiplier,effectiveAtTimestamp)` and `TransferWithScaledUI(from,to,value,uiValue)` [S4].
- `underlying shares = raw amount × uiMultiplier / 1e18`. The multiplier started at 1e18 [S4].
- Legal wrapper: tokenized debt securities issued by **Robinhood Assets (Jersey) Limited**. They give economic exposure only, with no legal or beneficial rights in the underlying [S10].
- **On-chain observation (my analysis, not documented):** every token checked is a 283-byte **BeaconProxy**. The beacon is stored in the EIP-1967 beacon slot: `0xe10b6f6b275de231345c20d14ab812db62151b00`. `implementation()` on that beacon returns `0xb35490d6f9163de4f80d88dc75c3516eb64c5ae2` (11,614 bytes). So all stock tokens share one upgradeable implementation, and Robinhood can upgrade all of them at once. `owner()` reverts, and the implementation has `hasRole(bytes32,address)`, so it likely uses role-based access control.

### Official addresses
The authoritative list is the **live asset registry** in the Robinhood API `GET https://api.robinhood.com/rhj/assets` [S5]. The Token Contracts page [S6] says its table is "generated live from the on-chain asset registry". On 2026-10-08 the API returned **194 assets, all on chainId 4663, all `ASSET_STATUS_ACTIVE`, all `tokenDecimals: 18`**. The full table is in the Appendix.

Major tickers (registry address, then checked on-chain against the public RPC on 2026-10-08):

| Symbol | Address | on-chain name() | decimals | uiMultiplier (raw) | effectiveAt |
|---|---|---|---|---|---|
| AAPL | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | Apple • Robinhood Token | 18 | 1000566080061092436 | 1786720366 |
| TSLA | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | Tesla • Robinhood Token | 18 | 1000000000000000000 | 0 |
| NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | NVIDIA • Robinhood Token | 18 | 1000775159164630595 | 1788998430 |
| MSFT | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` | Microsoft • Robinhood Token | 18 | 1000412952576205964 | 1789139430 |
| AMZN | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` | Amazon • Robinhood Token | 18 | 1000000000000000000 | 0 |
| GOOGL | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` | Alphabet Class A • Robinhood Token | 18 | 1000193924414112587 | 1789485027 |
| META | `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35` | Meta Platforms • Robinhood Token | 18 | 1000541459879451635 | 1789950036 |
| COIN | `0x6330D8C3178a418788dF01a47479c0ce7CCF450b` | Coinbase • Robinhood Token | 18 | 1000000000000000000 | 0 |
| SPY | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` | SPDR S&P 500 ETF Trust • Robinhood Token | 18 | 1001717991187472003 | 1789690233 |
| QQQ | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` | Invesco QQQ • Robinhood Token | 18 | 1000700791241405425 | 1790035834 |
| SCHD | `0xd63ABB2C13d7a8421a8017a712802053568e3C1D` | Schwab US Dividend Equity ETF • Robinhood Token | 18 | 1005538606893683992 | 1790208634 |
| ORCL | `0xb0992820E760d836549ba69BC7598b4af75dEE03` | Oracle • Robinhood Token | 18 | 1002210914971013375 | 1785165023 |

For every token in this table, `newUIMultiplier() == uiMultiplier()`, meaning no update was pending, and `paused() = 0` and `oraclePaused() = 0`.

---

## 3. Dividends and corporate actions

**Mechanism: a non-rebasing ERC-8056 multiplier with automatic dividend *reinvestment*.** There is **no stablecoin airdrop** and **no balance rebasing**.

- "dividends and stock splits [are managed] through an onchain multiplier, which adjusts the shares-per-token ratio while keeping your raw balance static until redemption" [S3].
- Raw `balanceOf` never changes. `uiMultiplier()` changes and emits `UIMultiplierUpdated` [S4].
- **Cash dividends** are reinvested as a small multiplier increase, e.g. 1.000 → 1.008, applied immediately [S7]. The oracle docs say "As dividends reinvest, the multiplier increases", so token value drifts above the headline share price [S8].
- **Splits:** a large multiplier change during a scheduled pause window (10:1 split means 1.0 → 10.0). **Reverse splits and spin-offs** lower the multiplier or change it depending on the event [S7].
- Update paths: `updateMultiplier(uint256)` takes effect immediately, and `updateMultiplier(uint256,uint256 effectiveAt)` is scheduled and exposed via `newUIMultiplier()` / `effectiveAt()` [S7]. The selector `updateMultiplier(uint256,uint256)` = `0xbad60f18` is present in the implementation bytecode.
- **Oracle pause:** during corporate actions Robinhood calls `pauseOracle()`, stages the multiplier, then calls `unpauseOracle()`. While `oraclePaused()` is true the Chainlink feed holds the last value [S7][S8].
- Corporate-action history: `GET https://api.robinhood.com/rhj/corporate-actions` [S5]. On 2026-10-08 it returned 48 actions, **all of type `CORPORATE_ACTION_TYPE_CASH_DIVIDEND`**. Each has `details.cashDividend.{underlyingSymbol, rate}`, where rate is USD per share, e.g. ORCL 0.5, processDate 2026-10-23. Statuses were IN_PROGRESS or COMPLETED. No split records were present in that window. The `/assets` endpoint also exposes `currentMultiplier` and `pendingMultiplier`.
- Live examples: the SCHD multiplier is 1.00554 and the SPY multiplier is 1.00172. Non-dividend payers (TSLA, AMZN, COIN) sit at exactly 1e18, which is consistent with reinvestment.

Useful selectors, computed via `web3_sha3` on the chain RPC: `uiMultiplier()`=`0xa60bf13d`, `newUIMultiplier()`=`0xdc767007`, `effectiveAt()`=`0x97a4064f`, `balanceOfUI(address)`=`0x437a9958`, `totalSupplyUI()`=`0x9bea6429`, `oraclePaused()`=`0x7706ba52`. The `UIMultiplierUpdated(uint256,uint256,uint256)` topic0 is `0x2205df4534432b2f60654a3fdb48737ffdaf3e9edb1a498bd985bc026b15b055`. **Uncertain:** that topic assumes all three parameters are `uint256`, and I could not see the verified ABI because Blockscout was Cloudflare-blocked. Confirm it against the verified source.

### Transfer restrictions
- **Docs:** the official Stock Token pages do not document allowlists, KYC gating at contract level, a blocklist, or pausing [S3][S4]. Off-chain restrictions: no offers, sales or delivery to **US persons**, plus restrictions in Canada, the UK and Switzerland. Robinhood Assets (Jersey) Limited publishes the full list [S10]. The Chainlink docs note that "primary mint/redeem may be permissioned" [S7].
- **On-chain bytecode scan (my analysis):** the implementation `0xb354…5ae2` contains the selectors **`pause()`, `unpause()`, `paused()`, `isBlocked(address)`**, `mint(address,uint256)`, `burn(address,uint256)`, `permit(...)` (EIP-2612), `hasRole`, and `supportsInterface`. It does **not** contain common allowlist selectors (`isAllowed`, `isAllowlisted`, `isWhitelisted`), `freeze`, or `forceTransfer`. So the token is very likely **pausable** and has a **per-address blocklist**, but is **not allowlist-gated**. Inferring this from bytecode can miss renamed functions; confirm with the verified source on Blockscout.
- **Contracts holding tokens:** I found nothing that forbids it. The docs describe composability with Uniswap AMM pools, RFQ (0x, 1inch Fusion, LiFi), Rialto and Lighter [S4], and AMM pools are contracts that hold the tokens. That is strong but indirect evidence that contracts can hold Stock Tokens.

---

## 4. Stablecoins

| Token | Address | Decimals | Source |
|---|---|---|---|
| USDG (Global Dollar) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | **6** (on-chain `decimals()`; name "Global Dollar", symbol "USDG") | [S6] |
| USDC (native, Circle) | **NOT FOUND**. Robinhood Chain is not listed on Circle's USDC address page [S11]. | – | [S11] |
| USDC (bridged) | **NOT FOUND** in official docs. A Chainlink USDC/USD feed exists, but no token address is given. | – | – |

USDG on-chain code is 170 bytes, so it is a proxy.

---

## 5. Oracles

**Chainlink Data Feeds** are the oracle that the official Robinhood docs name [S8]. The docs point to Chainlink's address page rather than listing addresses. Chainlink's feed directory JSON for `robinhood-mainnet` [S9] lists 58 feeds. All are 8-decimal USD feeds except the exchange-rate feeds (18 decimals), and all have a 86400s heartbeat. Selected Robinhood stock feeds (proxy addresses):

| Feed | Proxy |
|---|---|
| Robinhood AAPL / USD | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` |
| Robinhood TSLA / USD | `0x4A1166a659A55625345e9515b32adECea5547C38` |
| Robinhood NVDA / USD | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` |
| Robinhood MSFT / USD | `0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E` |
| Robinhood AMZN / USD | `0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C` |
| Robinhood GOOGL / USD | `0xF6f373a037c30F0e5010d854385cA89185AE638b` |
| Robinhood META / USD | `0x7C38C00C30BEe9378381E7B6135d7283356D71b1` |
| Robinhood SPY / USD | `0x319724394D3A0e3669269846abE664Cd621f9f6A` |
| Robinhood QQQ / USD | `0x80901d846d5D7B030F26B480776EE3b29374C2ae` |
| ETH / USD | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` |
| USDC / USD | `0x9e6f4605992a899eE2999999F3Ec80C41F452546` |
| USDG / USD | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` |

The full list is in the Appendix. **Not every stock token has a feed:** 194 tokens versus about 36 equity feeds. ORCL has a feed, but SCHD has none in the list, so check each token individually.

- Feed price = underlying price × `uiMultiplier()`. Do **not** apply the multiplier again [S4][S7][S8]. Feeds update 24/5 [S8].
- Live check: `latestRoundData()` on the AAPL feed returned answer `0x7ecbca2e3` = 34,032,264,931, which is **$340.32** at 8 decimals. `updatedAt` was `0x6ac7e32d`, and `description()` was "Robinhood AAPL / USD".
- **L2 Sequencer Uptime Feed:** the Robinhood docs tell integrators to check it [S8], but **NOT FOUND**. Robinhood Chain is not on Chainlink's L2 sequencer feeds page [S12], and no such feed is in the robinhood-mainnet directory JSON.
- **Chainlink Data Streams:** Verifier Proxy (mainnet 4663) = `0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7` [S13]. It has code on-chain (7,009 bytes).
- **Pyth / RedStone / Chronicle:** **NOT FOUND.** I found no official deployment address for Robinhood Chain. Chainstack marketplace pages mention these providers in general terms only.

---

## 6. Canonical contracts (L2 mainnet)

| Contract | Address | Official? | On-chain code (bytes) |
|---|---|---|---|
| WETH (L2, Arbitrum aeWETH) | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | Yes [S6][S14] | 2202; name/symbol "WETH", 18 decimals |
| L2 Multicall (Arbitrum-style, listed in docs) | `0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1` | Yes [S14] | 3339 |
| Multicall3 canonical | `0xcA11bde05977b3631167028862bE2a173976CA11` | Not in Robinhood docs. **Deployed: yes**, code present. | 3808 |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Yes [S14] | 9152 |
| CREATE2 deterministic deployer (Arachnid) | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | Not in docs; code present | 69 |
| Safe Singleton Factory | `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7` | Not in docs; code present | 69 |
| CreateX | `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` | Not in docs; code present | 11838 |
| L2 Gateway Router | `0x1E324B9316138CA9a73F960213621AD1aaf01B89` | Yes [S14] | – |
| L2 ERC20 Gateway | `0xfd9b17206278C16DdaacF6AC8f05dBf97EdCb31e` | Yes [S14] | – |
| L2 WETH Gateway | `0x1D187C3E2dA52D72BC9C41e3AbA0fdFa6a7bF055` | Yes [S14] | – |

For the L1 rollup and bridge contracts, see [S14]: Rollup `0x23A19d23e89166adedbDcB432518AB01e4272D94`, Bridge `0xDf8755334ce7A73cCF6b581C02eA649AE3E864b3`, and L1 Gateway Router `0x6a2E3a1e16FC29f27Ce61429746D558d656975bB`.

Testnet: WETH `0x7943e237c7F95DA44E0301572D358911207852Fa`, L2 Multicall `0xa432504b6F04Cafe775b09D8AA92e8dbe41Ec7a8`, Permit2 same address [S14].

---

## 7. Live RPC tests (raw results, 2026-10-08)

```
POST https://rpc.mainnet.chain.robinhood.com eth_chainId     -> {"jsonrpc":"2.0","id":1,"result":"0x1237"}      (=4663)
POST https://rpc.mainnet.chain.robinhood.com eth_blockNumber -> {"jsonrpc":"2.0","id":1,"result":"0x4fbb265"}   (=83,604,069)
POST https://rpc.testnet.chain.robinhood.com eth_chainId     -> {"jsonrpc":"2.0","id":1,"result":"0xb626"}      (=46630)
```
- Without an API key, the RPC is publicly reachable over HTTP. Bursts of about 30 or more requests triggered a Cloudflare HTML challenge in place of JSON. Use JSON-RPC batching with backoff.
- `eth_getCode` / `eth_call` results are shown in the tables in sections 2, 4 and 6. All token addresses listed there have non-empty code. Every stock token checked returned 283 bytes (BeaconProxy). The AAPL proxy runtime code embeds beacon `0xe10b6f6b275de231345c20d14ab812db62151b00` and calls `implementation()` (`0x5c60da1b`).
- Blockscout mainnet `https://robinhoodchain.blockscout.com/api` and `/api/v2/...` returned **HTTP 403 (Cloudflare challenge)** to curl. Testnet explorer `/api/v2/stats` returned **200 JSON**.

---

## Open items / uncertainty
1. The verified ABI or source of the stock token implementation (`0xb35490d6…5ae2`) was not inspected because Blockscout blocked access from this machine. Confirm the `isBlocked` and pause semantics, the exact event signatures, and who holds the multiplier and pause roles.
2. USDC on Robinhood Chain: **NOT FOUND** officially.
3. L2 sequencer uptime feed address: **NOT FOUND**.
4. Pyth / RedStone / Chronicle: **NOT FOUND**.
5. The testnet verifier URL comes from an unofficial source only.
6. No split or reverse-split records appeared in the current corporate-actions API window. The split mechanics come from Chainlink docs [S7] and Robinhood docs [S3][S4].

---

## Sources
- [S1] Connecting to Robinhood Chain: https://docs.robinhood.com/chain/connecting
- [S2] Deploy smart contracts (Foundry/Hardhat, verification): https://docs.robinhood.com/chain/deploy-smart-contracts
- [S3] Stock Tokens overview: https://docs.robinhood.com/chain/stock-tokens/ (and the docs index https://docs.robinhood.com/chain/, which says the gas token is ETH)
- [S4] Building with Stock Tokens: https://docs.robinhood.com/chain/building-with-stock-tokens
- [S5] Stock Token APIs: https://docs.robinhood.com/chain/stock-token-apis (endpoints `https://api.robinhood.com/rhj/assets`, `/rhj/prices/{symbol}`, `/rhj/corporate-actions`)
- [S6] Token Contracts (WETH, USDG, live registry): https://docs.robinhood.com/chain/contracts
- [S7] Chainlink, Robinhood tokenized equity feeds: https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood
- [S8] Oracles & Price Feeds: https://docs.robinhood.com/chain/oracles-and-price-feeds
- [S9] Chainlink feed addresses: https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood (data: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json)
- [S10] Robinhood support, Robinhood Chain mainnet: https://robinhood.com/us/en/support/articles/robinhood-chain-mainnet/
- [S11] Circle USDC contract addresses: https://developers.circle.com/stablecoins/usdc-contract-addresses
- [S12] Chainlink L2 sequencer uptime feeds: https://docs.chain.link/data-feeds/l2-sequencer-feeds
- [S13] Data Streams on Robinhood Chain: https://docs.robinhood.com/chain/data-streams
- [S14] Protocol Contracts: https://docs.robinhood.com/chain/protocol-contracts
- [S20] (unofficial, third-party) Smithii verification guide: https://smithii.io/verify-erc20-contract-robinhood-chain/ (localized variants were the ones indexed)
- On-chain: `https://rpc.mainnet.chain.robinhood.com` (2026-10-08)

---

## Appendix A — Full Stock Token registry (api.robinhood.com/rhj/assets, 2026-10-08, chainId 4663)

| Symbol | Name | Address | Decimals | currentMultiplier | pendingMultiplier | ISIN |
|---|---|---|---|---|---|---|
| AAOI | Applied Optoelectronics | `0x521Cf887E6531c6F667b5BC4D896E5d9bfE8EB2E` | 18 | 1.000000000000000000 | - | US03823U1025 |
| AAPL | Apple | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | 18 | 1.000566080061092436 | - | US0378331005 |
| ABCL | Abcellera Biologics | `0x3139D77Ace0cbAA5bDfD38bD1F1911a794AF0B0e` | 18 | 1.000000000000000000 | - | CA00288U1066 |
| ADBE | Adobe | `0x232B8ed6377BE97813853B0Ac104c4Cda8378d1B` | 18 | 1.000000000000000000 | - | US00724F1012 |
| AEHR | Aehr | `0x5F604fBA1162193A4388A5DFa56F556f3E133cC2` | 18 | 1.000000000000000000 | - | US00760J1088 |
| AEIS | Advanced Energy | `0xfAf9cb261B5FCC1f404Bb10CD39C5c6C1974E612` | 18 | 1.000000000000000000 | - | US0079731008 |
| ALAB | Astera Labs, Inc. | `0x748c32c3ca24eDf31ea597Db1F3d330a7a6DA3Dc` | 18 | 1.000000000000000000 | - | US04626A1034 |
| AMAT | Applied Materials | `0x36046893810a7E7fCE501229d57dc3FC8c8716d0` | 18 | 1.000044656302636618 | - | US0382221051 |
| AMBA | Ambarella | `0x99D9D8663545151603863C5AcbD6FC3218899009` | 18 | 1.000000000000000000 | - | KYG037AX1015 |
| AMC | AMC Entertainment | `0x05a3d1Cd21d0C88145E82600E62e7E496e0F222B` | 18 | 1.000000000000000000 | - | US00165C3025 |
| AMD | AMD | `0x86923f96303D656E4aa86D9d42D1e57ad2023fdC` | 18 | 1.000000000000000000 | - | US0079031078 |
| AMKR | Amkor Technology | `0xDd356AA38F40A7b7076755aC854B6FBb1F0D305B` | 18 | 1.000866850964062008 | - | US0316521006 |
| AMZN | Amazon | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` | 18 | 1.000000000000000000 | - | US0231351067 |
| ANET | Arista | `0x28bABD556b60E53663B8615036479a29c2CDd1Bf` | 18 | 1.000000000000000000 | - | US0404132054 |
| APLD | Applied Digital | `0xb8DBf92F9741c9ac1c32115E78581f23509916FD` | 18 | 1.000000000000000000 | - | US0381692070 |
| APP | AppLovin | `0xA249BAF1063Af884807C1E1400AEf7784836917E` | 18 | 1.000000000000000000 | - | US03831W1080 |
| ASML | ASML Holding NV | `0x47F93d52cBeC7C6D2CfC080e154002370a60dAEA` | 18 | 1.000101323251417769 | - | USN070592100 |
| ASTS | AST SpaceMobile | `0x1AF6446f07eb1d97c546AFC8c9544cBDF3AD5137` | 18 | 1.000000000000000000 | - | US00217D1000 |
| AUR | Aurora Innovation | `0x373C06c4f7BDe527D7Dae4BA169E42b55E393CeD` | 18 | 1.000000000000000000 | - | US0517741072 |
| AVAV | AeroVironment | `0xF6290b5e7C26502e2dA514C31509849718EA76A5` | 18 | 1.000000000000000000 | - | US0080731088 |
| AVGO | Broadcom | `0x156E175DD063a8cE274C50654eF40e0032b3fbcF` | 18 | 1.001257318662278132 | - | US11135F1012 |
| AXON | Axon | `0xC27dBD474aF5181c5A8777903690D8D262D12648` | 18 | 1.000000000000000000 | - | US05464C1018 |
| AXTI | AXT | `0x141eEa040c2250eEc0314e336975e81f85f6585e` | 18 | 1.000000000000000000 | - | US00246W1036 |
| BA | Boeing | `0x4D21483a44Bf67a86b77E3dA301411880797D452` | 18 | 1.000000000000000000 | - | US0970231058 |
| BABA | Alibaba | `0xad25Ac6C84D497db898fa1E8387bf6Af3532a1c4` | 18 | 1.000000000000000000 | - | US01609W1027 |
| BB | Blackberry | `0x48E39E56aCdbA37b09020C0b734A613C9a2f100A` | 18 | 1.000000000000000000 | - | CA09228F1036 |
| BE | Bloom Energy | `0x822CC93fFD030293E9842c30BBD678F530701867` | 18 | 1.000000000000000000 | - | US0937121079 |
| BND | Vanguard Total Bond Market ETF | `0x2F62fC9fAbb470C690f141c28340eD832bB27020` | 18 | 1.000000000000000000 | - | US9219378356 |
| BULL | Webull | `0xceF9027c7d6985b85f0BA431125073529A947A68` | 18 | 1.000000000000000000 | - | KYG9572D1034 |
| CBRS | Cerebras Systems | `0x5c90450Bbb4273D7b2f17CF6917AEB237A569679` | 18 | 1.000000000000000000 | - | US15675D1037 |
| CCL | Carnival Corporation | `0x9651342CeA770aE9a2969Ba2A52611523146aef9` | 18 | 1.021486444855206408 | - | BMG2004J1036 |
| CEG | Constellation Energy | `0xaE517A2903E68bd929Dfd15be875F8369D53e94a` | 18 | 1.000000000000000000 | - | US21037T1097 |
| CELH | Celsius | `0x8cF07C5A878945185d327aAa6e33FAa95F95e7bF` | 18 | 1.000000000000000000 | - | US15118V2079 |
| CIEN | Ciena | `0x44f6D488021f8233B9416294d1FE9b1fEe28382d` | 18 | 1.000000000000000000 | - | US1717793095 |
| CLOV | Clover Health Investments | `0x62200915e7DEab1eC7f79fb246daDbB80eACdDd0` | 18 | 1.000000000000000000 | - | US18914F1030 |
| CLS | Celestica | `0xBf449977089c718C004a66C554B26B94ef3Ad4De` | 18 | 1.000000000000000000 | - | CA15101Q2071 |
| CLSK | CleanSpark | `0xcBB95BBF36099d34dA091dc6Fa6F49EfA257Cee3` | 18 | 1.000000000000000000 | - | US18452B2097 |
| COHR | Coherent | `0x92F9F459F1a9a5AD266b182BE7Bffd1C6c666894` | 18 | 1.000000000000000000 | - | US19247G1076 |
| COIN | Coinbase | `0x6330D8C3178a418788dF01a47479c0ce7CCF450b` | 18 | 1.000000000000000000 | - | US19260Q1076 |
| COST | Costco | `0x4EA005168D7F09a7A0Ba9D1DEf21a479950E44C2` | 18 | 1.000612040296259656 | - | US22160K1051 |
| CRCL | Circle Internet Group | `0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5` | 18 | 1.000000000000000000 | - | US1725731079 |
| CRDO | Credo Technology Group | `0x4D67253bc223e6b0e104F1084c1fb2b669dDC41b` | 18 | 1.000000000000000000 | - | KYG254571055 |
| CRM | Salesforce | `0xd95B44124e475743a7589e68F3D74008A5536D44` | 18 | 1.001148322800714293 | - | US79466L3024 |
| CRWD | CrowdStrike Holdings | `0xea72Ecca2d0f6bFA1394DBBCff85b52CD4233931` | 18 | 4.000000000000000000 | - | US22788C1053 |
| CRWV | CoreWeave | `0x5f10A1C971B69e47e059e1dC91901B59b3fB49C3` | 18 | 1.000000000000000000 | - | US21873S1087 |
| CSCO | Cisco Systems | `0xF543967EEBB6f1917992eF0E68De63ab07a5a0dA` | 18 | 1.002674650028132112 | - | US17275R1023 |
| CTSH | Cognizant | `0x63D5a3b6939a33f1e75d8Bcd85759858239600DB` | 18 | 1.000000000000000000 | - | US1924461023 |
| CVNA | Carvana | `0xa4f319104089FE321dc8093C6E707d4fE190A988` | 18 | 1.000000000000000000 | - | US1468691027 |
| DDOG | Datadog | `0x27c99fBde9D0d2AA4f4Bfb4943f237843DdF6958` | 18 | 1.000000000000000000 | - | US23804L1035 |
| DELL | Dell | `0x941AE714EC6D8130c7B75d67160Ca08f1e7d11Dd` | 18 | 1.000063708620124549 | - | US24703L2025 |
| DJT | Trump Media & Technology Group | `0x1D11f0496982706C5e14A514D4E79F2e6BdE4516` | 18 | 1.000000000000000000 | - | US25400Q1058 |
| DOCN | DigitalOcean | `0xc02f12B9fe9E707079EC0d546f3050d3F6C1F8bD` | 18 | 1.000000000000000000 | - | US25402D1028 |
| ELF | e.l.f. Beauty | `0x39EC44Bee4F6A116c6F9B8De566848a985C53C60` | 18 | 1.000000000000000000 | - | US26856L1035 |
| EWT | iShares MSCI Taiwan Capped ETF | `0x1c690498150252222C275A5CEd69d3A6b1f52D5E` | 18 | 1.000000000000000000 | - | US46434G7723 |
| EWY | iShares MSCI South Korea fund | `0x7f0aBeF0C07280F82c6a08ead09dEd6BAE2C13Fc` | 18 | 1.000000000000000000 | - | US4642867729 |
| F | Ford Motor | `0x25C288E6D899b9BC30160965aD9644c67e73bE0C` | 18 | 1.000145502866134027 | - | US3453708600 |
| FICO | Fair Isaac | `0xa48F22A46C0F1C46CA7D111CB6c137c271987180` | 18 | 1.000000000000000000 | - | US3032501047 |
| FIG | Figma | `0x41F4267525a8AFf329540eF24fD83d9044758B33` | 18 | 1.000000000000000000 | - | US3168411052 |
| FISV | Fiserv | `0x9ECe29A4A2397C0a35fb5fA8EE2b9509130a98cc` | 18 | 1.000000000000000000 | - | US3377381088 |
| FIX | Comfort Systems | `0x93Dbb1d2Dc5D63F4abACFF30485273f538Df68Ac` | 18 | 1.000000000000000000 | - | US1999081045 |
| FLNC | Fluence Energy | `0x282e87451E10fA6679BC7D76C69BE44cD3fC777C` | 18 | 1.000000000000000000 | - | US34379V1035 |
| FLY | Firefly Aerospace Inc. | `0x03BC731Ffb162cdd7B98D3C6542bFC291126075d` | 18 | 1.000000000000000000 | - | US31816X1063 |
| FTNT | Fortinet | `0x3FB8976980d486084b2eb4a404BD12e72823958f` | 18 | 1.000000000000000000 | - | US34959E1091 |
| FUTU | Futu Holdings | `0xeB30663bDFf0622Ef4e4E5cBb4E975F19f33f51D` | 18 | 1.000000000000000000 | - | US36118L1061 |
| GE | General Electric | `0x63b814DDBd6BF339f25Fed8c36158a008D5B373e` | 18 | 1.001049053505552371 | - | US3696043013 |
| GEV | GE Vernova | `0x94B8AAE43A1cCc08Aa64B7D1F29b4D920aF4a0C9` | 18 | 1.000000000000000000 | - | US36828A1016 |
| GLD | SPDR Gold Trust | `0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e` | 18 | 1.000000000000000000 | - | US78463V1070 |
| GLW | Corning | `0x7c04E6A3368F2A1DE3874f0e80d2e0A1a9915da6` | 18 | 1.000000000000000000 | - | US2193501051 |
| GLXY | Galaxy Digital Inc. | `0x2D427692E928fa156ec22acfaBaFA0447C5805B7` | 18 | 1.000000000000000000 | - | US36317J2096 |
| GME | GameStop | `0x1b0E319c6A659F002271B69dB8A7df2F911c153E` | 18 | 1.000000000000000000 | - | US36467W1099 |
| GOOGL | Alphabet Class A | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` | 18 | 1.000193924414112587 | - | US02079K3059 |
| HII | Huntington Ingalls | `0xEB61c0Ed490A367d4E3631cCf8a74B3bfc7E775D` | 18 | 1.000000000000000000 | - | US4464131063 |
| HIMS | Hims & Hers Health | `0xCceE82fE024c36fA15E1005edE3E9e4787e23D09` | 18 | 1.000000000000000000 | - | US4330001060 |
| HPE | HP Enterprise | `0x59dd09d4900C2E4B5F75b7c0d4E6796fcc234Cb1` | 18 | 1.001716957939304938 | - | US42824C1099 |
| HWM | Howmet Aerospace | `0xAEa445c5F3DB1a462998ccC422A875A361ee5d99` | 18 | 1.000000000000000000 | - | US4432011082 |
| IBM | IBM | `0x980dcf6766FA79f5Cf0c4AAdb3ab477ff15a9619` | 18 | 1.000000000000000000 | - | US4592001014 |
| IBRX | ImmunityBio, | `0x7c148F74ac7445D1F28366b7FcDC6792a9Fcd0Cf` | 18 | 1.000000000000000000 | - | US45256X1037 |
| INDA | iShares MSCI India ETF | `0xACEF2e09adb47aD6aBeBAD9fF06689E60615C2B6` | 18 | 1.000000000000000000 | - | US46429B5984 |
| INFQ | Infleqtion | `0xB853bC83a753342a4f8320ea680b4B1E84118D21` | 18 | 1.000000000000000000 | - | US45676K1034 |
| INOD | Innodata | `0xf1953DAB6FaD537488d5A022361FfAa8B4c95eC6` | 18 | 1.000000000000000000 | - | US4576422053 |
| INTC | Intel | `0xc72b96e0E48ecd4DC75E1e45396e26300BC39681` | 18 | 1.000000000000000000 | - | US4581401001 |
| INTU | Intuit | `0x56d23beE5f41A7120170b0c603Dae30128e460e9` | 18 | 1.003226934400018698 | - | US4612021034 |
| IONQ | IonQ | `0x558378E000D634A36593E338eBacdd6207640EfE` | 18 | 1.000000000000000000 | - | US46222L1089 |
| IREN | IREN Limited | `0xF0AB0c93bE6F41369d302e55db1A96b3c430212D` | 18 | 1.000000000000000000 | - | AU0000185993 |
| JBL | Jabil Inc. | `0xEAf2512dFC1bEAc608F8794B3793CD4E02894Aa6` | 18 | 1.000000000000000000 | - | US4663131039 |
| JNJ | Johnson & Johnson | `0x03DfbBE0AC4E7bCDaFd08eD41A400326B77D8c80` | 18 | 1.000021490286701962 | - | US4781601046 |
| JOBY | Joby Aviation | `0xb334C5cE741B80B5B671F47F5C269Cb193fe8E24` | 18 | 1.000000000000000000 | - | KYG651631007 |
| KLAC | KLA | `0x96b933C74eCB4A0926b9210cef7b743EF46be2E9` | 18 | 1.000000000000000000 | - | US4824801009 |
| KSS | Kohls Corporation | `0x12e3c047bf9AeCAF9dDC98c05C31BFD1dd043993` | 18 | 1.004610068732316661 | - | US5002551043 |
| KTOS | Kratos Defense & Security Solutions | `0x7FD06a4d81cCfA3F351394E144d5191874C31313` | 18 | 1.000000000000000000 | - | US50077B2079 |
| LHX | L3Harris | `0x48d60243c66437c6ac3c2495Be94747aEd5Dfe25` | 18 | 1.004922488323561562 | - | US5024311095 |
| LITE | Lumentum | `0x8eF20885F94e3D9bc7eB3080279188Bd5ED7c08C` | 18 | 1.000000000000000000 | - | US55024U1097 |
| LLY | Eli Lilly | `0x8005d266423c7ea827372c9c864491e5786600ea` | 18 | 1.000002288774375687 | - | US5324571083 |
| LMT | Lockheed | `0x329fcACEb9AD6F9580DD5F643fed0646900D043c` | 18 | 1.000021050802889793 | - | US5398301094 |
| LRCX | Lam Research Corp | `0x57b0030166DB0C31690d1A5aA167e2e26e2C29a4` | 18 | 1.000732562938505984 | - | US5128073062 |
| LULU | Lululemon | `0x4e62068525Ab11FE768e29dfD00ef909B9803016` | 18 | 1.000000000000000000 | - | US5500211090 |
| LUNR | Intuitive Machines | `0xa5D4968421bA94814Be3B136b15cf422101aC1a3` | 18 | 1.000000000000000000 | - | US46125A1007 |
| MDB | MongoDB | `0xDdf2266b79abf0B48898959B0ed6E6adf512be74` | 18 | 1.000000000000000000 | - | US60937P1066 |
| META | Meta Platforms | `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35` | 18 | 1.000541459879451635 | - | US30303M1027 |
| MOD | Modine | `0xc6Cbad1016b38B797610c25E1dc7D95988B1f362` | 18 | 1.000000000000000000 | - | US6078281002 |
| MPWR | Monolithic Power Systems | `0x52D50D0280AD1054b43f052bD70a49a212A1b128` | 18 | 1.001003337041156841 | - | US6098391054 |
| MRNA | Moderna | `0x43B07D15cE533bEc5476d70C22a78a1B2B662155` | 18 | 1.000000000000000000 | - | US60770K1079 |
| MRVL | Marvell Technology | `0x62fd0668e10D8B72339BE2DCF7643001688ff13B` | 18 | 1.000000000000000000 | - | US5738741041 |
| MSFT | Microsoft | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` | 18 | 1.000412952576205964 | - | US5949181045 |
| MSTR | Strategy Inc. | `0xec262a75e413fAfD0dF80480274532C79D42da09` | 18 | 1.000000000000000000 | - | US5949724083 |
| MTSI | MACOM | `0xC93f4d80e268AB922e871bd169156C3CC41894e6` | 18 | 1.000000000000000000 | - | US55405Y1001 |
| MU | Micron Technology | `0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD` | 18 | 1.000074823219171086 | - | US5951121038 |
| MXL | MaxLinear | `0x48961813349333209994750ffA89b3c5C22eC969` | 18 | 1.000000000000000000 | - | US57776J1007 |
| NAVN | Navan | `0xf7181b63Fdb858558A74ba96BC42732684cd7965` | 18 | 1.000000000000000000 | - | US6391931010 |
| NBIS | Nebius Group | `0x9D9c6684F596F66a64C030B93A886D51Fd4D7931` | 18 | 1.000000000000000000 | - | NL0009805522 |
| NET | Cloudflare, Inc. Class A common stock | `0x116F00968269B7bfbaD4109cE591d6E74c0601d4` | 18 | 1.000000000000000000 | - | US18915M1071 |
| NFLX | Netflix | `0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8` | 18 | 1.000000000000000000 | - | US64110L1061 |
| NNE | Nano Nuclear Energy | `0xBEF75684C43c4ea7BD18Dd532a2244674Ee8b926` | 18 | 1.000000000000000000 | - | US63010H1086 |
| NOW | ServiceNow | `0x0C3260aF4B8f13a69c4c2dFb84fD667890CDFa14` | 18 | 1.000000000000000000 | - | US81762P1021 |
| NU | Nu | `0x408c14038a04f7bD235329E26d2bf569ee20e250` | 18 | 1.000000000000000000 | - | KYG6683N1034 |
| NVDA | NVIDIA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | 18 | 1.000775159164630595 | - | US67066G1040 |
| NVTS | Navitas Semiconductor | `0xbE6702d7b70315376dC48a3293f24f0982F86386` | 18 | 1.000000000000000000 | - | US63942X1063 |
| OKLO | Oklo | `0x8B2f88497f15A18E9D4FFa1a8fFB8538399aE774` | 18 | 1.000000000000000000 | - | US02156V1098 |
| ON | ON Semiconductor | `0xbBD09F72b025360FeE5C928053Dca6248d35be54` | 18 | 1.000000000000000000 | - | US6821891057 |
| ONTO | Onto Innovation | `0x8ff63eAeEe3fE54Ba450c4F5538064Ec5A893Aef` | 18 | 1.000000000000000000 | - | US6833441057 |
| ORCL | Oracle | `0xb0992820E760d836549ba69BC7598b4af75dEE03` | 18 | 1.002210914971013375 | - | US68389X1054 |
| OUST | Ouster | `0x40E7a279850e443f582059ae5dC1c3b6563E6395` | 18 | 1.000000000000000000 | - | US68989M2026 |
| P | Everpure | `0x1Cdad396DB64BDa184d5182A97Dd9B3C62100b7D` | 18 | 1.000000000000000000 | - | US74624M1027 |
| PANW | Palo Alto Networks | `0xB039597eD45CBa7B6E2fb9E8BE51802969CEe5Be` | 18 | 1.000000000000000000 | - | US6974351057 |
| PATH | UiPath | `0xfb2664f07B6Aadd29ea7a59D8859b1AeB8645cDa` | 18 | 1.000000000000000000 | - | US90364P1057 |
| PENG | Penguin Solutions | `0x9b23573b156B52565012F5cE02CDF60AFBaa70Be` | 18 | 1.000000000000000000 | - | US7069151055 |
| PFE | Pfizer | `0x7066A64c24e4206CD62E83bf198c1E7EB361F51e` | 18 | 1.000000000000000000 | - | US7170811035 |
| PL | Planet Labs | `0xAA4d64474c172010aB57719cb9951E6142a100d3` | 18 | 1.000000000000000000 | - | US72703X1063 |
| PLTR | Palantir Technologies | `0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A` | 18 | 1.000000000000000000 | - | US69608A1088 |
| POET | POET Technologies | `0xcf6B2D875361be807EAfa57458c80f28521F9333` | 18 | 1.000000000000000000 | - | CA73044W3021 |
| POWL | Powell Industries | `0x237c16D66590F67B886d978ACD362EAeaD8B18c7` | 18 | 1.000000000000000000 | - | US7391281067 |
| PR | Permian Resources | `0x4189F0c66EBBB0bfeF1C31f763131361EF32f77C` | 18 | 1.004477942292229526 | - | US71424F1057 |
| PWR | Quanta | `0x9Ab02Ead789b6903c3c44d0ED32F9c707CDF12FD` | 18 | 1.000000000000000000 | - | US74762E1029 |
| QBTS | D-Wave Quantum Inc. Common Stock | `0xC583c60aeF9Dc401Da72cEC1B404743a93cea1Cc` | 18 | 1.000000000000000000 | - | US26740W1099 |
| QCOM | Qualcomm | `0x0f17206447090e464C277571124dD2688E48AEA9` | 18 | 1.001228122794792830 | - | US7475251036 |
| QQQ | Invesco QQQ | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` | 18 | 1.000700791241405425 | - | US46090E1038 |
| QUBT | Quantum Computing | `0x59818904ab4cE163b3cE4FfB64f2D6Ca02c434B4` | 18 | 1.000000000000000000 | - | US74766W1080 |
| RBLX | Roblox | `0xF0C4BF4C582cb3836e98394b1d4e7B7281101bE8` | 18 | 1.000000000000000000 | - | US7710491033 |
| RCAT | Red Cat | `0xFDE6b5d9BB419B10C23268c74e369AbFF39C0460` | 18 | 1.000000000000000000 | - | US75644T1007 |
| RDDT | Reddit | `0x05b37Fb53A299a1b874A619e1c4C404D52C36F4C` | 18 | 1.000000000000000000 | - | US75734B1008 |
| RDW | Redwire | `0x92Ef19E82bD8fF36661DE838D5eaE7e5CEF0EfFE` | 18 | 1.000000000000000000 | - | US75776W1036 |
| RGTI | Rigetti Computing | `0x284358abc07F9359f19f4b5b4aC91901Be2597Ba` | 18 | 1.000000000000000000 | - | US76655K1034 |
| RIVN | Rivian Automotive | `0xB1BF26c1D20ff267A4f93550d1E0d06ac40a114B` | 18 | 1.000000000000000000 | - | US76954A1034 |
| RKLB | Rocket Lab Corporation | `0x3b14C39E89D60D627b42a1A4CA45b5bb45Fc12e2` | 18 | 1.000000000000000000 | - | US7731211089 |
| RUN | Sunrun | `0x756Bc80af765C82da966a788858d65aDF14f3793` | 18 | 1.000000000000000000 | - | US86771W1053 |
| SATS | EchoStar | `0x95052ddcd5DC25641657424A8Cf04834997E1730` | 18 | 1.000000000000000000 | - | US2787681061 |
| SCHD | Schwab US Dividend Equity ETF | `0xd63ABB2C13d7a8421a8017a712802053568e3C1D` | 18 | 1.005538606893683992 | - | US8085247976 |
| SGOV | iShares 0-3 Month Treasury Bond | `0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5` | 18 | 1.007186931447954063 | - | US46436E7186 |
| SHOP | Shopify | `0xF53F66751B1Eff985311b693531E3290F600c410` | 18 | 1.000000000000000000 | - | CA82509L1076 |
| SHY | iShares 1-3 Year Treasury Bond ETF | `0xBE274710Bf3d9567e1B290eF6a5F9f90ca016FD8` | 18 | 1.002055340428983545 | - | US4642874576 |
| SIMO | Silicon Motion | `0x77E655E37F4d913fB9540e0d541D824171a60e81` | 18 | 1.000000000000000000 | - | US82706C1080 |
| SKHY | SK hynix Inc. American Depositary Shares | `0x84CAb63bc87912E71ad199ff14A0bA45de68FeF8` | 18 | 1.000060353549285624 | - | US78392B2060 |
| SLS | SELLAS Life Sciences | `0x285b231728c7E4333799183DF1094d775246a535` | 18 | 1.000000000000000000 | - | US81642T2096 |
| SLV | iShares Silver Trust | `0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f` | 18 | 1.000000000000000000 | - | US46428Q1094 |
| SMCI | Super Micro Computer | `0xc01aA1fECeC0605b13bc84874ff7256C0f5F562a` | 18 | 1.000000000000000000 | - | US86800U3023 |
| SMH | VanEck Semiconductor ETF | `0x072f979c2CAc8e1391B0162a87Fee094bF8744a0` | 18 | 1.000000000000000000 | - | US92189F6768 |
| SMR | NuScale Power | `0x1Eebee7F74517e0279dFb09d25B0407bEEc3FDd6` | 18 | 1.000000000000000000 | - | US67079K1007 |
| SNAP | Snap | `0xF6589F11Bc40b669e584073F428B05562F568733` | 18 | 1.000000000000000000 | - | US83304A1060 |
| SNDK | Sandisk Corporation | `0xB90A19fF0Af67f7779afF50A882A9CfF42446400` | 18 | 1.000000000000000000 | - | US80004C2008 |
| SNOW | Snowflake | `0xBa0CAB75495255d0cB58E22B648bFED4ECD1F47E` | 18 | 1.000000000000000000 | - | US8334451098 |
| SOFI | SoFi Technologies | `0x98E75885157C80992A8D41b696D8c9C6Fb30A926` | 18 | 1.000000000000000000 | - | US83406F1021 |
| SOUN | SoundHound AI | `0x6E3Dfd9f7e1649BaA14D25cac18C94d62dB10A54` | 18 | 1.000000000000000000 | - | US8361001071 |
| SOXX | iShares Semiconductor ETF | `0x75742c18BC1f1C5c5f448f4C9D9C6F66dafAAa38` | 18 | 1.000450838210425960 | - | US4642875235 |
| SPCX | Space Exploration Technologies Corp. Class A Common Stock | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` | 18 | 1.000000000000000000 | - | US84615Q1031 |
| SPMO | Invesco S&P 500 Momentum ETF | `0xAd622320e520de39e72d41EF07438C3Fd3354875` | 18 | 1.002024883742416310 | - | US46138E3392 |
| SPY | SPDR S&P 500 ETF Trust | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` | 18 | 1.001717991187472003 | - | US78462F1030 |
| TE | T1 Energy | `0xb1969f6604CA1AE7a2cD3F1827876e914594CA2D` | 18 | 1.000000000000000000 | - | US35834F1049 |
| TEAM | Atlassian Corporation | `0x5B97476b922F3305131B8f0B9D333172E87f4aaE` | 18 | 1.000000000000000000 | - | US0494681010 |
| TEM | Tempus AI | `0xB1CC0EC7Db69Cf43539119814df40071b9d61793` | 18 | 1.000000000000000000 | - | US88023B1035 |
| TER | Teradyne | `0x2778C5024D5cA2CdB0f8eAD671ffc69963AdCD9C` | 18 | 1.000647857966979018 | - | US8807701029 |
| TSEM | Tower Semiconductor | `0x89776d4Cd68193597A2fC132cfaC1fDe36CCeA8a` | 18 | 1.000000000000000000 | - | IL0010823792 |
| TSLA | Tesla | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | 18 | 1.000000000000000000 | - | US88160R1014 |
| TSM | Taiwan Semiconductor Manufacturing | `0x58FfE4a942d3885bAa22D7520691F611EF09e7AA` | 18 | 1.002728577037771211 | - | US8740391003 |
| TTD | Trade Desk | `0x0b5fb4031cae9163db10B169Ee72685F0EdC8545` | 18 | 1.000000000000000000 | - | US88339J1051 |
| TTWO | Take-Two Interactive Software | `0x5e81213613b6B86EaB4c6c50d718d34359459786` | 18 | 1.000000000000000000 | - | US8740541094 |
| UMC | United Microelectronics | `0x0E6e67Ba88e7b5d9B67636A215c76779B948dE79` | 18 | 1.000000000000000000 | - | US9108734057 |
| UNH | UnitedHealth | `0xcF364ea52787e289De6F32077834056E3E70D6A8` | 18 | 1.004241501039702113 | - | US91324P1021 |
| UPS | UPS | `0xf23250dac154D05Bb671CB0d0eBEf3c635c79CE2` | 18 | 1.002208724969205741 | - | US9113121068 |
| USAR | USA Rare Earth | `0xd917B029C761D264c6A312BBbcDA868658eF86a6` | 18 | 1.000000000000000000 | - | US91733P1075 |
| USO | United States Oil Fund | `0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344` | 18 | 1.000000000000000000 | - | US91232N2071 |
| VICR | Vicor | `0x6006ed4B2F94110851ff7509D97D034f0EeD9226` | 18 | 1.000000000000000000 | - | US9258151029 |
| VRT | Vertiv | `0xFA78C12E6488814A0262E4e802749a4a737d5fB7` | 18 | 1.000162788892052072 | - | US92537N1081 |
| VSAT | ViaSat | `0x26dCbfb34FC83CAbD6990f449674efDc6097fF85` | 18 | 1.000000000000000000 | - | US92552V1008 |
| VST | Vistra | `0x561e2a49212b7cCF47f2744Ccb83e200722fADBc` | 18 | 1.001114738710796417 | - | US92840M1027 |
| VTI | Vanguard Morningstar Total Stock Market ETF | `0x0594134DF3f171a354D9C85eBD65b7A6148F6D09` | 18 | 1.001751012345030813 | - | US9229087690 |
| WDAY | Workday | `0x82DA4646242e1D962e96e932269Dc644c94a9CaA` | 18 | 1.000000000000000000 | - | US98138H1014 |
| WDC | Western Digital | `0xF52597345A8Edf418bc4071b4a35112472277D3e` | 18 | 1.000217565250523909 | - | US9581021055 |
| WULF | TeraWulf | `0x348Be1A8663f15edDe5CDf8A96BB69078f7aB6Fd` | 18 | 1.000000000000000000 | - | US88080T1043 |
| WYFI | WhiteFiber, Inc. | `0x9e7ABD3C9139D14E4c86DcE0e455AAB7A0C2FB3E` | 18 | 1.000000000000000000 | - | KYG961151035 |
| XLK | State Street Technology Select Sector SPDR ETF | `0x15Cd20759CE7F3285c29A319dE2D1A2e098c6f43` | 18 | 1.000804404520428861 | - | US81369Y8030 |
| XNDU | Xanadu Quantum | `0xA8eB3BCcbf2017eE7CBfb652eB51CF2E1B153289` | 18 | 1.000000000000000000 | - | CA98390R1029 |
| XOM | ExxonMobil Holdings Corporation | `0xf9B46d3D1B22199D4D1025a9cEDB540A33F1a2d5` | 18 | 1.001039563764661900 | - | US30233Q1085 |
| ZM | Zoom | `0x44c4F142009036cF477eD2d09932051843137CF1` | 18 | 1.000000000000000000 | - | US98980L1017 |
| ZS | Zscaler | `0x7dc013eB55e436f30d7ED1AFE4E36d6e45e3c3f7` | 18 | 1.000000000000000000 | - | US98980G1022 |

## Appendix B — Chainlink feeds on robinhood-mainnet (reference-data-directory, 2026-10-08)

| Name | Proxy | Decimals | Category | Asset class | Heartbeat (s) | Deviation threshold |
|---|---|---|---|---|---|---|
| BTC / USD | `0xa2c5184bF03d373Dc9dE4876eb4Bce595B460251` | 8 | low | Crypto | 86400 | 0.5 |
| BTC.B / USD | `0x5BB5e6a17a477d5B6Fec77b4322daD4A66bFb732` | 8 | new | Crypto | 86400 | 0.5 |
| CBBTC / USD | `0x0009cD492adf8167f9eEBf1293556A673530a21a` | 8 | low | Crypto | 86400 | 0.5 |
| ENA / USD | `0x2A291496b3aa19d8948e442Ef28Ee952f3Ee97E8` | 8 | low | Crypto | 86400 | 0.5 |
| ETH / USD | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` | 8 | low | Crypto | 86400 | 0.5 |
| EURC / USD | `0xfF2B10c1973eD10c841434f98e456d8f3a0D7DD8` | 8 | low | Crypto | 86400 | 0.5 |
| GLD / USD | `0x470A51258068043bd43dC0a56245625C9fE86eB0` | 8 | new | Crypto | 86400 | 0.5 |
| LBTC / USD | `0xa621344AdAEE699491597Fd8890E0C59a5BFBE59` | 8 | medium | Crypto | 86400 | 0.5 |
| LINK / USD | `0xe86e3422Aa9B5e8ee9f3E41a63975bC387A8bce9` | 8 | low | Crypto | 86400 | 0.5 |
| Robinhood AAPL / USD | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood AMD / USD | `0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood AMZN / USD | `0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood ASML / USD | `0xB4106147E8cce40b7d46124090d373A71b70f87D` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood BABA / USD | `0x62Cc8F9b5f56a33c9C8A60c8B92779f523c4E984` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood CLSK / USD | `0x810c12D3a554Bc47fd39597Fe3b3AAC4941F50eF` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood COIN / USD | `0xA3a468A452940B7D6b69991207B508c609a98Ef2` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood CRCL / USD | `0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood CRWV / USD | `0xe1b3aABCAFAd1c94708dc1367dcfF8Aa4407487C` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood DELL-USD | `0x1C6c8cADBe02E19129c39dDB92281cE4c0bf206b` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood EWY / USD | `0xEFdf54610B62A7753Ec30bDc380847c12D32e1D1` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood GME / USD | `0x27C71df6A64fB476468EdF256CF72c038baB5B67` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood GOOGL / USD | `0xF6f373a037c30F0e5010d854385cA89185AE638b` | 8 | low | Equity | 86400 | 0.5 |
| Robinhood INTC / USD | `0x3f390C5C24628Ac7C489515402235FeAD71D1913` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood IONQ / USD | `0x22EfeC4919baf55F360E0EDee4AbEB26DE4971eb` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood META / USD | `0x7C38C00C30BEe9378381E7B6135d7283356D71b1` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood MSFT / USD | `0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood MSTR / USD | `0x396118bdFB181e6240E74D243F266B061c0edc3D` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood MU / USD | `0x425EEFdCf05ed6526C3cE61Af99429A228a6d596` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood NBIS / USD | `0xE1D87B116Ba0fe898998f1D140339D1fA1E09705` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood NVDA / USD | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood ORCL / USD | `0x0e6a64a2B58A6693a531E6c555f3A5d042eEA844` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood PLTR / USD | `0x820ABedFF239034956B7A9d2F0a331f9F075eB4c` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood QQQ / USD | `0x80901d846d5D7B030F26B480776EE3b29374C2ae` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood RGTI / USD | `0x2A045cF1C49c61c166C036d2f06FA2D2d984f765` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood RKLB / USD | `0x045477BF65Aef6f4F2386ad0164579e48381CC74` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood SGOV-USD | `0xa0DF4ee0fFf975306345875E3548Fcc519577A11` | 8 |  |  | 86400 | 0.5 |
| Robinhood SLV / USD | `0x209b73908e92Ae021826eD79609845451Ecba2ce` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood SNDK / USD | `0xfb133Fa4B7b385802B693a293606682Df47109A3` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood SPCX / USD | `0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood SPY / USD | `0x319724394D3A0e3669269846abE664Cd621f9f6A` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood TSLA / USD | `0x4A1166a659A55625345e9515b32adECea5547C38` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood TSM / USD | `0x874cF94aa8eC88Fd9560094dD065f2fB3E41Fc2F` | 8 | custom | Equity | 86400 | 0.5 |
| Robinhood USAR-USD | `0xA994d3684e8400A6c8078226925779FdeE682DD9` | 8 |  |  | 86400 | 0.5 |
| Robinhood USO / USD | `0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c` | 8 | custom | Equity | 86400 | 0.5 |
| SYRUPUSDC / USD | `0x8765c3B9Cda41d1029E780D0c1C37C8200DC4675` | 8 | custom | Crypto | 86400 | 0.5 |
| SYRUPUSDC / USDC Exchange Rate | `0x6317f016FA3e312C4625dee51d32b43a223011f8` | 18 |  |  | 86400 | 0.05 |
| syrupUSDG / USDG Exchange Rate | `0xDd194C66aDcb422F188a04434e4824D70c151cF0` | 18 | custom | Crypto | 86400 | 0.05 |
| SYRUPUSDT / USDT Exchange Rate | `0xBB688c0184Ce03fEdac89D71ccE752Ab21bC2999` | 18 | custom | Crypto | 86400 | 0.05 |
| USDC / USD | `0x9e6f4605992a899eE2999999F3Ec80C41F452546` | 8 | low | Crypto | 86400 | 0.5 |
| USDE / USD | `0xb9fB4e65744E4178894f7C61CF80E8a48A5f224a` | 8 | low | Crypto | 86400 | 0.5 |
| USDG / USD | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` | 8 | medium | Crypto | 86400 | 0.5 |
| USDS / USD | `0x2D88D75b625633dCcd65d9d53BfDD3Aea2d8e84f` | 8 | medium |  | 86400 | 0.5 |
| USDT / USD | `0xbf3550B6fAe1671da7C238Af12e03Ac586BEf3B1` | 8 | low | Crypto | 86400 | 0.5 |
| WBTC / USD | `0x62107b0d3adA75fc1697fD342d99eed947a3aA5E` | 8 | low | Crypto | 86400 | 0.5 |
| WEETH / EETH Exchange Rate | `0xb63f44E40aA811Cc69Fc55da786a5F3834100B4A` | 18 | custom | Crypto | 86400 | 0.05 |
| WEETH / USD | `0xf882e1D50352aecB0Ac85378378918BCf40511e7` | 8 | medium | Crypto | 86400 | 0.5 |
| WSTETH / STETH Exchange Rate | `0x8E3Eb706B170c8FD1DdcD402932D952887736f9A` | 18 | custom | Crypto | 86400 | 0.05 |
| WSTETH / USD | `0x3F5040B50FB37934573B210fE54B53a6F1A792E8` | 8 | medium | Crypto | 86400 | 0.5 |

## Appendix C — Corporate actions (api.robinhood.com/rhj/corporate-actions, 2026-10-08)

| Token | Type | Status | Process date | Details |
|---|---|---|---|---|
| ORCL | CASH_DIVIDEND | IN_PROGRESS | 2026-10-23 | {"cashDividend":{"underlyingSymbol":"ORCL","rate":"0.5"}} |
| PWR | CASH_DIVIDEND | IN_PROGRESS | 2026-10-09 | {"cashDividend":{"underlyingSymbol":"PWR","rate":"0.11"}} |
| MU | CASH_DIVIDEND | IN_PROGRESS | 2026-10-29 | {"cashDividend":{"underlyingSymbol":"MU","rate":"0.15"}} |
| MPWR | CASH_DIVIDEND | IN_PROGRESS | 2026-10-15 | {"cashDividend":{"underlyingSymbol":"MPWR","rate":"2"}} |
| LRCX | CASH_DIVIDEND | IN_PROGRESS | 2026-10-14 | {"cashDividend":{"underlyingSymbol":"LRCX","rate":"0.33"}} |
| SPY | CASH_DIVIDEND | IN_PROGRESS | 2026-10-30 | {"cashDividend":{"underlyingSymbol":"SPY","rate":"1.888834"}} |
| MRVL | CASH_DIVIDEND | IN_PROGRESS | 2026-10-29 | {"cashDividend":{"underlyingSymbol":"MRVL","rate":"0.06"}} |
| GE | CASH_DIVIDEND | IN_PROGRESS | 2026-10-26 | {"cashDividend":{"underlyingSymbol":"GE","rate":"0.47"}} |
| CSCO | CASH_DIVIDEND | IN_PROGRESS | 2026-10-21 | {"cashDividend":{"underlyingSymbol":"CSCO","rate":"0.42"}} |
| HPE | CASH_DIVIDEND | IN_PROGRESS | 2026-10-16 | {"cashDividend":{"underlyingSymbol":"HPE","rate":"0.1425"}} |
| DELL | CASH_DIVIDEND | IN_PROGRESS | 2026-10-30 | {"cashDividend":{"underlyingSymbol":"DELL","rate":"0.63"}} |
| INTU | CASH_DIVIDEND | IN_PROGRESS | 2026-10-16 | {"cashDividend":{"underlyingSymbol":"INTU","rate":"1.38"}} |
| SGOV | CASH_DIVIDEND | IN_PROGRESS | 2026-10-06 | {"cashDividend":{"underlyingSymbol":"SGOV","rate":"0.300547"}} |
| QQQ | CASH_DIVIDEND | IN_PROGRESS | 2026-10-08 | {"cashDividend":{"underlyingSymbol":"QQQ","rate":"0.75143"}} |
| TSM | CASH_DIVIDEND | IN_PROGRESS | 2026-10-08 | {"cashDividend":{"underlyingSymbol":"TSM","rate":"0.866038"}} |
| SKHY | CASH_DIVIDEND | IN_PROGRESS | 2026-10-07 | {"cashDividend":{"underlyingSymbol":"SKHY","rate":"0.016001"}} |
| CRM | CASH_DIVIDEND | IN_PROGRESS | 2026-10-08 | {"cashDividend":{"underlyingSymbol":"CRM","rate":"0.44"}} |
| SHY | CASH_DIVIDEND | IN_PROGRESS | 2026-10-06 | {"cashDividend":{"underlyingSymbol":"SHY","rate":"0.241001"}} |
| AMKR | CASH_DIVIDEND | COMPLETED | 2026-09-22 | {"cashDividend":{"underlyingSymbol":"AMKR","rate":"0.08352"}} |
| KSS | CASH_DIVIDEND | COMPLETED | 2026-09-23 | {"cashDividend":{"underlyingSymbol":"KSS","rate":"0.125"}} |
| JNJ | CASH_DIVIDEND | COMPLETED | 2026-09-08 | {"cashDividend":{"underlyingSymbol":"JNJ","rate":"1.34"}} |
| GLW | CASH_DIVIDEND | COMPLETED | 2026-09-29 | {"cashDividend":{"underlyingSymbol":"GLW","rate":"0.28"}} |
| XLK | CASH_DIVIDEND | COMPLETED | 2026-09-23 | {"cashDividend":{"underlyingSymbol":"XLK","rate":"0.220686"}} |
| SCHD | CASH_DIVIDEND | COMPLETED | 2026-09-28 | {"cashDividend":{"underlyingSymbol":"SCHD","rate":"0.2665"}} |
| TER | CASH_DIVIDEND | COMPLETED | 2026-09-25 | {"cashDividend":{"underlyingSymbol":"TER","rate":"0.13"}} |
| META | CASH_DIVIDEND | COMPLETED | 2026-09-28 | {"cashDividend":{"underlyingSymbol":"META","rate":"0.525"}} |
| MSFT | CASH_DIVIDEND | COMPLETED | 2026-09-10 | {"cashDividend":{"underlyingSymbol":"MSFT","rate":"0.91"}} |
| XOM | CASH_DIVIDEND | COMPLETED | 2026-09-10 | {"cashDividend":{"underlyingSymbol":"XOM","rate":"1.03"}} |
| GOOGL | CASH_DIVIDEND | COMPLETED | 2026-09-14 | {"cashDividend":{"underlyingSymbol":"GOOGL","rate":"0.22"}} |
| HII | CASH_DIVIDEND | COMPLETED | 2026-09-11 | {"cashDividend":{"underlyingSymbol":"HII","rate":"1.38"}} |
| IBM | CASH_DIVIDEND | COMPLETED | 2026-09-10 | {"cashDividend":{"underlyingSymbol":"IBM","rate":"1.69"}} |
| SOXX | CASH_DIVIDEND | COMPLETED | 2026-09-18 | {"cashDividend":{"underlyingSymbol":"SOXX","rate":"0.325046"}} |
| VST | CASH_DIVIDEND | COMPLETED | 2026-09-30 | {"cashDividend":{"underlyingSymbol":"VST","rate":"0.23"}} |
| AMAT | CASH_DIVIDEND | COMPLETED | 2026-09-10 | {"cashDividend":{"underlyingSymbol":"AMAT","rate":"0.53"}} |
| LHX | CASH_DIVIDEND | COMPLETED | 2026-09-18 | {"cashDividend":{"underlyingSymbol":"LHX","rate":"1.25"}} |
| WDC | CASH_DIVIDEND | COMPLETED | 2026-09-17 | {"cashDividend":{"underlyingSymbol":"WDC","rate":"0.15"}} |
| LLY | CASH_DIVIDEND | COMPLETED | 2026-09-10 | {"cashDividend":{"underlyingSymbol":"LLY","rate":"1.73"}} |
| BND | CASH_DIVIDEND | COMPLETED | 2026-10-05 | {"cashDividend":{"underlyingSymbol":"BND","rate":"0.248502"}} |
| UNH | CASH_DIVIDEND | COMPLETED | 2026-09-22 | {"cashDividend":{"underlyingSymbol":"UNH","rate":"2.32"}} |
| NVDA | CASH_DIVIDEND | COMPLETED | 2026-10-01 | {"cashDividend":{"underlyingSymbol":"NVDA","rate":"0.25"}} |
| LMT | CASH_DIVIDEND | COMPLETED | 2026-09-25 | {"cashDividend":{"underlyingSymbol":"LMT","rate":"3.45"}} |
| QCOM | CASH_DIVIDEND | COMPLETED | 2026-09-24 | {"cashDividend":{"underlyingSymbol":"QCOM","rate":"0.92"}} |
| SPMO | CASH_DIVIDEND | COMPLETED | 2026-09-25 | {"cashDividend":{"underlyingSymbol":"SPMO","rate":"0.24322"}} |
| POWL | CASH_DIVIDEND | COMPLETED | 2026-09-16 | {"cashDividend":{"underlyingSymbol":"POWL","rate":"0.09"}} |
| AVGO | CASH_DIVIDEND | COMPLETED | 2026-09-30 | {"cashDividend":{"underlyingSymbol":"AVGO","rate":"0.65"}} |
| VTI | CASH_DIVIDEND | COMPLETED | 2026-09-30 | {"cashDividend":{"underlyingSymbol":"VTI","rate":"0.9555"}} |
| VRT | CASH_DIVIDEND | COMPLETED | 2026-09-24 | {"cashDividend":{"underlyingSymbol":"VRT","rate":"0.0625"}} |
| PR | CASH_DIVIDEND | COMPLETED | 2026-09-30 | {"cashDividend":{"underlyingSymbol":"PR","rate":"0.16"}} |
