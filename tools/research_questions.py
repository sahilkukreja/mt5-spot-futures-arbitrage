#!/usr/bin/env python3
"""Collect evidence for Q-002, Q-003, and Q-004 from a running MT5 terminal.

This is a read-only research tool. It never calls order_send(), order_check(),
position modification, or any other trading operation. It writes working data
under research/<UTC timestamp>/; promote conclusions into docs only after review.

The script collects:
- symbol specifications and calculated margin for both legs (Q-002/Q-003)
- optional historical bid/ask ticks and synchronized executable basis (Q-003)
- closed trade pairs and currently open positions as censored observations (Q-004)
- provenance for official MetaTrader Python API references (not broker facts)

Examples:
    python tools/research_questions.py --days 7 --ticks --fetch-references
    python tools/research_questions.py --days 30 --attempts 3 --retry-delay 10
"""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import pandas as pd

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = REPO_ROOT / "research"
SPOT_SYMBOL = "XAUUSD.vx"
FUTURES_SYMBOL = "GC-Z26"
DEFAULT_REFERENCES = (
    "https://www.mql5.com/en/docs/python_metatrader5",
    "https://www.mql5.com/en/docs/python_metatrader5/mt5copyticksrange_py",
    "https://www.mql5.com/en/docs/python_metatrader5/mt5historydealsget_py",
    "https://www.mql5.com/en/docs/python_metatrader5/mt5ordercalcmargin_py",
)


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, default=str), encoding="utf-8")


def load_existing_tools() -> tuple[Any, Any]:
    """Load existing read-only collectors without duplicating their MT5 logic."""
    try:
        collector = importlib.import_module("mt5_data_collector")
        analyzer = importlib.import_module("q3_q4_research")
    except (ImportError, SystemExit) as exc:
        raise RuntimeError(
            "Collector dependencies are unavailable. Install MetaTrader5 and pandas, "
            "then run this script on Windows with MT5 running and logged in."
        ) from exc
    return collector, analyzer


def retry(label: str, action: Callable[[], Any], attempts: int, delay: float) -> Any:
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            result = action()
            if result is not None:
                return result
            raise RuntimeError(f"{label} returned no data")
        except Exception as exc:  # Report every failed attempt, then preserve the cause.
            last_error = exc
            print(f"{label}: attempt {attempt}/{attempts} failed: {exc}", file=sys.stderr)
            if attempt < attempts and delay > 0:
                time.sleep(delay)
    raise RuntimeError(f"{label} failed after {attempts} attempt(s): {last_error}") from last_error


def fetch_reference(url: str, timeout: float) -> dict[str, Any]:
    request = Request(url, headers={"User-Agent": "mt5-spot-futures-arbitrage-research/1.0"})
    try:
        with urlopen(request, timeout=timeout) as response:
            body = response.read()
            text = body.decode("utf-8", errors="replace")
            title_match = re.search(r"<title[^>]*>(.*?)</title>", text, flags=re.I | re.S)
            title = re.sub(r"\s+", " ", title_match.group(1)).strip() if title_match else None
            return {
                "url": url,
                "status": "fetched",
                "http_status": response.status,
                "title": title,
                "bytes": len(body),
                "sha256": hashlib.sha256(body).hexdigest(),
                "note": "Official API reference provenance only; not broker-specific evidence.",
            }
    except (HTTPError, URLError, TimeoutError, OSError) as exc:
        return {"url": url, "status": "unavailable", "error": str(exc)}


def reference_manifest(urls: list[str], fetch: bool, timeout: float) -> dict[str, Any]:
    entries = [fetch_reference(url, timeout) if fetch else {
        "url": url,
        "status": "not_fetched",
        "note": "Reference URL recorded for review; no broker fact is inferred from it.",
    } for url in urls]
    return {
        "purpose": "Reference provenance for collection APIs and read-only calculations.",
        "broker_facts": "Must come from the live MT5 terminal or VPFX documentation/support.",
        "references": entries,
    }


def serialize_positions(mt5: Any, symbols: set[str]) -> pd.DataFrame:
    rows: list[dict[str, Any]] = []
    positions = mt5.positions_get()
    if positions is None:
        return pd.DataFrame(columns=["position_id", "symbol", "duration_hours"])
    now = datetime.now(timezone.utc)
    for position in positions:
        row = position._asdict()
        if row.get("symbol") not in symbols:
            continue
        opened = datetime.fromtimestamp(row["time"], tz=timezone.utc)
        rows.append({
            "position_id": row.get("ticket"),
            "symbol": row.get("symbol"),
            "volume": row.get("volume"),
            "open_time": opened.isoformat(),
            "duration_hours": round((now - opened).total_seconds() / 3600, 4),
            "price_open": row.get("price_open"),
            "price_current": row.get("price_current"),
            "profit": row.get("profit"),
        })
    return pd.DataFrame(rows)


def collect(args: argparse.Namespace, run_dir: Path) -> dict[str, Any]:
    collector, analyzer = load_existing_tools()
    collector.connect()
    try:
        specs = {symbol: collector.dump_symbol_spec(symbol) for symbol in (SPOT_SYMBOL, FUTURES_SYMBOL)}
        margins = {
            symbol: collector.margin_required(symbol, args.volume)
            for symbol in (SPOT_SYMBOL, FUTURES_SYMBOL)
        }
        write_json(run_dir / "symbol_specs.json", specs)
        write_json(run_dir / "margin_required.json", margins)

        utc_to = datetime.now(timezone.utc)
        utc_from = utc_to - timedelta(days=args.days)
        spot_trades = retry(
            f"closed trades {SPOT_SYMBOL}",
            lambda: collector.collect_closed_trades(SPOT_SYMBOL, utc_from, utc_to),
            args.attempts,
            args.retry_delay,
        )
        futures_trades = retry(
            f"closed trades {FUTURES_SYMBOL}",
            lambda: collector.collect_closed_trades(FUTURES_SYMBOL, utc_from, utc_to),
            args.attempts,
            args.retry_delay,
        )
        pairs, unmatched_spot, unmatched_futures = collector.reconcile_pairs(
            spot_trades, futures_trades, args.pair_tolerance_seconds
        )
        spot_trades.to_csv(run_dir / f"closed_trades_{SPOT_SYMBOL}.csv", index=False)
        futures_trades.to_csv(run_dir / f"closed_trades_{FUTURES_SYMBOL}.csv", index=False)
        pairs.to_csv(run_dir / "reconciled_pairs.csv", index=False)
        unmatched_spot.to_csv(run_dir / "unmatched_spot_trades.csv", index=False)
        unmatched_futures.to_csv(run_dir / "unmatched_futures_trades.csv", index=False)

        open_positions = serialize_positions(collector.mt5, {SPOT_SYMBOL, FUTURES_SYMBOL})
        open_positions.to_csv(run_dir / "open_positions_censored.csv", index=False)
        q4 = analyzer.analyze_q4(pairs, open_positions)

        q3: dict[str, Any] = {
            "status": "not_collected",
            "note": "Use --ticks to collect synchronized quote history for Q-003.",
        }
        if args.ticks:
            tick_from = utc_to - timedelta(days=args.tick_days)
            spot_ticks, futures_ticks = retry(
                "historical bid/ask ticks",
                lambda: collector.collect_tick_data(SPOT_SYMBOL, FUTURES_SYMBOL, tick_from, utc_to),
                args.attempts,
                args.retry_delay,
            )
            spot_ticks.to_csv(run_dir / f"ticks_{SPOT_SYMBOL}.csv", index=False)
            futures_ticks.to_csv(run_dir / f"ticks_{FUTURES_SYMBOL}.csv", index=False)
            basis = collector.compute_synchronized_basis(
                spot_ticks, futures_ticks, args.tolerance_ms
            )
            basis.to_csv(run_dir / "basis_synchronized.csv", index=False)
            basis_summary = collector.summarize_basis(basis, args.tolerance_ms)
            write_json(run_dir / "basis_summary.json", basis_summary)
            q3 = analyzer.analyze_q3(basis, tuple(args.stale_threshold_ms))

        return {
            "status": "collected_with_live_mt5",
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            "lookback_days": args.days,
            "tick_days": args.tick_days if args.ticks else None,
            "symbols": [SPOT_SYMBOL, FUTURES_SYMBOL],
            "margin_required": margins,
            "closed_pairs": int(len(pairs)),
            "open_positions_censored": int(len(open_positions)),
            "Q_003": q3,
            "Q_004": q4,
            "research_gate": "Evidence only; no thresholds, trading decision, or live approval is produced.",
        }
    finally:
        collector.disconnect()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Collect Q-002/Q-003/Q-004 MT5 research evidence.")
    parser.add_argument("--days", type=int, default=7, help="Trade-history lookback in days.")
    parser.add_argument("--ticks", action="store_true", help="Also fetch historical bid/ask ticks for Q-003.")
    parser.add_argument("--tick-days", type=int, default=7, help="Tick-history lookback in days.")
    parser.add_argument("--volume", type=float, default=0.01, help="Volume used for margin calculation.")
    parser.add_argument("--tolerance-ms", type=int, default=500, help="Tick merge tolerance in milliseconds.")
    parser.add_argument("--pair-tolerance-seconds", type=int, default=300, help="Open-time pair match tolerance.")
    parser.add_argument("--stale-threshold-ms", type=int, nargs="+", default=[100, 200, 300, 400, 500])
    parser.add_argument("--attempts", type=int, default=3, help="Attempts for MT5 history calls.")
    parser.add_argument("--retry-delay", type=float, default=5.0, help="Seconds between failed history attempts.")
    parser.add_argument("--fetch-references", action="store_true", help="Fetch official API reference metadata.")
    parser.add_argument("--reference-url", action="append", default=[], help="Additional reference URL.")
    parser.add_argument("--reference-timeout", type=float, default=15.0)
    parser.add_argument("--output-dir", type=Path, help="Output directory; default is research/<UTC timestamp>/.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.days < 1 or args.tick_days < 1 or args.attempts < 1:
        raise SystemExit("days, tick-days, and attempts must be positive")
    run_dir = args.output_dir or OUTPUT_ROOT / utc_stamp()
    run_dir.mkdir(parents=True, exist_ok=True)
    urls = list(dict.fromkeys((*DEFAULT_REFERENCES, *args.reference_url)))
    write_json(run_dir / "reference_manifest.json", reference_manifest(urls, args.fetch_references, args.reference_timeout))
    try:
        report = collect(args, run_dir)
    except Exception as exc:
        report = {
            "status": "blocked_by_environment_or_history",
            "error": str(exc),
            "research_gate": "No conclusion is produced when collection is incomplete.",
        }
        print(f"Collection failed: {exc}", file=sys.stderr)
    write_json(run_dir / "research_questions_summary.json", report)
    print(json.dumps(report, indent=2, default=str))
    print(f"\nResearch output: {run_dir}")


if __name__ == "__main__":
    main()
