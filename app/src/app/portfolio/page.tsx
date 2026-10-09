"use client";

import Link from "next/link";
import { useAccount, useReadContracts } from "wagmi";
import { formatUnits, type Address } from "viem";
import { deployment } from "@/lib/config";
import { erc20Abi, splitterAbi } from "@/lib/abis";
import { fmtDate } from "@/lib/math";
import { useTx } from "@/lib/tx";

export default function PortfolioPage() {
  const { address } = useAccount();
  const markets = deployment?.markets ?? [];
  const reads = useReadContracts({
    allowFailure: true,
    query: { enabled: !!address },
    contracts: markets.flatMap((m) => [
      { address: m.pToken, abi: erc20Abi, functionName: "balanceOf", args: [address as Address] },
      { address: m.dToken, abi: erc20Abi, functionName: "balanceOf", args: [address as Address] },
      { address: m.splitter, abi: splitterAbi, functionName: "claimable", args: [address as Address] },
    ]),
  });
  const { state, run } = useTx();

  if (!address) return <div className="card">Connect a wallet to see your positions and claimable dividends.</div>;

  const rows = markets
    .map((m, i) => {
      const r = (k: number) => (reads.data?.[i * 3 + k]?.status === "success" ? reads.data[i * 3 + k].result : undefined);
      const claim = r(2) as readonly [readonly Address[], readonly bigint[]] | undefined;
      const stockClaim = claim ? claim[1].reduce((a, x, j) => (claim[0][j].toLowerCase() === m.stock.toLowerCase() ? a + x : a), 0n) : 0n;
      const otherClaim = claim ? claim[1].some((x, j) => x > 0n && claim[0][j].toLowerCase() !== m.stock.toLowerCase()) : false;
      return { m, p: (r(0) as bigint) ?? 0n, d: (r(1) as bigint) ?? 0n, stockClaim, otherClaim };
    })
    .filter((x) => x.p > 0n || x.d > 0n || x.stockClaim > 0n || x.otherClaim);

  const f = (x: bigint) => Number(formatUnits(x, 18)).toLocaleString("en-US", { maximumFractionDigits: 6 });

  return (
    <>
      <h1>Portfolio</h1>
      <p className="lead">Your P and D positions and dividends ready to claim.</p>
      <div className="card table-wrap">
        <table>
          <thead>
            <tr>
              <th>Market</th>
              <th className="num">P</th>
              <th className="num">D</th>
              <th className="num">Claimable</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr>
                <td colSpan={5} className="muted">
                  No positions yet. <Link href="/">Split a stock</Link> to get started.
                </td>
              </tr>
            )}
            {rows.map(({ m, p, d, stockClaim, otherClaim }) => (
              <tr key={m.splitter}>
                <td>
                  <Link href={`/market/${m.splitter}`}>
                    {m.symbol} · {fmtDate(m.expiry)}
                  </Link>
                </td>
                <td className="num">{f(p)}</td>
                <td className="num">{f(d)}</td>
                <td className="num">
                  {f(stockClaim)} {m.symbol}
                  {otherClaim ? " + cash" : ""}
                </td>
                <td>
                  <button
                    className="btn secondary"
                    disabled={stockClaim === 0n && !otherClaim}
                    onClick={async () => {
                      if (await run("Claim", { address: m.splitter, abi: splitterAbi, functionName: "claimDividends", args: [address] })) reads.refetch();
                    }}
                  >
                    Claim
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {state.status !== "idle" && <div className={`status ${state.status === "err" ? "err" : state.status === "ok" ? "ok" : ""}`}>{state.message}</div>}
    </>
  );
}
