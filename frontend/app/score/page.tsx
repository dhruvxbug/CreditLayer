"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { Radar, RadarChart, PolarGrid, PolarAngleAxis, ResponsiveContainer } from "recharts";
import ScoreCard from "@/components/ScoreCard";
import { useCreditScore } from "@/hooks/useCreditScore";

export default function ScoreExplorerPage() {
  const [addressInput, setAddressInput] = useState("");
  const isAddress = /^0x[a-fA-F0-9]{40}$/.test(addressInput);
  const credit = useCreditScore(isAddress ? (addressInput as `0x${string}`) : undefined);

  const radarData = useMemo(
    () =>
      Object.entries(credit.features).map(([name, value]) => ({
        feature: name,
        value: Number(value),
      })),
    [credit.features]
  );

  return (
    <main className="mx-auto min-h-screen max-w-5xl px-6 py-12 md:py-20 font-sans">
      <h1 className="mb-10 text-4xl font-black tracking-tighter sm:text-5xl leading-tight text-neutral-900">Score Explorer</h1>

      <div className="mb-8 rounded-3xl border-[3px] border-neutral-900 bg-white p-6 shadow-[8px_8px_0px_#000]">
        <label className="block">
          <span className="text-sm font-extrabold uppercase tracking-widest text-neutral-500 mb-2 block">Lookup Address</span>
          <div className="relative border-b-4 border-neutral-900 focus-within:border-[#d4ff00] transition-colors">
            <input
              className="w-full bg-transparent py-3 text-2xl font-black tracking-tighter text-neutral-900 outline-none placeholder:text-neutral-300"
              placeholder="0x..."
              value={addressInput}
              onChange={(event) => setAddressInput(event.target.value.trim())}
            />
          </div>
        </label>
      </div>

      <div className="grid gap-8 md:grid-cols-2 mb-8">
        <ScoreCard score={credit.score} tier={credit.tier} zkVerified={credit.zkVerified} />
        
        <div className="rounded-[2rem] border-[3px] border-neutral-900 bg-[#FAFAFA] p-6 shadow-[8px_8px_0px_#000] flex flex-col">
          <h2 className="mb-4 text-sm font-extrabold uppercase tracking-widest text-neutral-500">Feature Radar</h2>
          <div className="h-72 flex-grow bg-white rounded-2xl border-2 border-neutral-900 shadow-[4px_4px_0px_#000] p-4">
            <ResponsiveContainer width="100%" height="100%">
              <RadarChart data={radarData}>
                <PolarGrid stroke="#e5e5e5" />
                <PolarAngleAxis dataKey="feature" tick={{ fill: "#525252", fontSize: 11, fontWeight: "bold" }} />
                <Radar dataKey="value" stroke="#171717" strokeWidth={3} fill="#d4ff00" fillOpacity={0.8} />
              </RadarChart>
            </ResponsiveContainer>
          </div>
        </div>
      </div>

      <div className="mb-12 rounded-[2rem] border-[3px] border-neutral-900 bg-neutral-900 p-8 shadow-[8px_8px_0px_#d4ff00] text-white">
        <h2 className="mb-4 text-sm font-extrabold uppercase tracking-widest text-[#d4ff00]">Agent Report</h2>
        <p className="text-lg font-medium leading-relaxed font-sans">{credit.report}</p>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-4">
        <Link 
          href="/" 
          className="inline-block text-sm font-bold uppercase tracking-widest text-neutral-500 hover:text-neutral-900 transition-colors"
        >
          ← Back to Dashboard
        </Link>
        <button
          className="rounded-full border-[3px] border-neutral-900 bg-[#d4ff00] px-8 py-4 font-black uppercase tracking-widest text-neutral-900 shadow-[4px_4px_0px_#000] transition-all hover:-translate-y-[2px] active:translate-y-[2px] active:shadow-none"
          type="button"
          onClick={() => void credit.refresh()}
        >
          Update My Score
        </button>
      </div>
    </main>
  );
}
