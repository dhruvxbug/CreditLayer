# CreditLayer (Mini-DeFi)

AI + ZK powered under-collateralized lending on EVM chains.

This repository contains a full-stack hackathon project that combines:

- on-chain **credit identity** via a soul-bound NFT,
- off-chain **AI scoring** via a Python/LangGraph agent,
- optional **zero-knowledge threshold proofs** via Noir,
- and a **Next.js dApp** for borrower/lender flows.

---

## Table of Contents

1. [Documentation](#documentation)
2. [Project Vision](#project-vision)
3. [What Exists Today](#what-exists-today)
4. [System Architecture](#system-architecture)
5. [Repository Structure](#repository-structure)
6. [Deep Dive: Smart Contracts (`contracts/`)](#deep-dive-smart-contracts-contracts)
7. [Deep Dive: AI Scoring Agent (`agent/`)](#deep-dive-ai-scoring-agent-agent)
8. [Deep Dive: ZK Circuits (`circuits/`)](#deep-dive-zk-circuits-circuits)
9. [Deep Dive: Frontend (`frontend/`)](#deep-dive-frontend-frontend)
10. [End-to-End User Flows](#end-to-end-user-flows)
11. [Configuration & Environment Variables](#configuration--environment-variables)
12. [Local Development Guide](#local-development-guide)
13. [Testing Guide](#testing-guide)
14. [Deployment Notes](#deployment-notes)
15. [Current Limitations / Known Gaps](#current-limitations--known-gaps)
16. [Roadmap Suggestions](#roadmap-suggestions)

---

## Documentation

- Full documentation hub: [`docs/README.md`](docs/README.md)
- Whitepaper: [`docs/WHITEPAPER.md`](docs/WHITEPAPER.md)
- Original architecture/build blueprint: [`Project_Guide.md`](Project_Guide.md)

---

## Project Vision

Traditional DeFi lending protocols are capital-inefficient for many users because borrowing often requires high over-collateralization.

**CreditLayer** aims to reduce that barrier by introducing a verifiable credit layer:

- borrowers receive a **Credit Score NFT** that represents their credit profile,
- an off-chain **AI scoring agent** computes score + explanation from protocol behavior,
- borrowers can prove threshold eligibility with **ZK proofs** without leaking private raw score details,
- the lending pool enforces tier-based collateral and pricing logic.

In short: convert on-chain behavior into borrowing power, with privacy-preserving proofs.

---

## What Exists Today

This repository already includes substantial, runnable implementation:

- **Foundry smart contracts** for NFT, oracle bridge, lending pool, mock USDC, deployment/seeding scripts, and tests.
- **Python FastAPI scoring service** with LangGraph pipeline, feature engineering, Graph subgraph ingestion, caching, and report generation.
- **Noir circuit package** for score-threshold proving (`score >= threshold`) and verifier generation docs.
- **Next.js 14 frontend** with wallet connection, dashboard, score explorer, borrow wizard, and protocol event feed.

Design-wise, frontend pages are styled in a clean, minimal, high-contrast light theme.

---

## System Architecture

```text
User Wallet
   │
   ▼
Frontend (Next.js + wagmi + RainbowKit)
   │                           │
   │ read/write                │ HTTP /score
   ▼                           ▼
Contracts (Base Sepolia)   AI Agent (FastAPI + LangGraph)
   │                           │
   │ NFT score state           │ Subgraph / RPC fetches
   │ lending state             ▼
   │                     Feature vector + score + report
   │
   └── Optional ZK proof verification via Noir verifier
```

### Core Components and Responsibilities

1. **`CreditScoreNFT`**
   - Soul-bound ERC-721 (non-transferable).
   - Stores per-wallet score metadata and zk-verification flag.
   - Derives tier from score.

2. **`CreditOracle`**
   - Validates EIP-712 signed score attestations.
   - Mints/updates score NFTs.
   - Enforces short attestation freshness window.

3. **`CreditLendingPool`**
   - Accepts ETH collateral and lends mUSDC.
   - Applies tier-based collateral ratios + APR.
   - Computes health factor and supports liquidation.
   - Optionally verifies ZK proof if verifier configured.

4. **AI Scoring Agent**
   - Aggregates wallet behavior from Aave/Compound/Uniswap signals.
   - Computes 12 normalized features.
   - Produces numeric score + tier + human-readable explanation.
   - Caches results in Redis.

5. **Noir Circuit**
   - Proves `score >= threshold` while binding to a commitment.
   - Intended to preserve privacy when proving loan eligibility.

6. **Frontend**
   - Wallet connect + credit profile display.
   - Borrow wizard with proof-generation step and transaction submit.
   - Score explorer with feature radar and report display.

---

## Repository Structure

```text
Mini-DeFi/
├── Project_Guide.md            # Original architecture/build plan
├── agent/                      # FastAPI + LangGraph scoring service
├── circuits/                   # Noir circuit(s)
├── contracts/                  # Foundry contracts + scripts + tests
└── frontend/                   # Next.js dApp
```

---

## Deep Dive: Smart Contracts (`contracts/`)

### Tooling & Config

- Solidity: `^0.8.24`
- Framework: Foundry (`forge`, `cast`, `anvil`)
- Config: `contracts/foundry.toml`
  - optimizer enabled
  - fuzz runs: 256
  - Base Sepolia RPC alias included

### `MockUSDC.sol`

- ERC-20 with **6 decimals** (USDC-like).
- Constructor mints `10,000,000` mUSDC to deployer.
- Public `mint()` intentionally permissionless for test/dev networks.

### `CreditScoreNFT.sol`

#### Purpose

- Permanent, non-transferable credit identity token.

#### Behavior

- One token per wallet via `walletToTokenId`.
- Transfer methods (`transferFrom`, `safeTransferFrom`) revert with `SoulBoundToken()`.
- `mintScore(address)` callable only by authorized oracle address.
- `updateScore(tokenId, newScore, zkVerified)`:
  - only oracle,
  - enforces `24 hours` cooldown per profile,
  - emits score update event.
- Tier derivation:
  - `>= 800` Gold,
  - `>= 600` Silver,
  - `>= 300` Bronze,
  - else Unverified.

#### Metadata

- `tokenURI()` is fully on-chain:
  - base64-encoded JSON + SVG,
  - displays score, tier, progress bar, zk badge.

### `CreditOracle.sol`

#### Purpose

- Bridge between off-chain AI score attestation and on-chain NFT state.

#### Signature Model

- Uses EIP-712 domain: name `CreditLayer`, version `1`.
- Struct: `ScoreAttestation(address borrower, uint16 score, uint64 timestamp, bool zkVerified)`.
- `submitScore(...)` verifies:
  - timestamp freshness (`ATTESTATION_WINDOW = 5 minutes`),
  - signature format,
  - recovered signer equals `trustedSigner`.

#### Side Effects

- Mints score NFT if missing.
- Updates score profile through `CreditScoreNFT`.

### `CreditLendingPool.sol`

#### Purpose

- ETH-collateralized borrowing of mUSDC with credit-tier gating.

#### Tier Policy (as implemented)

- Bronze: min score 300, min collateral 135%, APR 12%
- Silver: min score 600, min collateral 125%, APR 9%
- Gold: min score 800, min collateral 115%, APR 6%

#### Borrow Flow

`borrow(usdcAmount, zkProof, scoreThreshold)`:

1. Reads borrower score/tier from NFT.
2. Rejects unverified tier (tier 0).
3. Calculates required ETH collateral from Chainlink ETH/USD feed.
4. Optionally verifies proof if `zkVerifier != address(0)`.
5. Stores `LoanPosition` and transfers mUSDC to borrower.

> Note: current implementation ignores `scoreThreshold` input in borrow logic (it is accepted but not used).

#### Repay Flow

- `repay(loanId)` by borrower:
  - computes simple interest,
  - pulls USDC debt,
  - returns collateral ETH,
  - sets status to `Repaid`.

#### Liquidation Flow

- `liquidate(loanId)` by anyone when `healthFactor < 1e18`.
- Liquidator covers debt and receives collateral (plus bonus logic).
- Emits liquidation event and closes loan.

#### Risk Math

- Interest: simple linear accrual by elapsed seconds.
- Health factor:

$$
HF = \frac{\text{collateral USD value} \cdot 10^{18}}{\text{principal} + \text{accrued interest}}
$$

- Liquidatable when $HF < 1$ (scaled as `1e18`).

### Deployment Scripts

- `script/Deploy.s.sol`
  - Deploys `MockUSDC`, `CreditScoreNFT`, `CreditOracle`, `CreditLendingPool`.
  - Wires NFT oracle to oracle contract.
  - Seeds pool with initial mUSDC liquidity.

- `script/Seed.s.sol`
  - Mints test balances to wallets + pool.
  - Seeds score data either:
    - admin bypass mode (`USE_ADMIN_SEED=true`) for local testing, or
    - signature mode via oracle for testnet.

### Foundry Tests

1. `CreditScoreNFT.t.sol`
   - Soul-bound transfer reverts,
   - cooldown enforcement,
   - tier boundaries,
   - oracle-only mint/update,
   - broad scenario and fuzz-style checks.

2. `CreditLendingPool.t.sol`
   - borrow/repay path,
   - collateral-too-low revert,
   - insufficient-score gating,
   - liquidation behavior,
   - health-factor edge conditions,
   - interest accrual for 1/7/30 day windows,
   - fuzz-style borrow amount coverage.

3. `CreditOracle.t.sol`
   - EIP-712 attestation validation,
   - signer rotation,
   - timestamp freshness,
   - malformed signature rejection,
   - NFT retargeting checks.

---

## Deep Dive: AI Scoring Agent (`agent/`)

### Stack

- Python 3.11
- FastAPI
- LangGraph
- Anthropic SDK (Claude Sonnet)
- Redis (optional caching)
- httpx + web3

### API Surface

- `GET /health`
- `POST /score` with `{ "address": "0x..." }`
- `GET /score/{address}`

Response shape:

```json
{
  "score": 742,
  "tier": "Silver",
  "features": { "repayment_rate": 0.92 },
  "report": "...",
  "cached": false,
  "error": null
}
```

### Scoring Pipeline (`scorer/score_model.py`)

LangGraph linear pipeline:

1. `fetch_data`
2. `engineer_features`
3. `base_score`
4. `anomaly_check`
5. `final_score`
6. `report`

#### Data Ingestion (`data_fetcher.py`)

- Pulls GraphQL data from subgraphs:
  - Aave V3 (Base)
  - Compound V3 (Base)
  - Uniswap V3 (Base)
- Estimates wallet age using RPC binary-search heuristic.
- Produces `WalletOnChainData` dataclass with protocol metrics.

#### Feature Engineering (`feature_engine.py`)

Computes 12 normalized features:

1. repayment rate
2. volume reliability
3. protocol diversity
4. wallet age score
5. LP consistency
6. liquidation penalty (can be negative)
7. current health factor
8. activity recency
9. cross protocol trust
10. collateral consistency
11. DeFi tenure
12. Compound repayment rate

#### Base Score

- Weighted sum of features with predefined weights in `FEATURE_WEIGHTS`.
- Scaled to `0–1000` with clamping in final stage.

#### Anomaly Check

- If Anthropic key exists, asks Claude to output exactly:
  - `CLEAN`, or
  - `PENALTY::<50..300>`
- Penalty subtracted from base score.

#### Report Generation

- Uses Claude for 3-sentence plain-English explanation.
- Deterministic fallback report when AI is unavailable.

### Caching

- Redis cache key: `score:<address>`
- TTL: 1 hour
- If Redis unavailable, scoring still works without cache.

### Guardrails / Defaults

- Invalid address returns structured error payload.
- Zero-history wallets are normalized to low-trust response.
- Pipeline exceptions return deterministic fallback score/report.

### Agent Tests

`agent/tests/test_agent.py` validates:

- blank-wallet features,
- deterministic no-history score behavior,
- API zero-history response shaping,
- invalid-address response contract.

---

## Deep Dive: ZK Circuits (`circuits/`)

### Package

- Noir package: `circuits/score_threshold`
- Main circuit: `src/main.nr`
- Artifact example: `target/score_threshold.json`

### Purpose

Prove that:

- a private score belongs to borrower commitment,
- and `score >= threshold`,
- without revealing the score itself.

### Tooling Flow

- Compile: `nargo compile`
- Test: `nargo test`
- Solidity verifier generation: `nargo codegen-verifier`

The circuit README already documents proof generation and verifier export in detail.

---

## Deep Dive: Frontend (`frontend/`)

### Stack

- Next.js 14 App Router
- React 18 + TypeScript
- wagmi + viem + RainbowKit
- SWR + React Query
- Tailwind CSS
- Recharts

### App Routes

1. `/` (`app/page.tsx`) — dashboard
   - wallet connect
   - score card
   - loan health bar
   - protocol event panel
   - navigation to score/borrow

2. `/borrow` (`app/borrow/page.tsx`) — borrow wizard
   - amount input + collateral estimate
   - proof-generation step
   - borrow transaction submit
   - tx success/error feedback

3. `/score` (`app/score/page.tsx`) — score explorer
   - address lookup
   - score + tier card
   - feature radar chart
   - agent narrative report

4. `/lend` (`app/lend/page.tsx`) — lender page placeholder
   - currently UI scaffold and “coming soon” state

### Hooks

- `useCreditScore`
  - reads on-chain score via `getScore`,
  - fetches agent report/features from `NEXT_PUBLIC_AGENT_URL`,
  - merges data for UI.

- `useLoanPool`
  - writes borrow transaction,
  - reads latest health factor,
  - fetches recent loan events via viem log polling.

### Libs

- `lib/contracts.ts`
  - address registry from env vars,
  - minimal ABI fragments,
  - tier label utility.

- `lib/hypersync.ts`
  - recent on-chain event fetcher using `getLogs`.

- `lib/generateProof.ts`
  - Noir + Barretenberg browser proof utilities.

### UI Design Language

- minimalist, high-contrast light background,
- thick outlines + offset shadow style,
- prominent typography,
- lime accent (`#d4ff00`) for active highlights.

---

## End-to-End User Flows

### 1) Score Discovery

1. User opens frontend and connects wallet.
2. Frontend reads on-chain score from NFT.
3. Frontend requests `/score/{address}` from agent.
4. UI renders score/tier/features/report.

### 2) Borrowing

1. User enters desired USDC amount.
2. UI estimates collateral from tier assumptions.
3. User generates proof (currently UI mock value in `ZKProofGenerator`).
4. Frontend calls `CreditLendingPool.borrow(...)` with ETH collateral.
5. Pool validates score/tier + collateral + optional verifier.
6. Pool opens loan and transfers mUSDC.

### 3) Repayment / Liquidation

- Repayment: borrower approves USDC and calls `repay(loanId)`.
- Liquidation: any actor can liquidate unhealthy positions ($HF < 1$).

---

## Configuration & Environment Variables

### Contracts / Foundry

Used by scripts:

- `TRUSTED_SIGNER`
- `CHAINLINK_ETH_USD`
- `ZK_VERIFIER`
- `BASESCAN_API_KEY` (for verification workflows)

For seed script (additional):

- `MOCK_USDC`
- `CREDIT_SCORE_NFT`
- `CREDIT_ORACLE`
- `LENDING_POOL`
- `TEST_WALLET_A`
- `TEST_WALLET_B`
- optional signature vars (`WALLET_A_SIG`, `WALLET_A_TS`, etc.)

### Agent (`agent/.env`)

- `ANTHROPIC_API_KEY`
- `REDIS_URL`
- `RPC_URL`

### Frontend (`frontend/.env.local`)

- `NEXT_PUBLIC_BASE_RPC_URL`
- `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`
- `NEXT_PUBLIC_CREDIT_SCORE_NFT_ADDRESS`
- `NEXT_PUBLIC_LENDING_POOL_ADDRESS`
- `NEXT_PUBLIC_CREDIT_ORACLE_ADDRESS`
- `NEXT_PUBLIC_USDC_ADDRESS`
- `NEXT_PUBLIC_AGENT_URL`

---

## Local Development Guide

### Prerequisites

- Node.js 18+
- Python 3.11+
- Foundry
- (optional) Noir toolchain (`nargo`)
- Redis (optional but recommended for agent caching)

### 1) Contracts

```bash
cd contracts
forge build
forge test -vv
```

### 2) Agent

```bash
cd agent
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

### 3) Frontend

```bash
cd frontend
npm install
npm run dev
```

Then open `http://localhost:3000` (or your assigned local port).

### 4) Noir Circuit (optional local proof work)

```bash
cd circuits/score_threshold
nargo compile
nargo test
```

---

## Testing Guide

### Contracts

```bash
cd contracts
forge test -vv
forge coverage
```

### Agent

```bash
cd agent
pytest -q
```

### Frontend

```bash
cd frontend
npm run lint
npm run build
```

---

## Deployment Notes

### Contracts (Base Sepolia)

Use `script/Deploy.s.sol` with proper env setup and RPC endpoint.

### Frontend

- Recommended: Vercel deployment.
- Ensure all `NEXT_PUBLIC_*` values point to deployed contracts/agent.

### Agent

- Container-ready via `agent/Dockerfile`.
- Suitable for Railway/Fly/Render/Kubernetes style runtimes.

---

## Current Limitations / Known Gaps

1. **Proof generation in UI is currently mocked in component flow**
   - `ZKProofGenerator.tsx` currently emits a placeholder hex proof for UX demo.
   - `lib/generateProof.ts` contains real Noir proof plumbing but is not yet fully integrated into borrow transaction path.

2. **`borrow(..., scoreThreshold)` argument is not used in pool logic**
   - function accepts the value but currently relies on score/tier lookup + optional verifier.

3. **Lender page is scaffold-only**
   - `/lend` is designed and routed but core supply/withdraw functionality is pending.

4. **Data ingestion is subgraph-first**
   - robust for demos, but production-grade reliability likely needs additional indexer/backfill hardening.

5. **Economic/risk model still hackathon-grade**
   - liquidation/interest/tier policies are functional but should be stress-tested and audited before production use.

---

## Roadmap Suggestions

1. Integrate real Noir browser proof generation directly into `Borrow` transaction flow.
2. Enforce proof freshness/nonces on-chain to prevent replay.
3. Implement full lender actions (supply, withdraw, APR dashboards).
4. Add richer protocol support and confidence scoring in agent.
5. Add CI pipelines for Foundry + Pytest + Next build checks.
6. Security hardening: formal reviews, invariant tests, and external audit before mainnet.

---

## Practical Summary

This repo is already a strong full-stack prototype with genuine cross-discipline implementation (Solidity + AI agent + ZK + modern frontend). The core foundation is in place; the next stage is production hardening and deeper integration of the proof path and lender mechanics.
