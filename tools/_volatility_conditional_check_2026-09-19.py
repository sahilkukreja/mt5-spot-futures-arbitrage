"""One-off driver: does the basis's first-passage behavior differ conditional on
recent realized volatility (a "fast market" / high-variation proxy), rather than
averaged across all conditions as every prior pass in 15_SIGNAL_RESEARCH.md did?
Uses the corrected union merge (Q-005) and the same double-barrier methodology
as evaluate_double_barrier.py, split into high-vol vs low-vol terciles by
trailing realized volatility at each entry. Read-only research; no live capital.
"""
from pathlib import Path

import numpy as np
import pandas as pd

from tick_export_loader import read_export

print("Loading full 45-day tick exports...")
spot = read_export(Path("research/XAUUSD.vx_202607270600_202609161540.csv"))
fut = read_export(Path("research/GC-Z26_202607270922_202609161526.csv"))

spot_u = spot.rename(columns={"bid": "spot_bid", "ask": "spot_ask"})[["time_msc", "spot_bid", "spot_ask"]]
fut_u = fut.rename(columns={"bid": "fut_bid", "ask": "fut_ask"})[["time_msc", "fut_bid", "fut_ask"]]

print("Building union merge...")
union_t = np.union1d(spot_u["time_msc"].to_numpy(), fut_u["time_msc"].to_numpy())
union = pd.DataFrame({"time_msc": union_t})
union = union.merge(spot_u, on="time_msc", how="left").merge(fut_u, on="time_msc", how="left")
union[["spot_bid", "spot_ask", "fut_bid", "fut_ask"]] = union[
    ["spot_bid", "spot_ask", "fut_bid", "fut_ask"]
].ffill()
union = union.dropna(subset=["spot_bid", "spot_ask", "fut_bid", "fut_ask"]).reset_index(drop=True)
union["basis"] = union["fut_bid"] - union["spot_ask"]
union["t_utc"] = pd.to_datetime(union["time_msc"], unit="ms", utc=True)

RESAMPLE_S = 5
bars = union.set_index("t_utc")["basis"].resample(f"{RESAMPLE_S}s").last().ffill().dropna()
print(f"{len(bars):,} {RESAMPLE_S}s bars")

basis = bars.to_numpy()
t_ms = bars.index.values.astype("datetime64[ms]").astype("int64")

# Trailing realized volatility at each bar: std of basis changes over the prior 15 minutes.
VOL_WINDOW_BARS = (15 * 60) // RESAMPLE_S
diffs = np.diff(basis, prepend=basis[0])
vol = pd.Series(diffs).rolling(VOL_WINDOW_BARS).std().to_numpy()

INTERVAL_MIN = 15
step_bars = max(1, (INTERVAL_MIN * 60) // RESAMPLE_S)
MAX_HORIZON_MIN = 60
max_horizon_bars = (MAX_HORIZON_MIN * 60) // RESAMPLE_S

entry_idx = np.arange(VOL_WINDOW_BARS, len(bars) - max_horizon_bars - 1, step_bars)
entry_vol = vol[entry_idx]
valid = ~np.isnan(entry_vol)
entry_idx, entry_vol = entry_idx[valid], entry_vol[valid]

tercile_lo, tercile_hi = np.percentile(entry_vol, [33.3, 66.7])
regime = np.where(entry_vol <= tercile_lo, "low_vol", np.where(entry_vol >= tercile_hi, "high_vol", "mid_vol"))
print(f"Entries: {len(entry_idx):,}  vol terciles: low<={tercile_lo:.4f}  high>={tercile_hi:.4f}")


def first_passage_batch(idxs: np.ndarray, tp: float, sl: float) -> tuple[int, int, int]:
    n_tp = n_sl = n_neither = 0
    for idx in idxs:
        entry_basis = basis[idx]
        window = basis[idx + 1: idx + 1 + max_horizon_bars]
        favorable = entry_basis - window
        adverse = window - entry_basis
        tp_hit = np.argmax(favorable >= tp) if np.any(favorable >= tp) else -1
        sl_hit = np.argmax(adverse >= sl) if np.any(adverse >= sl) else -1
        if tp_hit == -1 and sl_hit == -1:
            n_neither += 1
        elif sl_hit == -1 or (tp_hit != -1 and tp_hit <= sl_hit):
            n_tp += 1
        else:
            n_sl += 1
    return n_tp, n_sl, n_neither


TP = SL = 0.61
print(f"\nSymmetric double-barrier, TP=SL=${TP}, horizon={MAX_HORIZON_MIN}min:")
for label in ["low_vol", "mid_vol", "high_vol"]:
    idxs = entry_idx[regime == label]
    n_tp, n_sl, n_neither = first_passage_batch(idxs, TP, SL)
    n = len(idxs)
    print(f"  {label}: n={n:,}  P(TP first)={n_tp/n:.4f}  P(SL first)={n_sl/n:.4f}  "
          f"P(neither)={n_neither/n:.4f}")
