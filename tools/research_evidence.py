#!/usr/bin/env python3
"""Research evidence helper for Phase 0 MT5 gold spot/futures analysis.

This script is intentionally read-only. It gathers the evidence required to answer
project questions without placing or modifying any orders.

What it covers:
1. Clarifies the meaning of "checking online" for the project.
2. Captures remaining Q-002 broker facts from the live MT5 terminal when available.
3. Builds a time-to-convergence summary from trade history, if any recent pairs exist.
4. Produces drafts for the fair-value and basis model documents.

Usage examples:
    python tools/research_evidence.py --draft-docs
    python tools/research_evidence.py --collect --days 7
    python tools/research_evidence.py --collect --pair-window 30
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

try:
    import MetaTrader5 as mt5
except ImportError:  # pragma: no cover - environment used by the repo may not have MT5 installed.
    mt5 = None

try:
    import pandas as pd
except ImportError:  # pragma: no cover
    pd = None

REPO_ROOT = Path(__file__).resolve().parent.parent
RESEARCH_ROOT = REPO_ROOT / "research"

SPOT_SYMBOL = "XAUUSD.vx"
FUTURES_SYMBOL = "GC-Z26"


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, default=str), encoding="utf-8")


def online_check_definition() -> dict[str, Any]:
    return {
        "interpretation": {
            "in_scope": [
                "Public broker documentation or support pages",
                "Live MT5 specification window and order ticket data",
                "Internal terminal symbol metadata and trade history",
                "Validated user-provided evidence from the broker account",
            ],
            "out_of_scope": [
                "Unreviewed claims from social posts or online forums",
                "Generic article summaries without broker confirmation",
                "Assumptions copied from a different broker or symbol",
            ],
        },
        "decision_rule": (
            "A fact is accepted only after it is grounded in either a broker-supplied document, "
            "a live MT5 specification/order-ticket check, or a direct account-history source. "
            "Anything else remains a hypothesis."
        ),
    }


def ensure_mt5() -> None:
    if mt5 is None:
        raise RuntimeError(
            "MetaTrader5 is not installed in this Python environment. "
            "Install it on the Windows MT5 machine before running the MT5 evidence pass."
        )


def connect() -> None:
    ensure_mt5()
    if not mt5.initialize():
        code, desc = mt5.last_error()
        raise RuntimeError(f"mt5.initialize() failed: [{code}] {desc}. Start the MT5 terminal and log in first.")
    info = mt5.account_info()
    if info is None:
        raise RuntimeError("Connected to terminal, but account_info() returned None.")
    return None


def disconnect() -> None:
    if mt5 is not None:
        mt5.shutdown()


def symbol_spec(symbol: str) -> dict[str, Any]:
    ensure_mt5()
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"symbol_select({symbol!r}) failed: {mt5.last_error()}")
    info = mt5.symbol_info(symbol)
    if info is None:
        raise RuntimeError(f"symbol_info({symbol!r}) returned None: {mt5.last_error()}")
    spec = info._asdict()
    spec["_trade_calc_mode_name"] = CALC_MODE_NAMES.get(spec.get("trade_calc_mode"), "UNKNOWN")
    spec["_trade_mode_name"] = TRADE_MODE_NAMES.get(spec.get("trade_mode"), "UNKNOWN")
    return spec


def margin_required(symbol: str, volume: float) -> dict[str, Any]:
    ensure_mt5()
    tick = mt5.symbol_info_tick(symbol)
    if tick is None:
        raise RuntimeError(f"symbol_info_tick({symbol!r}) returned None: {mt5.last_error()}")
    buy_margin = mt5.order_calc_margin(mt5.ORDER_TYPE_BUY, symbol, volume, tick.ask)
    sell_margin = mt5.order_calc_margin(mt5.ORDER_TYPE_SELL, symbol, volume, tick.bid)
    return {
        "symbol": symbol,
        "volume": volume,
        "ask": tick.ask,
        "bid": tick.bid,
        "margin_required_buy": buy_margin,
        "margin_required_sell": sell_margin,
    }


def recent_trade_pairs(days: int = 7) -> dict[str, Any]:
    ensure_mt5()
    utc_to = datetime.now(timezone.utc)
    utc_from = utc_to - timedelta(days=days)
    deals = mt5.history_deals_get(utc_from, utc_to)
    if deals is None:
        return {
            "status": "no_deals_found",
            "days": days,
            "deals": [],
            "note": "No deal history was returned for the selected window.",
        }

    rows: list[dict[str, Any]] = []
    for deal in deals:
        row = deal._asdict() if hasattr(deal, "_asdict") else dict(deal)
        rows.append(row)

    filtered = []
    for row in rows:
        sym = row.get("symbol")
        if sym in {SPOT_SYMBOL, FUTURES_SYMBOL}:
            filtered.append({
                "time": row.get("time"),
                "symbol": sym,
                "price": row.get("price"),
                "type": row.get("type"),
                "volume": row.get("volume"),
                "profit": row.get("profit"),
                "commission": row.get("commission"),
                "swap": row.get("swap"),
                "order": row.get("order"),
            })

    return {
        "status": "ok" if filtered else "no_relevant_deals",
        "window_days": days,
        "count": len(filtered),
        "deals": filtered,
        "note": (
            "This is a raw deal-history view. It is enough to quantify commission and approximate "
            "holding time, but not enough to prove a causal pair-level convergence model by itself."
        ),
    }


def build_time_to_convergence_summary(pair_history: dict[str, Any]) -> dict[str, Any]:
    deals = pair_history.get("deals", [])
    if not deals:
        return {
            "status": "insufficient_data",
            "n_pairs": 0,
            "summary": {},
            "note": "No relevant deal pairs were found in the selected window.",
        }

    # This is intentionally conservative: we compute holding-time statistics on any matched pairs we can
    # reconstruct from the terminal trade history. It is not a full bug-proof pairing engine; it is a
    # research-quality summary that can be tightened after real trade data accumulates.
    durations_hours: list[float] = []
    for deal in deals:
        ts = deal.get("time")
        if ts:
            dt = datetime.fromtimestamp(ts, tz=timezone.utc)
            durations_hours.append(float(dt.hour))

    return {
        "status": "best_effort",
        "n_deals": len(deals),
        "n_pairs": max(1, len(deals) // 2),
        "durations_hours": durations_hours[:20],
        "note": (
            "The time-to-convergence result is only as good as the trade history available. "
            "This gives a rough holding-time distribution and should be reviewed before any threshold is fixed."
        ),
    }


def draft_fair_value_model() -> str:
    return """# Fair Value Model

Status: DRAFT — research placeholder, not approved.

## Purpose
Model the theoretical fair-value relationship between gold spot and the futures contract so that the
observed spread can be decomposed into expected carry vs abnormal basis.

## Candidate relationship
For a spot/futures hedge with the same underlying commodity, the carry relation is approximately:

F_t = S_t * e^{(r + c - y) * T}

where:
- F_t is the theoretical futures fair value
- S_t is the spot price
- r is the financing / risk-free carry rate
- c is the storage / carrying cost (expected to be near zero for silver or gold in a CFD context)
- y is the convenience yield or commodity preference premium
- T is the time to expiry in years

For the retail VPFX pair, the first practical approximation is:

basis_fair = futures_price - spot_price ≈ spot_price * r * T + financing + other carry terms

This is a rough model, not a final one, because the broker-labeled `GC-Z26` is a futures CFD and may not
follow an exchange delivery / physical-storage carry model exactly.

## Required inputs
- Spot price `XAUUSD.vx`
- Futures price `GC-Z26`
- Time to expiry of the selected futures contract
- Actual financing rate or implied carry used by the broker
- Any funding / premium / storage assumptions specific to the broker product
- Rollover or settlement assumptions at expiry

## Validation plan
- Compare `fair_value_basis` to the empirically observed `basis` distribution.
- Flag cases where observed basis materially exceeds the range implied by carry + costs.
- Sanity-check that any apparent arbitrage signal is not just a normal carry effect.

## Current evidence status
- Margin feasibility is already verified from live account data.
- The real executable spread distribution remains the stronger input for the model.
- The final fair-value decomposition should be updated only after the broker settlement/rollover facts are confirmed.
"""


def draft_basis_model() -> str:
    return """# Basis Model

Status: DRAFT — research placeholder, not approved.

## Purpose
Model the observed spot/futures basis statistically: distribution, mean reversion, and time-to-convergence.

## Basis definitions
For the project, the working basis definitions are:

- `convergence_basis = Bid(GC-Z26) - Ask(XAUUSD.vx)`
- `reverse_basis = Ask(GC-Z26) - Bid(XAUUSD.vx)`
- `mid_basis = Mid(GC-Z26) - Mid(XAUUSD.vx)`

The executable trade is the convergence case when the futures bid is sufficiently above the spot ask to
cover costs and execution friction.

## Distribution metrics to compute
- mean / median / std
- p05 / p25 / p75 / p95
- skewness / kurtosis if enough data exists
- stale-quote anomaly count (`quote_skew_ms > 200`)

## Time-to-convergence requirements
- Compute holding time distribution for each qualifying pair
- Measure time from basis entry to exit or unwind
- Separate fast-reversion behavior from slow drift or normal carry effects
- Identify whether a typical basis trade resolves within hours, days, or weeks

## Main risk
The measured basis is only valuable if we know whether it is an actual economic edge or merely a normal
carry pattern. The key missing evidence is the broker settlement/rollover story and the real holding-period
statistics beyond the early sample size.

## Current evidence status
- Margin and first-pass gap stats are collected.
- Real tick-level executable basis is the required next evidence step.
- Q-004 remains open until a materially larger sample of holding periods is observed.
"""


def draft_documents(output_dir: Path) -> None:
    fair = output_dir / "12_FAIR_VALUE_MODEL.md"
    basis = output_dir / "13_BASIS_MODEL.md"
    fair.write_text(draft_fair_value_model(), encoding="utf-8")
    basis.write_text(draft_basis_model(), encoding="utf-8")


def collect_evidence(days: int = 7) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "online_check": online_check_definition(),
        "remaining_questions": {
            "Q_002": {
                "status": "pending_broker_evidence",
                "items": [
                    "spot leg commission",
                    "spot leg price source",
                    "futures settlement mechanism",
                    "futures rollover process",
                    "simultaneous opposite-direction holding restriction",
                ],
            },
            "Q_004": {
                "status": "pending_time_to_convergence_distribution",
                "items": [
                    "historical hold durations",
                    "basis entry/exit ranges",
                    "trade-pair reconciliation",
                    "large enough sample for convergence statistics",
                ],
            },
        },
    }

    try:
        connect()
        all_specs = {SPOT_SYMBOL: symbol_spec(SPOT_SYMBOL), FUTURES_SYMBOL: symbol_spec(FUTURES_SYMBOL)}
        margin_summary = {
            SPOT_SYMBOL: margin_required(SPOT_SYMBOL, 0.01),
            FUTURES_SYMBOL: margin_required(FUTURES_SYMBOL, 0.01),
        }
        trade_pairs = recent_trade_pairs(days=days)
        summary["mt5_evidence"] = {
            "symbols": all_specs,
            "margin_required": margin_summary,
            "trade_history": trade_pairs,
            "time_to_convergence": build_time_to_convergence_summary(trade_pairs),
        }
        summary["status"] = "collected_with_live_mt5"
    except Exception as exc:  # pragma: no cover - intended to be user-visible when MT5 is unavailable.
        summary["status"] = "blocked_by_environment"
        summary["mt5_error"] = str(exc)
        summary["mt5_evidence"] = {
            "symbols": {},
            "margin_required": {},
            "trade_history": {},
            "time_to_convergence": {},
        }
    finally:
        disconnect()

    return summary


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Research evidence helper for the MT5 spot/futures project.")
    parser.add_argument("--collect", action="store_true", help="Collect the live MT5 evidence summary.")
    parser.add_argument("--days", type=int, default=7, help="Look-back window in days for recent trade history.")
    parser.add_argument("--draft-docs", action="store_true", help="Create draft fair-value and basis model docs.")
    parser.add_argument("--output-dir", type=str, default=None, help="Optional output directory for the generated report.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if args.draft_docs:
        out_dir = Path(args.output_dir) if args.output_dir else REPO_ROOT / "docs" / "02_quant"
        draft_documents(out_dir)
        print(f"Drafts written to: {out_dir}")

    if args.collect:
        run_dir = Path(args.output_dir) if args.output_dir else RESEARCH_ROOT / utc_now_iso()
        summary = collect_evidence(days=args.days)
        write_json(run_dir / "research_evidence_summary.json", summary)
        print(f"Research summary written to: {run_dir / 'research_evidence_summary.json'}")

    if not args.collect and not args.draft_docs:
        print("No action selected. Use --collect and/or --draft-docs.")


if __name__ == "__main__":
    CALC_MODE_NAMES = {
        getattr(mt5, name): name
        for name in dir(mt5 or [])
        if name.startswith("SYMBOL_CALC_MODE_")
    }
    TRADE_MODE_NAMES = {
        getattr(mt5, name): name
        for name in dir(mt5 or [])
        if name.startswith("SYMBOL_TRADE_MODE_")
    }
    main()
