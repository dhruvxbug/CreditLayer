from __future__ import annotations

import asyncio

import pytest

import main
from scorer import score_model
from scorer.data_fetcher import WalletOnChainData
from scorer.feature_engine import compute_features


def test_blank_wallet_features_are_zero_credit() -> None:
    features = compute_features(WalletOnChainData())

    assert features.repayment_rate == 0.0
    assert features.lp_consistency == 0.0
    assert features.current_health_factor == 0.0
    assert features.collateral_consistency == 0.0
    assert features.wallet_age_score == 0.0


def test_score_wallet_zero_history_uses_deterministic_path(monkeypatch: pytest.MonkeyPatch) -> None:
    async def fake_fetch_wallet_data(address: str) -> WalletOnChainData:
        return WalletOnChainData()

    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.setattr(score_model, "fetch_wallet_data", fake_fetch_wallet_data)
    score_model._graph = None

    result = asyncio.run(score_model.score_wallet("0x0000000000000000000000000000000000000001"))

    assert result["score"] == 0
    assert result["tier"] == "Unverified"
    assert all(value == 0.0 for value in result["features"].values())


def test_api_zero_history_response_is_score_100(monkeypatch: pytest.MonkeyPatch) -> None:
    async def fake_score_wallet(address: str) -> dict:
        return {
            "score": 0,
            "tier": "Unverified",
            "features": {
                "repayment_rate": 0.0,
                "volume_reliability": 0.0,
            },
            "report": "fallback",
            "error": None,
        }

    main._state["redis"] = None
    monkeypatch.setattr(main, "score_wallet", fake_score_wallet)

    response = asyncio.run(main._score_address("0x0000000000000000000000000000000000000001"))

    assert response.score == 100
    assert response.tier == "Unverified"
    assert response.report == "Insufficient on-chain history to generate a reliable credit score."
    assert response.error is None


def test_invalid_get_score_returns_structured_200_payload() -> None:
    response = asyncio.run(main.get_score("not-an-address"))

    assert response.score == 0
    assert response.tier == "Unverified"
    assert response.error is not None
