"use client";

import { ProtocolEvent } from "@/lib/hypersync";

type LoanPanelProps = {
  events: ProtocolEvent[];
  loanIdLabel: string;
  onRefresh?: () => void;
};

export default function LoanPanel({ events, loanIdLabel, onRefresh }: LoanPanelProps) {
  return (
    <div className="rounded-[2rem] border-[3px] border-neutral-900 bg-white p-6 shadow-[8px_8px_0px_#000]">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-4">
        <h3 className="text-2xl font-black tracking-tight text-neutral-900">Recent Global Events</h3>
        <button
          onClick={onRefresh}
          className="rounded-full border-2 border-neutral-900 bg-neutral-100 px-4 py-1 text-sm font-bold shadow-[2px_2px_0px_#000] hover:bg-neutral-200 hover:shadow-[1px_1px_0px_#000] hover:translate-y-[1px] transition-all"
          type="button"
        >
          Refresh Feed
        </button>
      </div>
      <div className="mb-6 flex items-center gap-2 text-sm font-bold uppercase tracking-widest text-neutral-500">
        <span className="h-2 w-2 animate-pulse rounded-full bg-[#d4ff00] border border-neutral-900"></span>
        Latest loan ID: {loanIdLabel}
      </div>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {events.length === 0 ? (
          <p className="text-sm font-medium text-neutral-500">No recent protocol events detected.</p>
        ) : (
          events.slice(0, 6).map((event, index) => (
            <div key={`${event.txHash}-${index}`} className="flex flex-col justify-between rounded-xl border-2 border-neutral-900 bg-[#FAFAFA] p-4 shadow-[4px_4px_0px_#E5E7EB]">
              <div>
                <p className="text-lg font-black text-neutral-900">{event.type}</p>
                <p className="text-sm font-bold text-neutral-500 uppercase tracking-wider">Loan #{event.loanId?.toString() ?? "-"}</p>
              </div>
              <p className="mt-4 truncate text-xs font-mono text-neutral-400">{event.txHash}</p>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
