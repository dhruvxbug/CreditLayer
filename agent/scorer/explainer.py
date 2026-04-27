# SPDX-License-Identifier: MIT
"""
Mini-DeFi/agent/scorer/explainer.py

Generates a short plain-English credit report for a wallet by calling the
Anthropic Claude API.  Falls back to a deterministic string when the API is
unavailable so callers never receive an exception.
"""

from __future__ import annotations

import logging
import inspect

__all__ = ["generate_report"]

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def generate_report(
    address: str,
    score: int,
    tier: str,
    features: dict,
    anthropic_client,
) -> str:
    """
    Generate a 3-sentence plain-English credit report using Claude.

    Parameters
    ----------
    address:
        The wallet address being scored.
    score:
        The final credit score (0-1000).
    tier:
        The tier label: "Unverified", "Bronze", "Silver", or "Gold".
    features:
        Dictionary of computed feature names → float values.
    anthropic_client:
        An initialised ``anthropic.AsyncAnthropic`` (or ``anthropic.Anthropic``)
        client instance.  May be ``None`` – in that case the fallback string is
        returned immediately.

    Returns
    -------
    str
        A 3-sentence credit report, or the deterministic fallback string.
    """
    if anthropic_client is None:
        return _fallback(score, tier)

    # ------------------------------------------------------------------
    # Build a concise prompt so Claude can produce a focused report.
    # ------------------------------------------------------------------
    feature_lines = "\n".join(
        f"  {name}: {value:.4f}" for name, value in features.items()
    )

    prompt = (
        f"You are a DeFi credit analyst writing a brief credit report for a wallet.\n\n"
        f"Wallet address : {address}\n"
        f"Credit score   : {score} / 1000\n"
        f"Tier           : {tier}\n\n"
        f"Computed on-chain feature scores (all normalised 0-1 unless noted):\n"
        f"{feature_lines}\n\n"
        f"Write EXACTLY 3 sentences in plain English for a non-technical audience.\n"
        f"Sentence 1: Summarise the wallet's overall creditworthiness and tier.\n"
        f"Sentence 2: Highlight the 2-3 strongest positive signals from the features.\n"
        f"Sentence 3: Mention any risk factors or areas for improvement.\n"
        f"Do NOT include bullet points, markdown, or any preamble — just the 3 sentences."
    )

    try:
        # Support both sync Anthropic and async AsyncAnthropic clients.
        # Prefer the async path; fall back to the sync call in a thread if needed.
        if hasattr(anthropic_client, "messages"):
            messages_api = anthropic_client.messages
        else:
            return _fallback(score, tier)

        response = messages_api.create(
            model="claude-sonnet-4-20250514",
            max_tokens=256,
            messages=[{"role": "user", "content": prompt}],
        )
        if inspect.isawaitable(response):
            response = await response

        # Extract text from the first content block
        if response.content and len(response.content) > 0:
            block = response.content[0]
            text = block.text if hasattr(block, "text") else str(block)
            return text.strip()

        logger.warning("Claude returned an empty response for address %s", address)
        return _fallback(score, tier)

    except Exception as exc:  # noqa: BLE001
        logger.warning("Claude API call failed for address %s: %s", address, exc)
        return _fallback(score, tier)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _fallback(score: int, tier: str) -> str:
    """Return a deterministic fallback report when Claude is unavailable."""
    return (
        f"Score: {score}/1000 ({tier} tier). "
        f"Based on on-chain DeFi activity analysis. "
        f"AI_UNAVAILABLE - deterministic scoring only."
    )
