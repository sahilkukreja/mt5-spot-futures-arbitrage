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


def analyze_residual_reversion(
    basis: pd.DataFrame, expiry_date: str, r_hat: float, resample_minutes: tuple[int, ...]
) -> dict[str, Any]:
    """Measures the carry-baseline residual x_t = mid_basis - B_hat, where B_hat = spot_ask * r_hat * T_years,
    using the already-validated median implied rate (r_hat) as a fixed baseline. This is the quantity a
    residual-mean-reversion strategy (e.g. docs/Gold-Basis-EA-Strategy-and-System-Design.md section 5) would
    actually need to trade -- distinct from analyze_basis_decay()'s raw convergence_basis proxy, which mixes
    the deterministic carry drift (T shrinking over time) in with any genuine residual reversion. Requested by
    /arb-hostile-review's mandatory-test finding against that proposal, 2026-09-18: the proposal's central
    premise (residual reversion) had no measurement anywhere in this repository.

    Does NOT itself establish tradeable edge: still ignores spread/commission/slippage entirely (14_TRANSACTION_
    COST_MODEL.md's ~$0.4975 round trip is not subtracted here), and r_hat as a single fixed rate is a
    simplification -- the proposal's own r_hat is a "lagged robust estimate," not a fixed constant. This
    establishes only whether there is a dollar-scale residual worth building a rolling estimator around at all.
    """
    required = {"fut_time_msc", "mid_basis", "spot_ask"}
    if not required.issubset(basis.columns):
        return {"status": "insufficient_data", "reason": f"missing columns: {sorted(required - set(basis.columns))}"}

    frame = basis[["fut_time_msc", "mid_basis", "spot_ask"]].copy()
    frame["fut_time_utc"] = pd.to_datetime(frame["fut_time_msc"], unit="ms", utc=True)
    expiry = pd.Timestamp(expiry_date, tz="UTC")
    frame["T_years"] = (expiry - frame["fut_time_utc"]).dt.total_seconds() / (365 * 24 * 3600)
    frame = frame[frame["T_years"] > 0].dropna(subset=["mid_basis", "spot_ask"])
    if frame.empty:
        return {"status": "insufficient_data", "reason": "all rows are at/after the supplied expiry date"}

    frame["b_hat"] = frame["spot_ask"] * r_hat * frame["T_years"]
    frame["x_t"] = frame["mid_basis"] - frame["b_hat"]
    residual_stats = stats(frame["x_t"])

    round_trip_cost = 0.4975  # sourced, 14_TRANSACTION_COST_MODEL.md -- comparison only, not subtracted above
    result: dict[str, Any] = {
        "status": "measured",
        "model": "x_t = mid_basis - spot_ask * r_hat * T_years, r_hat fixed at the already-validated median "
        "implied rate (NOT a rolling/lagged estimate as the proposal itself specifies -- a simplification, "
        "stated explicitly)",
        "r_hat_used": r_hat,
        "expiry_date": expiry_date,
        "residual_x_t_dollars": residual_stats,
        "round_trip_cost_usd_for_comparison": round_trip_cost,
        "residual_std_over_round_trip_cost": round(residual_stats["std"] / round_trip_cost, 3)
        if residual_stats.get("std")
        else None,
    }

    # Reversion structure of x_t itself, same method as analyze_basis_decay()'s raw-basis proxy --
    # this is the version that isolates genuine residual reversion from deterministic carry drift.
    timestamps = pd.to_datetime(frame["fut_time_msc"], unit="ms", utc=True)
    series = pd.Series(frame["x_t"].to_numpy(), index=timestamps).sort_index()
    halflife_by_grid: dict[str, Any] = {}
    for minutes in resample_minutes:
        resampled = series.resample(f"{minutes}min").last().dropna()
        r = _ar1_halflife(resampled, minutes)
        halflife_by_grid[f"{minutes}min"] = r if r is not None else {
            "status": "insufficient_data",
            "reason": "fewer than 20 resampled bars at this grid",
        }
    result["residual_halflife_by_resample_grid"] = halflife_by_grid

    # Intraday-range decomposition: how much of a day's basis range is the deterministic carry-baseline's own
    # (small) intraday drift, versus the residual's own range -- addresses the specific "$7.91 median intraday
    # range cited as opportunity, without checking whether it's residual or ordinary carry drift" hostile-review
    # finding.
    frame["date"] = timestamps.dt.date
    daily = frame.groupby("date").agg(
        basis_range=("mid_basis", lambda s: float(s.max() - s.min())),
        b_hat_range=("b_hat", lambda s: float(s.max() - s.min())),
        x_t_range=("x_t", lambda s: float(s.max() - s.min())),
    )
    if not daily.empty:
        result["intraday_range_decomposition"] = {
            "n_days": int(len(daily)),
            "median_basis_range": round(float(daily["basis_range"].median()), 4),
            "median_carry_baseline_range": round(float(daily["b_hat_range"].median()), 4),
            "median_residual_range": round(float(daily["x_t_range"].median()), 4),
            "interpretation": (
                "If median_carry_baseline_range is small relative to median_basis_range, most of the intraday "
                "range is residual variance, not deterministic carry decay -- supports treating it as "
                "'opportunity' as the proposal does. If it's large, the proposal's $7.91 figure overstates "
                "genuine residual opportunity."
            ),
        }

    return result


def analyze_threshold_reversion(
    basis: pd.DataFrame,
    expiry_date: str,
    r_hat: float,
    percentiles: tuple[float, ...],
    horizons_minutes: tuple[int, ...],
    round_trip_cost: float = 0.4975,
) -> dict[str, Any]:
    """The actual missing test for 02_quant/15_SIGNAL_RESEARCH.md: does the carry-baseline residual x_t
    revert far enough, after crossing an extreme threshold, to clear round-trip cost -- gross of slippage,
    which remains barely measured (n=10 real Stage 2 pairs) and is NOT subtracted here. This is an event
    study, not a backtest: for each threshold percentile of |x_t| (computed on a 1-min resampled series to
    reduce tick noise), find each "entry" -- a bar where |x_t| first crosses above the threshold after being
    below it -- then measure x_t at entry+horizon for several horizons. capture = |x_t(entry)| -
    |x_t(entry+horizon)| is the dollar amount of the extreme that reverted (positive = reverted toward zero,
    negative = the residual moved further away). net_capture = capture - round_trip_cost is what's left
    after the one fixed cost this project has actually sourced.

    What this does NOT establish, stated explicitly:
    - No slippage or latency subtracted -- Stage 2's own real pairs (n=10) are nowhere near enough for a
      slippage distribution; results here are a gross-of-slippage upper bound, not a net-of-everything claim.
    - Fixed r_hat, not the "lagged robust estimate" any real signal would use -- same simplification as
      analyze_residual_reversion().
    - Overlapping entry events are not independent samples (an extreme excursion can trigger several nearby
      entries as it decays) -- reported n is a count of qualifying bars, not independent observations; treat
      the reported distribution as indicative, not a rigorous confidence interval.
    - Direction-agnostic: captures the magnitude of reversion, not whether a real strategy could actually
      execute both legs in the correct direction at the moment of crossing.
    """
    required = {"fut_time_msc", "mid_basis", "spot_ask"}
    if not required.issubset(basis.columns):
        return {"status": "insufficient_data", "reason": f"missing columns: {sorted(required - set(basis.columns))}"}

    frame = basis[["fut_time_msc", "mid_basis", "spot_ask"]].copy()
    frame["fut_time_utc"] = pd.to_datetime(frame["fut_time_msc"], unit="ms", utc=True)
    expiry = pd.Timestamp(expiry_date, tz="UTC")
    frame["T_years"] = (expiry - frame["fut_time_utc"]).dt.total_seconds() / (365 * 24 * 3600)
    frame = frame[frame["T_years"] > 0].dropna(subset=["mid_basis", "spot_ask"])
    if frame.empty:
        return {"status": "insufficient_data", "reason": "all rows are at/after the supplied expiry date"}
    frame["x_t"] = frame["mid_basis"] - frame["spot_ask"] * r_hat * frame["T_years"]

    timestamps = pd.to_datetime(frame["fut_time_msc"], unit="ms", utc=True)
    series = pd.Series(frame["x_t"].to_numpy(), index=timestamps).sort_index()
    one_min = series.resample("1min").last().dropna()
    abs_x = one_min.abs()

    result: dict[str, Any] = {
        "status": "measured",
        "model": "event study on x_t = mid_basis - spot_ask*r_hat*T_years, r_hat fixed at the supplied "
        "median rate; 1-min resampled series",
        "round_trip_cost_usd": round_trip_cost,
        "by_percentile": {},
    }

    for pct in percentiles:
        threshold = float(abs_x.quantile(pct / 100.0))
        above = abs_x >= threshold
        # Entry = first bar of a new excursion above threshold (previous bar was below).
        entries = above & ~above.shift(1, fill_value=False)
        entry_times = abs_x.index[entries.to_numpy()]

        horizon_results: dict[str, Any] = {}
        for h in horizons_minutes:
            captures = []
            for t in entry_times:
                t_exit = t + pd.Timedelta(minutes=h)
                idx = one_min.index.searchsorted(t_exit)
                if idx >= len(one_min):
                    continue
                x_entry = one_min.loc[t]
                x_exit = one_min.iloc[idx]
                captures.append(abs(x_entry) - abs(x_exit))
            if not captures:
                horizon_results[f"{h}min"] = {"status": "insufficient_data", "reason": "no entry had a valid exit bar"}
                continue
            cap_series = pd.Series(captures)
            horizon_results[f"{h}min"] = {
                "n_entries": int(cap_series.size),
                "mean_gross_capture_usd": round(float(cap_series.mean()), 4),
                "median_gross_capture_usd": round(float(cap_series.median()), 4),
                "mean_net_of_round_trip_usd": round(float(cap_series.mean()) - round_trip_cost, 4),
                "fraction_positive_gross_capture": round(float((cap_series > 0).mean()), 4),
                "fraction_clearing_round_trip": round(float((cap_series > round_trip_cost).mean()), 4),
            }

        result["by_percentile"][f"p{pct:g}"] = {
            "threshold_usd": round(threshold, 4),
            "n_qualifying_entries": int(entry_times.size),
            "horizons": horizon_results,
        }

    return result


def _rolling_implied_rate(frame: pd.DataFrame, window_hours: float) -> pd.Series:
    """Causal (backward-looking only) rolling median of the implied annual rate, replacing the fixed r_hat
    used elsewhere. At each row, uses only rows at or before that row's own timestamp -- no lookahead. This
    is the refinement 15_SIGNAL_RESEARCH.md names as its smallest next test: the proposal this project
    reviewed specifies a "lagged robust estimate," not a fixed constant, and that has never been tested.
    """
    rate = frame["mid_basis"].to_numpy() / (frame["spot_ask"].to_numpy() * frame["T_years"].to_numpy())
    rate = np.clip(rate, 0, 1)
    timestamps = pd.to_datetime(frame["fut_time_msc"], unit="ms", utc=True)
    rate_series = pd.Series(rate, index=pd.DatetimeIndex(timestamps.to_numpy())).sort_index()
    rate_series = rate_series[~rate_series.index.duplicated(keep="last")]
    return rate_series.rolling(f"{window_hours}h").median()


def analyze_signal_variants(
    basis: pd.DataFrame,
    expiry_date: str,
    percentiles: tuple[float, ...],
    horizons_minutes: tuple[int, ...],
    r_hat_mode: str = "fixed",
    r_hat_fixed: float | None = None,
    rolling_window_hours: float = 24.0,
    basis_column: str = "mid_basis",
    capture_mode: str = "reversion",
    round_trip_cost: float = 0.4975,
) -> dict[str, Any]:
    """Generalizes analyze_threshold_reversion() along the three axes 15_SIGNAL_RESEARCH.md's own
    "unresolved questions" and the account owner named as follow-up tests, 2026-09-18:

    - r_hat_mode: "fixed" (the already-tested simplification) or "rolling" (a causal trailing-median
      estimate, _rolling_implied_rate() above -- the proposal's own "lagged robust estimate" spec).
    - basis_column: "mid_basis" (statistical, not executable -- what was tested so far), "convergence_basis"
      (executable for SELL futures/BUY spot -- Bid(fut)-Ask(spot)), or "reverse_basis" (executable for BUY
      futures/SELL spot -- Ask(fut)-Bid(spot), the "reverse hedge" direction). Using the executable basis
      directly, rather than mid_basis plus a flat round-trip-cost subtraction, is a more realistic test of
      what a specific direction could actually capture.
    - capture_mode: "reversion" (bets the residual shrinks back toward baseline -- what was tested so far) or
      "extension" (bets an already-moving residual keeps moving further away -- a momentum/trend-following
      hypothesis, motivated by this project's own finding that the raw basis series has "a fast, partially
      mean-reverting intraday component layered on a slower-moving level that does not fully revert,"
      analyze_basis_decay()'s own interpretation).
    """
    required = {"fut_time_msc", "mid_basis", "spot_ask", basis_column}
    if not required.issubset(basis.columns):
        return {"status": "insufficient_data", "reason": f"missing columns: {sorted(required - set(basis.columns))}"}
    if r_hat_mode == "fixed" and r_hat_fixed is None:
        return {"status": "insufficient_data", "reason": "r_hat_mode='fixed' requires r_hat_fixed"}

    cols = list(dict.fromkeys(["fut_time_msc", "mid_basis", "spot_ask", basis_column]))
    frame = basis[cols].copy()
    frame["fut_time_utc"] = pd.to_datetime(frame["fut_time_msc"], unit="ms", utc=True)
    expiry = pd.Timestamp(expiry_date, tz="UTC")
    frame["T_years"] = (expiry - frame["fut_time_utc"]).dt.total_seconds() / (365 * 24 * 3600)
    frame = frame[frame["T_years"] > 0].dropna(subset=["mid_basis", "spot_ask", basis_column])
    if frame.empty:
        return {"status": "insufficient_data", "reason": "all rows are at/after the supplied expiry date"}

    if r_hat_mode == "rolling":
        r_hat_series = _rolling_implied_rate(frame, rolling_window_hours).dropna()
        frame = frame.sort_values("fut_time_utc")
        r_hat_lookup = pd.DataFrame({"fut_time_utc": r_hat_series.index, "r_hat": r_hat_series.to_numpy()})
        frame = pd.merge_asof(frame, r_hat_lookup, on="fut_time_utc", direction="backward")
        frame = frame.dropna(subset=["r_hat"])
        if frame.empty:
            return {"status": "insufficient_data", "reason": "rolling_window_hours too large for available history"}
        frame["x_t"] = frame[basis_column] - frame["spot_ask"] * frame["r_hat"] * frame["T_years"]
        model_desc = f"rolling {rolling_window_hours}h causal median implied rate (no lookahead)"
    else:
        frame["x_t"] = frame[basis_column] - frame["spot_ask"] * r_hat_fixed * frame["T_years"]
        model_desc = f"fixed r_hat={r_hat_fixed}"

    timestamps = pd.to_datetime(frame["fut_time_msc"], unit="ms", utc=True)
    series = pd.Series(frame["x_t"].to_numpy(), index=timestamps).sort_index().dropna()
    one_min = series.resample("1min").last().dropna()
    abs_x = one_min.abs()

    result: dict[str, Any] = {
        "status": "measured",
        "model": f"x_t = {basis_column} - spot_ask*r_hat*T_years ({model_desc}); capture_mode={capture_mode}; "
        "1-min resampled series",
        "round_trip_cost_usd": round_trip_cost,
        "by_percentile": {},
    }

    for pct in percentiles:
        threshold = float(abs_x.quantile(pct / 100.0))
        above = abs_x >= threshold
        entries = above & ~above.shift(1, fill_value=False)
        entry_times = abs_x.index[entries.to_numpy()]

        horizon_results: dict[str, Any] = {}
        for h in horizons_minutes:
            captures = []
            for t in entry_times:
                t_exit = t + pd.Timedelta(minutes=h)
                idx = one_min.index.searchsorted(t_exit)
                if idx >= len(one_min):
                    continue
                x_entry = one_min.loc[t]
                x_exit = one_min.iloc[idx]
                # reversion: bets |x| shrinks (captures if it did). extension: bets |x| grows further
                # (captures if it did) -- the sign of the capture formula flips between the two hypotheses.
                if capture_mode == "extension":
                    captures.append(abs(x_exit) - abs(x_entry))
                else:
                    captures.append(abs(x_entry) - abs(x_exit))
            if not captures:
                horizon_results[f"{h}min"] = {"status": "insufficient_data", "reason": "no entry had a valid exit bar"}
                continue
            cap_series = pd.Series(captures)
            horizon_results[f"{h}min"] = {
                "n_entries": int(cap_series.size),
                "mean_gross_capture_usd": round(float(cap_series.mean()), 4),
                "median_gross_capture_usd": round(float(cap_series.median()), 4),
                "mean_net_of_round_trip_usd": round(float(cap_series.mean()) - round_trip_cost, 4),
                "fraction_positive_gross_capture": round(float((cap_series > 0).mean()), 4),
                "fraction_clearing_round_trip": round(float((cap_series > round_trip_cost).mean()), 4),
            }

        result["by_percentile"][f"p{pct:g}"] = {
            "threshold_usd": round(threshold, 4),
            "n_qualifying_entries": int(entry_times.size),
            "horizons": horizon_results,
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
    parser.add_argument(
        "--residual-r-hat",
        type=float,
        help="Fixed annualized carry rate (decimal, e.g. 0.0471) used as r_hat for the residual-reversion "
        "analysis (analyze_residual_reversion). Requires --expiry-date. Use the already-validated median "
        "implied rate from a prior --expiry-date run, not an assumed value.",
    )
    parser.add_argument(
        "--threshold-percentiles",
        type=float,
        nargs="+",
        help="Percentiles of |x_t| (e.g. 90 95 99) to test as entry thresholds in the threshold-reversion "
        "event study (analyze_threshold_reversion). Requires --expiry-date and --residual-r-hat.",
    )
    parser.add_argument(
        "--reversion-horizons-minutes",
        type=int,
        nargs="+",
        default=[15, 60, 240],
        help="Horizons (minutes) to check post-entry for the threshold-reversion event study",
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
    if args.expiry_date and args.residual_r_hat is not None:
        report["residual_reversion"] = analyze_residual_reversion(
            basis, args.expiry_date, args.residual_r_hat, tuple(args.decay_resample_minutes)
        )
    if args.expiry_date and args.residual_r_hat is not None and args.threshold_percentiles:
        report["threshold_reversion"] = analyze_threshold_reversion(
            basis, args.expiry_date, args.residual_r_hat,
            tuple(args.threshold_percentiles), tuple(args.reversion_horizons_minutes),
        )
    output = args.output or args.basis_csv.parent / "q3_q4_report.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    print(f"\nReport written to: {output}")


if __name__ == "__main__":
    main()