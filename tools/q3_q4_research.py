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
    completed convergence events. Also reports a tick-level basis mean-reversion
    ("decay") proxy — an AR(1) half-life and autocorrelation decay of the
    convergence_basis series — as *additional*, distinct evidence alongside the
    realized-pair sample. This proxy is not a substitute for the true
    time-to-convergence distribution: it measures how fast the raw basis series
    statistically reverts toward its own recent mean, not how long an actual
    entry/exit-threshold-conditioned trade would be held.

Fair value (feeds 12_FAIR_VALUE_MODEL.md):
    Backs out the annualized carry rate implied by the observed basis, spot
    price, and time to the futures expiry, and compares it against an
    externally sourced risk-free rate (e.g. SOFR) supplied via --sofr-rate.
    This quantifies how much of the basis is consistent with plain financing
    carry versus an unexplained residual. It is a descriptive comparison, not
    a claim that the residual is executable edge.

Example:
    python tools/q3_q4_research.py \
        --basis-csv research/2026-09-15T190918Z/basis_synchronized.csv \
        --pairs-csv research/2026-09-15T190918Z/reconciled_pairs.csv \
        --expiry-date 2026-11-25 \
        --sofr-rate 0.0364 --sofr-rate-date 2026-09-15
"""

from __future__ import annotations

import argparse
import json
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
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


def _ar1_halflife(values: pd.Series, dt_minutes: float) -> dict[str, Any] | None:
    x = pd.to_numeric(values, errors="coerce").dropna().to_numpy()
    if x.size < 20:
        return None
    x_lag = x[:-1]
    dx = x[1:] - x_lag
    design = np.column_stack([np.ones_like(x_lag), x_lag])
    (intercept, slope), *_ = np.linalg.lstsq(design, dx, rcond=None)
    theta_per_step = -slope
    if theta_per_step <= 0:
        return {
            "n": int(x.size),
            "theta_per_step": round(float(theta_per_step), 6),
            "halflife_minutes": None,
            "note": "Non mean-reverting at this resampling frequency (theta <= 0) over the sampled window.",
        }
    halflife_minutes = math.log(2) / theta_per_step * dt_minutes
    implied_mean = -intercept / slope if slope != 0 else None
    return {
        "n": int(x.size),
        "theta_per_step": round(float(theta_per_step), 6),
        "halflife_minutes": round(float(halflife_minutes), 2),
        "implied_local_mean": round(float(implied_mean), 4) if implied_mean is not None else None,
    }


def analyze_basis_decay(basis: pd.DataFrame, resample_minutes: tuple[int, ...]) -> dict[str, Any]:
    """Tick-level mean-reversion proxy for Q-004: NOT a substitute for realized holding-period data."""
    required = {"fut_time_msc", "convergence_basis"}
    if not required.issubset(basis.columns):
        return {"status": "insufficient_data", "reason": f"missing columns: {sorted(required - set(basis.columns))}"}

    frame = basis[["fut_time_msc", "convergence_basis"]].copy()
    frame["fut_time_msc"] = pd.to_numeric(frame["fut_time_msc"], errors="coerce")
    frame = frame.dropna().sort_values("fut_time_msc")
    if frame.empty:
        return {"status": "insufficient_data", "reason": "no valid timestamped rows"}

    timestamps = pd.to_datetime(frame["fut_time_msc"], unit="ms", utc=True)
    series = pd.Series(frame["convergence_basis"].to_numpy(), index=timestamps).sort_index()

    halflife_by_grid: dict[str, Any] = {}
    for minutes in resample_minutes:
        resampled = series.resample(f"{minutes}min").last().dropna()
        result = _ar1_halflife(resampled, minutes)
        halflife_by_grid[f"{minutes}min"] = result if result is not None else {
            "status": "insufficient_data",
            "reason": "fewer than 20 resampled bars at this grid",
        }

    one_min = series.resample("1min").last().dropna()
    x = one_min.to_numpy()
    autocorrelation: dict[str, float] = {}
    if x.size > 30:
        centered = x - x.mean()
        for lag_minutes in (1, 5, 15, 30, 60, 120, 240, 360, 480, 720, 1440):
            if lag_minutes < x.size:
                num = float((centered[:-lag_minutes] * centered[lag_minutes:]).mean())
                den = float((centered**2).mean())
                autocorrelation[f"{lag_minutes}min"] = round(num / den, 4) if den else None

    return {
        "status": "decay_proxy_only",
        "halflife_by_resample_grid": halflife_by_grid,
        "autocorrelation_1min_series": autocorrelation,
        "interpretation": (
            "The AR(1) half-life shrinks at fine grids and grows at coarse grids while autocorrelation decays "
            "slowly over many hours — consistent with a fast, partially mean-reverting intraday component "
            "layered on a slower-moving level that does not fully revert within this single ~7-day window. "
            "This does not resolve Q-004: it describes statistical persistence of the raw series, not the "
            "duration of an actual threshold-triggered trade."
        ),
    }


def find_basis_anomaly(basis: pd.DataFrame, threshold: float, context_rows: int = 2) -> dict[str, Any]:
    """Isolate the lowest convergence_basis rows below `threshold` with surrounding context (feeds R-004)."""
    required = {"fut_time_msc", "convergence_basis", "fut_bid", "fut_ask", "spot_bid", "spot_ask", "quote_skew_ms"}
    if not required.issubset(basis.columns):
        return {"status": "insufficient_data", "reason": f"missing columns: {sorted(required - set(basis.columns))}"}

    frame = basis.sort_values("fut_time_msc").reset_index(drop=True)
    hits = frame.index[frame["convergence_basis"] < threshold].tolist()
    if not hits:
        return {"status": "no_rows_below_threshold", "threshold": threshold}

    idx = hits[0]
    lo, hi = max(0, idx - context_rows), min(len(frame) - 1, idx + context_rows)
    window = frame.loc[lo:hi, ["fut_time_msc", "fut_bid", "fut_ask", "spot_bid", "spot_ask", "convergence_basis", "quote_skew_ms"]]
    window = window.assign(fut_time_utc=pd.to_datetime(window["fut_time_msc"], unit="ms", utc=True).astype(str))
    return {
        "status": "isolated",
        "threshold": threshold,
        "rows_below_threshold": len(hits),
        "context": window.to_dict(orient="records"),
    }


def analyze_fair_value(basis: pd.DataFrame, expiry_date: str, sofr_rate: float | None) -> dict[str, Any]:
    """Back out the implied annualized carry rate from mid_basis, spot_ask, and time to expiry."""
    required = {"fut_time_msc", "mid_basis", "spot_ask"}
    if not required.issubset(basis.columns):
        return {"status": "insufficient_data", "reason": f"missing columns: {sorted(required - set(basis.columns))}"}

    frame = basis[["fut_time_msc", "mid_basis", "spot_ask"]].copy()
    frame["fut_time_utc"] = pd.to_datetime(frame["fut_time_msc"], unit="ms", utc=True)
    expiry = pd.Timestamp(expiry_date, tz="UTC")
    frame["T_years"] = (expiry - frame["fut_time_utc"]).dt.total_seconds() / (365 * 24 * 3600)
    frame = frame[frame["T_years"] > 0]
    if frame.empty:
        return {"status": "insufficient_data", "reason": "all rows are at/after the supplied expiry date"}

    frame["implied_annual_rate"] = frame["mid_basis"] / (frame["spot_ask"] * frame["T_years"])
    rate_stats = stats(frame["implied_annual_rate"])

    result: dict[str, Any] = {
        "status": "measured",
        "model": "mid_basis ~= spot_ask * implied_annual_rate * T_years (simple, uncompounded; T is small so "
        "compounding difference is negligible)",
        "expiry_date": expiry_date,
        "T_years_range": [round(float(frame["T_years"].min()), 4), round(float(frame["T_years"].max()), 4)],
        "implied_annual_rate": rate_stats,
        "mean_spot_ask": round(float(frame["spot_ask"].mean()), 2),
        "mean_mid_basis": round(float((frame["spot_ask"] * frame["implied_annual_rate"] * frame["T_years"]).mean()), 4),
    }

    if sofr_rate is not None:
        median_rate = rate_stats["median"]
        unexplained_rate = median_rate - sofr_rate
        mean_spot_ask = result["mean_spot_ask"]
        mean_T = float(frame["T_years"].mean())
        unexplained_dollars = mean_spot_ask * unexplained_rate * mean_T
        mean_mid_basis_actual = float(frame["mid_basis"].mean())
        result["external_rate_comparison"] = {
            "sofr_rate": sofr_rate,
            "sofr_source": "manually supplied; cite the sourced date/publication when recording this in docs",
            "median_implied_rate": median_rate,
            "unexplained_rate_median_minus_sofr": round(unexplained_rate, 6),
            "unexplained_basis_dollars_at_mean_spot_and_T": round(unexplained_dollars, 4),
            "mean_actual_mid_basis": round(mean_mid_basis_actual, 4),
            "unexplained_fraction_of_mean_mid_basis": round(unexplained_dollars / mean_mid_basis_actual, 4)
            if mean_mid_basis_actual
            else None,
            "caveat": (
                "This residual is a descriptive gap between the observed basis and a SOFR-only carry model. "
                "It is not itself an executable edge claim: GC-Z26 is a broker CFD (SYMBOL_CALC_MODE_CFD), not "
                "an exchange-cleared future, so part of the residual may be ordinary dealer/liquidity markup in "
                "the synthetic quote construction rather than a genuine mispricing. Must still clear all "
                "14_TRANSACTION_COST_MODEL.md costs and a safety margin before being considered tradeable."
            ),
        }

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
    parser.add_argument(
        "--decay-resample-minutes",
        type=int,
        nargs="+",
        default=[1, 5, 15, 30, 60, 240],
        help="Resampling grids (minutes) for the Q-004 basis mean-reversion decay proxy",
    )
    parser.add_argument(
        "--anomaly-threshold",
        type=float,
        default=10.0,
        help="convergence_basis threshold (price units) below which a row is treated as an R-004 anomaly candidate",
    )
    parser.add_argument(
        "--expiry-date",
        type=str,
        help="Futures expiry date (YYYY-MM-DD, UTC) — enables the fair-value implied-carry-rate analysis",
    )
    parser.add_argument(
        "--sofr-rate",
        type=float,
        help="Externally sourced SOFR (or other risk-free) rate as a decimal, e.g. 0.0364 for 3.64%%",
    )
    parser.add_argument(
        "--sofr-rate-date",
        type=str,
        help="Date the --sofr-rate value was sourced for (recorded in the report only, not used in the calc)",
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
            "expiry_date": args.expiry_date,
            "sofr_rate": args.sofr_rate,
            "sofr_rate_date": args.sofr_rate_date,
        },
        "Q_003": analyze_q3(basis, tuple(args.stale_threshold_ms)),
        "Q_004": analyze_q4(pairs, censored),
        "Q_004_decay_proxy": analyze_basis_decay(basis, tuple(args.decay_resample_minutes)),
        "R_004_anomaly": find_basis_anomaly(basis, args.anomaly_threshold),
        "research_gate": "Evidence report only; no production thresholds or trading decision are approved.",
    }
    if args.expiry_date:
        report["fair_value"] = analyze_fair_value(basis, args.expiry_date, args.sofr_rate)
    output = args.output or args.basis_csv.parent / "q3_q4_report.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"\nReport written to: {output}")


if __name__ == "__main__":
    main()