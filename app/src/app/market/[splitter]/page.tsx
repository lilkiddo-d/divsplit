"use client";

import { use, useMemo, useState } from "react";
import Link from "next/link";
import { useAccount, useReadContracts } from "wagmi";
import { formatUnits, parseUnits, type Address } from "viem";
import { marketBySplitter, deployment } from "@/lib/config";
import { useMarketStats } from "@/lib/hooks";
import { ammAbi, erc20Abi, routerAbi, splitterAbi } from "@/lib/abis";
import { deadline, minOut, useTx } from "@/lib/tx";
import { fmtDate, fmtPct, fmtUsd, yearsUntil } from "@/lib/math";
import { YieldChart } from "@/components/YieldChart";

type Tab = "split" | "merge" | "redeem" | "trade" | "liquidity" | "claim";

export default function MarketPage({ params }: { params: Promise<{ splitter: string }> }) {
  const { splitter } = use(params);
  const market = marketBySplitter(splitter);
  const markets = useMemo(() => (market ? [market] : []), [market]);
  const { stats } = useMarketStats(markets);
  const s = stats[0];
  const [tab, setTab] = useState<Tab>("split");
  const { address } = useAccount();

  const stable = deployment?.stable as Address;
  const bal = useReadContracts({
    allowFailure: true,
    query: { enabled: !!address && !!market },
    contracts: market
      ? ([
          { address: market.stock, abi: erc20Abi, functionName: "balanceOf", args: [address!] },
          { address: market.pToken, abi: erc20Abi, functionName: "balanceOf", args: [address!] },
          { address: market.dToken, abi: erc20Abi, functionName: "balanceOf", args: [address!] },
          { address: stable, abi: erc20Abi, functionName: "balanceOf", args: [address!] },
          { address: market.splitter, abi: splitterAbi, functionName: "claimable", args: [address!] },
          { address: market.pPool, abi: ammAbi, functionName: "balanceOf", args: [address!] },
          { address: market.dPool, abi: ammAbi, functionName: "balanceOf", args: [address!] },
        ] as const)
      : [],
  });
  const get = (i: number) => (bal.data?.[i]?.status === "success" ? bal.data[i].result : undefined);
  const balances = {
    stock: (get(0) as bigint | undefined) ?? 0n,
    p: (get(1) as bigint | undefined) ?? 0n,
    d: (get(2) as bigint | undefined) ?? 0n,
    stable: (get(3) as bigint | undefined) ?? 0n,
    claimable: get(4) as readonly [readonly Address[], readonly bigint[]] | undefined,
    lpP: (get(5) as bigint | undefined) ?? 0n,
    lpD: (get(6) as bigint | undefined) ?? 0n,
  };

  if (!market) {
    return (
      <div className="card">
        Unknown market. <Link href="/">Back to markets</Link>
      </div>
    );
  }

  const expired = Date.now() / 1000 >= market.expiry;
  const tokenPx = s?.unitPrice !== undefined && s.scale ? s.unitPrice / s.scale : undefined;

  return (
    <>
      <p className="muted" style={{ margin: 0 }}>
        <Link href="/">Markets</Link> / {market.symbol}
      </p>
      <h1>
        {market.symbol} · expires {fmtDate(market.expiry)}
      </h1>
      <p className="lead">
        1 {market.symbol} token = 1 <span className="pill p">P</span> + 1 <span className="pill d">D</span> while no
        dividend has been reinvested. Each reinvested dividend is carved out of the stock and paid to D holders, so
        one P+D pair then redeems slightly fewer tokens representing the same number of shares.
      </p>
      {(s?.corporateAction || s?.paused) && (
        <div className="banner">
          {s?.corporateAction
            ? "A corporate action (split, reverse split or mechanism change) was detected. Split, merge and redeem are halted until governance resolves it through the timelock."
            : "This market is paused by the guardian. Claims and LP withdrawals still work."}
        </div>
      )}
      {s?.inBlackout && <div className="banner">Ex-date blackout: new splits are disabled until the dividend is paid.</div>}

      <div className="grid grid-4" style={{ marginBottom: 16 }}>
        <Stat label="Stock token" value={tokenPx !== undefined ? fmtUsd(tokenPx) : "–"} />
        <Stat label="P price" value={s?.pPriceUnits !== undefined && s.unitPrice ? fmtUsd(s.pPriceUnits * s.unitPrice) : "–"} />
        <Stat label="D price" value={s?.liquidity && s.dPriceUnits !== undefined && s.unitPrice ? fmtUsd(s.dPriceUnits * s.unitPrice) : "–"} />
        <Stat label="Implied yield" value={s?.impliedYield !== undefined ? fmtPct(s.impliedYield) : "–"} />
        <Stat label="Trailing yield" value={s?.historicalYield !== undefined ? fmtPct(s.historicalYield) : "–"} />
        <Stat
          label="Spread"
          value={s?.impliedYield !== undefined && s.historicalYield !== undefined ? fmtPct(s.impliedYield - s.historicalYield) : "–"}
        />
        <Stat label="Time to expiry" value={`${(yearsUntil(market.expiry) * 365).toFixed(0)} days`} />
        <Stat label="Stock per P+D" value={s?.scale !== undefined ? s.scale.toFixed(6) : "–"} />
      </div>

      <div className="grid grid-2">
        <div className="card">
          <h2>Implied vs trailing dividend yield</h2>
          <YieldChart dPool={market.dPool} pPool={market.pPool} historical={s?.historicalYield} current={s?.impliedYield} />
          <p className="notice">
            Implied yield r solves D = 1 − e<sup>−r·t</sup> (D in units of one P+D pair, t in years). When implied is
            above trailing, the market prices more dividends than history suggests (D rich, P cheap).
          </p>
        </div>

        <div className="card">
          <div className="tabs">
            {(["split", "merge", "redeem", "trade", "liquidity", "claim"] as Tab[]).map((t) => (
              <button key={t} className={tab === t ? "active" : ""} onClick={() => setTab(t)}>
                {t[0].toUpperCase() + t.slice(1)}
              </button>
            ))}
          </div>
          <div className="row notice" style={{ marginBottom: 12 }}>
            <span>
              Wallet: {fmt(balances.stock)} {market.symbol} · {fmt(balances.p)} P · {fmt(balances.d)} D · {fmt(balances.stable, 6)} USDG
            </span>
          </div>
          {tab === "split" && <SplitForm market={market} max={balances.stock} expired={expired} onDone={bal.refetch} />}
          {tab === "merge" && <MergeForm market={market} max={balances.p < balances.d ? balances.p : balances.d} expired={expired} onDone={bal.refetch} />}
          {tab === "redeem" && <RedeemForm market={market} max={balances.p} expired={expired} onDone={bal.refetch} />}
          {tab === "trade" && <TradeForm market={market} expired={expired} onDone={bal.refetch} />}
          {tab === "liquidity" && <LiquidityForm market={market} lpP={balances.lpP} lpD={balances.lpD} expired={expired} onDone={bal.refetch} />}
          {tab === "claim" && <ClaimForm market={market} claimable={balances.claimable} onDone={bal.refetch} />}
        </div>
      </div>
    </>
  );
}

function fmt(x: bigint, dec = 18) {
  const n = Number(formatUnits(x, dec));
  return n.toLocaleString("en-US", { maximumFractionDigits: 4 });
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="card stat">
      <div className="label">{label}</div>
      <div className="value">{value}</div>
    </div>
  );
}

type M = NonNullable<ReturnType<typeof marketBySplitter>>;

function Status({ state }: { state: ReturnType<typeof useTx>["state"] }) {
  if (state.status === "idle") return null;
  return <div className={`status ${state.status === "err" ? "err" : state.status === "ok" ? "ok" : ""}`}>{state.message}</div>;
}

function AmountInput({ value, onChange, max, dec = 18, label }: { value: string; onChange: (v: string) => void; max?: bigint; dec?: number; label: string }) {
  return (
    <label className="field">
      <span>
        {label}
        {max !== undefined && (
          <>
            {" "}
            ·{" "}
            <a href="#" onClick={(e) => (e.preventDefault(), onChange(formatUnits(max, dec)))}>
              max {fmt(max, dec)}
            </a>
          </>
        )}
      </span>
      <input inputMode="decimal" placeholder="0.0" value={value} onChange={(e) => onChange(e.target.value)} />
    </label>
  );
}

function parse(v: string, dec = 18): bigint {
  try {
    return v ? parseUnits(v, dec) : 0n;
  } catch {
    return 0n;
  }
}

function SplitForm({ market, max, expired, onDone }: { market: M; max: bigint; expired: boolean; onDone: () => void }) {
  const [v, setV] = useState("");
  const { state, run, address } = useTx();
  const amt = parse(v);
  return (
    <>
      <AmountInput label={`${market.symbol} to split`} value={v} onChange={setV} max={max} />
      <p className="notice">You receive equal amounts of P and D. Splitting is closed during ex-date blackouts.</p>
      <button
        className="btn"
        disabled={!address || amt === 0n || expired}
        onClick={async () => {
          if (await run("Split", { address: market.splitter, abi: splitterAbi, functionName: "split", args: [amt, address!] }, [{ token: market.stock, spender: market.splitter, amount: amt }])) onDone();
        }}
      >
        {expired ? "Expired" : "Split"}
      </button>
      <Status state={state} />
    </>
  );
}

function MergeForm({ market, max, expired, onDone }: { market: M; max: bigint; expired: boolean; onDone: () => void }) {
  const [v, setV] = useState("");
  const { state, run, address } = useTx();
  const amt = parse(v);
  return (
    <>
      <AmountInput label="P + D pairs to merge" value={v} onChange={setV} max={max} />
      <p className="notice">Burns equal P and D and returns the stock. Your accrued dividends stay claimable.</p>
      <button
        className="btn"
        disabled={!address || amt === 0n || expired}
        onClick={async () => {
          if (await run("Merge", { address: market.splitter, abi: splitterAbi, functionName: "merge", args: [amt, address!] })) onDone();
        }}
      >
        {expired ? "Expired — use Redeem" : "Merge"}
      </button>
      <Status state={state} />
    </>
  );
}

function RedeemForm({ market, max, expired, onDone }: { market: M; max: bigint; expired: boolean; onDone: () => void }) {
  const [v, setV] = useState("");
  const { state, run, address } = useTx();
  const amt = parse(v);
  return (
    <>
      <AmountInput label="P to redeem" value={v} onChange={setV} max={max} />
      <p className="notice">After expiry each P redeems its share of the stock. Not available before {fmtDate(market.expiry)}.</p>
      <button
        className="btn"
        disabled={!address || amt === 0n || !expired}
        onClick={async () => {
          if (await run("Redeem", { address: market.splitter, abi: splitterAbi, functionName: "redeem", args: [amt, address!] })) onDone();
        }}
      >
        Redeem
      </button>
      <Status state={state} />
    </>
  );
}

function TradeForm({ market, expired, onDone }: { market: M; expired: boolean; onDone: () => void }) {
  const [side, setSide] = useState<"P" | "D">("D");
  const [dir, setDir] = useState<"buy" | "sell">("buy");
  const [v, setV] = useState("");
  const { state, run, address } = useTx();
  const pool = side === "P" ? market.pPool : market.dPool;
  const token = side === "P" ? market.pToken : market.dToken;
  const stable = deployment!.stable as Address;
  const router = deployment!.router as Address;
  const amt = parse(v, dir === "buy" ? 6 : 18);

  const reads = useReadContracts({
    allowFailure: true,
    query: { enabled: amt > 0n },
    contracts: [
      dir === "buy"
        ? { address: router, abi: routerAbi, functionName: "quoteBuyExactStable", args: [pool, amt] }
        : { address: pool, abi: ammAbi, functionName: "previewSell", args: [amt] },
    ],
  });
  const quote = reads.data?.[0]?.status === "success" ? (reads.data[0].result as bigint) : undefined;
  // price impact vs the pool's spot price (both in USDG per whole token)
  const spot = useReadContracts({ allowFailure: true, contracts: [{ address: pool, abi: ammAbi, functionName: "spotPriceInStable" }] });
  const spotPx = spot.data?.[0]?.status === "success" ? Number(formatUnits(spot.data[0].result as bigint, 18)) : undefined;
  const execPx =
    quote !== undefined && quote > 0n && amt > 0n
      ? dir === "buy"
        ? Number(formatUnits(amt, 6)) / Number(formatUnits(quote, 18))
        : Number(formatUnits(quote, 6)) / Number(formatUnits(amt, 18))
      : undefined;
  const impact = spotPx && execPx ? Math.abs(execPx / spotPx - 1) : undefined;

  return (
    <>
      <div className="row" style={{ marginBottom: 12 }}>
        <select value={side} onChange={(e) => setSide(e.target.value as "P" | "D")} style={{ width: "auto" }}>
          <option value="D">D (dividends)</option>
          <option value="P">P (price)</option>
        </select>
        <select value={dir} onChange={(e) => (setDir(e.target.value as "buy" | "sell"), setV(""))} style={{ width: "auto" }}>
          <option value="buy">Buy with USDG</option>
          <option value="sell">Sell for USDG</option>
        </select>
      </div>
      <AmountInput label={dir === "buy" ? "USDG to spend" : `${side} to sell`} value={v} onChange={setV} />
      <p className="notice">
        {quote !== undefined
          ? dir === "buy"
            ? `≈ ${fmt(quote)} ${side} (0.5% slippage tolerance)`
            : `≈ ${fmt(quote, 6)} USDG (0.5% slippage tolerance)`
          : amt > 0n
            ? "No quote (insufficient liquidity or stale oracle)"
            : "Swaps settle against the time-decay pool; prices converge to P = 1 pair and D = 0 at expiry."}
      </p>
      {impact !== undefined && (
        <p className={`notice ${impact > 0.05 ? "status err" : ""}`}>
          Price impact {(impact * 100).toFixed(2)}% (execution ≈ ${execPx!.toFixed(4)} vs spot ${spotPx!.toFixed(4)})
          {impact > 0.05 ? " — large relative to pool liquidity; consider a smaller order." : ""}
        </p>
      )}
      <button
        className="btn"
        disabled={!address || amt === 0n || quote === undefined || expired}
        onClick={async () => {
          const ok =
            dir === "buy"
              ? await run("Buy", { address: router, abi: routerAbi, functionName: "buyExactStable", args: [pool, amt, minOut(quote!), address!, deadline()] }, [{ token: stable, spender: router, amount: amt }])
              : await run("Sell", { address: router, abi: routerAbi, functionName: "sellExactToken", args: [pool, amt, minOut(quote!), address!, deadline()] }, [{ token, spender: router, amount: amt }]);
          if (ok) onDone();
        }}
      >
        {expired ? "Trading closed at expiry" : dir === "buy" ? `Buy ${side}` : `Sell ${side}`}
      </button>
      <Status state={state} />
    </>
  );
}

function LiquidityForm({ market, lpP, lpD, expired, onDone }: { market: M; lpP: bigint; lpD: bigint; expired: boolean; onDone: () => void }) {
  const [side, setSide] = useState<"P" | "D">("P");
  const [tok, setTok] = useState("");
  const [usd, setUsd] = useState("");
  const { state, run, address } = useTx();
  const pool = side === "P" ? market.pPool : market.dPool;
  const token = side === "P" ? market.pToken : market.dToken;
  const lp = side === "P" ? lpP : lpD;
  const stable = deployment!.stable as Address;
  const t = parse(tok);
  const u = parse(usd, 6);
  return (
    <>
      <select value={side} onChange={(e) => setSide(e.target.value as "P" | "D")} style={{ width: "auto", marginBottom: 12 }}>
        <option value="P">P / USDG pool</option>
        <option value="D">D / USDG pool</option>
      </select>
      <AmountInput label={`${side} amount`} value={tok} onChange={setTok} />
      <AmountInput label="USDG amount (max; the pool takes its current ratio)" value={usd} onChange={setUsd} dec={6} />
      <div className="row">
        <button
          className="btn"
          disabled={!address || t === 0n || u === 0n || expired}
          onClick={async () => {
            if (
              await run("Add liquidity", { address: pool, abi: ammAbi, functionName: "addLiquidity", args: [t, u, 0n, address!, deadline()] }, [
                { token, spender: pool, amount: t },
                { token: stable, spender: pool, amount: u },
              ])
            )
              onDone();
          }}
        >
          Add
        </button>
        <button
          className="btn secondary"
          disabled={!address || lp === 0n}
          onClick={async () => {
            if (await run("Remove liquidity", { address: pool, abi: ammAbi, functionName: "removeLiquidity", args: [lp, 0n, 0n, address!, deadline()] })) onDone();
          }}
        >
          Remove all ({fmt(lp)} LP)
        </button>
      </div>
      <p className="notice">Removing liquidity is always possible, including while paused and after expiry. LPs earn 80% of the 0.30% swap fee.</p>
      <Status state={state} />
    </>
  );
}

function ClaimForm({ market, claimable, onDone }: { market: M; claimable?: readonly [readonly Address[], readonly bigint[]]; onDone: () => void }) {
  const { state, run, address } = useTx();
  const rows = claimable ? claimable[0].map((tkn, i) => ({ tkn, amt: claimable[1][i] })) : [];
  const total = rows.reduce((a, r) => a + r.amt, 0n);
  return (
    <>
      <p className="notice">D holders accrue every dividend the splitter captures. Under the ERC-8056 multiplier mechanism dividends are paid in the stock token itself.</p>
      <table>
        <tbody>
          {rows.map((r) => (
            <tr key={r.tkn}>
              <td className="mono">{r.tkn.toLowerCase() === market.stock.toLowerCase() ? market.symbol : r.tkn}</td>
              <td className="num">{fmt(r.amt)}</td>
            </tr>
          ))}
          {rows.length === 0 && (
            <tr>
              <td className="muted">Connect a wallet to see claimable dividends.</td>
            </tr>
          )}
        </tbody>
      </table>
      <div className="row" style={{ marginTop: 12 }}>
        <button
          className="btn"
          disabled={!address || total === 0n}
          onClick={async () => {
            if (await run("Claim", { address: market.splitter, abi: splitterAbi, functionName: "claimDividends", args: [address!] })) onDone();
          }}
        >
          Claim dividends
        </button>
        <button
          className="btn secondary"
          disabled={!address}
          onClick={async () => {
            if (await run("Harvest", { address: market.splitter, abi: splitterAbi, functionName: "harvest", args: [] })) onDone();
          }}
        >
          Harvest now
        </button>
      </div>
      <Status state={state} />
    </>
  );
}

