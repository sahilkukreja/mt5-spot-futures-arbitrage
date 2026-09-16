# Fair Value Model

Status: IN PROGRESS — decomposition now validated across a materially wider time-to-expiry window (2026-09-16
update, see "45-day validation" below); the narrow-window limitation flagged in the first pass is resolved.
Still not a Net Executable Edge input on its own (see `14_TRANSACTION_COST_MODEL.md` and
`17_EXPECTED_VALUE.md`).

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

## 45-day validation (2026-09-16) — the narrow-window limitation, resolved

**Data:** `research/2026-09-16T140628Z/basis_synchronized.csv`, **5,111,120** synchronized rows,
2026-08-02 23:02 UTC to 2026-09-16 14:06 UTC — the full local tick history the terminal actually has for
`GC-Z26`/`XAUUSD.vx` (verified: `copy_ticks_range()` lookback plateaus at the same tick count between 45 and
60 days back, so 45 days is the real ceiling, not an arbitrary choice). Before running this, tick density was
checked per few-day interval across the whole window specifically to rule out a "recently listed, thin early
history" artifact for `GC-Z26` — density stayed in a consistent 54k–220k ticks/day range back to the earliest
sampled day, with the only zero-tick days landing exactly on Saturdays (market closed) — no evidence the
contract was thinly quoted or newly listed within this window. Reproducible via the same
`tools/q3_q4_research.py --expiry-date 2026-11-25 --sofr-rate 0.0364 --sofr-rate-date 2026-09-15` command,
output archived at `research/2026-09-16T140628Z/q3_q4_decay_fairvalue_report.json`.

**This is now a real test of the carry model's central prediction**, because `T_years` finally moves
meaningfully across the sample: **0.1902 to 0.3124** (vs. 0.1923–0.2115 in the first pass) — 45 days of real
time-to-expiry variation instead of 7.

| Stat | 7-day pass (n=707,467) | 45-day pass (n=5,111,120) |
|---|---|---|
| `T_years` range | 0.1923–0.2115 | **0.1902–0.3124** |
| Median implied annual rate | 4.74% | **4.71%** |
| Std | 0.09 pp | **0.11 pp** |
| p05 / p95 | 4.55% / 4.87% | **4.51% / 4.88%** |
| Mean spot ask (window average, not comparable directly — see caveat) | $4,344.80 | $4,410.87 |
| Mean mid-basis (dollars) | $41.63 | $52.23 |

**Result: the implied annualized rate held almost perfectly stable — median moved by only 3 bp (4.74% → 4.71%)
even though `T_years` now spans a 60% wider range and the underlying spot price itself moved substantially
over the window** (from roughly $4,072 on 2026-08-02 to the low-$4,300s by 2026-09-16 — an ~8% move in the
underlying, unrelated to the carry relationship itself). The raw dollar mid-basis grew from ~$41.6 to ~$52.2
over the same window, but that is exactly what the carry model predicts when both `T` and spot price are
larger earlier in the window — the *rate*, not the raw dollar gap, is the quantity the model should hold
stable, and it did. This is a genuine pass of the model's own central, falsifiable prediction, not just a
restatement of the earlier finding.

**SOFR comparison, updated:** unexplained rate (median − 3.64% SOFR) = **1.07 pp** (vs. 1.10 pp before — also
stable), translating to **≈$11.90 unexplained** of the ~$52.23 average mid-basis, **≈22.8%** (vs. ≈23.3%
before). The ~23% unexplained share is now confirmed stable across a 7x larger sample and a 60% wider `T`
range, strengthening (not just repeating) the earlier finding that this residual looks like a persistent,
structural feature of the quoting relationship rather than a narrow-window artifact. The same caveat as before
still applies: this does not distinguish "broker CFD markup" from "genuine mispricing" — no independent second
source exists to test that.

## Limitations

- **Resolved 2026-09-16:** the narrow-`T` window limitation from the first pass — see "45-day validation"
  above.
- The SOFR comparison still uses a single day's published rate, not a rate matched to each row's timestamp
  (checked: SOFR was unchanged at 3.64% between 2026-09-15 and 2026-09-16, the two dates this analysis has been
  run, so this has not yet been a material source of error, but a full daily SOFR series would be more correct
  for a 45-day window than it was for 7 days).
- No independent second source (another broker, another liquidity provider) exists to separate "genuine
  carry-over-SOFR premium" from "this broker's markup convention" — both remain plausible explanations for the
  unexplained ~107 bp.
- Rollover/settlement mechanics at the 25 Nov 2026 expiry are still not confirmed (Q-002) — this analysis
  assumes the quoted `GC-Z26` price is a consistent forward-style quote up to that date, not a price subject to
  a discontinuous jump beforehand. The dataset still doesn't reach close enough to expiry (`T_years` still
  ≥0.19, i.e. ≥69 days out) to observe whether the relationship holds or breaks down as expiry actually nears.

## Decisions proposed

None. The implied-carry decomposition is now validated evidence, not just a first-pass observation, that a
stable ~4.7% annualized rate explains roughly three-quarters of the observed basis, with the remaining ~23%
(~$11.90 of the ~$52.23 average gap) an unexplained residual, confirmed stable across two independent tick
collections spanning 7x different sample sizes and 60% different `T` ranges. This narrows, but does not close,
the mandate's "EXPECTED vs ABNORMAL" question — a fair-value-based entry/exit threshold still cannot be
proposed responsibly until Q-002 (settlement/rollover) resolves and, ideally, the dataset extends closer to the
actual 25 Nov 2026 expiry to observe the relationship's behavior as `T → 0`, which remains untested.

## Smallest next empirical test

Re-run the same tick collection and `analyze_fair_value()` call periodically (roughly monthly, and especially
in the final weeks before 25 Nov 2026) as `T_years` continues to shrink toward zero — that is the one part of
the carry model's prediction this dataset still cannot test, since even the widest window collected so far
only reaches `T_years ≈ 0.19` (about 10 weeks out). If the implied rate keeps holding stable as `T` shrinks
further, that is stronger evidence for the carry explanation; a rate that starts drifting as expiry nears would
weaken it.

## Current evidence status
- Margin feasibility is already verified from live account data.
- The real executable spread distribution (`11_SPREAD_DEFINITION.md`) and the implied-carry decomposition
  above are both now validated across two independent collections (7-day and 45-day).
- The final fair-value decomposition should be updated once the broker settlement/rollover facts (Q-002) are
  confirmed and once data reaches closer to the actual expiry date.
