"""One-off driver: re-derive the second-pass in-sample rolling-r-hat result
(the original "+$0.65 net capture, 86% clearing" headline) using a UNION merge
of both legs' ticks over the full 45-day archive, instead of
compute_synchronized_basis()'s futures-anchored merge (Q-005,
docs/OPEN_QUESTIONS.md). Read-only research; no live capital.
"""
import json
from pathlib import Path

import numpy as np
import pandas as pd

from tick_export_loader import read_export
from q3_q4_research import analyze_signal_variants

EXPIRY_DATE = "2026-11-25"

print("Loading full 45-day tick exports (this will take a minute)...")
spot = read_export(Path("research/XAUUSD.vx_202607270600_202609161540.csv"))
fut = read_export(Path("research/GC-Z26_202607270922_202609161526.csv"))

spot = spot.rename(columns={"bid": "spot_bid", "ask": "spot_ask"})[["time_msc", "spot_bid", "spot_ask"]]
fut = fut.rename(columns={"bid": "fut_bid", "ask": "fut_ask"})[["time_msc", "fut_bid", "fut_ask"]]

print("Building union of both legs' tick timestamps...")
union_t = np.union1d(spot["time_msc"].to_numpy(), fut["time_msc"].to_numpy())
print(f"union event rows: {len(union_t):,}")

union = pd.DataFrame({"time_msc": union_t})
union = union.merge(spot, on="time_msc", how="left").merge(fut, on="time_msc", how="left")
union[["spot_bid", "spot_ask", "fut_bid", "fut_ask"]] = union[
    ["spot_bid", "spot_ask", "fut_bid", "fut_ask"]
].ffill()
union = union.dropna(subset=["spot_bid", "spot_ask", "fut_bid", "fut_ask"]).reset_index(drop=True)

union["mid_basis"] = (union["fut_bid"] + union["fut_ask"]) / 2.0 - (union["spot_bid"] + union["spot_ask"]) / 2.0
union["fut_time_msc"] = union["time_msc"]

print(f"Final union rows after dropna: {len(union):,}")

for freq_label, freq in [("1min", "1min")]:
    print(f"\n=== FULL 45-day UNION merge, in-sample, resample_freq={freq_label} ===")
    result = analyze_signal_variants(
        union, expiry_date=EXPIRY_DATE, percentiles=(0.90, 0.95, 0.99), horizons_minutes=(15, 60, 240),
        r_hat_mode="rolling", rolling_window_hours=24.0, basis_column="mid_basis",
        capture_mode="reversion", resample_freq=freq,
    )
    out = Path(f"research/2026-09-16T140628Z/insample_union_recheck_{freq_label}_report.json")
    out.write_text(json.dumps(result, indent=2))
    for pct, pdata in result.get("by_percentile", {}).items():
        for h, hdata in pdata.get("horizons", {}).items():
            print(f"  {pct} {h}: n={hdata.get('n_entries')} "
                  f"mean_net={hdata.get('mean_net_of_round_trip_usd')} "
                  f"frac_clear={hdata.get('fraction_clearing_round_trip')}")
    print("Wrote", out)
