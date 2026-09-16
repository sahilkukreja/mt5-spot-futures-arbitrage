# Fair Value Model

Status: IN PROGRESS — first real decomposition computed against the tick dataset. Still not a Net Executable
Edge input on its own (see `14_TRANSACTION_COST_MODEL.md` and `17_EXPECTED_VALUE.md`), and the analysis below
covers only a 7-day, narrow-time-to-expiry window — see "Limitations."

## Purpose
Model the theoretical fair-value relationship between gold spot and the futures contract so that the
observed spread can be decomposed into expected carry vs abnormal basis.

## Candidate relationship
For a spot/futures hedge with the same underlying commodity, the carry relation is approximately:

F_t = S_t * e^{(r + c - y) * T}

where:
- F_t is the theoretical futures fair value
- S_t is the spot price
- r is the financing / risk-free carry rate
- c is the storage / carrying cost (expected to be near zero for silver or gold in a CFD context)
- y is the convenience yield or commodity preference premium
- T is the time to expiry in years

For the retail VPFX pair, the first practical approximation is:

basis_fair = futures_price - spot_price ≈ spot_price * r * T + financing + other carry terms

This is a rough model, not a final one, because the broker-labeled `GC-Z26` is a futures CFD and may not
follow an exchange delivery / physical-storage carry model exactly.

## Required inputs
- Spot price `XAUUSD.vx`
- Futures price `GC-Z26`
- Time to expiry of the selected futures contract
- Actual financing rate or implied carry used by the broker
- Any funding / premium / storage assumptions specific to the broker product
- Rollover or settlement assumptions at expiry

## Validation plan
- Compare `fair_value_basis` to the empirically observed `basis` distribution.
- Flag cases where observed basis materially exceeds the range implied by carry + costs.
- Sanity-check that any apparent arbitrage signal is not just a normal carry effect.

## Evidence (sourced, 2026-09-16)

**Data:** `research/2026-09-15T190918Z/basis_synchronized.csv`, 707,467 synchronized bid/ask rows,
2026-09-08 19:09 UTC to 2026-09-15 19:09 UTC (the same tick dataset promoted into `11_SPREAD_DEFINITION.md`).
`GC-Z26` expiry: 25 Nov 2026 (`01_research/07_BROKER_RESEARCH.md`). Reproducible via
`tools/q3_q4_research.py --expiry-date 2026-11-25 --sofr-rate 0.0364 --sofr-rate-date 2026-09-15`
(`analyze_fair_value()`), output archived at `research/2026-09-15T190918Z/q3_q4_decay_fairvalue_report.json`.

**Method:** invert the simple carry relation for each row — `implied_annual_rate = mid_basis / (spot_ask *
T_years)`, where `T_years` is time from that row's timestamp to the 25 Nov 2026 expiry. `T_years` ranges only
0.1923–0.2115 across the window (see Limitations). At this small `T`, the difference between simple
(`r*T`) and continuously-compounded (`e^{r*T}-1`) carry is negligible (<0.05% relative), so the simple form is
used.

**Result — implied annualized carry rate**, n=707,467:

| Stat | Value |
|---|---|
| mean | 4.74% |
| median | 4.74% |
| std | 0.09 pp |
| p05 / p25 / p75 / p95 | 4.55% / 4.68% / 4.81% / 4.87% |
| min / max | 1.43% / 5.38% |

The distribution is tight (IQR only 13 bp) — the ~41.6 average gap behaves like a rate-driven quantity scaled
by spot price and time-to-expiry, not like unstructured noise. This is consistent with (does not prove) the
`14_TRANSACTION_COST_MODEL.md` hypothesis that most of the gap is expected carry rather than a pure anomaly.
The single `min = 1.43%` row is the same stale/asynchronous-quote artifact isolated in `13_BASIS_MODEL.md` and
`docs/RISK_REGISTER.md` R-004 (`convergence_basis` collapsed to 5.07 momentarily) — not a second finding.

**External rate comparison:** SOFR = 3.64% on 2026-09-15 (sourced: FRED series `SOFR`,
https://fred.stlouisfed.org/series/SOFR, fetched 2026-09-16, dated exactly within the tick-collection window).

| Quantity | Value |
|---|---|
| Median implied rate | 4.74% |
| SOFR (2026-09-15) | 3.64% |
| Unexplained rate (median − SOFR) | **1.10 pp** |
| Mean spot ask / mean T | $4,344.80 / 0.2023 years |
| Unexplained basis, in dollars | **≈ $9.67** |
| As a share of the mean 41.63 mid-basis gap | **≈ 23%** |

**Interpretation:** if the entire average gap were pure SOFR-based financing carry, it should be smaller than
what is actually observed by about $9.67 (≈23%). About three-quarters of the gap is consistent with plain
risk-free carry; roughly a quarter is not explained by SOFR alone. This residual is **not** itself an
executable-edge claim. `GC-Z26`'s `_trade_calc_mode_name` is `SYMBOL_CALC_MODE_CFD` (sourced directly from
`symbol_specs.json`, not the marketing name) — it is a broker CFD tracking a futures reference price, not an
exchange-cleared, physically-deliverable contract. A CFD's quoted basis over SOFR can plausibly reflect the
broker's own dealer/liquidity markup or spread-construction convention rather than a genuine, capturable
mispricing. Distinguishing those two explanations is out of scope for this document (would need, e.g., a
second broker's quote for the same underlying, which is not available) and remains an open limitation.

## Limitations

- **Narrow time-to-expiry window.** The 7-day tick dataset only covers `T_years` 0.1923–0.2115 — about 3 weeks
  of the ~10-week remaining contract life. A real test of the carry model would show the implied rate staying
  roughly stable (or the dollar basis shrinking close to linearly) as `T → 0`; this dataset cannot test that
  because `T` barely moves within the sample. This is the natural next empirical test (see below).
- The SOFR comparison uses a single day's published rate, not a rate matched to each row's timestamp (SOFR
  moves daily; over this 7-day window the difference is expected to be small but wasn't checked row-by-row).
- No independent second source (another broker, another liquidity provider) exists to separate "genuine
  carry-over-SOFR premium" from "this broker's markup convention" — both remain plausible explanations for the
  unexplained ~110 bp.
- Rollover/settlement mechanics at the 25 Nov 2026 expiry are still not confirmed (Q-002) — this analysis
  assumes the quoted `GC-Z26` price is a consistent forward-style quote up to that date, not a price subject to
  a discontinuous jump beforehand.

## Decisions proposed

None. The implied-carry decomposition is descriptive evidence that a meaningful share (~77%) of the observed
basis is consistent with SOFR-based carry, and ~23% (~$9.67 of the ~$41.6 average gap) is not explained by it.
This narrows, but does not close, the mandate's "EXPECTED vs ABNORMAL" question — it is not sufficient on its
own to propose a fair-value-based entry/exit threshold, since the narrow-`T` limitation above means the model
is untested against its own central prediction (basis shrinking as expiry approaches).

## Smallest next empirical test

Extend tick collection so `T_years` spans a materially wider range (e.g. re-run the same `--ticks` collection
monthly through to the 25 Nov 2026 expiry) and re-run `tools/q3_q4_research.py --expiry-date 2026-11-25
--sofr-rate <then-current SOFR>` on the combined data. If the carry model holds, the implied annualized rate
should stay roughly stable (or track SOFR's own drift) while the dollar gap itself shrinks as `T` falls toward
zero; a rate that instead drifts unpredictably would weaken the carry explanation.

## Current evidence status
- Margin feasibility is already verified from live account data.
- The real executable spread distribution (`11_SPREAD_DEFINITION.md`) and the implied-carry decomposition
  above are both now in place.
- The final fair-value decomposition should be updated once the broker settlement/rollover facts (Q-002) are
  confirmed and once a wider-`T` dataset exists.
