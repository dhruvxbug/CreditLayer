"use client";

type HealthBarProps = {
  healthFactor: number;
};

export default function HealthBar({ healthFactor }: HealthBarProps) {
  const value = Number.isFinite(healthFactor) ? healthFactor : 0;
  const normalized = Math.min(2, Math.max(0, value));
  const pct = (normalized / 2) * 100;
  const status = value < 1 ? "At risk" : value < 1.3 ? "Watch" : "Healthy";
  const color = value < 1 ? "bg-red-500" : value < 1.3 ? "bg-amber-400" : "bg-[#d4ff00]";

  return (
    <div className="rounded-[2rem] border-4 border-neutral-900 bg-white p-6 shadow-[6px_6px_0px_#000] flex flex-col justify-between">
      <div>
        <div className="mb-4 flex items-start justify-between">
          <span className="text-sm font-extrabold uppercase tracking-widest text-neutral-500">Loan Health</span>
          <span className="rounded-full border-2 border-neutral-900 px-3 py-1 font-black text-neutral-900">{value ? value.toFixed(2) : "--"}</span>
        </div>
      </div>
      <div>
        <div className="h-6 w-full rounded-full border-2 border-neutral-900 bg-neutral-100 overflow-hidden relative">
          <div className={`h-full border-r-2 border-neutral-900 transition-all duration-500 ${color}`} style={{ width: `${pct}%` }} />
        </div>
        <p className="mt-4 text-sm font-bold text-neutral-600 uppercase tracking-widest">
          Status: <span className="text-neutral-900">{status}</span>
        </p>
      </div>
    </div>
  );
}
