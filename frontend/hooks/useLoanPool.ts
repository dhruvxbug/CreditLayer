"use client";

import useSWR from "swr";
import { formatEther, parseUnits } from "viem";
import { useAccount, useReadContract, useWriteContract } from "wagmi";
import { CONTRACTS, lendingPoolAbi } from "@/lib/contracts";
import { fetchRecentProtocolEvents } from "@/lib/hypersync";

export function useLoanPool() {
  const { address } = useAccount();
  const { writeContractAsync, isPending } = useWriteContract();

  const nextLoanId = useReadContract({
    abi: lendingPoolAbi,
    address: CONTRACTS.lendingPool,
    functionName: "nextLoanId",
    query: { refetchInterval: 20_000 },
  });

  const loanId = nextLoanId.data && nextLoanId.data > 1n ? nextLoanId.data - 1n : 0n;

  const healthFactorRead = useReadContract({
    abi: lendingPoolAbi,
    address: CONTRACTS.lendingPool,
    functionName: "getHealthFactor",
    args: [loanId],
    query: { enabled: loanId > 0n, refetchInterval: 15_000 },
  });

  const { data: events, isLoading: eventsLoading, mutate: refreshEvents } = useSWR(
    "protocol-events",
    () => fetchRecentProtocolEvents(),
    { refreshInterval: 15_000 }
  );

  async function borrow(usdcAmount: string, collateralEth: string, proofHex: `0x${string}`, scoreThreshold: number) {
    if (!address) {
      throw new Error("Connect wallet before borrowing");
    }

    const usdcAmountRaw = parseUnits(usdcAmount, 6);
    const collateralWei = parseUnits(collateralEth, 18);

    return writeContractAsync({
      abi: lendingPoolAbi,
      address: CONTRACTS.lendingPool,
      functionName: "borrow",
      args: [usdcAmountRaw, proofHex, BigInt(scoreThreshold)],
      value: collateralWei,
    });
  }

  const healthFactor = healthFactorRead.data ? Number(healthFactorRead.data) / 1e18 : 0;

  return {
    latestLoanId: loanId,
    healthFactor,
    healthFactorDisplay: healthFactor ? healthFactor.toFixed(2) : "--",
    events: events ?? [],
    eventsLoading,
    refreshEvents,
    borrow,
    isBorrowing: isPending,
    hasActiveLoan: loanId > 0n,
    loanIdLabel: loanId > 0n ? loanId.toString() : "None",
    latestLoanEthCollateral: loanId > 0n ? formatEther(0n) : "0",
  };
}
