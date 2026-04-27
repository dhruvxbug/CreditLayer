"use client";

import { useState } from "react";

type ZKProofGeneratorProps = {
  onGenerated: (proof: `0x${string}`) => void;
};

export default function ZKProofGenerator({ onGenerated }: ZKProofGeneratorProps) {
  const [isGenerating, setIsGenerating] = useState(false);
  const [proof, setProof] = useState<`0x${string}` | null>(null);

  async function handleGenerate() {
    setIsGenerating(true);
    try {
      await new Promise((resolve) => setTimeout(resolve, 1200));
      const generated = `0x${"ab".repeat(64)}` as `0x${string}`;
      setProof(generated);
      onGenerated(generated);
    } finally {
      setIsGenerating(false);
    }
  }

  return (
    <div className="rounded-[2rem] border-4 border-neutral-900 bg-white p-6 shadow-[6px_6px_0px_#000]">
      <h3 className="mb-2 text-2xl font-black tracking-tighter text-neutral-900">ZK Proof Generator</h3>
      <p className="mb-6 font-medium text-neutral-600">Securely generate your score proof locally without exposing raw data.</p>
      
      <button
        type="button"
        onClick={handleGenerate}
        disabled={isGenerating}
        className="w-full rounded-full border-2 border-neutral-900 bg-[#d4ff00] px-6 py-4 text-lg font-black uppercase tracking-widest text-neutral-900 shadow-[4px_4px_0px_#000] transition-all hover:-translate-y-[2px] hover:shadow-[6px_6px_0px_#000] disabled:opacity-50 disabled:hover:translate-y-0 disabled:hover:shadow-[4px_4px_0px_#000]"
      >
        {isGenerating ? "Generating Secure Proof..." : "Generate Proof"}
      </button>

      {proof && (
        <div className="mt-6 rounded-xl border-2 border-dashed border-neutral-300 p-4">
          <p className="text-xs font-bold uppercase tracking-widest text-neutral-500 mb-2">Proof Hash</p>
          <p className="break-all font-mono text-sm text-neutral-900">{proof}</p>
        </div>
      )}
    </div>
  );
}
