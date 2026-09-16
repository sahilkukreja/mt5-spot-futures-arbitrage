"""
Load MT5 *terminal-exported* tick CSVs and produce the same synchronized-basis
output as `mt5_data_collector.py --ticks`, without needing a live MT5 connection.

READ-ONLY. Never connects to a broker, never places/modifies/closes an order.

Why this exists
---------------
`mt5_data_collector.py` pulls ticks through `mt5.copy_ticks_range()`, which is
capped by whatever the terminal happens to hold in its own tick cache. The
terminal's manual export (Symbols -> Ticks -> Export) reaches the same depth but
can be taken once and re-analysed offline, and it is what the user actually
provided. This module parses that format and hands DataFrames to the *existing*
`compute_synchronized_basis()` so both paths produce identical column semantics.

Export format (tab-separated, produced by MT5 itself)::

    <DATE>      <TIME>          <BID>    <ASK>    <LAST>  <VOLUME>  <FLAGS>
    2026.07.27  09:22:07.239    4151.68  4151.92                    102

Two things about that format matter:

1. `<BID>` or `<ASK>` can be EMPTY. An MT5 tick carries only the fields that
   actually changed, so a bid-only tick leaves `<ASK>` blank. The correct
   reconstruction of the book is a forward-fill of the last known value on each
   side, NOT a row drop -- dropping them would silently discard real quote
   updates. Rows before the first value on a side are unrecoverable and are
   dropped (a handful at the start of each file).

2. Timestamps are in TERMINAL (broker server) time, not UTC. `copy_ticks_range()`
   returns UTC. The two are therefore NOT directly comparable without an offset.
   This module does not guess: it records the timestamps as-is, labels them
   `terminal time`, and `--tz-offset-hours` applies an offset only when the
   caller supplies one that has been established by evidence.

Memory
------
The two files are ~6.5M and ~8.8M ticks. Merging them in one pass needs several
GB, so this processes one calendar day at a time, carrying a small tail of the
previous day's spot ticks so the first futures tick of a day can still match
backwards across the boundary.

Usage
-----
    python tools/tick_export_loader.py \
        --spot    research/XAUUSD.vx_202607270600_202609161540.csv \
        --futures research/GC-Z26_202607270922_202609161526.csv

    # optional: skip writing the (large) row-level CSV
    python tools/tick_export_loader.py ... --no-write-rows
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

from mt5_data_collector import (
    OUTPUT_ROOT,
    TICK_SYNC_TOLERANCE_MS,
    compute_synchronized_basis,
)

EXPORT_COLUMNS = ["<DATE>", "<TIME>", "<BID>", "<ASK>"]

# Columns kept in the row-level output. Deliberately narrower than the merge's
# own output -- the dropped ones are reconstructable and cost ~200MB on disk.
OUTPUT_COLUMNS = [
    "fut_time_msc",
    "fut_bid",
    "fut_ask",
    "spot_bid",
    "spot_ask",
    "convergence_basis",
    "reverse_basis",
    "mid_basis",
    "quote_skew_ms",
]


def read_export(path: Path, tz_offset_hours: float = 0.0) -> pd.DataFrame:
    """
    Parse one MT5 terminal tick export into the schema the collector uses.

    Returns columns: time_msc (int, epoch ms), time_utc (datetime64), bid, ask.
    `time_utc` is a misnomer inherited from the collector's schema when
    tz_offset_hours is 0 -- see the module docstring. It is terminal time until
    an offset is supplied.
    """
    df = pd.read_csv(
        path,
        sep="\t",
        usecols=EXPORT_COLUMNS,
        dtype={"<DATE>": "string", "<TIME>": "string"},
    )

    ts = pd.to_datetime(
        df.pop("<DATE>") + " " + df.pop("<TIME>"),
        format="%Y.%m.%d %H:%M:%S.%f",
    )
    if tz_offset_hours:
        ts = ts - pd.Timedelta(hours=tz_offset_hours)

    out = pd.DataFrame({
        "time_utc": ts,
        "bid": pd.to_numeric(df.pop("<BID>"), errors="coerce"),
        "ask": pd.to_numeric(df.pop("<ASK>"), errors="coerce"),
    })

    # Reconstruct the book: a blank side means "unchanged", not "no quote".
    n_bid_blank = int(out["bid"].isna().sum())
    n_ask_blank = int(out["ask"].isna().sum())
    out[["bid", "ask"]] = out[["bid", "ask"]].ffill()

    n_before = len(out)
    out = out.dropna(subset=["bid", "ask"]).reset_index(drop=True)
    n_unrecoverable = n_before - len(out)

    # Convert to epoch MILLISECONDS explicitly. Do NOT use `.astype("int64") // N`:
    # pandas parses these timestamps as datetime64[us], not [ns], so a hardcoded
    # divisor silently yields seconds instead of milliseconds -- which makes the
    # merge tolerance 1000x too permissive and understates quote skew by the same
    # factor. Casting the dtype first makes the unit explicit and resolution-proof.
    out["time_msc"] = out["time_utc"].to_numpy(dtype="datetime64[ms]").astype("int64")
    out = out.sort_values("time_msc").reset_index(drop=True)

    print(
        f"  {path.name}: {len(out):,} ticks "
        f"({out['time_utc'].iloc[0]} to {out['time_utc'].iloc[-1]})"
    )
    print(
        f"    forward-filled blanks: bid {n_bid_blank:,}, ask {n_ask_blank:,}; "
        f"dropped {n_unrecoverable:,} leading rows with no prior quote on one side"
    )
    return out


def leg_spread_stats(df: pd.DataFrame, label: str) -> dict:
    """Per-leg quoted spread distribution -- an input to the transaction cost model."""
    spread = df["ask"] - df["bid"]
    return {
        "symbol": label,
        "n_ticks": int(len(df)),
        "mean": round(float(spread.mean()), 5),
        "median": round(float(spread.median()), 5),
        "std": round(float(spread.std()), 5),
        "min": round(float(spread.min()), 5),
        "p05": round(float(spread.quantile(0.05)), 5),
        "p25": round(float(spread.quantile(0.25)), 5),
        "p75": round(float(spread.quantile(0.75)), 5),
        "p95": round(float(spread.quantile(0.95)), 5),
        "p99": round(float(spread.quantile(0.99)), 5),
        "p999": round(float(spread.quantile(0.999)), 5),
        "max": round(float(spread.max()), 5),
    }


def _accumulate(acc: dict, merged: pd.DataFrame) -> None:
    """Fold one day's merged rows into streaming accumulators."""
    acc["n"] += len(merged)
    for col in ("convergence_basis", "reverse_basis", "mid_basis", "quote_skew_ms"):
        s = merged[col].astype("float64")
        a = acc["cols"].setdefault(col, {"sum": 0.0, "sumsq": 0.0,
                                         "min": np.inf, "max": -np.inf,
                                         "samples": []})
        a["sum"] += float(s.sum())
        a["sumsq"] += float((s ** 2).sum())
        a["min"] = min(a["min"], float(s.min()))
        a["max"] = max(a["max"], float(s.max()))
        # Reservoir-free approach: keep a fixed-stride subsample for quantiles.
        # Stride is large enough that the retained sample stays small but is
        # spread evenly across the whole window rather than biased to one day.
        a["samples"].append(s.to_numpy()[::97])
    acc["negatives"] += int((merged["convergence_basis"] < 0).sum())


def _finalize(acc: dict, tolerance_ms: int) -> dict:
    out: dict = {"n_synchronized_rows": acc["n"],
                 "convergence_basis_negative_rows": acc["negatives"],
                 "merge_tolerance_ms": tolerance_ms}
    for col, a in acc["cols"].items():
        n = acc["n"]
        mean = a["sum"] / n
        var = max(a["sumsq"] / n - mean ** 2, 0.0)
        sample = np.concatenate(a["samples"])
        out[col] = {
            "n": n,
            "mean": round(mean, 4),
            "std": round(float(np.sqrt(var)), 4),
            "min": round(a["min"], 4),
            "max": round(a["max"], 4),
            "median": round(float(np.percentile(sample, 50)), 4),
            "p05": round(float(np.percentile(sample, 5)), 4),
            "p25": round(float(np.percentile(sample, 25)), 4),
            "p75": round(float(np.percentile(sample, 75)), 4),
            "p95": round(float(np.percentile(sample, 95)), 4),
            "p99": round(float(np.percentile(sample, 99)), 4),
            "quantile_note": (
                f"quantiles from an evenly-strided 1-in-97 subsample "
                f"(n={len(sample):,}); mean/std/min/max are exact"
            ),
        }
    return out


def run(spot_path: Path, futures_path: Path, out_dir: Path,
        tolerance_ms: int, tz_offset_hours: float, write_rows: bool) -> dict:
    print("--- Loading terminal tick exports ---")
    spot = read_export(spot_path, tz_offset_hours)
    fut = read_export(futures_path, tz_offset_hours)

    manifest = {
        "generated_utc": datetime.now(tz=timezone.utc).isoformat(),
        "source": "MT5 terminal tick export (manual), parsed by tools/tick_export_loader.py",
        "timestamp_basis": (
            "terminal/server time as exported, NO offset applied"
            if not tz_offset_hours
            else f"terminal time shifted by {tz_offset_hours:+g}h"
        ),
        "spot_file": spot_path.name,
        "futures_file": futures_path.name,
        "spot_leg_spread": leg_spread_stats(spot, "spot"),
        "futures_leg_spread": leg_spread_stats(fut, "futures"),
    }

    print("\n--- Per-leg quoted spread (executable cost input) ---")
    for key in ("spot_leg_spread", "futures_leg_spread"):
        s = manifest[key]
        print(f"  {s['symbol']:9s} mean {s['mean']:.4f}  median {s['median']:.4f}  "
              f"p95 {s['p95']:.4f}  p99 {s['p99']:.4f}  max {s['max']:.4f}")

    print(f"\n--- Synchronized basis, day by day (tolerance={tolerance_ms} ms) ---")
    out_dir.mkdir(parents=True, exist_ok=True)
    rows_path = out_dir / "basis_synchronized.csv"
    if write_rows and rows_path.exists():
        rows_path.unlink()

    fut["day"] = fut["time_utc"].dt.normalize()
    spot["day"] = spot["time_utc"].dt.normalize()
    acc: dict = {"n": 0, "negatives": 0, "cols": {}}
    daily: list[dict] = []
    header_written = False

    for day, fut_day in fut.groupby("day", sort=True):
        # Carry a tail of the prior day so the first futures tick can still
        # match backwards across midnight within the tolerance.
        lo = day - pd.Timedelta(milliseconds=tolerance_ms)
        spot_day = spot[(spot["time_utc"] >= lo) & (spot["day"] <= day)]
        if spot_day.empty:
            print(f"  {day.date()}: no spot ticks -- skipped")
            continue

        merged = compute_synchronized_basis(
            spot_day.drop(columns="day"),
            fut_day.drop(columns="day"),
            tolerance_ms,
        )
        if merged.empty:
            continue

        _accumulate(acc, merged)
        daily.append({
            "day": str(day.date()),
            "n": int(len(merged)),
            "convergence_basis_mean": round(float(merged["convergence_basis"].mean()), 4),
            "convergence_basis_min": round(float(merged["convergence_basis"].min()), 4),
            "convergence_basis_max": round(float(merged["convergence_basis"].max()), 4),
            "quote_skew_ms_p95": round(float(merged["quote_skew_ms"].quantile(0.95)), 1),
        })

        if write_rows:
            merged[OUTPUT_COLUMNS].to_csv(
                rows_path, mode="a", header=not header_written,
                index=False, float_format="%.4f",
            )
            header_written = True

    summary = _finalize(acc, tolerance_ms)
    summary["daily"] = daily
    summary.update(manifest)
    summary["note"] = (
        "Post-hoc tick merge via pd.merge_asof (backward, tolerance="
        f"{tolerance_ms} ms), computed one calendar day at a time. "
        "convergence_basis = Bid(futures) - Ask(spot): executable for SELL futures / BUY spot. "
        "reverse_basis = Ask(futures) - Bid(spot): executable for BUY futures / SELL spot. "
        "mid_basis is distributional research only -- not an executable price. "
        "Timestamps are terminal time unless an offset was supplied; they are NOT "
        "directly comparable to copy_ticks_range() output, which is UTC."
    )

    (out_dir / "basis_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    print(f"\nWrote {out_dir / 'basis_summary.json'}")
    if write_rows:
        print(f"Wrote {rows_path}")
    return summary


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--spot", required=True, type=Path)
    p.add_argument("--futures", required=True, type=Path)
    p.add_argument("--out-dir", type=Path, default=None,
                   help="default: research/<UTC timestamp>-export/")
    p.add_argument("--tolerance-ms", type=int, default=TICK_SYNC_TOLERANCE_MS)
    p.add_argument("--tz-offset-hours", type=float, default=0.0,
                   help="subtract this many hours to convert terminal time to UTC. "
                        "Only pass a value established by evidence -- default 0 "
                        "leaves timestamps as exported and labels them as such.")
    p.add_argument("--no-write-rows", action="store_true",
                   help="skip the large row-level basis_synchronized.csv")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    out_dir = args.out_dir or (
        OUTPUT_ROOT / (datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H%M%SZ") + "-export")
    )
    summary = run(
        spot_path=args.spot,
        futures_path=args.futures,
        out_dir=out_dir,
        tolerance_ms=args.tolerance_ms,
        tz_offset_hours=args.tz_offset_hours,
        write_rows=not args.no_write_rows,
    )
    cb = summary["convergence_basis"]
    print(f"\nconvergence_basis over {summary['n_synchronized_rows']:,} rows: "
          f"mean {cb['mean']}, median {cb['median']}, "
          f"p05 {cb['p05']}, p95 {cb['p95']}, min {cb['min']}, max {cb['max']}")


if __name__ == "__main__":
    main()
