/**
 * Canonical chain + external-contract registry for Divsplit.
 *
 * Every value here comes from an official source (link next to it) and was checked on-chain against the public
 * mainnet RPC on 2026-10-08. Full research notes: docs/research/robinhood-chain.md.
 * Nothing in this file is guessed. Where something does not exist on the chain, it is listed under `gaps`.
 */

export const robinhoodMainnet = {
  id: 4663, // https://docs.robinhood.com/chain/connecting  (eth_chainId -> 0x1237)
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, // https://docs.robinhood.com/chain/connecting
  rpcUrls: {
    // Public endpoint is rate-limited ("not recommended for production") — https://docs.robinhood.com/chain/connecting
    public: "https://rpc.mainnet.chain.robinhood.com",
    // Provider endpoint (needs a key) — https://docs.robinhood.com/chain/connecting
    alchemy: "https://robinhood-mainnet.g.alchemy.com/v2/{API_KEY}",
    alchemyWs: "wss://robinhood-mainnet.g.alchemy.com/v2/{API_KEY}",
  },
  explorer: {
    name: "Blockscout",
    url: "https://robinhoodchain.blockscout.com", // https://docs.robinhood.com/chain/connecting
    // Verification: forge --verifier blockscout --verifier-url <apiUrl> — https://docs.robinhood.com/chain/deploy-smart-contracts
    apiUrl: "https://robinhoodchain.blockscout.com/api/",
  },
} as const;

export const robinhoodTestnet = {
  id: 46630, // https://docs.robinhood.com/chain/connecting (eth_chainId -> 0xb626)
  name: "Robinhood Chain Testnet",
  rpcUrl: "https://rpc.testnet.chain.robinhood.com",
  explorer: "https://explorer.testnet.chain.robinhood.com",
} as const;

/** USDG (Global Dollar), 6 decimals — https://docs.robinhood.com/chain/contracts */
export const STABLECOINS = {
  USDG: { address: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", decimals: 6 },
} as const;

/**
 * Stock tokens: ERC-20, 18 decimals, ERC-8056 `uiMultiplier()`; dividends are reinvested by raising the multiplier.
 * Source: official live asset registry https://api.robinhood.com/rhj/assets (linked from
 * https://docs.robinhood.com/chain/contracts and https://docs.robinhood.com/chain/stock-token-apis).
 * Feeds: Chainlink robinhood-mainnet directory https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
 * (8 decimals, 86400s heartbeat; price already includes the multiplier).
 */
export const STOCKS = {
  AAPL: { token: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9", feed: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0", name: "Apple" },
  MSFT: { token: "0xe93237C50D904957Cf27E7B1133b510C669c2e74", feed: "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E", name: "Microsoft" },
  NVDA: { token: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", feed: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15", name: "NVIDIA" },
  GOOGL: { token: "0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3", feed: "0xF6f373a037c30F0e5010d854385cA89185AE638b", name: "Alphabet A" },
  META: { token: "0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35", feed: "0x7C38C00C30BEe9378381E7B6135d7283356D71b1", name: "Meta Platforms" },
  SPY: { token: "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C", feed: "0x319724394D3A0e3669269846abE664Cd621f9f6A", name: "S&P 500 ETF" },
  QQQ: { token: "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68", feed: "0x80901d846d5D7B030F26B480776EE3b29374C2ae", name: "Nasdaq-100 ETF" },
} as const;

/** Chainlink USDG/USD — Chainlink robinhood-mainnet directory (link above). */
export const STABLE_FEEDS = { USDG: "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2" } as const;

/** Canonical helpers — https://docs.robinhood.com/chain/contracts (Multicall3 verified on-chain, not in docs). */
export const CANONICAL = {
  WETH: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  Permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  Multicall3: "0xcA11bde05977b3631167028862bE2a173976CA11",
} as const;

/** Issuer corporate-actions feed used for ex-dates and historical yield (public JSON API). */
export const CORPORATE_ACTIONS_API = "https://api.robinhood.com/rhj/corporate-actions";

/** Things Divsplit needs that do not exist on the chain today, and how they are handled. */
export const gaps = [
  "No L2 sequencer-uptime feed on Robinhood Chain: OracleAdapter.setSequencerUptimeFeed exists and is left unset.",
  "No native/bridged USDC in official docs: USDG is the quote stablecoin (factory.setStable can switch).",
  "No Pyth/RedStone/Chronicle deployments: OracleAdapter accepts any AggregatorV3-compatible feed as primary/secondary.",
  "Only ~36 of 194 stock tokens have Chainlink feeds (e.g. SCHD has none): only stocks with a feed are listed.",
  "Stock tokens are pausable/blocklistable beacon proxies controlled by the issuer: see THREAT_MODEL.md.",
] as const;
