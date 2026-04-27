# CreditLayer Documentation

This folder is the canonical documentation hub for the Mini-DeFi/CreditLayer project.

---

## Documentation Map

- `WHITEPAPER.md` — protocol whitepaper (motivation, mechanism design, risk, roadmap).
- `../README.md` — full repository guide with architecture and implementation deep dives.
- `../Project_Guide.md` — original build blueprint and hackathon specification.
- `../circuits/README.md` — Noir circuit workflow and verifier generation.
- `../frontend/README.md` — frontend setup and environment variables.
- `../contracts/.env.example` — contract deployment/seed environment reference.

---

## Quick Start (End-to-End)

1. **Contracts**
   - Go to `contracts/`
   - Install Foundry dependencies
   - Configure `.env` from `.env.example`
   - Run tests and deploy scripts

2. **Agent**
   - Go to `agent/`
   - Create Python environment
   - Install `requirements.txt`
   - Run FastAPI app (`main.py`)

3. **Frontend**
   - Go to `frontend/`
   - Create `.env.local`
   - Install dependencies and run Next.js app

4. **Circuits (optional for local demo)**
   - Go to `circuits/score_threshold/`
   - Compile circuit and generate verifier if needed

---

## System Modules

### 1) Smart Contracts (`contracts/`)

Core protocol state and enforcement:

- `CreditScoreNFT.sol` — soul-bound credit profile NFT storing score metadata.
- `CreditOracle.sol` — EIP-712 attestation verifier; bridge from off-chain AI score to on-chain state.
- `CreditLendingPool.sol` — tiered under-collateralized lending logic, repayment, liquidation, and health factor checks.
- `MockUSDC.sol` — development/test settlement token (6 decimals).

### 2) AI Scoring Agent (`agent/`)

Off-chain risk engine:

- `scorer/data_fetcher.py` — wallet behavioral data collection.
- `scorer/feature_engine.py` — transforms raw behavior into normalized features.
- `scorer/score_model.py` — weighted scoring logic + optional LLM-assisted anomaly/explainer path.
- `scorer/explainer.py` — explanation/report generation.
- `main.py` — FastAPI API surface (e.g., score endpoint).

### 3) ZK Circuit Layer (`circuits/`)

Privacy-preserving eligibility checks:

- Noir circuit proves `score >= threshold`.
- Borrower can prove eligibility without revealing raw score publicly.
- Verifier can be integrated on-chain via generated Solidity contract.

### 4) Frontend (`frontend/`)

User interface and protocol interaction:

- Wallet connection and borrower/lender workflows.
- Score exploration and loan health visualization.
- Optional proof generation helper integration (`lib/generateProof.ts`).

---

## Data & Trust Boundaries

- **On-chain truth:** loan positions, collateral, repayment status, score NFT state.
- **Off-chain computation:** score generation from wallet behavior.
- **Bridge trust point:** trusted signer used by `CreditOracle` for EIP-712 attestations.
- **Privacy layer:** ZK threshold proof can prove eligibility without publishing the score.

---

## Testing Surface

- **Contracts:** Foundry tests under `contracts/test/`
- **Agent:** Pytest suite under `agent/tests/`
- **Circuits:** Noir tests under `circuits/score_threshold/`
- **Frontend:** manual integration checks against deployed/local contracts and running agent

---

## Security & Risk Notes

- Score attestations rely on trusted signer integrity and short freshness windows.
- Current score model behavior and thresholds are policy parameters, not immutable economics.
- ZK verification may be disabled in some dev/test deployments (`zkVerifier == address(0)`).
- Liquidation and pricing safety depends on oracle availability/correctness.

For protocol-level rationale and risk analysis, read `WHITEPAPER.md`.
