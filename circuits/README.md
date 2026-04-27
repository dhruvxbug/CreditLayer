# CreditLayer ZK Circuits

This directory contains the Noir zero-knowledge circuits used by CreditLayer to prove credit score thresholds without revealing the underlying score on-chain.

---

## Directory Structure

```
circuits/
└── score_threshold/
    ├── Nargo.toml          # Package manifest
    ├── src/
    │   └── main.nr         # Circuit definition
    └── target/             # Compiled artifacts (generated)
        ├── score_threshold.json
        └── score_threshold.gz
```

---

## 1. Install Noir

Install the Noir toolchain (`nargo`) using `noirup`:

```bash
curl -L https://raw.githubusercontent.com/noir-lang/noirup/main/install | bash
noirup
```

This installs the latest compatible version. To pin to the exact version required by this project (≥ 0.31.0):

```bash
noirup --version 0.31.0
```

Verify the installation:

```bash
nargo --version
# nargo version = 0.31.0 ...
```

---

## 2. Compile the Circuit

Navigate to the circuit package directory and compile:

```bash
cd circuits/score_threshold
nargo compile
```

This produces `target/score_threshold.json` (the compiled ACIR artifact) and `target/score_threshold.gz`. The JSON artifact is imported by the frontend's proof-generation module (`frontend/lib/generateProof.ts`).

---

## 3. Run Tests

```bash
cd circuits/score_threshold
nargo test
```

Expected output:

```
[score_threshold] Running 2 test functions
[score_threshold] Testing test_valid_score_above_threshold... ok
[score_threshold] Testing test_score_below_threshold_fails... ok
[score_threshold] 2 tests passed, 0 tests failed
```

To run a specific test:

```bash
nargo test test_valid_score_above_threshold
```

---

## 4. Generate Solidity Verifier

Once the circuit is compiled, generate a Solidity verifier contract:

```bash
cd circuits/score_threshold
nargo codegen-verifier
```

This outputs `contract/plonk_vk.sol` inside the circuit directory. Copy this file into the Foundry contracts directory:

```bash
cp contract/plonk_vk.sol ../../contracts/src/ScoreThresholdVerifier.sol
```

Update the SPDX header and pragma as needed. Then deploy the verifier and pass its address to `CreditLendingPool` via `setZKVerifier(address)`.

---

## 5. Generate a Proof

### 5a. Using the CLI (for testing)

Create an input file `Prover.toml` in the circuit directory:

```toml
# circuits/score_threshold/Prover.toml
score     = "700"
salt      = "12345"
borrower  = "0x1234" # wallet address converted to a field
threshold = "600"

# commitment = Poseidon2([score, salt, borrower])
# You can compute this with `nargo execute` first to get the commitment value,
# then paste it here as the public input.
commitment = "0x..."   # fill in after running nargo execute
```

**Step 1 — Execute** (generates the witness and prints public outputs):

```bash
cd circuits/score_threshold
nargo execute witness
```

This writes `target/witness.gz` and prints the public outputs to stdout, including the computed `commitment` value. Copy that value back into `Prover.toml`.

**Step 2 — Prove**:

```bash
nargo prove
```

This writes `proofs/score_threshold.proof`.

**Step 3 — Verify locally**:

```bash
nargo verify
```

### 5b. From the Frontend (Browser WASM)

The frontend automatically generates proofs in-browser using `@noir-lang/noir_js` and `@noir-lang/backend_barretenberg`. See `frontend/lib/generateProof.ts` for the implementation. The user never sees the raw score — only the commitment and proof are submitted on-chain.

---

## 6. Circuit Overview

```noir
fn main(
    score:      u64,    // PRIVATE — the borrower's actual credit score
    salt:       Field,  // PRIVATE — random salt to bind the commitment
    borrower:   pub Field,  // PUBLIC — msg.sender/wallet encoded as a field
    threshold:  pub u64,    // PUBLIC  — minimum score required by the lender
    commitment: pub Field   // PUBLIC  — Poseidon2(score, salt, borrower) stored on-chain
)
```

| Input        | Visibility | Description |
|--------------|------------|-------------|
| `score`      | Private    | Raw credit score (0–1000) |
| `salt`       | Private    | Random 256-bit salt chosen by borrower |
| `borrower`   | Public     | Borrower wallet / `msg.sender` encoded as a field |
| `threshold`  | Public     | Tier minimum (e.g. 600 for Silver) |
| `commitment` | Public     | On-chain binding: `Poseidon2([score, salt, borrower])` |

The circuit asserts two things:

1. **Commitment integrity**: `Poseidon2([score as Field, salt, borrower]) == commitment`  
   This ties the private score to the public commitment stored in the borrower's CreditScoreNFT, preventing the borrower from proving a different score than the one attested by the oracle or replaying another wallet's proof.

2. **Threshold check**: `score >= threshold`  
   This proves the score qualifies for the requested loan tier without revealing the actual number.

---

## 7. Key Security Notes

### Commitment Scheme

- The `commitment` is computed as `Poseidon2([score as Field, salt, borrower], 3)` using the Poseidon2 sponge hash, which is ZK-friendly and collision-resistant.
- The `salt` **must** be at least 128 bits of entropy chosen by the borrower (preferably 256 bits). A weak or reused salt allows an attacker to brute-force the score from the public commitment, since the score space (0–1000) is small.
- The commitment should be stored in the borrower's on-chain CreditScoreNFT at the time the oracle attests the score, so the verifier contract can confirm the proof corresponds to that borrower's actual attested score.

### Proof Freshness

- A valid proof only demonstrates the score threshold at proof-generation time. If a borrower's score is later updated (e.g. drops below threshold), the old proof must not be reusable.
- Mitigations:
  - Include a `block.number` or `nonce` as an additional public input tied to the borrow transaction.
  - The smart contract should reject proofs with a stale commitment (i.e. commitment no longer matches the NFT's stored value).

### Trusted Setup

- The Barretenberg backend uses an **UltraPlonk** proving system with a universal trusted setup (the Aztec Ignition ceremony / Barretenberg SRS). No circuit-specific trusted setup is required.
- Verify you are using the official `@noir-lang/backend_barretenberg` package from the Noir monorepo — do not use unofficial builds.

### Oracle–ZK Integration

- The off-chain CreditOracle signs the score with EIP-712. The on-chain `CreditOracle.sol` verifies this signature and stores the score in the NFT.
- The ZK proof proves knowledge of a private score consistent with the stored commitment **and** above the threshold. The two together (oracle attestation + ZK proof) give strong guarantees: the score is real (oracle), and it qualifies (ZK).

### Testnet Deployment

- `CreditLendingPool` is deployed with `zkVerifier == address(0)` on Base Sepolia, which skips on-chain ZK proof verification. This allows end-to-end testing without deploying the Solidity verifier.
- Before mainnet deployment, set the verifier via `setZKVerifier(address)` with the address of the deployed `plonk_vk.sol` contract generated by `nargo codegen-verifier`.
