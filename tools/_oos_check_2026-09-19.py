"""One-off driver: genuine out-of-sample check of the rolling-r-hat lead (15_SIGNAL_RESEARCH.md
sections 10/11) against real ticks collected after the original 45-day archive's end
(2026-09-16), using the exact same parameters as the second/third pass -- no retuning.
Scratch script, not part of the permanent tools/ CLI surface.
"""
import json
from pathlib import Path

import pandas as pd

from q3_q4_research import analyze_signal_variants

OOS_CSV = Path("research/2026-09-18T205013Z/basis_synchronized.csv")
ARCHIVE_END_MS = int(pd.Timestamp("2026-09-16 16:00:00", tz="UTC").value // 1_000_000)
EXPIRY_DATE = "2026-11-25"

df = pd.read_csv(OOS_CSV)
print("raw rows:", len(df))
print("columns:", list(df.columns))

oos = df[df["fut_time_msc"] > ARCHIVE_END_MS].copy()
print(f"OOS rows (strictly after {ARCHIVE_END_MS} ms / 2026-09-16 16:00 UTC): {len(oos)}")
if len(oos):
    print("OOS time range:",
          pd.to_datetime(oos["fut_time_msc"].min(), unit="ms", utc=True),
          "to",
          pd.to_datetime(oos["fut_time_msc"].max(), unit="ms", utc=True))

for freq_label, freq in [("1min", "1min"), ("5s", "5s"), ("raw_tick", None)]:
    print(f"\n=== resample_freq={freq_label} ===")
    result = analyze_signal_variants(
        oos,
        expiry_date=EXPIRY_DATE,
        percentiles=(0.90, 0.95, 0.99),
        horizons_minutes=(15, 60, 240),
        r_hat_mode="rolling",
        rolling_window_hours=24.0,
        basis_column="mid_basis",
        capture_mode="reversion",
        resample_freq=freq,
    )
    out = Path(f"research/2026-09-16T140628Z/oos_check_2026-09-19_{freq_label}_report.json")
    out.write_text(json.dumps(result, indent=2))
    for pct, pdata in result.get("by_percentile", {}).items():
        for h, hdata in pdata.get("horizons", {}).items():
            print(f"  {pct} {h}: n={hdata.get('n_entries')} "
                  f"mean_net={hdata.get('mean_net_of_round_trip_usd')} "
                  f"frac_clear={hdata.get('fraction_clearing_round_trip')}")
    print("Wrote", out)
