import type { CompiledCircuit, ProofData } from "@noir-lang/types";

export type ScoreThresholdProofInput = {
  circuit: CompiledCircuit;
  score: number;
  salt: bigint | number | string;
  borrower: `0x${string}`;
  threshold: number;
  commitment: bigint | number | string;
};

export type ScoreThresholdProof = {
  proof: `0x${string}`;
  publicInputs: string[];
  proofData: ProofData;
};

function toField(value: bigint | number | string): string {
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "number") return BigInt(value).toString();
  return value;
}

export function addressToField(address: `0x${string}`): string {
  return BigInt(address).toString();
}

function bytesToHex(bytes: Uint8Array): `0x${string}` {
  return `0x${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

export async function generateScoreThresholdProof({
  circuit,
  score,
  salt,
  borrower,
  threshold,
  commitment,
}: ScoreThresholdProofInput): Promise<ScoreThresholdProof> {
  const [{ Noir }, { BarretenbergBackend }] = await Promise.all([
    import("@noir-lang/noir_js"),
    import("@noir-lang/backend_barretenberg"),
  ]);

  const noir = new Noir(circuit);
  const backend = new BarretenbergBackend(circuit);

  await noir.init();

  try {
    const { witness } = await noir.execute({
      score,
      salt: toField(salt),
      borrower: addressToField(borrower),
      threshold,
      commitment: toField(commitment),
    });
    const proofData = await backend.generateProof(witness);

    return {
      proof: bytesToHex(proofData.proof),
      publicInputs: proofData.publicInputs,
      proofData,
    };
  } finally {
    await backend.destroy();
  }
}
