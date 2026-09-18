"""One-off driver: closes Q-005's last open item (OPEN_QUESTIONS.md) -- does the
futures-anchored-merge bias also affect the D-006/13_BASIS_MODEL.md decay-rate
finding (-$0.3905/day, 95% CI -0.4480...-0.3330, R^2=0.83), not just the A4
signal check it already reversed? Re-derives the same OLS regression
(convergence_basis vs. elapsed calendar days, full 45-day/51-calendar-day
window) on both the original futures-anchored merge and the corrected union
merge, for direct comparison. Read-only research; no live capital.
"""
from pathlib import Path

import numpy as np
import pandas as pd

from tick_export_loader import read_export


class _OLSResult:
    def __init__(self, slope, intercept, stderr, rvalue):
        self.slope, self.intercept, self.stderr, self.rvalue = slope, intercept, stderr, rvalue


def linregress(x: np.ndarray, y: np.ndarray) -> _OLSResult:
    """Plain-numpy OLS (scipy is not installed in this environment) -- slope, intercept,
    R, and the slope's standard error, matching scipy.stats.linregress's fields."""
    n = len(x)
    x_mean, y_mean = x.mean(), y.mean()
    sxx = np.sum((x - x_mean) ** 2)
    sxy = np.sum((x - x_mean) * (y - y_mean))
    slope = sxy / sxx
    intercept = y_mean - slope * x_mean
    resid = y - (intercept + slope * x)
    resid_ss = np.sum(resid ** 2)
    r2 = 1 - resid_ss / np.sum((y - y_mean) ** 2)
    dof = n - 2
    stderr = np.sqrt((resid_ss / dof) / sxx)
    rvalue = np.sign(slope) * np.sqrt(max(r2, 0.0))
    return _OLSResult(slope, intercept, stderr, rvalue)

print("Loading full 45-day tick exports...")
spot = read_export(Path("research/XAUUSD.vx_202607270600_202609161540.csv"))
fut = read_export(Path("research/GC-Z26_202607270922_202609161526.csv"))


def ols_decay(y: np.ndarray, t_days: np.ndarray, label: str) -> None:
    res = linregress(t_days, y)
    n = len(y)
    ci_halfwidth = 1.96 * res.stderr
    print(f"\n--- {label} ---")
    print(f"  n = {n:,}")
    print(f"  slope = {res.slope:.4f} $/day  (stderr {res.stderr:.4f}, 95% CI "
          f"[{res.slope - ci_halfwidth:.4f}, {res.slope + ci_halfwidth:.4f}])")
    print(f"  R^2 = {res.rvalue**2:.4f}")
    print(f"  fitted start->end: ${res.intercept:.2f} -> ${res.intercept + res.slope * t_days.max():.2f} "
          f"over {t_days.max():.1f} days")


# --- Original futures-anchored merge (reuses the same tolerance as compute_synchronized_basis) ---
spot_r = spot.rename(columns={"bid": "spot_bid", "ask": "spot_ask", "time_msc": "spot_time_msc"})
fut_r = fut.rename(columns={"bid": "fut_bid", "ask": "fut_ask", "time_msc": "fut_time_msc"})
merged = pd.merge_asof(
    fut_r.sort_values("fut_time_msc"), spot_r.sort_values("spot_time_msc"),
    left_on="fut_time_msc", right_on="spot_time_msc", direction="backward", tolerance=500,
).dropna(subset=["spot_bid", "spot_ask"])
merged["convergence_basis"] = merged["fut_bid"] - merged["spot_ask"]
t0 = merged["fut_time_msc"].min()
t_days_fa = (merged["fut_time_msc"].to_numpy() - t0) / 86_400_000.0
ols_decay(merged["convergence_basis"].to_numpy(), t_days_fa, "Futures-anchored merge (original method)")

# --- Union merge ---
spot_u = spot.rename(columns={"bid": "spot_bid", "ask": "spot_ask"})[["time_msc", "spot_bid", "spot_ask"]]
fut_u = fut.rename(columns={"bid": "fut_bid", "ask": "fut_ask"})[["time_msc", "fut_bid", "fut_ask"]]
union_t = np.union1d(spot_u["time_msc"].to_numpy(), fut_u["time_msc"].to_numpy())
union = pd.DataFrame({"time_msc": union_t})
union = union.merge(spot_u, on="time_msc", how="left").merge(fut_u, on="time_msc", how="left")
union[["spot_bid", "spot_ask", "fut_bid", "fut_ask"]] = union[
    ["spot_bid", "spot_ask", "fut_bid", "fut_ask"]
].ffill()
union = union.dropna(subset=["spot_bid", "spot_ask", "fut_bid", "fut_ask"])
union["convergence_basis"] = union["fut_bid"] - union["spot_ask"]
t_days_u = (union["time_msc"].to_numpy() - t0) / 86_400_000.0
ols_decay(union["convergence_basis"].to_numpy(), t_days_u, "Union merge (both legs' real ticks)")
