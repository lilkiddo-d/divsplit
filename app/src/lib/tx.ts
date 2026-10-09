"use client";

import { useState } from "react";
import { useAccount, useConfig } from "wagmi";
import { readContract, waitForTransactionReceipt, writeContract } from "wagmi/actions";
import { maxUint256, type Abi, type Address } from "viem";
import { erc20Abi } from "./abis";

export type TxState = { status: "idle" | "pending" | "ok" | "err"; message?: string };

/** Sequential tx runner: approvals (if needed) then the action. Surfaces short human-readable errors. */
export function useTx() {
  const config = useConfig();
  const { address } = useAccount();
  const [state, setState] = useState<TxState>({ status: "idle" });

  async function ensureAllowance(token: Address, spender: Address, amount: bigint) {
    if (!address) throw new Error("Connect a wallet first");
    const allowance = (await readContract(config, { address: token, abi: erc20Abi, functionName: "allowance", args: [address, spender] })) as bigint;
    if (allowance >= amount) return;
    setState({ status: "pending", message: "Approve in your wallet…" });
    const hash = await writeContract(config, { address: token, abi: erc20Abi, functionName: "approve", args: [spender, maxUint256] });
    await waitForTransactionReceipt(config, { hash });
  }

  async function run(
    label: string,
    call: { address: Address; abi: Abi; functionName: string; args: readonly unknown[] },
    approvals: { token: Address; spender: Address; amount: bigint }[] = [],
  ) {
    try {
      setState({ status: "pending", message: "Preparing…" });
      for (const a of approvals) await ensureAllowance(a.token, a.spender, a.amount);
      setState({ status: "pending", message: `${label}: confirm in your wallet…` });
      const hash = await writeContract(config, call as never);
      setState({ status: "pending", message: `${label}: waiting for confirmation…` });
      const receipt = await waitForTransactionReceipt(config, { hash });
      if (receipt.status !== "success") throw new Error("Transaction reverted");
      setState({ status: "ok", message: `${label} confirmed.` });
      return true;
    } catch (e) {
      const err = e as { shortMessage?: string; message?: string };
      setState({ status: "err", message: err.shortMessage ?? err.message?.split("\n")[0] ?? "Failed" });
      return false;
    }
  }

  return { state, run, address };
}

export const deadline = () => BigInt(Math.floor(Date.now() / 1000) + 20 * 60);

/** Apply slippage in basis points: down for minimum outputs, up for maximum inputs. */
export const minOut = (x: bigint, bps = 50n) => (x * (10_000n - bps)) / 10_000n;
export const maxIn = (x: bigint, bps = 50n) => (x * (10_000n + bps)) / 10_000n + 1n;
