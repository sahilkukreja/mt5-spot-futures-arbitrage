"""One-off driver: rebuild the OOS basis series as a UNION of both legs' ticks
(every spot tick AND every futures tick gets its own row, each side forward-filled
from its own last known quote) instead of compute_synchronized_basis()'s
futures-anchored merge, which silently drops the majority of spot-only tick
events (measured: 944,457 raw spot ticks vs 336,973 raw futures ticks in this
OOS window -- the futures-anchored merge can have at most one row per futures
tick, so well over half a million real spot price-change events were never
their own row in the earlier check). Scratch script, not part of the permanent
tools/ CLI surface.
"""
import json
from pathlib import Path

import numpy as np
import pandas as pd

from q3_q4_research import analyze_signal_variants

RUN_DIR = Path("research/2026-09-18T205013Z")
ARCHIVE_END_MS = int(pd.Timestamp("2026-09-16 16:00:00", tz="UTC").value // 1_000_000)
EXPIRY_DATE = "2026-11-25"

spot = pd.read_csv(RUN_DIR / "ticks_XAUUSD.vx.csv", usecols=["time_msc", "bid", "ask"])
fut = pd.read_csv(RUN_DIR / "ticks_GC-Z26.csv", usecols=["time_msc", "bid", "ask"])
spot = spot.rename(columns={"bid": "spot_bid", "ask": "spot_ask"}).sort_values("time_msc")
fut = fut.rename(columns={"bid": "fut_bid", "ask": "fut_ask"}).sort_values("time_msc")
print(f"raw spot ticks: {len(spot):,}  raw futures ticks: {len(fut):,}")

# Union of both timestamp sets; each row is a real tick event from EITHER leg.
spot["time_msc"] = spot["time_msc"].astype(np.int64)
fut["time_msc"] = fut["time_msc"].astype(np.int64)
union_t = np.union1d(spot["time_msc"].to_numpy(), fut["time_msc"].to_numpy())
print(f"union event rows: {len(union_t):,}")

union = pd.DataFrame({"time_msc": union_t})
union = union.merge(spot, on="time_msc", how="left").merge(fut, on="time_msc", how="left")
union[["spot_bid", "spot_ask", "fut_bid", "fut_ask"]] = union[
    ["spot_bid", "spot_ask", "fut_bid", "fut_ask"]
].ffill()
union = union.dropna(subset=["spot_bid", "spot_ask", "fut_bid", "fut_ask"]).reset_index(drop=True)

union["mid_basis"] = (union["fut_bid"] + union["fut_ask"]) / 2.0 - (union["spot_bid"] + union["spot_ask"]) / 2.0
union["convergence_basis"] = union["fut_bid"] - union["spot_ask"]
union["fut_time_msc"] = union["time_msc"]  # analyze_signal_variants expects this column name

oos = union[union["fut_time_msc"] > ARCHIVE_END_MS].copy()
print(f"OOS union rows (every real tick from either leg, strictly after archive end): {len(oos):,}")

for freq_label, freq in [("1min", "1min"), ("raw_tick", None)]:
    print(f"\n=== union merge, resample_freq={freq_label} ===")
    result = analyze_signal_variants(
        oos, expiry_date=EXPIRY_DATE, percentiles=(0.90, 0.95, 0.99), horizons_minutes=(15, 60, 240),
        r_hat_mode="rolling", rolling_window_hours=24.0, basis_column="mid_basis",
        capture_mode="reversion", resample_freq=freq,
    )
    out = Path(f"research/2026-09-16T140628Z/oos_check_2026-09-19_union_{freq_label}_report.json")
    out.write_text(json.dumps(result, indent=2))
    for pct, pdata in result.get("by_percentile", {}).items():
        for h, hdata in pdata.get("horizons", {}).items():
            print(f"  {pct} {h}: n={hdata.get('n_entries')} "
                  f"mean_net={hdata.get('mean_net_of_round_trip_usd')} "
                  f"frac_clear={hdata.get('fraction_clearing_round_trip')}")
    print("Wrote", out)
