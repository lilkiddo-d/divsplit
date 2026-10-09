"use client";

import Link from "next/link";
import { deployment, RPC_URL } from "@/lib/config";
import { useMarketStats } from "@/lib/hooks";
import { fmtDate, fmtPct, fmtUsd } from "@/lib/math";

export default function MarketsPage() {
  const { stats, isLoading } = useMarketStats();

  if (!deployment) {
    return (
      <div className="card">
        <h1>No deployment found</h1>
        <p className="muted">
          No contracts are configured for this chain. Run the deploy script (see DEPLOY.md) — it writes
          app/src/config/generated/deployments.&lt;chainId&gt;.json.
        </p>
      </div>
    );
  }

  return (
    <>
      <h1>Markets</h1>
      <p className="lead">
        Each market splits one stock token into a <span className="pill p">P</span> Price token (redeems the stock
        at expiry) and a <span className="pill d">D</span> Dividend token (receives every dividend until expiry). The
        implied yield is what the D-token price says the market expects in dividends; compare it with the trailing
        yield.
      </p>
      {RPC_URL.includes("127.0.0.1") && <div className="banner">Connected to a local fork at {RPC_URL}.</div>}
      <div className="card table-wrap">
        <table>
          <thead>
            <tr>
              <th>Stock</th>
              <th>Expiry</th>
              <th className="num">Stock token</th>
              <th className="num">P price</th>
              <th className="num">D price</th>
              <th className="num">Implied yield</th>
              <th className="num">Trailing yield</th>
              <th>Next dividend</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {stats.map((s) => {
              const tokenPx = s.unitPrice !== undefined && s.scale ? s.unitPrice / s.scale : undefined;
              const status = s.corporateAction
                ? { cls: "warn", text: "Corporate action" }
                : s.paused
                  ? { cls: "warn", text: "Paused" }
                  : s.inBlackout
                    ? { cls: "warn", text: "Ex-date blackout" }
                    : !s.liquidity
                      ? { cls: "", text: "No liquidity yet" }
                      : { cls: "p", text: "Live" };
              return (
                <tr key={s.market.splitter}>
                  <td>
                    <Link href={`/market/${s.market.splitter}`}>
                      <strong>{s.market.symbol}</strong>
                    </Link>
                  </td>
                  <td>{fmtDate(s.market.expiry)}</td>
                  <td className="num">{tokenPx !== undefined ? fmtUsd(tokenPx) : isLoading ? "…" : "–"}</td>
                  <td className="num">
                    {s.pPriceUnits !== undefined && s.unitPrice !== undefined ? fmtUsd(s.pPriceUnits * s.unitPrice) : "–"}
                  </td>
                  <td className="num">
                    {s.liquidity && s.dPriceUnits !== undefined && s.unitPrice !== undefined ? fmtUsd(s.dPriceUnits * s.unitPrice) : "–"}
                  </td>
                  <td className="num">{s.impliedYield !== undefined ? fmtPct(s.impliedYield) : "–"}</td>
                  <td className="num">{s.historicalYield !== undefined ? fmtPct(s.historicalYield) : "–"}</td>
                  <td>
                    {s.nextAction ? (
                      <>
                        {fmtDate(s.nextAction.date)} <span className="muted">${s.nextAction.rate}</span>
                      </>
                    ) : (
                      <span className="muted">none announced</span>
                    )}
                  </td>
                  <td>
                    <span className={`pill ${status.cls}`}>{status.text}</span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <p className="notice" style={{ marginTop: 12 }}>
        Prices from the protocol oracle (Chainlink). Next dividend = issuer process date (multiplier update) and cash
        rate per share from the issuer&apos;s public corporate-actions feed. Implied yield is the continuous rate
        stored by the D-token pool.
      </p>
    </>
  );
}
