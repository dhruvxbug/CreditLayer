# SPDX-License-Identifier: MIT
"""
CreditLayer Agent – FastAPI entry-point
POST /score  {"address": "0x..."}
GET  /score/{address}
GET  /health
"""

from __future__ import annotations

import json
import logging
import os
from contextlib import asynccontextmanager
from typing import Any

import anthropic
import redis.asyncio as aioredis
from dotenv import load_dotenv
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, field_validator
from scorer.score_model import score_wallet

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
)
log = logging.getLogger("creditlayer.api")

ANTHROPIC_API_KEY: str = os.getenv("ANTHROPIC_API_KEY", "")
REDIS_URL: str = os.getenv("REDIS_URL", "redis://localhost:6379")
RPC_URL: str = os.getenv("RPC_URL", "https://mainnet.base.org")

CACHE_TTL_SECONDS = 3600  # 1 hour

# ---------------------------------------------------------------------------
# App-level shared state (populated in lifespan)
# ---------------------------------------------------------------------------

_state: dict[str, Any] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialise long-lived resources on startup; clean up on shutdown."""
    log.info("Starting up CreditLayer agent …")

    # Anthropic client
    if ANTHROPIC_API_KEY:
        _state["anthropic_client"] = anthropic.AsyncAnthropic(api_key=ANTHROPIC_API_KEY)
        log.info("Anthropic client initialised.")
    else:
        _state["anthropic_client"] = None
        log.warning("ANTHROPIC_API_KEY not set – AI explanations will be skipped.")

    # Redis client
    try:
        redis_client = aioredis.from_url(
            REDIS_URL,
            encoding="utf-8",
            decode_responses=True,
            socket_connect_timeout=3,
        )
        await redis_client.ping()
        _state["redis"] = redis_client
        log.info("Redis connected at %s", REDIS_URL)
    except Exception as exc:
        log.warning("Redis unavailable (%s) – caching disabled.", exc)
        _state["redis"] = None

    yield

    # Shutdown
    if _state.get("redis"):
        await _state["redis"].aclose()
    log.info("CreditLayer agent shut down.")


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(
    title="CreditLayer Scoring Agent",
    version="1.0.0",
    description="On-chain DeFi credit scoring API backed by a LangGraph agent.",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------


class ScoreRequest(BaseModel):
    address: str

    @field_validator("address")
    @classmethod
    def normalise_address(cls, v: str) -> str:
        return v.strip().lower()


class ScoreResponse(BaseModel):
    score: int
    tier: str
    features: dict[str, float]
    report: str
    cached: bool
    error: str | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_ZERO_HISTORY_THRESHOLD = 150  # scores at or below this are treated as "no history"


def _cache_key(address: str) -> str:
    return f"score:{address.lower()}"


async def _get_cached(address: str) -> dict | None:
    redis: aioredis.Redis | None = _state.get("redis")
    if redis is None:
        return None
    try:
        raw = await redis.get(_cache_key(address))
        if raw:
            return json.loads(raw)
    except Exception as exc:
        log.warning("Redis GET error: %s", exc)
    return None


async def _set_cached(address: str, payload: dict) -> None:
    redis: aioredis.Redis | None = _state.get("redis")
    if redis is None:
        return
    try:
        await redis.set(_cache_key(address), json.dumps(payload), ex=CACHE_TTL_SECONDS)
    except Exception as exc:
        log.warning("Redis SET error: %s", exc)


def _tier_for_score(score: int) -> str:
    if score >= 800:
        return "Gold"
    if score >= 600:
        return "Silver"
    if score >= 300:
        return "Bronze"
    return "Unverified"


def _is_valid_address(address: str) -> bool:
    if not address.startswith("0x") or len(address) != 42:
        return False
    try:
        int(address[2:], 16)
    except ValueError:
        return False
    return True


def _invalid_address_response(address: str) -> ScoreResponse:
    return ScoreResponse(
        score=0,
        tier="Unverified",
        features={},
        report="Invalid Ethereum address format.",
        cached=False,
        error=f"Invalid Ethereum address format: {address}",
    )


def _zero_history_response(address: str) -> ScoreResponse:
    return ScoreResponse(
        score=100,
        tier="Unverified",
        features={},
        report="Insufficient on-chain history to generate a reliable credit score.",
        cached=False,
        error=None,
    )


# ---------------------------------------------------------------------------
# Core scoring logic (shared by POST and GET handlers)
# ---------------------------------------------------------------------------


async def _score_address(address: str) -> ScoreResponse:
    address = address.lower()

    # 1. Check cache
    cached_payload = await _get_cached(address)
    if cached_payload:
        log.info("Cache hit for %s", address)
        cached_payload["cached"] = True
        return ScoreResponse(**cached_payload)

    # 2. Run the LangGraph scoring pipeline
    try:
        result: dict = await score_wallet(address)
    except Exception as exc:
        log.exception("score_wallet raised for %s: %s", address, exc)
        return ScoreResponse(
            score=0,
            tier="Unverified",
            features={},
            report="Scoring pipeline encountered an unexpected error.",
            cached=False,
            error=str(exc),
        )

    score: int = result.get("score", 0)
    tier: str = result.get("tier", _tier_for_score(score))
    features: dict = result.get("features", {})
    report: str = result.get("report", "")

    # 3. Zero-history guard
    if score <= _ZERO_HISTORY_THRESHOLD and not any(v > 0 for v in features.values()):
        response = _zero_history_response(address)
        # Still cache the zero-history result
        await _set_cached(address, response.model_dump())
        return response

    payload: dict = {
        "score": score,
        "tier": tier,
        "features": features,
        "report": report,
        "cached": False,
        "error": result.get("error"),
    }

    # 4. Store in cache
    await _set_cached(address, payload)

    return ScoreResponse(**payload)


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/health", tags=["meta"])
async def health_check() -> dict:
    """Simple liveness probe."""
    redis_ok = False
    if _state.get("redis"):
        try:
            await _state["redis"].ping()
            redis_ok = True
        except Exception:
            pass
    return {
        "status": "ok",
        "redis": redis_ok,
        "anthropic": _state.get("anthropic_client") is not None,
    }


@app.post("/score", response_model=ScoreResponse, tags=["scoring"])
async def post_score(body: ScoreRequest) -> ScoreResponse:
    """Score a wallet address (POST body)."""
    if not _is_valid_address(body.address):
        return _invalid_address_response(body.address)
    return await _score_address(body.address)


@app.get("/score/{address}", response_model=ScoreResponse, tags=["scoring"])
async def get_score(address: str) -> ScoreResponse:
    """Score a wallet address (path parameter)."""
    address = address.strip().lower()
    if not _is_valid_address(address):
        return _invalid_address_response(address)
    return await _score_address(address)
