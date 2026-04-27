# SPDX-License-Identifier: MIT
"""
score_model.py
==============
LangGraph-based credit-scoring agent for CreditLayer.

Pipeline (6 nodes, linear graph):
    fetch_data → engineer_features → base_score → anomaly_check → final_score → report → END
"""

from __future__ import annotations

import asyncio
import logging
import os
from typing import Any, Optional, TypedDict

import anthropic
from langgraph.graph import END, StateGraph

from .data_fetcher import WalletOnChainData, fetch_wallet_data
from .explainer import generate_report
from .feature_engine import FeatureVector, compute_features

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Feature weights (must sum to 1.0)
# Index maps to FeatureVector fields in declaration order:
#   0  repayment_rate          0.20
#   1  volume_reliability      0.10
#   2  protocol_diversity      0.08
#   3  wallet_age_score        0.08
#   4  lp_consistency          0.07
#   5  liquidation_penalty     0.12
#   6  current_health_factor   0.10
#   7  activity_recency        0.07
#   8  cross_protocol_trust    0.06
#   9  collateral_consistency  0.05
#  10  defi_tenure             0.04
#  11  compound_repayment_rate 0.03
# ---------------------------------------------------------------------------
FEATURE_WEIGHTS: list[float] = [
    0.20,  # repayment_rate
    0.10,  # volume_reliability
    0.08,  # protocol_diversity
    0.08,  # wallet_age_score
    0.07,  # lp_consistency
    0.12,  # liquidation_penalty
    0.10,  # current_health_factor
    0.07,  # activity_recency
    0.06,  # cross_protocol_trust
    0.05,  # collateral_consistency
    0.04,  # defi_tenure
    0.03,  # compound_repayment_rate
]


# ---------------------------------------------------------------------------
# State definition
# ---------------------------------------------------------------------------


class ScoringState(TypedDict, total=False):
    """Mutable state that flows through every node of the scoring graph."""

    address: str
    wallet_data: Optional[WalletOnChainData]
    features: Optional[FeatureVector]
    base_score_value: float
    anomaly_result: str  # "CLEAN" | "PENALTY::<amount>"
    final_score_value: int
    report_text: str
    error: Optional[str]


# ---------------------------------------------------------------------------
# Tier helper
# ---------------------------------------------------------------------------


def _derive_tier(score: int) -> str:
    if score >= 800:
        return "Gold"
    if score >= 600:
        return "Silver"
    if score >= 300:
        return "Bronze"
    return "Unverified"


def _features_to_dict(fv: FeatureVector) -> dict[str, float]:
    """Convert FeatureVector dataclass to a plain dict for serialisation."""
    return {
        "repayment_rate": fv.repayment_rate,
        "volume_reliability": fv.volume_reliability,
        "protocol_diversity": fv.protocol_diversity,
        "wallet_age_score": fv.wallet_age_score,
        "lp_consistency": fv.lp_consistency,
        "liquidation_penalty": fv.liquidation_penalty,
        "current_health_factor": fv.current_health_factor,
        "activity_recency": fv.activity_recency,
        "cross_protocol_trust": fv.cross_protocol_trust,
        "collateral_consistency": fv.collateral_consistency,
        "defi_tenure": fv.defi_tenure,
        "compound_repayment_rate": fv.compound_repayment_rate,
    }


def _feature_values(fv: FeatureVector) -> list[float]:
    """Return feature values in the same order as FEATURE_WEIGHTS."""
    return [
        fv.repayment_rate,
        fv.volume_reliability,
        fv.protocol_diversity,
        fv.wallet_age_score,
        fv.lp_consistency,
        fv.liquidation_penalty,
        fv.current_health_factor,
        fv.activity_recency,
        fv.cross_protocol_trust,
        fv.collateral_consistency,
        fv.defi_tenure,
        fv.compound_repayment_rate,
    ]


# ---------------------------------------------------------------------------
# Node 1 — fetch_data_node
# ---------------------------------------------------------------------------


async def fetch_data_node(state: ScoringState) -> ScoringState:
    """Fetch on-chain wallet data from subgraphs and RPC."""
    address = state["address"]
    logger.info("[fetch_data_node] fetching data for %s", address)
    try:
        wallet_data = await fetch_wallet_data(address)
        return {**state, "wallet_data": wallet_data, "error": None}
    except Exception as exc:
        logger.error("[fetch_data_node] unexpected error: %s", exc)
        # Provide a default blank profile so the pipeline can continue
        wallet_data = WalletOnChainData(
            aave_borrow_count=0,
            aave_borrow_volume_usd=0.0,
            aave_repay_count=0,
            aave_repay_volume_usd=0.0,
            aave_repayment_rate=0.0,
            aave_health_factor=999.0,
            aave_first_interaction_days=0,
            compound_borrow_count=0,
            compound_repay_count=0,
            compound_repayment_rate=0.0,
            compound_liquidation_count=0,
            uniswap_lp_positions=0,
            uniswap_lp_duration_days=0.0,
            uniswap_lp_fees_earned_usd=0.0,
            uniswap_panic_withdrawals=0,
            wallet_age_days=0,
            unique_protocol_interactions=0,
            eth_balance=0.0,
            total_liquidation_count=0,
        )
        return {**state, "wallet_data": wallet_data, "error": str(exc)}


# ---------------------------------------------------------------------------
# Node 2 — engineer_features_node
# ---------------------------------------------------------------------------


async def engineer_features_node(state: ScoringState) -> ScoringState:
    """Compute the 12-dimensional feature vector from raw wallet data."""
    logger.info("[engineer_features_node] computing features for %s", state["address"])
    try:
        wallet_data = state["wallet_data"]
        if wallet_data is None:
            raise ValueError("wallet_data is None — fetch_data_node may have failed")
        features = compute_features(wallet_data)
        return {**state, "features": features}
    except Exception as exc:
        logger.error("[engineer_features_node] error: %s", exc)
        # Return zero-vector features as fallback
        from dataclasses import fields

        from .feature_engine import FeatureVector as FV

        zero_fv = FV(**{f.name: 0.0 for f in fields(FV)})
        return {**state, "features": zero_fv, "error": str(exc)}


# ---------------------------------------------------------------------------
# Node 3 — base_score_node
# ---------------------------------------------------------------------------


async def base_score_node(state: ScoringState) -> ScoringState:
    """Compute the weighted base score (0–1000 float) from the feature vector."""
    logger.info("[base_score_node] computing base score for %s", state["address"])
    try:
        features = state["features"]
        if features is None:
            raise ValueError("features is None")

        values = _feature_values(features)
        weighted_sum = sum(v * w for v, w in zip(values, FEATURE_WEIGHTS))
        # weighted_sum is in [-1.0, 1.0] roughly; scale to 0–1000
        base_score = weighted_sum * 1000.0
        logger.info(
            "[base_score_node] raw weighted_sum=%.4f  base_score=%.2f",
            weighted_sum,
            base_score,
        )
        return {**state, "base_score_value": base_score}
    except Exception as exc:
        logger.error("[base_score_node] error: %s", exc)
        return {**state, "base_score_value": 100.0, "error": str(exc)}


# ---------------------------------------------------------------------------
# Node 4 — anomaly_check_node
# ---------------------------------------------------------------------------

_ANOMALY_SYSTEM_PROMPT = (
    "You are a Sybil-detection engine for a DeFi credit-scoring protocol. "
    "Analyse the provided wallet feature vector for signs of Sybil behaviour, "
    "wash trading, or artificial inflation of on-chain metrics. "
    "Reply with exactly one of:\n"
    "  CLEAN\n"
    "  PENALTY::<integer between 50 and 300>\n"
    "No other text, no explanations."
)


async def anomaly_check_node(state: ScoringState) -> ScoringState:
    """Call Claude to detect Sybil patterns; parse CLEAN or PENALTY::<amount>."""
    logger.info("[anomaly_check_node] running anomaly check for %s", state["address"])

    features = state.get("features")
    wallet_data = state.get("wallet_data")

    # Build a human-readable feature summary for the LLM
    feature_summary = "No feature data available."
    if features is not None:
        fd = _features_to_dict(features)
        feature_summary = "\n".join(f"  {k}: {v:.4f}" for k, v in fd.items())

    wallet_summary = "No wallet data available."
    if wallet_data is not None:
        wallet_summary = (
            f"  aave_borrow_count: {wallet_data.aave_borrow_count}\n"
            f"  aave_repay_count: {wallet_data.aave_repay_count}\n"
            f"  aave_repayment_rate: {wallet_data.aave_repayment_rate:.4f}\n"
            f"  compound_borrow_count: {wallet_data.compound_borrow_count}\n"
            f"  compound_repay_count: {wallet_data.compound_repay_count}\n"
            f"  compound_liquidation_count: {wallet_data.compound_liquidation_count}\n"
            f"  uniswap_panic_withdrawals: {wallet_data.uniswap_panic_withdrawals}\n"
            f"  wallet_age_days: {wallet_data.wallet_age_days}\n"
            f"  unique_protocol_interactions: {wallet_data.unique_protocol_interactions}\n"
            f"  total_liquidation_count: {wallet_data.total_liquidation_count}"
        )

    user_message = (
        f"Wallet address: {state['address']}\n\n"
        f"Feature vector:\n{feature_summary}\n\n"
        f"Raw on-chain data:\n{wallet_summary}\n\n"
        "Is this wallet showing signs of Sybil behaviour or metric gaming?"
    )

    api_key = os.getenv("ANTHROPIC_API_KEY", "")
    if not api_key:
        logger.warning(
            "[anomaly_check_node] ANTHROPIC_API_KEY not set — skipping, using CLEAN"
        )
        return {**state, "anomaly_result": "CLEAN"}

    try:
        client = anthropic.AsyncAnthropic(api_key=api_key)
        message = await client.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=32,
            system=_ANOMALY_SYSTEM_PROMPT,
            messages=[{"role": "user", "content": user_message}],
        )
        raw_reply = message.content[0].text.strip()
        logger.info("[anomaly_check_node] Claude replied: %r", raw_reply)

        if raw_reply == "CLEAN":
            anomaly_result = "CLEAN"
        elif raw_reply.startswith("PENALTY::"):
            # Validate the penalty value
            try:
                parts = raw_reply.split("::", 1)
                int(parts[1])  # ensure it's a valid integer
                anomaly_result = raw_reply
            except (IndexError, ValueError):
                logger.warning(
                    "[anomaly_check_node] malformed PENALTY reply %r — using CLEAN",
                    raw_reply,
                )
                anomaly_result = "CLEAN"
        else:
            logger.warning(
                "[anomaly_check_node] unexpected reply %r — using CLEAN", raw_reply
            )
            anomaly_result = "CLEAN"

        return {**state, "anomaly_result": anomaly_result}

    except Exception as exc:
        logger.error("[anomaly_check_node] API error: %s — defaulting to CLEAN", exc)
        return {**state, "anomaly_result": "CLEAN"}


# ---------------------------------------------------------------------------
# Node 5 — final_score_node
# ---------------------------------------------------------------------------


async def final_score_node(state: ScoringState) -> ScoringState:
    """Apply anomaly penalty, clamp to [0, 1000], and convert to int."""
    logger.info("[final_score_node] finalising score for %s", state["address"])

    base_score = state.get("base_score_value", 100.0)
    anomaly_result = state.get("anomaly_result", "CLEAN")

    penalty = 0
    if anomaly_result.startswith("PENALTY::"):
        try:
            penalty = int(anomaly_result.split("::", 1)[1])
        except (IndexError, ValueError):
            penalty = 0

    raw_final = base_score - penalty
    final_score = int(max(0.0, min(1000.0, raw_final)))

    logger.info(
        "[final_score_node] base=%.2f  penalty=%d  final=%d",
        base_score,
        penalty,
        final_score,
    )
    return {**state, "final_score_value": final_score}


# ---------------------------------------------------------------------------
# Node 6 — report_node
# ---------------------------------------------------------------------------


async def report_node(state: ScoringState) -> ScoringState:
    """Generate a plain-English credit report using Claude."""
    logger.info("[report_node] generating report for %s", state["address"])

    final_score = state.get("final_score_value", 0)
    tier = _derive_tier(final_score)
    features = state.get("features")
    features_dict = _features_to_dict(features) if features is not None else {}
    address = state["address"]

    api_key = os.getenv("ANTHROPIC_API_KEY", "")
    client = None
    if api_key:
        try:
            client = anthropic.AsyncAnthropic(api_key=api_key)
        except Exception:
            client = None

    report = await generate_report(
        address=address,
        score=final_score,
        tier=tier,
        features=features_dict,
        anthropic_client=client,
    )

    return {**state, "report_text": report}


# ---------------------------------------------------------------------------
# Graph construction
# ---------------------------------------------------------------------------


def _build_graph() -> Any:
    """Build and compile the LangGraph StateGraph for wallet scoring."""
    builder: StateGraph = StateGraph(ScoringState)

    # Register nodes
    builder.add_node("fetch_data", fetch_data_node)
    builder.add_node("engineer_features", engineer_features_node)
    builder.add_node("base_score", base_score_node)
    builder.add_node("anomaly_check", anomaly_check_node)
    builder.add_node("final_score", final_score_node)
    builder.add_node("report", report_node)

    # Linear edge chain
    builder.set_entry_point("fetch_data")
    builder.add_edge("fetch_data", "engineer_features")
    builder.add_edge("engineer_features", "base_score")
    builder.add_edge("base_score", "anomaly_check")
    builder.add_edge("anomaly_check", "final_score")
    builder.add_edge("final_score", "report")
    builder.add_edge("report", END)

    return builder.compile()


# Module-level compiled graph (lazy singleton)
_graph: Any = None


def _get_graph() -> Any:
    global _graph
    if _graph is None:
        _graph = _build_graph()
    return _graph


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def score_wallet(address: str) -> dict[str, Any]:
    """
    Run the full 6-node scoring pipeline for a wallet address.

    Returns
    -------
    dict with keys:
        score   : int   — final credit score in [0, 1000]
        tier    : str   — "Unverified" | "Bronze" | "Silver" | "Gold"
        features: dict  — {feature_name: float, ...}
        report  : str   — plain-English credit report
    """
    graph = _get_graph()

    initial_state: ScoringState = {
        "address": address,
        "wallet_data": None,
        "features": None,
        "base_score_value": 100.0,
        "anomaly_result": "CLEAN",
        "final_score_value": 0,
        "report_text": "",
        "error": None,
    }

    try:
        final_state: ScoringState = await graph.ainvoke(initial_state)
    except Exception as exc:
        logger.error("[score_wallet] graph execution failed for %s: %s", address, exc)
        final_state = {
            **initial_state,
            "final_score_value": 100,
            "report_text": (
                f"Score: 100/1000 (Unverified tier). "
                f"Pipeline error — deterministic fallback applied. "
                f"Error: {exc}"
            ),
            "error": str(exc),
        }

    final_score: int = final_state.get("final_score_value", 100)
    tier: str = _derive_tier(final_score)

    features_obj = final_state.get("features")
    features_dict: dict[str, float] = (
        _features_to_dict(features_obj) if features_obj is not None else {}
    )

    return {
        "score": final_score,
        "tier": tier,
        "features": features_dict,
        "report": final_state.get("report_text", ""),
    }


__all__ = ["score_wallet", "ScoringState"]
