"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { parseAbiItem, type Address } from "viem";
import { fmtPct } from "@/lib/math";

const swapEvent = parseAbiItem(
  "event Swap(address indexed sender, address indexed to, int256 tokenToAccount, int256 stableToAccount, uint256 fee, uint256 protocolFee, int256 lnImpliedRate)",
);

interface Point {
  t: number;
  y: number;
}

/** Implied dividend yield history from on-chain swaps (D pool), against the trailing historical yield. */
export function YieldChart({ dPool, pPool, historical, current }: { dPool: Address; pPool: Address; historical?: number; current?: number }) {
  const client = usePublicClient();
  const q = useQuery({
    queryKey: ["yield-history", dPool],
    enabled: !!client,
    queryFn: async (): Promise<Point[]> => {
      if (!client) return [];
      const latest = await client.getBlockNumber();
      const from = latest > 2_000_000n ? latest - 2_000_000n : 0n;
      const logs = await client.getLogs({ address: [dPool, pPool], event: swapEvent, fromBlock: from, toBlock: latest }).catch(() => []);
      const pts: Point[] = [];
      for (const l of logs.slice(-200)) {
        const block = await client.getBlock({ blockNumber: l.blockNumber! });
        pts.push({ t: Number(block.timestamp), y: Number(l.args.lnImpliedRate!) / 1e18 });
      }
      return pts;
    },
    refetchInterval: 60_000,
  });

  const points = [...(q.data ?? [])];
  const now = Date.now() / 1000;
  if (current !== undefined) points.push({ t: now, y: current });
  if (points.length === 1) points.unshift({ t: now - 86400, y: points[0].y });

  const W = 640;
  const H = 220;
  const pad = { l: 48, r: 12, t: 12, b: 28 };
  const ys = points.map((p) => p.y).concat(historical !== undefined ? [historical] : []);
  const yMax = Math.max(0.01, ...ys) * 1.2;
  const tMin = points.length ? points[0].t : now - 86400;
  const tMax = Math.max(now, tMin + 1);
  const x = (t: number) => pad.l + ((t - tMin) / (tMax - tMin)) * (W - pad.l - pad.r);
  const y = (v: number) => H - pad.b - (v / yMax) * (H - pad.t - pad.b);
  const path = points.map((p, i) => `${i ? "L" : "M"}${x(p.t).toFixed(1)},${y(p.y).toFixed(1)}`).join(" ");
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => f * yMax);

  return (
    <div className="chart">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Implied versus historical dividend yield">
        {ticks.map((v) => (
          <g key={v}>
            <line x1={pad.l} x2={W - pad.r} y1={y(v)} y2={y(v)} stroke="var(--border)" strokeWidth={1} />
            <text x={pad.l - 6} y={y(v) + 4} textAnchor="end" fontSize={11} fill="var(--muted)">
              {fmtPct(v, 1)}
            </text>
          </g>
        ))}
        {historical !== undefined && (
          <line x1={pad.l} x2={W - pad.r} y1={y(historical)} y2={y(historical)} stroke="var(--muted)" strokeDasharray="5 4" strokeWidth={1.5} />
        )}
        {points.length > 0 && <path d={path} fill="none" stroke="var(--dividend)" strokeWidth={2} />}
        {points.map((p, i) => (
          <circle key={i} cx={x(p.t)} cy={y(p.y)} r={2.5} fill="var(--dividend)" />
        ))}
        <text x={pad.l} y={H - 8} fontSize={11} fill="var(--muted)">
          {new Date(tMin * 1000).toISOString().slice(0, 10)}
        </text>
        <text x={W - pad.r} y={H - 8} fontSize={11} fill="var(--muted)" textAnchor="end">
          now
        </text>
      </svg>
      <div className="legend">
        <span>
          <i style={{ background: "var(--dividend)" }} />
          Implied yield (D pool, per swap)
        </span>
        <span>
          <i style={{ background: "var(--muted)" }} />
          Trailing 12m yield (issuer feed)
        </span>
        {q.isLoading && <span>loading history…</span>}
      </div>
    </div>
  );
}
