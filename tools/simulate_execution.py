"""
Offline execution simulator: replays the real 5.84M-row synchronized tick dataset
to estimate legging drift and basis shift between order decision and both legs'
actual fills, using this project's own measured send-to-fill latency distribution
-- never a broker connection, never live capital.

Context: Stage 3/4 (a 300-pair live measurement run) was retired (D-009) because it
cost USD 150-250 guaranteed and still couldn't answer the conditional-tail slippage
question at any affordable sample size (R-008). This tool answers a narrower,
cheaper, offline question instead: given the latency this project's own harness has
actually measured, how much does the basis move between deciding to trade and both
legs actually filling? It is a legging-drift estimate, not a broker fill-quality
measurement -- see the module-level caveat in the report output.

Latency source: measurement_harness/arb_harness_stage2_journal.csv, the 10 real
Stage 2 pairs (n=20 leg fills, both legs pooled -- small sample, bootstrap-resampled
with replacement, not fit to a parametric distribution). This is a DATED snapshot of
broker conditions as of 2026-09-17/18; the account owner has since asked the broker
to reduce futures feed latency, which would make this distribution stale once/if it
changes. Re-measure from the journal rather than reusing this script's cached numbers
if that happens.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

from tick_export_loader import read_export

# Measured 2026-09-18 from measurement_harness/arb_harness_stage2_journal.csv,
# t_fill - t_send across all LEG1_FILLED rows (leg_id 1 and 2 pooled), n=20.
# Real numbers, not assumed -- see RISK_REGISTER.md / this session's chat record.
MEASURED_SEND_TO_FILL_MS = np.array([
    78, 126, 156, 162, 175, 218, 241, 251, 254, 307,
    332, 345, 559, 592, 599, 630, 672, 703, 716, 736,
], dtype=float)

ANOMALY_START = pd.Timestamp("2026-09-11 13:29:30", tz="UTC")
ANOMALY_END = pd.Timestamp("2026-09-11 13:31:00", tz="UTC")


def price_at_or_after(df: pd.DataFrame, t_ms: np.ndarray, side: str) -> np.ndarray:
    """Nearest available quote at or after each requested time_msc (searchsorted)."""
    idx = np.searchsorted(df["time_msc"].to_numpy(), t_ms, side="left")
    idx = np.clip(idx, 0, len(df) - 1)
    return df[side].to_numpy()[idx]


def simulate(
    spot: pd.DataFrame,
    fut: pd.DataFrame,
    entry_times_ms: np.ndarray,
    rng: np.random.Generator,
    direction: str = "convergence",
) -> pd.DataFrame:
    """
    direction='convergence': SELL futures / BUY spot (this project's primary
    studied direction, see D-006/17_EXPECTED_VALUE.md). Executable prices:
    futures fills at bid, spot fills at ask.
    """
    n = len(entry_times_ms)
    lat_fut = rng.choice(MEASURED_SEND_TO_FILL_MS, size=n, replace=True)
    lat_spot = rng.choice(MEASURED_SEND_TO_FILL_MS, size=n, replace=True)

    fut_side, spot_side = ("bid", "ask") if direction == "convergence" else ("ask", "bid")

    fut_t0 = price_at_or_after(fut, entry_times_ms, fut_side)
    spot_t0 = price_at_or_after(spot, entry_times_ms, spot_side)
    basis_t0 = fut_t0 - spot_t0 if direction == "convergence" else spot_t0 - fut_t0

    fut_fill_t = entry_times_ms + lat_fut
    spot_fill_t = entry_times_ms + lat_spot
    fut_fill = price_at_or_after(fut, fut_fill_t, fut_side)
    spot_fill = price_at_or_after(spot, spot_fill_t, spot_side)
    basis_fill = fut_fill - spot_fill if direction == "convergence" else spot_fill - fut_fill

    legging_drift_spot = spot_fill - spot_t0
    basis_shift = basis_fill - basis_t0

    return pd.DataFrame({
        "entry_time_ms": entry_times_ms,
        "lat_fut_ms": lat_fut,
        "lat_spot_ms": lat_spot,
        "spot_t0": spot_t0,
        "spot_fill": spot_fill,
        "legging_drift_spot": legging_drift_spot,
        "basis_t0": basis_t0,
        "basis_fill": basis_fill,
        "basis_shift": basis_shift,
    })


def summarize(df: pd.DataFrame, label: str) -> dict:
    bs = df["basis_shift"]
    return {
        "label": label,
        "n": int(len(df)),
        "mean_usd": round(float(bs.mean()), 4),
        "std_usd": round(float(bs.std()), 4),
        "p50_usd": round(float(bs.quantile(0.50)), 4),
        "p90_usd": round(float(bs.quantile(0.90)), 4),
        "p95_usd": round(float(bs.quantile(0.95)), 4),
        "p99_usd": round(float(bs.quantile(0.99)), 4),
        "min_usd": round(float(bs.min()), 4),
        "max_usd": round(float(bs.max()), 4),
        "fraction_exceeding_round_trip_0.4975": round(float((bs.abs() > 0.4975).mean()), 4),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spot", type=Path, default=Path("research/XAUUSD.vx_202607270600_202609161540.csv"))
    parser.add_argument("--futures", type=Path, default=Path("research/GC-Z26_202607270922_202609161526.csv"))
    parser.add_argument("--interval-minutes", type=int, default=15,
                         help="Sample one simulated entry every N minutes across the full dataset")
    parser.add_argument("--seed", type=int, default=20260918)
    parser.add_argument("--out", type=Path, default=Path("research/2026-09-16T140628Z/execution_simulation_report.json"))
    args = parser.parse_args()

    print("Loading tick exports (this is the same 45-day canonical dataset used throughout this project)...")
    spot = read_export(args.spot)
    fut = read_export(args.futures)

    rng = np.random.default_rng(args.seed)

    t_start = max(spot["time_msc"].iloc[0], fut["time_msc"].iloc[0])
    t_end = min(spot["time_msc"].iloc[-1], fut["time_msc"].iloc[-1])
    step_ms = args.interval_minutes * 60_000
    entry_times = np.arange(t_start, t_end, step_ms, dtype=np.int64)
    print(f"Unconditional sample: {len(entry_times):,} entries at {args.interval_minutes}-minute spacing")

    unconditional = simulate(spot, fut, entry_times, rng, direction="convergence")

    anomaly_start_ms = int(ANOMALY_START.value // 1_000_000)
    anomaly_end_ms = int(ANOMALY_END.value // 1_000_000)
    anomaly_entries = np.arange(anomaly_start_ms, anomaly_end_ms, 1000, dtype=np.int64)
    anomaly = simulate(spot, fut, anomaly_entries, rng, direction="convergence")
    print(f"Anomaly-window sample (2026-09-11 R-004 event, +/-45s at 1s spacing): {len(anomaly_entries):,} entries")

    report = {
        "caveat": (
            "This is a legging-drift estimate: how much the basis moves between decision "
            "and both legs' actual fills, using this project's own measured send-to-fill "
            "latency (n=20, bootstrap-resampled). It does NOT measure broker fill quality, "
            "requotes, rejections, or price improvement/adverse selection at the moment of "
            "fill -- R-007 already flags why a simulated environment cannot substitute for "
            "that. Latency is dated to 2026-09-17/18 Stage 2 conditions; the account owner "
            "has an open request with the broker to reduce futures feed latency, which would "
            "make this stale once it takes effect."
        ),
        "latency_source": "measurement_harness/arb_harness_stage2_journal.csv, n=20 real leg fills, Stage 2, 2026-09-17/18",
        "unconditional": summarize(unconditional, "unconditional (15-min spacing, full 45-day window)"),
        "anomaly_window_2026-09-11": summarize(anomaly, "R-004 anomaly window, 1s spacing, +/-45s"),
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2))
    print(f"\nWrote {args.out}")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
