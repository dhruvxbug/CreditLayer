import { createPublicClient, http, parseAbiItem } from "viem";
import { CONTRACTS, NETWORK } from "@/lib/contracts";

const publicClient = createPublicClient({
  chain: NETWORK,
  transport: http(process.env.NEXT_PUBLIC_BASE_RPC_URL),
});

export type ProtocolEvent = {
  type: "LoanOpened" | "LoanRepaid";
  txHash: string;
  blockNumber: bigint;
  borrower?: string;
  loanId?: bigint;
};

export async function fetchRecentProtocolEvents(fromBlock?: bigint): Promise<ProtocolEvent[]> {
  const latest = await publicClient.getBlockNumber();
  const start = fromBlock ?? (latest > 500n ? latest - 500n : 0n);

  const [opened, repaid] = await Promise.all([
    publicClient.getLogs({
      address: CONTRACTS.lendingPool,
      event: parseAbiItem("event LoanOpened(uint256 indexed loanId, address indexed borrower, uint256 principal, uint256 collateral, uint16 interestRateBps)"),
      fromBlock: start,
      toBlock: latest,
    }),
    publicClient.getLogs({
      address: CONTRACTS.lendingPool,
      event: parseAbiItem("event LoanRepaid(uint256 indexed loanId, address indexed borrower, uint256 principal, uint256 interestPaid)"),
      fromBlock: start,
      toBlock: latest,
    }),
  ]);

  const openedEvents: ProtocolEvent[] = opened.map((log) => ({
    type: "LoanOpened",
    txHash: log.transactionHash,
    blockNumber: log.blockNumber,
    loanId: log.args.loanId,
    borrower: log.args.borrower,
  }));

  const repaidEvents: ProtocolEvent[] = repaid.map((log) => ({
    type: "LoanRepaid",
    txHash: log.transactionHash,
    blockNumber: log.blockNumber,
    loanId: log.args.loanId,
    borrower: log.args.borrower,
  }));

  return [...openedEvents, ...repaidEvents].sort((a, b) => Number(b.blockNumber - a.blockNumber));
}
