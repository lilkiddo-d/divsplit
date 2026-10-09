"use client";

import { useState } from "react";
import { useAccount, useReadContracts } from "wagmi";
import { formatUnits, parseUnits, type Address } from "viem";
import { deployment, PROJECT_TOKEN, TOKEN_FEATURES } from "@/lib/config";
import { erc20Abi, hooksAbi } from "@/lib/abis";
import { useTx } from "@/lib/tx";
import { fmtDate } from "@/lib/math";

const KINDS = ["List stock", "Add expiry", "Delist stock", "Parameter change"];
const STATES = ["Active", "Defeated", "Succeeded (advisory)"];

/** Staking + advisory listing votes. Hidden entirely unless NEXT_PUBLIC_PROJECT_TOKEN is set. */
export default function GovernPage() {
  if (!TOKEN_FEATURES || !deployment) {
    return (
      <div className="card">
        <h1>Token features are not live</h1>
        <p className="muted">The project token has not been launched. The protocol works fully without it.</p>
      </div>
    );
  }
  return <Govern hooks={deployment.projectTokenHooks} token={PROJECT_TOKEN!} stable={deployment.stable} />;
}

function Govern({ hooks, token, stable }: { hooks: Address; token: Address; stable: Address }) {
  const { address } = useAccount();
  const [amt, setAmt] = useState("");
  const [desc, setDesc] = useState("");
  const { state, run } = useTx();
  const reads = useReadContracts({
    allowFailure: true,
    contracts: [
      { address: hooks, abi: hooksAbi, functionName: "projectToken" },
      { address: hooks, abi: hooksAbi, functionName: "totalStaked" },
      { address: hooks, abi: hooksAbi, functionName: "stakeOf", args: [address ?? "0x0000000000000000000000000000000000000000"] },
      { address: hooks, abi: hooksAbi, functionName: "earned", args: [address ?? "0x0000000000000000000000000000000000000000", stable] },
      { address: token, abi: erc20Abi, functionName: "balanceOf", args: [address ?? "0x0000000000000000000000000000000000000000"] },
      { address: hooks, abi: hooksAbi, functionName: "proposalCount" },
    ],
  });
  const r = (i: number) => (reads.data?.[i]?.status === "success" ? reads.data[i].result : undefined);
  const onchainToken = r(0) as Address | undefined;
  const wired = onchainToken && onchainToken.toLowerCase() === token.toLowerCase();
  const n = Number((r(5) as bigint | undefined) ?? 0n);
  const ids = Array.from({ length: Math.min(n, 20) }, (_, i) => BigInt(n - 1 - i));
  const props = useReadContracts({
    allowFailure: true,
    contracts: ids.flatMap((id) => [
      { address: hooks, abi: hooksAbi, functionName: "proposal", args: [id] },
      { address: hooks, abi: hooksAbi, functionName: "state", args: [id] },
    ]),
  });
  const f = (x?: unknown, d = 18) => (typeof x === "bigint" ? Number(formatUnits(x, d)).toLocaleString("en-US", { maximumFractionDigits: 4 }) : "–");
  const a = (() => {
    try {
      return amt ? parseUnits(amt, 18) : 0n;
    } catch {
      return 0n;
    }
  })();

  return (
    <>
      <h1>Stake &amp; vote</h1>
      <p className="lead">
        Stakers earn a streamed share of protocol swap fees and vote on which stocks and expiries should be listed.
        Votes are advisory: listings are executed by the 48-hour timelock.
      </p>
      {!wired && <div className="banner">The project token is configured in the app but not yet wired on-chain (setProjectToken via the timelock).</div>}
      <div className="grid grid-4" style={{ marginBottom: 16 }}>
        <div className="card stat"><div className="label">Total staked</div><div className="value">{f(r(1))}</div></div>
        <div className="card stat"><div className="label">Your stake</div><div className="value">{f(r(2))}</div></div>
        <div className="card stat"><div className="label">Wallet</div><div className="value">{f(r(4))}</div></div>
        <div className="card stat"><div className="label">Earned USDG</div><div className="value">{f(r(3), 6)}</div></div>
      </div>
      <div className="grid grid-2">
        <div className="card">
          <h2>Stake</h2>
          <label className="field"><span>Amount</span><input value={amt} onChange={(e) => setAmt(e.target.value)} placeholder="0.0" /></label>
          <div className="row">
            <button className="btn" disabled={!wired || !address || a === 0n} onClick={() => run("Stake", { address: hooks, abi: hooksAbi, functionName: "stake", args: [a] }, [{ token, spender: hooks, amount: a }])}>Stake</button>
            <button className="btn secondary" disabled={!wired || !address || a === 0n} onClick={() => run("Unstake", { address: hooks, abi: hooksAbi, functionName: "unstake", args: [a] })}>Unstake</button>
            <button className="btn secondary" disabled={!wired || !address} onClick={() => run("Claim", { address: hooks, abi: hooksAbi, functionName: "claimRewards", args: [] })}>Claim fees</button>
          </div>
        </div>
        <div className="card">
          <h2>Propose a listing</h2>
          <label className="field"><span>Description (stock, expiry, rationale)</span><input value={desc} onChange={(e) => setDesc(e.target.value)} /></label>
          <button className="btn" disabled={!wired || !address || !desc} onClick={() => run("Propose", { address: hooks, abi: hooksAbi, functionName: "propose", args: [0, "0x0000000000000000000000000000000000000000", 0n, desc] })}>Submit proposal</button>
        </div>
      </div>
      <div className="card table-wrap" style={{ marginTop: 16 }}>
        <h2>Proposals</h2>
        <table>
          <thead><tr><th>#</th><th>Kind</th><th>Ends</th><th className="num">For</th><th className="num">Against</th><th>State</th><th /></tr></thead>
          <tbody>
            {ids.map((id, i) => {
              const p = props.data?.[i * 2]?.result as { kind: number; voteEnd: number; forVotes: bigint; againstVotes: bigint } | undefined;
              const st = props.data?.[i * 2 + 1]?.result as number | undefined;
              if (!p) return null;
              return (
                <tr key={String(id)}>
                  <td>{String(id)}</td>
                  <td>{KINDS[p.kind]}</td>
                  <td>{fmtDate(Number(p.voteEnd))}</td>
                  <td className="num">{f(p.forVotes)}</td>
                  <td className="num">{f(p.againstVotes)}</td>
                  <td>{st !== undefined ? STATES[st] : "–"}</td>
                  <td className="row">
                    <button className="btn secondary" disabled={st !== 0} onClick={() => run("Vote", { address: hooks, abi: hooksAbi, functionName: "castVote", args: [id, true] })}>For</button>
                    <button className="btn secondary" disabled={st !== 0} onClick={() => run("Vote", { address: hooks, abi: hooksAbi, functionName: "castVote", args: [id, false] })}>Against</button>
                  </td>
                </tr>
              );
            })}
            {ids.length === 0 && <tr><td colSpan={7} className="muted">No proposals yet.</td></tr>}
          </tbody>
        </table>
      </div>
      {state.status !== "idle" && <div className={`status ${state.status === "err" ? "err" : state.status === "ok" ? "ok" : ""}`}>{state.message}</div>}
    </>
  );
}
