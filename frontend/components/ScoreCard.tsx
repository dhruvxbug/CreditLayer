"use client";

type ScoreCardProps = {
  score: number;
  tier: string;
  zkVerified?: boolean;
  lastUpdatedLabel?: string;
};

function tierBgColor(tier: string): string {
  if (tier === "Gold") return "bg-[#FFD700]";
  if (tier === "Silver") return "bg-[#E5E7EB]";
  if (tier === "Bronze") return "bg-[#CD7F32]";
  return "bg-neutral-100";
}

export default function ScoreCard({ score, tier, zkVerified = false, lastUpdatedLabel = "Just now" }: ScoreCardProps) {
  return (
    <div className="relative rounded-[2rem] border-[3px] border-neutral-900 bg-white p-6 shadow-[8px_8px_0px_#000] transition-colors">
      <div className="flex items-center justify-between">
        <p className="text-sm font-bold uppercase tracking-widest text-neutral-500">Credit Score</p>
        <span className={`rounded-full border-2 border-neutral-900 px-4 py-1 text-sm font-extrabold ${tierBgColor(tier)}`}>
          {tier}
        </span>
      </div>
      <div className="mt-4 flex items-baseline gap-2">
        <h3 className="text-6xl font-black tracking-tighter text-neutral-900">{score}</h3>
        <span className="text-xl font-bold text-neutral-400">/1000</span>
      </div>
      <div className="mt-8 h-4 w-full rounded-full border-2 border-neutral-900 bg-neutral-100 overflow-hidden">
        <div className="h-full bg-[#d4ff00] border-r-2 border-neutral-900" style={{ width: `${Math.min(100, Math.max(0, (score / 1000) * 100))}%` }} />
      </div>
      <div className="mt-6 flex items-center justify-between font-medium text-sm text-neutral-500">
        <span>Updated: {lastUpdatedLabel}</span>
        <span className="flex items-center gap-1">
          {zkVerified ? (
            <>
              <div className="h-2 w-2 rounded-full bg-emerald-500" />
              ZK Verified
            </>
          ) : (
            <>
              <div className="h-2 w-2 rounded-full bg-amber-500" />
              ZK Pending
            </>
          )}
        </span>
      </div>
    </div>
  );
}
