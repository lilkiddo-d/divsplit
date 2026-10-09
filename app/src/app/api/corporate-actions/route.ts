import { NextResponse } from "next/server";
import { CORPORATE_ACTIONS_API } from "@config/chains";

export const dynamic = "force-dynamic";

interface RawAction {
  type: string;
  status: string;
  processDate?: { year: number; month: number; day: number };
  tokenSymbol?: string;
  deployments?: { contractAddress: string; chainId: number }[];
  details?: { cashDividend?: { underlyingSymbol: string; rate: string } };
}

export interface CorpAction {
  symbol: string;
  token: string | null;
  type: "CASH_DIVIDEND" | string;
  status: string;
  date: number; // unix seconds (issuer process date: multiplier update)
  rate: number | null; // USD per underlying share for cash dividends
}

/** Server-side proxy of the issuer's public corporate-actions feed (avoids CORS, cached for an hour). */
export async function GET() {
  try {
    const res = await fetch(CORPORATE_ACTIONS_API, { next: { revalidate: 3600 }, headers: { accept: "application/json" } });
    if (!res.ok) throw new Error(`upstream ${res.status}`);
    const json = (await res.json()) as { corpActions?: RawAction[] };
    const actions: CorpAction[] = (json.corpActions ?? [])
      .filter((a) => a.processDate)
      .map((a) => ({
        symbol: a.details?.cashDividend?.underlyingSymbol ?? a.tokenSymbol ?? "",
        token: a.deployments?.find((d) => d.chainId === 4663)?.contractAddress ?? null,
        type: a.type.replace("CORPORATE_ACTION_TYPE_", ""),
        status: a.status.replace("CORPORATE_ACTION_STATUS_", ""),
        date: Date.UTC(a.processDate!.year, a.processDate!.month - 1, a.processDate!.day) / 1000,
        rate: a.details?.cashDividend ? Number(a.details.cashDividend.rate) : null,
      }));
    return NextResponse.json({ ok: true, actions });
  } catch (e) {
    return NextResponse.json({ ok: false, error: (e as Error).message, actions: [] }, { status: 200 });
  }
}
