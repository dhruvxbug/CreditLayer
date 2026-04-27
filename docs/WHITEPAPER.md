# CreditLayer Whitepaper

**Version:** 1.0  
**Date:** April 27, 2026  
**Project:** CreditLayer (Mini-DeFi)

---

## Abstract

CreditLayer is a modular DeFi lending architecture designed to improve capital efficiency by using behavior-based creditworthiness rather than pure over-collateralization. The protocol combines:

1. **On-chain credit identity** using a non-transferable (soul-bound) score NFT,
2. **Off-chain AI risk scoring** over wallet behavior,
3. **Optional zero-knowledge threshold proofs** for privacy-preserving eligibility checks,
4. **Tiered lending policy** for collateral and APR requirements.

The goal is not to remove collateral, but to reduce collateral requirements for demonstrably responsible borrowers while preserving verifiability and controllable risk.

---

## 1. Problem Statement

Most DeFi money markets are highly collateralized (often 130–150%+). This protects lenders but excludes many users who have strong behavioral credit signals yet limited idle capital.

Traditional DeFi underwriting is simplistic:

- risk = collateral ratio,
- identity = wallet address,
- trust = liquidation buffer.

CreditLayer introduces an additional risk primitive: **verifiable behavioral credit**.

---

## 2. Design Objectives

1. **Capital efficiency:** enable lower collateral ratios for higher-quality borrowers.
2. **Composability:** represent credit state in a reusable on-chain primitive.
3. **Privacy:** allow proving minimum eligibility without revealing full score when needed.
4. **Auditability:** keep policy logic and position state transparent on-chain.
5. **Modularity:** keep scoring engine upgradable independently from lending contracts.

---

## 3. System Architecture

```text
Wallet
  │
  ├── interacts with protocol contracts (borrow/repay/liquidate)
  │
  ├── receives score updates via oracle-attested writes
  │
  └── optionally submits ZK threshold proof during borrow

Off-chain agent
  ├── fetches wallet behavior signals
  ├── computes normalized features
  ├── outputs score + explanation
  └── signs attestation (trusted signer)
```

Core modules:

- `CreditScoreNFT` — persistent, non-transferable credit profile anchor.
- `CreditOracle` — attestation verification and NFT update bridge.
- `CreditLendingPool` — loan accounting, collateral checks, liquidation logic.
- Scoring agent — feature computation and score/report generation.
- Noir circuit — optional threshold proof (`score >= threshold`).

---

## 4. Credit Identity Primitive

### 4.1 Soul-Bound Score NFT

Each wallet maps to one non-transferable NFT profile. The NFT stores (directly or by associated state):

- current score,
- last update timestamp,
- derived tier,
- optional proof-verification flag.

This design prevents score markets and identity transfer through token transferability.

### 4.2 Tier Mapping

A representative policy (implementation-defined) maps score to tier:

- Gold: score $\ge 800$
- Silver: score $\ge 600$
- Bronze: score $\ge 300$
- Unverified otherwise

Tier then parameterizes borrowing constraints.

---

## 5. Off-Chain Risk Engine

### 5.1 Inputs

The scoring pipeline consumes wallet behavior from DeFi venues (e.g., borrow/repay history, liquidations, activity age/diversity, LP behavior).

### 5.2 Feature Engineering

Raw data is transformed into normalized features in $[0,1]$ (except explicit penalties), then aggregated into a weighted score in $[0,1000]$.

A representative weighted model:

$$
\text{baseScore} = 1000 \cdot \sum_{i=1}^{n} w_i f_i
$$

where $f_i$ are features and $w_i$ are policy weights with $\sum w_i = 1$.

### 5.3 Explainability

The agent returns:

- numeric score,
- tier label,
- key features,
- short human-readable report.

This provides user-level transparency while preserving internal model flexibility.

---

## 6. Oracle Attestation Bridge

The on-chain oracle contract accepts signed score attestations (EIP-712) from a trusted signer.

Attestation fields typically include:

- borrower address,
- score,
- timestamp,
- optional verification metadata.

The contract verifies signature validity and freshness window before minting/updating NFT profile state.

This creates a controlled trust boundary:

- **off-chain computes risk,**
- **on-chain enforces policy with verified attestations.**

---

## 7. Lending Mechanics

Borrowers post ETH collateral and receive stablecoin-denominated credit (mock USDC in current implementation).

Tier affects:

- minimum collateral ratio,
- borrowing capacity,
- APR.

### 7.1 Health Factor

Risk state can be represented as:

$$
HF = \frac{\text{CollateralUSD}}{\text{DebtUSD}}
$$

Liquidation is enabled when $HF < 1$ (after applying implementation scaling/precision).

### 7.2 Interest

Current model uses time-based simple accrual. Future versions may support variable rate curves and utilization-based pricing.

---

## 8. Zero-Knowledge Threshold Proofs (Optional)

### 8.1 Objective

Allow a borrower to prove score eligibility (e.g., score above threshold) without publishing raw score in transaction calldata.

### 8.2 Statement

The circuit proves:

$$
\text{score} \ge \text{threshold}
$$

while binding private score to a public commitment.

### 8.3 Practical Notes

- Testnet deployments may run with verifier disabled for velocity.
- Production-grade usage should bind proof freshness/nonces and commitment lifecycle to prevent replay.

---

## 9. Economic and Security Assumptions

1. **Signer security:** compromise of trusted signer can corrupt score updates.
2. **Oracle correctness:** collateral valuation depends on accurate, live price feed data.
3. **Model risk:** poor weighting or biased features can misprice borrower risk.
4. **Sybil/identity risk:** wallets are pseudonymous; behavior clustering and anomaly checks are required.
5. **Latency risk:** stale scores or delayed updates can lead to temporary underpricing.

Mitigations include attestation TTL, update cooldowns, conservative initial parameters, and robust monitoring.

---

## 10. Governance and Parameterization (Future)

A mature version should externalize policy into governance-controlled parameters, including:

- tier thresholds,
- collateral ratios,
- APR curves,
- liquidation bonus,
- attestation validity windows,
- scorer versioning/rollback controls.

Suggested progression:

- Phase 1: multisig-admin policy updates,
- Phase 2: guarded governance with timelock,
- Phase 3: decentralized risk committee + transparent model registry.

---

## 11. Limitations in Current Implementation

- Primary implementation is hackathon-grade and not production-audited.
- Some parameter paths are fixed/static for simplicity.
- Optional ZK verifier may not be enforced in every deployment.
- Stablecoin/token logic currently uses mock assets for testing.

---

## 12. Roadmap

### Near-term

- Strengthen score attestation schema and replay resistance.
- Enforce verifier path across all target deployments.
- Expand integration tests across contract + agent + frontend boundaries.

### Mid-term

- Multi-model ensemble scoring and calibration dashboards.
- Adaptive rate model tied to protocol utilization and borrower quality.
- Improved anti-Sybil heuristics and longitudinal behavior tracking.

### Long-term

- Cross-protocol reusable credit primitive standard.
- Privacy-preserving attestations for broader risk attributes.
- Inter-protocol credit portability and delegated underwriting markets.

---

## 13. Conclusion

CreditLayer demonstrates a practical architecture for bringing behavior-based credit into DeFi without sacrificing composability. By combining soul-bound credit identity, signed AI attestations, and optional zero-knowledge threshold proofs, the protocol offers a path toward safer under-collateralized lending with stronger user privacy controls.

This whitepaper defines the conceptual and technical baseline for iterative hardening, economic validation, and productionization.
