"""
data_fetcher.py
---------------
Fetches on-chain DeFi activity for a wallet address by querying
The Graph subgraphs for Aave V3, Compound III, and Uniswap V3 (all on Base),
plus a Web3 fallback for wallet age estimation.

Never crashes — always returns a WalletOnChainData with safe defaults.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import Any

import httpx

__all__ = ["WalletOnChainData", "fetch_wallet_data"]

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Subgraph endpoints
# ---------------------------------------------------------------------------

AAVE_V3_BASE_URL = "https://api.thegraph.com/subgraphs/name/aave/protocol-v3-base"
COMPOUND_V3_BASE_URL = (
    "https://api.thegraph.com/subgraphs/name/compound-finance/compound-v3-base"
)
UNISWAP_V3_BASE_URL = "https://api.thegraph.com/subgraphs/name/uniswap/uniswap-v3-base"

# Timeout for each individual HTTP request
REQUEST_TIMEOUT = 15.0  # seconds

# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class WalletOnChainData:
    # ── Aave V3 ──────────────────────────────────────────────────────────────
    aave_borrow_count: int = 0
    aave_borrow_volume_usd: float = 0.0
    aave_repay_count: int = 0
    aave_repay_volume_usd: float = 0.0
    # repaid / borrowed — 0.0 when there are no borrows
    aave_repayment_rate: float = 0.0
    # From getUserAccountData; default 999.0 means "no open position / pristine"
    aave_health_factor: float = 999.0
    # Days since first Aave interaction; 0 when never interacted
    aave_first_interaction_days: int = 0

    # ── Compound III ─────────────────────────────────────────────────────────
    compound_borrow_count: int = 0
    compound_repay_count: int = 0
    compound_repayment_rate: float = 0.0
    compound_liquidation_count: int = 0

    # ── Uniswap V3 ───────────────────────────────────────────────────────────
    uniswap_lp_positions: int = 0
    uniswap_lp_duration_days: float = 0.0
    uniswap_lp_fees_earned_usd: float = 0.0
    uniswap_panic_withdrawals: int = 0

    # ── General wallet metrics ────────────────────────────────────────────────
    wallet_age_days: int = 0
    unique_protocol_interactions: int = 0
    eth_balance: float = 0.0
    total_liquidation_count: int = 0


# ---------------------------------------------------------------------------
# GraphQL query helpers
# ---------------------------------------------------------------------------


async def _gql(
    client: httpx.AsyncClient,
    url: str,
    query: str,
    variables: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """
    Execute a single GraphQL request and return the ``data`` portion of the
    response.  Raises ``httpx.HTTPError`` or ``ValueError`` on failure so
    callers can catch and apply defaults.
    """
    payload: dict[str, Any] = {"query": query}
    if variables:
        payload["variables"] = variables

    response = await client.post(url, json=payload, timeout=REQUEST_TIMEOUT)
    response.raise_for_status()
    body = response.json()

    if "errors" in body:
        raise ValueError(f"GraphQL errors from {url}: {body['errors']}")

    return body.get("data", {})


# ---------------------------------------------------------------------------
# Aave V3 queries
# ---------------------------------------------------------------------------

_AAVE_BORROW_QUERY = """
query AaveBorrows($user: String!, $skip: Int!) {
  borrows(
    first: 1000
    skip: $skip
    where: { user: $user }
    orderBy: timestamp
    orderDirection: asc
  ) {
    id
    amount
    amountUSD
    timestamp
    reserve { symbol }
  }
}
"""

_AAVE_REPAY_QUERY = """
query AaveRepays($user: String!, $skip: Int!) {
  repays(
    first: 1000
    skip: $skip
    where: { user: $user }
    orderBy: timestamp
    orderDirection: asc
  ) {
    id
    amount
    amountUSD
    timestamp
  }
}
"""

_AAVE_USER_RESERVE_QUERY = """
query AaveUserReserve($user: String!) {
  userReserves(where: { user: $user, currentTotalDebt_gt: "0" }, first: 1) {
    healthFactor
  }
  _meta { block { timestamp } }
}
"""


async def _fetch_aave_data(
    client: httpx.AsyncClient,
    address: str,
) -> dict[str, Any]:
    """Return raw Aave stats for *address*; falls back to empty defaults."""
    user = address.lower()
    result: dict[str, Any] = {
        "borrow_count": 0,
        "borrow_volume_usd": 0.0,
        "repay_count": 0,
        "repay_volume_usd": 0.0,
        "health_factor": 999.0,
        "first_interaction_ts": None,
    }

    # --- borrows (paginated) -------------------------------------------------
    try:
        all_borrows: list[dict] = []
        skip = 0
        while True:
            data = await _gql(
                client,
                AAVE_V3_BASE_URL,
                _AAVE_BORROW_QUERY,
                {"user": user, "skip": skip},
            )
            batch = data.get("borrows", [])
            all_borrows.extend(batch)
            if len(batch) < 1000:
                break
            skip += 1000

        result["borrow_count"] = len(all_borrows)
        result["borrow_volume_usd"] = sum(
            float(b.get("amountUSD") or 0) for b in all_borrows
        )
        if all_borrows:
            result["first_interaction_ts"] = int(all_borrows[0].get("timestamp", 0))
    except Exception as exc:
        logger.warning("Aave borrow query failed for %s: %s", address, exc)

    # --- repays (paginated) --------------------------------------------------
    try:
        all_repays: list[dict] = []
        skip = 0
        while True:
            data = await _gql(
                client,
                AAVE_V3_BASE_URL,
                _AAVE_REPAY_QUERY,
                {"user": user, "skip": skip},
            )
            batch = data.get("repays", [])
            all_repays.extend(batch)
            if len(batch) < 1000:
                break
            skip += 1000

        result["repay_count"] = len(all_repays)
        result["repay_volume_usd"] = sum(
            float(r.get("amountUSD") or 0) for r in all_repays
        )
        # Use earliest repay timestamp if no borrow timestamp found
        if all_repays and result["first_interaction_ts"] is None:
            result["first_interaction_ts"] = int(all_repays[0].get("timestamp", 0))
    except Exception as exc:
        logger.warning("Aave repay query failed for %s: %s", address, exc)

    # --- health factor -------------------------------------------------------
    try:
        data = await _gql(
            client, AAVE_V3_BASE_URL, _AAVE_USER_RESERVE_QUERY, {"user": user}
        )
        reserves = data.get("userReserves", [])
        if reserves:
            hf_raw = reserves[0].get("healthFactor")
            if hf_raw is not None:
                result["health_factor"] = float(hf_raw)
    except Exception as exc:
        logger.warning("Aave health-factor query failed for %s: %s", address, exc)

    return result


# ---------------------------------------------------------------------------
# Compound III queries
# ---------------------------------------------------------------------------

_COMPOUND_BORROW_QUERY = """
query CompoundBorrows($user: String!, $skip: Int!) {
  borrowEvents(
    first: 1000
    skip: $skip
    where: { account: $user }
    orderBy: timestamp
    orderDirection: asc
  ) {
    id
    amount
    timestamp
  }
}
"""

_COMPOUND_REPAY_QUERY = """
query CompoundRepays($user: String!, $skip: Int!) {
  supplyEvents(
    first: 1000
    skip: $skip
    where: { account: $user }
    orderBy: timestamp
    orderDirection: asc
  ) {
    id
    amount
    timestamp
  }
}
"""

_COMPOUND_LIQUIDATION_QUERY = """
query CompoundLiquidations($user: String!, $skip: Int!) {
  liquidationEvents(
    first: 1000
    skip: $skip
    where: { account: $user }
  ) {
    id
    timestamp
  }
}
"""


async def _fetch_compound_data(
    client: httpx.AsyncClient,
    address: str,
) -> dict[str, Any]:
    """Return raw Compound III stats; falls back to empty defaults."""
    user = address.lower()
    result: dict[str, Any] = {
        "borrow_count": 0,
        "repay_count": 0,
        "liquidation_count": 0,
    }

    # --- borrows -------------------------------------------------------------
    try:
        skip = 0
        total = 0
        while True:
            data = await _gql(
                client,
                COMPOUND_V3_BASE_URL,
                _COMPOUND_BORROW_QUERY,
                {"user": user, "skip": skip},
            )
            batch = data.get("borrowEvents", [])
            total += len(batch)
            if len(batch) < 1000:
                break
            skip += 1000
        result["borrow_count"] = total
    except Exception as exc:
        logger.warning("Compound borrow query failed for %s: %s", address, exc)

    # --- repays --------------------------------------------------------------
    try:
        skip = 0
        total = 0
        while True:
            data = await _gql(
                client,
                COMPOUND_V3_BASE_URL,
                _COMPOUND_REPAY_QUERY,
                {"user": user, "skip": skip},
            )
            batch = data.get("supplyEvents", [])
            total += len(batch)
            if len(batch) < 1000:
                break
            skip += 1000
        result["repay_count"] = total
    except Exception as exc:
        logger.warning("Compound repay query failed for %s: %s", address, exc)

    # --- liquidations --------------------------------------------------------
    try:
        skip = 0
        total = 0
        while True:
            data = await _gql(
                client,
                COMPOUND_V3_BASE_URL,
                _COMPOUND_LIQUIDATION_QUERY,
                {"user": user, "skip": skip},
            )
            batch = data.get("liquidationEvents", [])
            total += len(batch)
            if len(batch) < 1000:
                break
            skip += 1000
        result["liquidation_count"] = total
    except Exception as exc:
        logger.warning("Compound liquidation query failed for %s: %s", address, exc)

    return result


# ---------------------------------------------------------------------------
# Uniswap V3 queries
# ---------------------------------------------------------------------------

_UNI_POSITIONS_QUERY = """
query UniPositions($owner: String!, $skip: Int!) {
  positions(
    first: 1000
    skip: $skip
    where: { owner: $owner }
    orderBy: transaction__timestamp
    orderDirection: asc
  ) {
    id
    liquidity
    collectedFeesToken0
    collectedFeesToken1
    token0 { derivedETH decimals }
    token1 { derivedETH decimals }
    transaction { timestamp }
    pool { token0Price }
  }
}
"""

_UNI_MINTS_QUERY = """
query UniMints($origin: String!, $skip: Int!) {
  mints(
    first: 1000
    skip: $skip
    where: { origin: $origin }
    orderBy: timestamp
    orderDirection: asc
  ) {
    id
    timestamp
    amountUSD
    origin
  }
}
"""

_UNI_BURNS_QUERY = """
query UniBurns($origin: String!, $skip: Int!) {
  burns(
    first: 1000
    skip: $skip
    where: { origin: $origin }
    orderBy: timestamp
    orderDirection: asc
  ) {
    id
    timestamp
    amountUSD
    origin
  }
}
"""


async def _fetch_uniswap_data(
    client: httpx.AsyncClient,
    address: str,
) -> dict[str, Any]:
    """Return raw Uniswap V3 LP stats; falls back to empty defaults."""
    owner = address.lower()
    result: dict[str, Any] = {
        "lp_positions": 0,
        "lp_duration_days": 0.0,
        "lp_fees_earned_usd": 0.0,
        "panic_withdrawals": 0,
    }

    # --- positions -----------------------------------------------------------
    try:
        all_positions: list[dict] = []
        skip = 0
        while True:
            data = await _gql(
                client,
                UNISWAP_V3_BASE_URL,
                _UNI_POSITIONS_QUERY,
                {"owner": owner, "skip": skip},
            )
            batch = data.get("positions", [])
            all_positions.extend(batch)
            if len(batch) < 1000:
                break
            skip += 1000

        result["lp_positions"] = len(all_positions)

        # Fees earned — sum token fees converted via derivedETH (rough USD via $2k ETH)
        fees_usd = 0.0
        for pos in all_positions:
            try:
                f0 = float(pos.get("collectedFeesToken0") or 0)
                f1 = float(pos.get("collectedFeesToken1") or 0)
                eth0 = float((pos.get("token0") or {}).get("derivedETH") or 0)
                eth1 = float((pos.get("token1") or {}).get("derivedETH") or 0)
                fees_usd += (f0 * eth0 + f1 * eth1) * 2000.0
            except (TypeError, ValueError):
                pass
        result["lp_fees_earned_usd"] = fees_usd
    except Exception as exc:
        logger.warning("Uniswap positions query failed for %s: %s", address, exc)

    # --- mints & burns to compute duration and panic withdrawals -------------
    try:
        all_mints: list[dict] = []
        skip = 0
        while True:
            data = await _gql(
                client,
                UNISWAP_V3_BASE_URL,
                _UNI_MINTS_QUERY,
                {"origin": owner, "skip": skip},
            )
            batch = data.get("mints", [])
            all_mints.extend(batch)
            if len(batch) < 1000:
                break
            skip += 1000

        all_burns: list[dict] = []
        skip = 0
        while True:
            data = await _gql(
                client,
                UNISWAP_V3_BASE_URL,
                _UNI_BURNS_QUERY,
                {"origin": owner, "skip": skip},
            )
            batch = data.get("burns", [])
            all_burns.extend(batch)
            if len(batch) < 1000:
                break
            skip += 1000

        # Duration: average time between first mint and paired burn
        if all_mints:
            first_mint_ts = int(all_mints[0].get("timestamp", 0))
            now_ts = int(time.time())
            duration_sec = now_ts - first_mint_ts
            result["lp_duration_days"] = max(0.0, duration_sec / 86400.0)

        # Panic withdrawal heuristic:
        # A burn that happens within 24 hours of a matching mint is flagged.
        mint_timestamps = sorted(int(m.get("timestamp", 0)) for m in all_mints)
        burn_timestamps = sorted(int(b.get("timestamp", 0)) for b in all_burns)
        panic = 0
        for bts in burn_timestamps:
            # Check if any mint occurred within 24 hours before this burn
            for mts in mint_timestamps:
                if 0 <= bts - mts <= 86400:
                    panic += 1
                    break
        result["panic_withdrawals"] = panic

    except Exception as exc:
        logger.warning("Uniswap mints/burns query failed for %s: %s", address, exc)

    return result


# ---------------------------------------------------------------------------
# Wallet age via Web3 / block estimation
# ---------------------------------------------------------------------------


async def _estimate_wallet_age_days(address: str) -> int:
    """
    Attempt to estimate wallet age in days.

    Strategy:
    1. If WEB3_RPC_URL / RPC_URL env var is set, use web3.py to find the
       earliest transaction block for the address via eth_getTransactionCount
       and binary-search heuristic.
    2. Fall back to 0 if Web3 is unavailable or the call fails.

    This is a best-effort estimate; accuracy depends on the RPC endpoint.
    """
    import os

    rpc_url = os.environ.get("RPC_URL") or os.environ.get("WEB3_RPC_URL")
    if not rpc_url:
        logger.debug("No RPC_URL set — skipping wallet age estimation.")
        return 0

    try:
        from web3 import AsyncHTTPProvider, AsyncWeb3  # type: ignore[attr-defined]

        w3 = AsyncWeb3(AsyncHTTPProvider(rpc_url))
        checksum = AsyncWeb3.to_checksum_address(address)

        # Get current block
        latest_block = await w3.eth.get_block("latest")  # type: ignore[misc]
        current_block_number: int = latest_block["number"]  # type: ignore[index]
        current_ts: int = latest_block["timestamp"]  # type: ignore[index]

        # Approximate seconds per block on Base (~2 seconds)
        BLOCK_TIME = 2

        # We do a binary search to find the earliest block where the tx count
        # is non-zero, using a bounded search window (last 3 years ~ 47M blocks)
        nonce = await w3.eth.get_transaction_count(checksum, "latest")  # type: ignore[misc]
        if nonce == 0:
            # Never sent a transaction from this address
            return 0

        # Estimate first-tx block using a coarse binary search
        # (we cap search range to 3 years of Base blocks)
        three_years_blocks = int(3 * 365 * 24 * 3600 / BLOCK_TIME)
        lo = max(1, current_block_number - three_years_blocks)
        hi = current_block_number

        while lo < hi:
            mid = (lo + hi) // 2
            try:
                nonce_at_mid = await w3.eth.get_transaction_count(  # type: ignore[misc]
                    checksum, mid
                )
                if nonce_at_mid == 0:
                    lo = mid + 1
                else:
                    hi = mid
            except Exception:
                break

        # Fetch the timestamp at the estimated earliest block
        try:
            block = await w3.eth.get_block(lo)  # type: ignore[misc]
            first_tx_ts: int = block["timestamp"]  # type: ignore[index]
            age_seconds = current_ts - first_tx_ts
            return max(0, int(age_seconds / 86400))
        except Exception:
            return 0

    except Exception as exc:
        logger.warning("Wallet age estimation failed for %s: %s", address, exc)
        return 0


# ---------------------------------------------------------------------------
# Protocol interaction counter
# ---------------------------------------------------------------------------


def _count_unique_protocols(
    aave: dict[str, Any],
    compound: dict[str, Any],
    uniswap: dict[str, Any],
) -> int:
    """
    Return how many distinct protocols the wallet has genuinely interacted with.
    Each protocol contributes at most 1 to the count.
    Additional weight is given to cross-protocol breadth (each sub-activity
    counts as a separate interaction point up to a max of 10 per protocol).
    """
    interactions = 0

    # Aave
    aave_events = aave.get("borrow_count", 0) + aave.get("repay_count", 0)
    if aave_events > 0:
        interactions += min(10, aave_events)

    # Compound
    comp_events = compound.get("borrow_count", 0) + compound.get("repay_count", 0)
    if comp_events > 0:
        interactions += min(10, comp_events)

    # Uniswap
    uni_positions = uniswap.get("lp_positions", 0)
    if uni_positions > 0:
        interactions += min(10, uni_positions)

    return interactions


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def fetch_wallet_data(address: str) -> WalletOnChainData:
    """
    Fetch on-chain DeFi activity for *address* and return a
    :class:`WalletOnChainData` instance.

    Never raises — if all queries fail, returns a zero-filled record.

    Parameters
    ----------
    address:
        Ethereum wallet address (checksummed or lowercase).

    Returns
    -------
    WalletOnChainData
    """
    data = WalletOnChainData()

    async with httpx.AsyncClient(
        headers={"Content-Type": "application/json"},
        follow_redirects=True,
    ) as client:
        # Fire all three subgraph fetches + wallet age concurrently
        aave_task = asyncio.create_task(_fetch_aave_data(client, address))
        compound_task = asyncio.create_task(_fetch_compound_data(client, address))
        uniswap_task = asyncio.create_task(_fetch_uniswap_data(client, address))
        age_task = asyncio.create_task(_estimate_wallet_age_days(address))

        aave_raw, compound_raw, uniswap_raw, wallet_age = await asyncio.gather(
            aave_task,
            compound_task,
            uniswap_task,
            age_task,
            return_exceptions=False,
        )

    # ── Aave ─────────────────────────────────────────────────────────────────
    data.aave_borrow_count = aave_raw.get("borrow_count", 0)
    data.aave_borrow_volume_usd = aave_raw.get("borrow_volume_usd", 0.0)
    data.aave_repay_count = aave_raw.get("repay_count", 0)
    data.aave_repay_volume_usd = aave_raw.get("repay_volume_usd", 0.0)
    data.aave_health_factor = aave_raw.get("health_factor", 999.0)

    # Repayment rate: repaid USD / borrowed USD (capped at 1.0)
    if data.aave_borrow_volume_usd > 0:
        data.aave_repayment_rate = min(
            1.0,
            data.aave_repay_volume_usd / data.aave_borrow_volume_usd,
        )
    else:
        data.aave_repayment_rate = 0.0

    # Days since first Aave interaction
    first_ts = aave_raw.get("first_interaction_ts")
    if first_ts:
        age_sec = int(time.time()) - int(first_ts)
        data.aave_first_interaction_days = max(0, int(age_sec / 86400))
    else:
        data.aave_first_interaction_days = 0

    # ── Compound ─────────────────────────────────────────────────────────────
    data.compound_borrow_count = compound_raw.get("borrow_count", 0)
    data.compound_repay_count = compound_raw.get("repay_count", 0)
    data.compound_liquidation_count = compound_raw.get("liquidation_count", 0)

    if data.compound_borrow_count > 0:
        data.compound_repayment_rate = min(
            1.0,
            data.compound_repay_count / data.compound_borrow_count,
        )
    else:
        data.compound_repayment_rate = 0.0

    # ── Uniswap ──────────────────────────────────────────────────────────────
    data.uniswap_lp_positions = uniswap_raw.get("lp_positions", 0)
    data.uniswap_lp_duration_days = uniswap_raw.get("lp_duration_days", 0.0)
    data.uniswap_lp_fees_earned_usd = uniswap_raw.get("lp_fees_earned_usd", 0.0)
    data.uniswap_panic_withdrawals = uniswap_raw.get("panic_withdrawals", 0)

    # ── General ──────────────────────────────────────────────────────────────
    data.wallet_age_days = wallet_age
    data.total_liquidation_count = (
        data.compound_liquidation_count
        # Aave liquidations would be tracked here too if queried separately
    )
    data.unique_protocol_interactions = _count_unique_protocols(
        aave_raw, compound_raw, uniswap_raw
    )

    # eth_balance is left at 0.0; can be populated by the caller via Web3 if
    # desired, but we avoid a blocking call here
    data.eth_balance = 0.0

    logger.debug(
        "fetch_wallet_data(%s) → borrows=%d repays=%d hf=%.2f age=%d days",
        address,
        data.aave_borrow_count,
        data.aave_repay_count,
        data.aave_health_factor,
        data.wallet_age_days,
    )

    return data
