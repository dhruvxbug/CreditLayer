"""
feature_engine.py
─────────────────
Transforms raw on-chain wallet data into a 12-dimensional normalised feature
vector used by the CreditLayer scoring model.

All features are in [0.0, 1.0] except liquidation_penalty, which can be
negative and is bounded at -1.0.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .data_fetcher import WalletOnChainData

__all__ = ["FeatureVector", "compute_features"]


# ---------------------------------------------------------------------------
# Output dataclass
# ---------------------------------------------------------------------------


@dataclass
class FeatureVector:
    """12-dimensional feature representation of a wallet's DeFi credit profile."""

    # Feature 1 – Aave repayment reliability
    repayment_rate: float

    # Feature 2 – Volume-weighted reliability (log-scaled)
    volume_reliability: float

    # Feature 3 – Number of distinct protocol interactions (normalised)
    protocol_diversity: float

    # Feature 4 – Wallet age (sigmoid centred at 1 year)
    wallet_age_score: float

    # Feature 5 – LP position consistency (penalised by panic withdrawals)
    lp_consistency: float

    # Feature 6 – Liquidation penalty (0 or negative; bounded at -1.0)
    liquidation_penalty: float

    # Feature 7 – Current Aave health factor (normalised to [0, 1])
    current_health_factor: float

    # Feature 8 – Activity recency score (recent activity = higher)
    activity_recency: float

    # Feature 9 – Cross-protocol trust (weighted Aave + Compound)
    cross_protocol_trust: float

    # Feature 10 – Collateral consistency derived from health factor
    collateral_consistency: float

    # Feature 11 – DeFi tenure on log scale (5 years → 1.0)
    defi_tenure: float

    # Feature 12 – Compound repayment rate
    compound_repayment_rate: float


# ---------------------------------------------------------------------------
# Individual feature computations
# ---------------------------------------------------------------------------


def _f1_repayment_rate(data: WalletOnChainData) -> float:
    """Feature 1: Aave repayment rate (already 0-1 from data_fetcher)."""
    return float(data.aave_repayment_rate)


def _f2_volume_reliability(data: WalletOnChainData) -> float:
    """Feature 2: Log-scaled borrow volume reliability.

    Reaches 1.0 at $100k cumulative borrow volume.
    """
    return min(1.0, math.log1p(data.aave_borrow_volume_usd) / math.log1p(100_000.0))


def _f3_protocol_diversity(data: WalletOnChainData) -> float:
    """Feature 3: Normalised count of unique protocol interactions (10 = max)."""
    return min(1.0, data.unique_protocol_interactions / 10.0)


def _f4_wallet_age_score(data: WalletOnChainData) -> float:
    """Feature 4: Sigmoid centred at 365 days.

    No detected wallet age returns 0.0 so blank wallets do not receive credit.
    1 day   → ~0.03
    365 days → 0.50
    730 days → ~0.73
    ∞       → 1.0
    """
    if data.wallet_age_days <= 0:
        return 0.0
    return 1.0 / (1.0 + math.exp(-0.01 * (data.wallet_age_days - 365)))


def _f5_lp_consistency(data: WalletOnChainData) -> float:
    """Feature 5: LP consistency penalised by panic withdrawals (each -0.2)."""
    if data.uniswap_lp_positions <= 0:
        return 0.0
    return max(0.0, min(1.0, 1.0 - (data.uniswap_panic_withdrawals * 0.2)))


def _f6_liquidation_penalty(data: WalletOnChainData) -> float:
    """Feature 6: Negative score per liquidation event (-0.3 each, floor -1.0)."""
    return max(-1.0, -(data.total_liquidation_count * 0.3))


def _f7_current_health_factor(data: WalletOnChainData) -> float:
    """Feature 7: Normalised Aave health factor.

    No active Aave borrow history returns 0.0; the fetcher uses 999.0 as a
    sentinel for "no open position", not as a credit signal.
    HF = 1.0 → 0.0 (just above liquidation threshold)
    HF = 2.0 → 0.5
    HF = 3.0 → 1.0  (capped)
    HF > 3.0 → 1.0
    HF < 1.0 → 0.0  (clamped)
    """
    if data.aave_borrow_count == 0 or data.aave_health_factor >= 900.0:
        return 0.0
    clamped_hf = min(3.0, data.aave_health_factor)
    return min(1.0, max(0.0, (clamped_hf - 1.0) / 2.0))


def _f8_activity_recency(data: WalletOnChainData) -> float:
    """Feature 8: Recency score based on first Aave interaction age.

    Within the last 730 days: 1 - exp(-0.005 * (730 - days))
      - Very recent (0 days old) → ~1.0
      - 730 days ago            → 0.0
    Older than 730 days: 1.0 (long-established user, max recency credit).

    Note: this metric rewards wallets that have *recently* been active AND
    have been active for a long time.  The score plateaus at 1.0 for wallets
    whose first Aave interaction was more than ~2 years ago.
    """
    days = data.aave_first_interaction_days
    if days <= 0:
        # No Aave history at all – no recency credit
        return 0.0
    if days < 730:
        return 1.0 - math.exp(-0.005 * max(0.0, 730.0 - days))
    return 1.0


def _f9_cross_protocol_trust(
    repayment_rate: float,
    compound_repayment_rate: float,
) -> float:
    """Feature 9: Weighted average of Aave (60%) and Compound (40%) repayment."""
    return 0.6 * repayment_rate + 0.4 * compound_repayment_rate


def _f10_collateral_consistency(data: WalletOnChainData) -> float:
    """Feature 10: Collateral buffer derived from Aave health factor.

    No active Aave borrow history returns 0.0.
    HF = 1.0 → 0.0  (at liquidation boundary)
    HF = 2.0 → 0.5
    HF = 3.0 → 1.0  (capped)
    """
    if data.aave_borrow_count == 0 or data.aave_health_factor >= 900.0:
        return 0.0
    return min(1.0, max(0.0, (data.aave_health_factor - 1.0) / 2.0))


def _f11_defi_tenure(data: WalletOnChainData) -> float:
    """Feature 11: Log-scaled wallet age where 5 years ≈ 1.0.

    log1p(years) / log1p(5)
    """
    years = data.wallet_age_days / 365.0
    return min(1.0, math.log1p(years) / math.log1p(5.0))


def _f12_compound_repayment_rate(data: WalletOnChainData) -> float:
    """Feature 12: Compound repayment rate (already 0-1 from data_fetcher)."""
    return float(data.compound_repayment_rate)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def compute_features(data: WalletOnChainData) -> FeatureVector:
    """Compute the 12-feature vector from raw wallet on-chain data.

    All features are clamped to [-1.0, 1.0] after computation.
    ``liquidation_penalty`` may be negative but is still bounded at -1.0.

    Args:
        data: Populated ``WalletOnChainData`` instance from ``data_fetcher``.

    Returns:
        A ``FeatureVector`` with all 12 normalised features.
    """
    # Compute base features
    f1 = _f1_repayment_rate(data)
    f2 = _f2_volume_reliability(data)
    f3 = _f3_protocol_diversity(data)
    f4 = _f4_wallet_age_score(data)
    f5 = _f5_lp_consistency(data)
    f6 = _f6_liquidation_penalty(data)  # can be negative
    f7 = _f7_current_health_factor(data)
    f8 = _f8_activity_recency(data)
    f9 = _f9_cross_protocol_trust(f1, _f12_compound_repayment_rate(data))
    f10 = _f10_collateral_consistency(data)
    f11 = _f11_defi_tenure(data)
    f12 = _f12_compound_repayment_rate(data)

    def _clamp(v: float) -> float:
        return max(-1.0, min(1.0, v))

    return FeatureVector(
        repayment_rate=_clamp(f1),
        volume_reliability=_clamp(f2),
        protocol_diversity=_clamp(f3),
        wallet_age_score=_clamp(f4),
        lp_consistency=_clamp(f5),
        liquidation_penalty=_clamp(f6),  # stays as-is (already bounded)
        current_health_factor=_clamp(f7),
        activity_recency=_clamp(f8),
        cross_protocol_trust=_clamp(f9),
        collateral_consistency=_clamp(f10),
        defi_tenure=_clamp(f11),
        compound_repayment_rate=_clamp(f12),
    )
