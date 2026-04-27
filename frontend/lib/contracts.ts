import { Address } from "viem";
import { baseSepolia } from "viem/chains";

export const CONTRACTS = {
  creditScoreNFT: (process.env.NEXT_PUBLIC_CREDIT_SCORE_NFT_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address,
  lendingPool: (process.env.NEXT_PUBLIC_LENDING_POOL_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address,
  creditOracle: (process.env.NEXT_PUBLIC_CREDIT_ORACLE_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address,
  usdc: (process.env.NEXT_PUBLIC_USDC_ADDRESS ?? "0x0000000000000000000000000000000000000000") as Address,
};

export const NETWORK = baseSepolia;

export const creditScoreNftAbi = [
  {
    type: "function",
    name: "getScore",
    stateMutability: "view",
    inputs: [{ name: "wallet", type: "address" }],
    outputs: [
      { name: "score", type: "uint16" },
      { name: "tier", type: "uint8" },
      { name: "zkVerified", type: "bool" },
    ],
  },
] as const;

export const lendingPoolAbi = [
  {
    type: "function",
    name: "borrow",
    stateMutability: "payable",
    inputs: [
      { name: "usdcAmount", type: "uint256" },
      { name: "zkProof", type: "bytes" },
      { name: "scoreThreshold", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "getHealthFactor",
    stateMutability: "view",
    inputs: [{ name: "loanId", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "nextLoanId",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "event",
    name: "LoanOpened",
    anonymous: false,
    inputs: [
      { indexed: true, name: "loanId", type: "uint256" },
      { indexed: true, name: "borrower", type: "address" },
      { indexed: false, name: "principal", type: "uint256" },
      { indexed: false, name: "collateral", type: "uint256" },
      { indexed: false, name: "interestRateBps", type: "uint16" },
    ],
  },
  {
    type: "event",
    name: "LoanRepaid",
    anonymous: false,
    inputs: [
      { indexed: true, name: "loanId", type: "uint256" },
      { indexed: true, name: "borrower", type: "address" },
      { indexed: false, name: "principal", type: "uint256" },
      { indexed: false, name: "interestPaid", type: "uint256" },
    ],
  },
] as const;

export function tierLabel(tier: number): string {
  if (tier === 3) return "Gold";
  if (tier === 2) return "Silver";
  if (tier === 1) return "Bronze";
  return "Unverified";
}
