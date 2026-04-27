"use client";

import Link from "next/link";

export default function LendPage() {
  return (
    <main className="mx-auto min-h-screen max-w-3xl px-6 py-12 md:py-20 font-sans">
      <h1 className="mb-10 text-4xl font-black tracking-tighter sm:text-5xl leading-tight text-neutral-900">
        Lend Liquidity
      </h1>

      <section className="space-y-8 rounded-[2.5rem] border-[3px] border-neutral-900 bg-[#FAFAFA] p-8 md:p-12 shadow-[12px_12px_0px_#000]">
        <div className="rounded-3xl border-2 border-neutral-900 bg-white p-8 text-center shadow-[4px_4px_0px_#000] relative overflow-hidden group">
          <div className="absolute inset-0 bg-[#d4ff00] translate-y-[100%] group-hover:translate-y-0 transition-transform duration-300 ease-out z-0"></div>
          <div className="relative z-10">
            <h2 className="text-2xl font-black tracking-tighter text-neutral-900 mb-2">
              Pool Liquidity Management
            </h2>
            <p className="text-neutral-600 font-medium mb-6">
              View yields, supply/withdraw USDC, and manage risk controls for your
              liquidity position.
            </p>
            <div className="inline-block rounded-full bg-neutral-900 text-[#d4ff00] px-6 py-3 font-bold uppercase tracking-widest text-sm shadow-[4px_4px_0px_rgba(0,0,0,0.2)]">
              Coming Soon
            </div>
          </div>
        </div>

        <div className="text-center pt-4">
          <Link
            href="/"
            className="inline-block text-sm font-bold uppercase tracking-widest text-neutral-500 hover:text-neutral-900 transition-colors"
          >
            ← Back to Dashboard
          </Link>
        </div>
      </section>
    </main>
  );
}
