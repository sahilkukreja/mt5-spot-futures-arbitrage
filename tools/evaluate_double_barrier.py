"""
Symmetric double-barrier (first-passage) test for the convergence-basis signal
candidate, against the full 45-day synchronized archive. Read-only research; no
broker connection, no live capital.

Why this tool exists: a real-pair counterfactual replay (docs/02_quant/15_SIGNAL_RESEARCH.md
section 12) looked strong -- 10 of 11 usable real pairs "converged" by $0.61 within
30 minutes -- but was disqualified on two grounds: (1) 8 of those 11 pairs came from
a single 39-minute window (clustering pseudoreplication, N_eff~4, not 11), and (2)
the replay only checked the favorable direction, which cannot be distinguished from
ordinary two-sided noise without a symmetric comparison.

This tool fixes both: entries are drawn at regular intervals across the FULL 45-day
archive (not 12 clustered real pairs), and for every entry BOTH a take-profit and a
stop-loss barrier are evaluated together, asking P(tau_TP < tau_SL) -- whether the
favorable barrier is reached first. For symmetric barriers (TP == SL) a driftless
random walk gives P=0.5 by construction (reflection principle); for asymmetric
barriers (TP != SL) the closed-form null for a driftless Brownian motion is the
classic gambler's-ruin result P(hit +a before -b) = b / (a+b). The real question
this answers is whether the MEASURED probability differs from that null by more
than clustering-aware sampling noise explains -- not whether a raw hit rate looks
high, which is exactly what made section 12's replay misleading.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

from tick_export_loader import read_export


def build_basis_series(spot: pd.DataFrame, fut: pd.DataFrame, resample_seconds: int) -> pd.DataFrame:
    """1-row-per-resample_seconds convergence_basis = Bid(fut) - Ask(spot), forward-filled."""
    spot_s = spot.set_index("time_utc")[["ask"]].rename(columns={"ask": "spot_ask"})
    fut_s = fut.set_index("time_utc")[["bid"]].rename(columns={"bid": "fut_bid"})
    merged = pd.merge_asof(
        fut_s.sort_index(), spot_s.sort_index(),
        left_index=True, right_index=True, direction="backward",
        tolerance=pd.Timedelta(seconds=30),
    ).dropna()
    freq = f"{resample_seconds}s"
    bars = merged.resample(freq).last().ffill().dropna()
    bars["basis"] = bars["fut_bid"] - bars["spot_ask"]
    bars["t_ms"] = bars.index.values.astype("datetime64[ms]").astype("int64")
    return bars.reset_index(drop=True)


def first_passage(
    basis: np.ndarray,
    t_ms: np.ndarray,
    entry_idx: np.ndarray,
    tp: float,
    sl: float,
    max_horizon_bars: int,
) -> pd.DataFrame:
    """
    For each entry index, scan forward up to max_horizon_bars bars. Direction
    convention: entering the convergence trade (SELL fut/BUY spot) profits when
    basis SHRINKS. tau_TP = first bar where entry_basis - basis[i] >= tp.
    tau_SL = first bar where basis[i] - entry_basis >= sl.
    """
    n = len(basis)
    rows = []
    for idx in entry_idx:
        if idx + 1 >= n:
            continue
        entry_basis = basis[idx]
        end = min(idx + 1 + max_horizon_bars, n)
        window = basis[idx + 1:end]
        if len(window) == 0:
            continue
        favorable = entry_basis - window   # positive = basis shrinking
        adverse = window - entry_basis     # positive = basis widening
        tp_hit = np.argmax(favorable >= tp) if np.any(favorable >= tp) else -1
        sl_hit = np.argmax(adverse >= sl) if np.any(adverse >= sl) else -1

        if tp_hit == -1 and sl_hit == -1:
            outcome = "neither"
            elapsed_s = np.nan
        elif sl_hit == -1 or (tp_hit != -1 and tp_hit <= sl_hit):
            outcome = "tp_first"
            elapsed_s = (t_ms[idx + 1 + tp_hit] - t_ms[idx]) / 1000.0
        else:
            outcome = "sl_first"
            elapsed_s = (t_ms[idx + 1 + sl_hit] - t_ms[idx]) / 1000.0

        rows.append({"entry_idx": int(idx), "entry_t_ms": int(t_ms[idx]), "outcome": outcome, "elapsed_s": elapsed_s})

    return pd.DataFrame(rows)


def cluster_ids(entry_t_ms: np.ndarray) -> np.ndarray:
    """UTC-calendar-day blocks. A fixed time-gap heuristic does not work when entries
    are regularly spaced closer together than the look-forward horizon -- every entry
    then falls in the same gap-connected cluster (this tool's first run collapsed the
    entire 45-day archive to n_clusters=1 for exactly this reason). Calendar days are
    a meaningful, non-overlapping unit for this data: each day's price path is a
    genuinely different realization, closer to what "N_eff~4" in section 12 was
    actually pointing at than a same-cluster-if-close heuristic is."""
    days = (entry_t_ms // 86_400_000).astype(np.int64)
    _, ids = np.unique(days, return_inverse=True)
    return ids


def simulate_driftless_null(
    basis: np.ndarray, tp: float, sl: float, max_horizon_bars: int,
    n_paths: int, rng: np.random.Generator,
) -> dict:
    """
    Monte Carlo null matched to the ACTUAL finite horizon and the basis's own
    realized (bootstrap-resampled, demeaned) increment distribution -- not the
    closed-form gambler's-ruin formula, which assumes eventual passage over
    infinite time and so does not account for "neither" (censored-at-horizon)
    paths. A driftless random walk restricted to the same finite horizon has
    p_tp_first < 0.5 and p_sl_first < 0.5 simultaneously, by construction, once
    "neither" has real mass -- comparing a measured rate to a bare 0.5 (or to
    the infinite-horizon formula) overstates any apparent edge. This function
    exists because a symmetric buy-futures/sell-spot ("gap increases") variant
    is exactly the complementary event to what was measured first, and checking
    it surfaced this bug: p_tp_first + p_sl_first was well under 1 minus
    fraction_neither would suggest under the (wrong) closed-form null.
    """
    increments = np.diff(basis)
    increments = increments[np.isfinite(increments)]
    increments = increments - increments.mean()  # remove drift explicitly

    draws = rng.choice(increments, size=(n_paths, max_horizon_bars), replace=True)
    paths = np.cumsum(draws, axis=1)  # path[i, k] = cumulative move after k+1 bars, path[i,-1] excluded start=0

    tp_hit = (paths >= tp)
    sl_hit = (paths <= -sl)
    tp_first_bar = np.where(tp_hit.any(axis=1), tp_hit.argmax(axis=1), max_horizon_bars)
    sl_first_bar = np.where(sl_hit.any(axis=1), sl_hit.argmax(axis=1), max_horizon_bars)

    is_tp_first = (tp_first_bar < sl_first_bar) & (tp_first_bar < max_horizon_bars)
    is_sl_first = (sl_first_bar < tp_first_bar) & (sl_first_bar < max_horizon_bars)
    is_neither = ~is_tp_first & ~is_sl_first

    p_tp = float(is_tp_first.mean())
    p_sl = float(is_sl_first.mean())
    p_neither = float(is_neither.mean())
    se = float(np.sqrt(p_tp * (1 - p_tp) / n_paths))

    return {"null_p_tp_first_finite_horizon": round(p_tp, 4),
            "null_p_sl_first_finite_horizon": round(p_sl, 4),
            "null_fraction_neither": round(p_neither, 4),
            "null_se": round(se, 4)}


def cluster_robust_summary(
    df: pd.DataFrame, tp: float, sl: float, basis: np.ndarray,
    max_horizon_bars: int, rng: np.random.Generator, n_null_paths: int = 20_000,
) -> dict:
    n = len(df)
    if n == 0:
        return {"tp": tp, "sl": sl, "n": 0}

    p_tp_hat = float((df["outcome"] == "tp_first").mean())
    p_sl_hat = float((df["outcome"] == "sl_first").mean())

    # cluster-robust: per-cluster hit rate, then treat clusters as the sampling unit
    per_cluster_tp = df.groupby("cluster")["outcome"].apply(lambda s: (s == "tp_first").mean())
    n_clusters = per_cluster_tp.shape[0]
    cluster_mean_tp = float(per_cluster_tp.mean())
    cluster_se_tp = float(per_cluster_tp.std(ddof=1) / np.sqrt(n_clusters)) if n_clusters > 1 else float("nan")

    null = simulate_driftless_null(basis, tp, sl, max_horizon_bars, n_null_paths, rng)
    combined_se = float(np.sqrt(cluster_se_tp ** 2 + null["null_se"] ** 2)) if not np.isnan(cluster_se_tp) else None
    diff = cluster_mean_tp - null["null_p_tp_first_finite_horizon"]
    z = round(diff / combined_se, 2) if combined_se else None

    return {
        "tp": tp, "sl": sl,
        "n_entries": int(n),
        "n_clusters": int(n_clusters),
        "raw_p_tp_first": round(p_tp_hat, 4),
        "raw_p_sl_first": round(p_sl_hat, 4),
        "cluster_mean_p_tp_first": round(cluster_mean_tp, 4),
        "cluster_robust_se": round(cluster_se_tp, 4) if not np.isnan(cluster_se_tp) else None,
        **null,
        "diff_from_finite_horizon_null": round(diff, 4),
        "z_score_vs_finite_horizon_null": z,
        "fraction_neither": round(float((df["outcome"] == "neither").mean()), 4),
        "median_elapsed_s_tp_first": round(float(df.loc[df["outcome"] == "tp_first", "elapsed_s"].median()), 1)
            if (df["outcome"] == "tp_first").any() else None,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spot", type=Path, default=Path("research/XAUUSD.vx_202607270600_202609161540.csv"))
    parser.add_argument("--futures", type=Path, default=Path("research/GC-Z26_202607270922_202609161526.csv"))
    parser.add_argument("--resample-seconds", type=int, default=5)
    parser.add_argument("--interval-minutes", type=int, default=15, help="entry spacing")
    parser.add_argument("--max-horizon-minutes", type=int, default=60)
    parser.add_argument("--n-null-paths", type=int, default=20_000)
    parser.add_argument("--seed", type=int, default=20260919)
    parser.add_argument("--out", type=Path, default=Path("research/2026-09-16T140628Z/double_barrier_report.json"))
    args = parser.parse_args()
    rng = np.random.default_rng(args.seed)

    print("Loading tick exports...")
    spot = read_export(args.spot)
    fut = read_export(args.futures)

    print(f"Building {args.resample_seconds}s basis series...")
    bars = build_basis_series(spot, fut, args.resample_seconds)
    print(f"  {len(bars):,} bars, {bars['t_ms'].iloc[0]} to {bars['t_ms'].iloc[-1]} (ms epoch)")

    basis = bars["basis"].to_numpy()
    t_ms = bars["t_ms"].to_numpy()

    step_bars = max(1, (args.interval_minutes * 60) // args.resample_seconds)
    entry_idx = np.arange(0, len(bars) - 1, step_bars)
    max_horizon_bars = (args.max_horizon_minutes * 60) // args.resample_seconds
    print(f"Entries: {len(entry_idx):,} at {args.interval_minutes}-min spacing, "
          f"horizon {args.max_horizon_minutes}min ({max_horizon_bars} bars)")

    configs = [
        ("symmetric_0.61", 0.61, 0.61),
        ("symmetric_1.00", 1.00, 1.00),
        ("asymmetric_tp0.61_sl1.00", 0.61, 1.00),
        ("asymmetric_tp0.61_sl0.31", 0.61, 0.31),
    ]

    report = {
        "caveat": (
            "This measures whether a favorable barrier is reached before an adverse one, "
            "against a Monte Carlo driftless null (bootstrap-resampled, demeaned real "
            "increments) matched to the SAME finite horizon and censoring as the measured "
            "run -- not the closed-form gambler's-ruin formula, which assumes eventual "
            "passage over infinite time and so overstates any apparent edge once 'neither' "
            "(horizon-censored) paths have real mass. It does not measure execution cost, "
            "slippage, or fill quality -- see tools/simulate_execution.py and R-007 for why "
            "a simulated environment cannot answer that part. Declustering uses UTC-calendar-"
            "day blocks, not a rigorous block-bootstrap -- treat cluster_robust_se as "
            "indicative, not exact."
        ),
        "resample_seconds": args.resample_seconds,
        "interval_minutes": args.interval_minutes,
        "max_horizon_minutes": args.max_horizon_minutes,
        "results": [],
    }

    for label, tp, sl in configs:
        print(f"Running {label} (TP={tp}, SL={sl})...")
        df = first_passage(basis, t_ms, entry_idx, tp, sl, max_horizon_bars)
        df["cluster"] = cluster_ids(df["entry_t_ms"].to_numpy())
        summary = cluster_robust_summary(df, tp, sl, basis, max_horizon_bars, rng, args.n_null_paths)
        summary["label"] = label
        report["results"].append(summary)
        print(f"  {json.dumps(summary, indent=2)}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2))
    print(f"\nWrote {args.out}")


if __name__ == "__main__":
    main()
