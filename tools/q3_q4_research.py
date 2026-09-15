#!/usr/bin/env python3
"""Analyze the evidence needed for Q-003 and Q-004.

This tool is deliberately offline and read-only. It consumes research CSV files
already produced by ``mt5_data_collector.py`` and writes a JSON report. It does
not connect to MT5, place orders, or turn measured percentiles into approved
production limits.

Q-003:
    Quantifies quote-skew/stale-quote evidence and reports candidate thresholds.
    Orphan-leg timeout and margin-stress multiplier remain explicitly
    ``insufficient_data`` until execution trials and stress scenarios exist.

Q-004:
    Summarizes matched-pair holding durations and basis/P&L outcomes. Optional
    censored rows can be supplied to avoid treating currently-open positions as
    completed convergence events.

Example:
    python tools/q3_q4_research.py \
        --basis-csv research/2026-09-15T181953Z/basis_synchronized.csv \
        --pairs-csv research/2026-09-15T181429Z/reconciled_pairs.csv
"""

from __future__ import annotations

import argparse
import json
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pandas as pd


DEFAULT_STALE_THRESHOLDS_MS = (100, 200, 300, 400, 500)


def finite_values(series: pd.Series) -> pd.Series:
    values = pd.to_numeric(series, errors="coerce")
    return values[values.notna() & values.map(math.isfinite)]


def stats(series: pd.Series) -> dict[str, Any]:
    values = finite_values(series)
    if values.empty:
        return {"n": 0, "status": "insufficient_data"}
    return {
        "n": int(values.size),
        "min": round(float(values.min()), 4),
        "p05": round(float(values.quantile(0.05)), 4),
        "p25": round(float(values.quantile(0.25)), 4),
        "median": round(float(values.quantile(0.50)), 4),
        "p75": round(float(values.quantile(0.75)), 4),
        "p95": round(float(values.quantile(0.95)), 4),
        "p99": round(float(values.quantile(0.99)), 4),
        "max": round(float(values.max()), 4),
        "mean": round(float(values.mean()), 4),
        "std": round(float(values.std()), 4),
    }


def load_csv(path: Path, required_columns: set[str]) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(f"Input file does not exist: {path}")
    frame = pd.read_csv(path)
    missing = required_columns - set(frame.columns)
    if missing:
        raise ValueError(f"{path} is missing required columns: {sorted(missing)}")
    return frame


def analyze_q3(basis: pd.DataFrame, stale_thresholds_ms: tuple[int, ...]) -> dict[str, Any]:
    skew = finite_values(basis["quote_skew_ms"])
    if skew.empty:
        return {
            "status": "insufficient_data",
            "quote_skew_ms": stats(basis["quote_skew_ms"]),
            "stale_rates": {},
            "candidate_limits": {},
            "orphan_leg_timeout": {
                "status": "insufficient_data",
                "reason": "No signal-to-fill or orphan-leg execution trial data was supplied.",
            },
            "margin_stress_multiplier": {
                "status": "insufficient_data",
                "reason": "No account-equity, margin, or adverse-price stress scenarios were supplied.",
            },
        }

    stale_rates = {
        str(threshold): {
            "rows_over_threshold": int((skew > threshold).sum()),
            "fraction_over_threshold": round(float((skew > threshold).mean()), 6),
        }
        for threshold in stale_thresholds_ms
    }
    q = stats(skew)
    return {
        "status": "measured_quote_skew_only",
        "quote_skew_ms": q,
        "stale_rates": stale_rates,
        "candidate_limits": {
            "quote_staleness_threshold_ms": {
                "p95_candidate": q["p95"],
                "p99_candidate": q["p99"],
                "status": "research_candidate_only",
                "reason": "Candidates describe this post-hoc merge sample; they are not approved live limits.",
            }
        },
        "orphan_leg_timeout": {
            "status": "insufficient_data",
            "reason": "Closed trade durations do not measure signal-to-fill or orphan-leg resolution latency.",
        },
        "margin_stress_multiplier": {
            "status": "insufficient_data",
            "reason": "A margin multiplier requires account-equity and adverse-price stress scenarios.",
        },
    }


def analyze_q4(pairs: pd.DataFrame, censored: pd.DataFrame | None) -> dict[str, Any]:
    required_columns = {"duration_hours", "basis_change", "net_pnl"}
    if not required_columns.issubset(pairs.columns):
        censored_count = 0 if censored is None else len(censored)
        return {
            "status": "insufficient_data",
            "completed_pairs": 0,
            "censored_observations": censored_count,
            "duration_hours": stats(pd.Series(dtype=float)),
            "note": "The pair reconciler returned no matched-pair rows in the selected window.",
        }

    completed = pairs.copy()
    completed["duration_hours"] = pd.to_numeric(completed["duration_hours"], errors="coerce")
    completed = completed[completed["duration_hours"].notna() & (completed["duration_hours"] >= 0)]

    censored_count = 0
    censored_duration = []
    if censored is not None and not censored.empty:
        if "duration_hours" not in censored.columns:
            raise ValueError("Censored input must contain duration_hours")
        values = pd.to_numeric(censored["duration_hours"], errors="coerce")
        values = values[values.notna() & (values >= 0)]
        censored_duration = [round(float(value), 4) for value in values]
        censored_count = len(censored_duration)

    if completed.empty:
        return {
            "status": "insufficient_data",
            "completed_pairs": 0,
            "censored_observations": censored_count,
            "duration_hours": stats(pd.Series(dtype=float)),
        }

    duration = stats(completed["duration_hours"])
    result: dict[str, Any] = {
        "status": "provisional_closed_sample",
        "completed_pairs": int(len(completed)),
        "censored_observations": censored_count,
        "duration_hours": duration,
        "basis_change": stats(completed["basis_change"]),
        "net_pnl": stats(completed["net_pnl"]),
        "profitable_pairs": int((pd.to_numeric(completed["net_pnl"], errors="coerce") > 0).sum()),
        "loss_making_pairs": int((pd.to_numeric(completed["net_pnl"], errors="coerce") < 0).sum()),
        "censoring_note": (
            "Completed rows are observed exits. Censored rows represent positions still open at the observation "
            "cutoff and must not be treated as convergence events. No survival-model estimate is claimed by this "
            "descriptive report."
        ),
    }
    if censored_duration:
        result["censored_duration_hours"] = censored_duration
    result["conclusion"] = (
        "Provisional only: this describes the supplied sample and does not establish the pair's expected "
        "holding period or multi-week convergence distribution."
    )
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Offline Q-003 and Q-004 evidence analyzer.")
    parser.add_argument("--basis-csv", type=Path, required=True, help="basis_synchronized.csv from a tick run")
    parser.add_argument("--pairs-csv", type=Path, required=True, help="reconciled_pairs.csv from a pair run")
    parser.add_argument(
        "--censored-csv",
        type=Path,
        help="Optional CSV with duration_hours for open/censored observations at the cutoff",
    )
    parser.add_argument(
        "--stale-threshold-ms",
        type=int,
        nargs="+",
        default=list(DEFAULT_STALE_THRESHOLDS_MS),
        help="Thresholds used for stale-rate reporting (default: 100 200 300 400 500)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="JSON output path (default: sibling q3_q4_report.json beside basis CSV)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    basis = load_csv(args.basis_csv, {"quote_skew_ms"})
    pairs = load_csv(args.pairs_csv, {"duration_hours", "basis_change", "net_pnl"})
    censored = load_csv(args.censored_csv, {"duration_hours"}) if args.censored_csv else None

    report = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "inputs": {
            "basis_csv": str(args.basis_csv),
            "pairs_csv": str(args.pairs_csv),
            "censored_csv": str(args.censored_csv) if args.censored_csv else None,
        },
        "Q_003": analyze_q3(basis, tuple(args.stale_threshold_ms)),
        "Q_004": analyze_q4(pairs, censored),
        "research_gate": "Evidence report only; no production thresholds or trading decision are approved.",
    }
    output = args.output or args.basis_csv.parent / "q3_q4_report.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"\nReport written to: {output}")


if __name__ == "__main__":
    main()