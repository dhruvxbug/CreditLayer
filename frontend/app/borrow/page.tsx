"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import ZKProofGenerator from "@/components/ZKProofGenerator";
import { useCreditScore } from "@/hooks/useCreditScore";
import { useLoanPool } from "@/hooks/useLoanPool";

function minCollateralRatioByTier(tier: string): number {
  if (tier === "Gold") return 1.15;
  if (tier === "Silver") return 1.25;
  if (tier === "Bronze") return 1.35;
  return 0;
}

export default function BorrowPage() {
  const { tier } = useCreditScore();
  const { borrow, isBorrowing } = useLoanPool();

  const [usdcAmount, setUsdcAmount] = useState("1000");
  const [proof, setProof] = useState<`0x${string}`>("0x");
  const [txHash, setTxHash] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const collateralRatio = minCollateralRatioByTier(tier);
  const requiredCollateralEth = useMemo(() => {
    const amount = Number(usdcAmount || "0");
    if (!collateralRatio || !amount) return 0;
    return (amount * collateralRatio) / 2000;
  }, [usdcAmount, collateralRatio]);

  async function submitBorrow() {
    setError(null);
    setTxHash(null);
    try {
      const threshold = tier === "Gold" ? 800 : tier === "Silver" ? 600 : 300;
      const hash = await borrow(usdcAmount, requiredCollateralEth.toFixed(6), proof, threshold);
      setTxHash(hash);
    } catch (submitError) {
      setError(submitError instanceof Error ? submitError.message : "Borrow failed");
    }
  }

  return (
    <main className="mx-auto min-h-screen max-w-3xl px-6 py-12 md:py-20 font-sans">
      <h1 className="mb-10 text-4xl font-black tracking-tighter sm:text-5xl leading-tight text-neutral-900">Borrow Wizard</h1>

      <div className="space-y-8 rounded-[2.5rem] border-[3px] border-neutral-900 bg-[#FAFAFA] p-8 shadow-[12px_12px_0px_#000]">
        
        <div className="rounded-3xl border-2 border-neutral-900 bg-white p-6 shadow-[4px_4px_0px_#000]">
          <h2 className="text-sm font-extrabold uppercase tracking-widest text-neutral-500 mb-4">Step 1: Amount & Collateral</h2>
          <label className="block mb-6">
            <span className="sr-only">Borrow amount (USDC)</span>
            <div className="relative border-b-4 border-neutral-900 focus-within:border-[#d4ff00] transition-colors">
              <span className="absolute left-0 top-1/2 -translate-y-1/2 text-2xl font-black text-neutral-400">USDC</span>
              <input
                className="w-full bg-transparent py-4 pl-20 pr-4 text-5xl font-black tracking-tighter text-neutral-900 outline-none"
                value={usdcAmount}
                onChange={(event) => setUsdcAmount(event.target.value)}
              />
            </div>
          </label>

          <div className="flex flex-wrap items-center justify-between gap-4 rounded-xl bg-neutral-100 p-4 border border-neutral-200">
            <div>
              <p className="text-xs font-bold uppercase tracking-widest text-neutral-500">Your Tier</p>
              <p className="text-lg font-black text-neutral-900">{tier}</p>
            </div>
            <div className="text-right">
              <p className="text-xs font-bold uppercase tracking-widest text-neutral-500">Required Collateral</p>
              <p className="text-lg font-black text-[#65A30D]">
                {requiredCollateralEth.toFixed(6)} ETH
              </p>
            </div>
          </div>
        </div>

        <div>
          <h2 className="text-sm font-extrabold uppercase tracking-widest text-neutral-500 mb-4 px-2">Step 2: Verify Identity</h2>
          <ZKProofGenerator onGenerated={setProof} />
        </div>

        <div className="pt-4">
          <button
            type="button"
            onClick={submitBorrow}
            disabled={isBorrowing || proof === "0x"}
            className="w-full rounded-full border-[3px] border-neutral-900 bg-neutral-900 px-6 py-5 text-xl font-black tracking-widest text-white uppercase shadow-[6px_6px_0px_#d4ff00] transition-all hover:-translate-y-[2px] disabled:opacity-50 disabled:hover:translate-y-0 disabled:shadow-none"
          >
            {isBorrowing ? "Submitting Tx..." : "Step 3: Confirm Borrow"}
          </button>
        </div>

        {txHash && (
          <div className="rounded-2xl border-2 border-neutral-900 bg-[#d4ff00] p-4 text-center shadow-[4px_4px_0px_#000]">
            <p className="text-sm font-bold uppercase tracking-widest text-neutral-900">Borrow Complete!</p>
            <a href={`https://sepolia.basescan.org/tx/${txHash}`} target="_blank" rel="noreferrer" className="mt-1 inline-block text-lg font-black underline decoration-2 underline-offset-4 hover:opacity-75">
              Tx: {txHash.slice(0, 10)}...
            </a>
          </div>
        )}

        {error && (
          <div className="rounded-2xl border-2 border-red-500 bg-red-50 p-4 text-center">
            <p className="text-sm font-bold text-red-600">{error}</p>
          </div>
        )}

        <div className="text-center pt-2">
          <Link href="/" className="inline-block text-sm font-bold uppercase tracking-widest text-neutral-500 hover:text-neutral-900 transition-colors">
            ← Back to Dashboard
          </Link>
        </div>
      </div>
    </main>
  );
}
