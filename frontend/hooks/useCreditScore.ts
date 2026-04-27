"use client";

import useSWR from "swr";
import { useAccount, useReadContract } from "wagmi";
import { CONTRACTS, creditScoreNftAbi, tierLabel } from "@/lib/contracts";

type AgentScoreResponse = {
  score: number;
  tier: string;
  features: Record<string, number>;
  report: string;
  cached: boolean;
  error?: string | null;
};

const fetcher = async (url: string) => {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return (await response.json()) as AgentScoreResponse;
};

export function useCreditScore(addressOverride?: `0x${string}`) {
  const { address } = useAccount();
  const targetAddress = addressOverride ?? address;

  const onChain = useReadContract({
    abi: creditScoreNftAbi,
    address: CONTRACTS.creditScoreNFT,
    functionName: "getScore",
    args: targetAddress ? [targetAddress] : undefined,
    query: {
      enabled: Boolean(targetAddress),
      refetchInterval: 30_000,
    },
  });

  const agentBaseUrl = process.env.NEXT_PUBLIC_AGENT_URL;
  const { data: agentData, isLoading: agentLoading, error: agentError, mutate } = useSWR(
    targetAddress && agentBaseUrl ? `${agentBaseUrl}/score/${targetAddress}` : null,
    fetcher,
    { refreshInterval: 60_000 }
  );

  const score = onChain.data?.[0] ? Number(onChain.data[0]) : agentData?.score ?? 0;
  const tier = onChain.data?.[1] !== undefined ? tierLabel(Number(onChain.data[1])) : agentData?.tier ?? "Unverified";
  const zkVerified = onChain.data?.[2] ?? false;

  return {
    score,
    tier,
    zkVerified,
    report: agentData?.report ?? "No credit report available yet.",
    features: agentData?.features ?? {},
    isLoading: onChain.isLoading || agentLoading,
    error: onChain.error ?? agentError,
    refresh: mutate,
  };
}
