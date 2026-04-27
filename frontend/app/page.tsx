"use client";

import Link from "next/link";
import ScoreCard from "@/components/ScoreCard";
import HealthBar from "@/components/HealthBar";
import LoanPanel from "@/components/LoanPanel";
import { useCreditScore } from "@/hooks/useCreditScore";
import { useLoanPool } from "@/hooks/useLoanPool";

export default function DashboardPage() {
  const credit = useCreditScore();
  const pool = useLoanPool();

  return (
    <main className="mx-auto min-h-screen max-w-6xl px-6 py-12 md:py-20 font-sans">
      <div className="mb-16 max-w-3xl">
        <h1 className="text-5xl font-black tracking-tighter sm:text-7xl leading-[1.05]">
          Under-collateralised <br />
          loans powered by <br />
          <span className="relative inline-block mt-2">
            <span className="absolute -inset-2 block -skew-y-2 bg-[#d4ff00] rounded-xl"></span>
            <span className="relative text-neutral-900">verifiable AI history.</span>
          </span>
        </h1>
        <p className="mt-8 max-w-xl text-lg font-medium leading-relaxed text-neutral-600 sm:text-xl">
          Instantly convert your on-chain reputation into borrowing power.
          Experience the hold-or-spend freedom without selling your crypto.
        </p>
      </div>

      <section className="grid gap-6 md:grid-cols-2">
        <ScoreCard score={credit.score} tier={credit.tier} zkVerified={credit.zkVerified} />
        <HealthBar healthFactor={pool.healthFactor} />
      </section>

      <section className="mt-8 flex flex-wrap items-center gap-4">
        <Link className="rounded-full border-2 border-neutral-900 bg-[#d4ff00] px-8 py-3 text-lg font-bold text-neutral-900 shadow-[4px_4px_0px_#000] hover:shadow-[2px_2px_0px_#000] hover:translate-y-[2px] transition-all" href="/score">
          My Score Profile
        </Link>
        <Link className="rounded-full border-2 border-neutral-900 bg-white px-8 py-3 text-lg font-bold text-neutral-900 shadow-[4px_4px_0px_#000] hover:shadow-[2px_2px_0px_#000] hover:translate-y-[2px] transition-all" href="/borrow">
          Borrow Now
        </Link>
      </section>

      <section className="mt-16">
        <LoanPanel events={pool.events} loanIdLabel={pool.loanIdLabel} onRefresh={() => void pool.refreshEvents()} />
      </section>
    </main>
  );
}
