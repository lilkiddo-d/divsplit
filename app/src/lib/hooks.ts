"use client";

import { useQuery } from "@tanstack/react-query";
import { useReadContracts } from "wagmi";
import { formatUnits, type Address } from "viem";
import { ammAbi, scaledUiAbi, splitterAbi } from "./abis";
import { deployment, type MarketInfo } from "./config";
import { historicalYield, impliedYieldFromDPrice, yearsUntil, yieldFromLnRate } from "./math";
import type { CorpAction } from "@/app/api/corporate-actions/route";

export function useCorporateActions() {
  return useQuery({
    queryKey: ["corp-actions"],
    queryFn: async (): Promise<CorpAction[]> => {
      const r = await fetch("/api/corporate-actions");
      const j = (await r.json()) as { actions: CorpAction[] };
      return j.actions;
    },
    staleTime: 3_600_000,
    refetchInterval: false,
  });
}

export interface MarketStats {
  market: MarketInfo;
  unitPrice?: number; // stable per unit (P+D pair)
  pPriceUnits?: number;
  dPriceUnits?: number;
  impliedYield?: number; // continuous, from D pool
  impliedYieldP?: number; // continuous, from P pool
  historicalYield?: number;
  multiplier?: number;
  scale?: number;
  paused?: boolean;
  corporateAction?: boolean;
  inBlackout?: boolean;
  nextAction?: CorpAction;
  liquidity?: boolean;
}

/** Batched reads for every market (multicall). */
export function useMarketStats(markets: MarketInfo[] = deployment?.markets ?? []) {
  const contracts = markets.flatMap((m) => [
    { address: m.pPool, abi: ammAbi, functionName: "unitPrice" },
    { address: m.pPool, abi: ammAbi, functionName: "spotPriceInUnits" },
    { address: m.dPool, abi: ammAbi, functionName: "spotPriceInUnits" },
    { address: m.dPool, abi: ammAbi, functionName: "lnImpliedRate" },
    { address: m.pPool, abi: ammAbi, functionName: "lnImpliedRate" },
    { address: m.stock, abi: scaledUiAbi, functionName: "uiMultiplier" },
    { address: m.splitter, abi: splitterAbi, functionName: "scale" },
    { address: m.splitter, abi: splitterAbi, functionName: "paused" },
    { address: m.splitter, abi: splitterAbi, functionName: "corporateActionPending" },
    { address: m.splitter, abi: splitterAbi, functionName: "inBlackout" },
    { address: m.dPool, abi: ammAbi, functionName: "totalSupply" },
  ] as const);
  const per = 11;
  const reads = useReadContracts({ contracts: contracts as never, allowFailure: true, query: { enabled: markets.length > 0 } }) as {
    data?: { status: "success" | "failure"; result?: unknown }[];
    isLoading: boolean;
    error: Error | null;
    refetch: () => void;
  };
  const corp = useCorporateActions();

  const stats: MarketStats[] = markets.map((m, i) => {
    const r = (k: number) => {
      const x = reads.data?.[i * per + k];
      return x && x.status === "success" ? (x.result as unknown) : undefined;
    };
    const wad = (v: unknown) => (typeof v === "bigint" ? Number(formatUnits(v, 18)) : undefined);
    const unitPrice = wad(r(0));
    const dLiquid = typeof r(10) === "bigint" && (r(10) as bigint) > 0n;
    const pLn = r(4) as bigint | undefined;
    const dLn = r(3) as bigint | undefined;
    const multiplier = wad(r(5));
    const now = Date.now() / 1000;
    const actions = (corp.data ?? []).filter((a) => a.symbol === m.symbol && a.type === "CASH_DIVIDEND");
    const nextAction = actions.filter((a) => a.date >= now - 86400).sort((a, b) => a.date - b.date)[0];
    const tokenPrice = unitPrice !== undefined ? unitPrice / (wad(r(6)) || 1) : undefined;
    const hist =
      tokenPrice && multiplier
        ? historicalYield(actions.filter((a) => a.rate !== null).map((a) => ({ exDate: a.date, ratePerShare: a.rate! })), tokenPrice, multiplier)
        : undefined;
    const dUnits = dLiquid ? wad(r(2)) : undefined;
    return {
      market: m,
      unitPrice,
      pPriceUnits: wad(r(1)),
      dPriceUnits: dUnits,
      impliedYield: dLiquid && dLn !== undefined ? yieldFromLnRate(dLn) : dUnits ? impliedYieldFromDPrice(dUnits, yearsUntil(m.expiry)) : undefined,
      impliedYieldP: pLn !== undefined ? yieldFromLnRate(pLn) : undefined,
      historicalYield: hist,
      multiplier,
      scale: wad(r(6)),
      paused: r(7) as boolean | undefined,
      corporateAction: r(8) as boolean | undefined,
      inBlackout: r(9) as boolean | undefined,
      nextAction,
      liquidity: dLiquid,
    };
  });
  return { stats, isLoading: reads.isLoading, error: reads.error, refetch: reads.refetch };
}

export function shortAddr(a?: Address | string) {
  return a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "";
}
