import { defineChain, isAddress, type Address } from "viem";
import { robinhoodMainnet } from "@config/chains";
import deployments4663 from "../config/generated/deployments.4663.json";

export interface MarketInfo {
  stock: Address;
  symbol: string;
  expiry: number;
  splitter: Address;
  pToken: Address;
  dToken: Address;
  pPool: Address;
  dPool: Address;
}

export interface Deployment {
  chainId: number;
  factory: Address;
  router: Address;
  stable: Address;
  projectTokenHooks: Address;
  feeCollector: Address;
  oracle: Address;
  timelock: Address;
  markets: MarketInfo[];
}

export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? robinhoodMainnet.id);
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || robinhoodMainnet.rpcUrls.public;

export const appChain = defineChain({
  id: CHAIN_ID,
  name: RPC_URL.includes("127.0.0.1") || RPC_URL.includes("localhost") ? "Robinhood Chain (local fork)" : robinhoodMainnet.name,
  nativeCurrency: robinhoodMainnet.nativeCurrency,
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: robinhoodMainnet.explorer.name, url: robinhoodMainnet.explorer.url } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});

function normalize(raw: unknown): Deployment {
  const d = raw as Deployment & { markets: MarketInfo[] | string };
  const markets = typeof d.markets === "string" ? (JSON.parse(d.markets) as MarketInfo[]) : (d.markets ?? []);
  return { ...d, markets: markets.map((m) => ({ ...m, expiry: Number(m.expiry) })) };
}

const all: Record<number, Deployment> = {
  4663: normalize(deployments4663),
};

export const deployment: Deployment | undefined = all[CHAIN_ID]?.factory ? all[CHAIN_ID] : undefined;

const rawToken = (process.env.NEXT_PUBLIC_PROJECT_TOKEN ?? "").trim();
/** $DIVS address, or undefined -> every token feature is hidden. */
export const PROJECT_TOKEN: Address | undefined = isAddress(rawToken) ? (rawToken as Address) : undefined;
export const TOKEN_FEATURES = PROJECT_TOKEN !== undefined;

export function marketBySplitter(splitter: string): MarketInfo | undefined {
  return deployment?.markets.find((m) => m.splitter.toLowerCase() === splitter.toLowerCase());
}

const rawDev = (process.env.NEXT_PUBLIC_DEV_IMPERSONATE ?? "").trim();
const isLocalRpc = /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?/.test(RPC_URL);
/** Local-fork testing only: address to impersonate through anvil (no private key involved). */
export const DEV_IMPERSONATE: Address | undefined = isLocalRpc && isAddress(rawDev) ? (rawDev as Address) : undefined;
