# Signal Research (A4)

Status: **FIRST PASS, 2026-09-18 — no tradeable edge found in the formulation tested; several refinements
remain unexplored.** This is the document `PROJECT_STATE.md` has named the critical path since the mandate's
own signal question was first raised. It does not close A4 — it answers the most natural, simplest version of
the candidate signal this project's own evidence pointed toward, and the answer is negative under that
formulation. Treat "no edge found yet" as a legitimate, recorded result, not an unfinished task.

## 1. Objective

D-006 already rejected hold-to-convergence: the raw basis decays deterministically as `T → 0` and does not
revert to a level, so nothing about holding to expiry is tradeable (`17_EXPECTED_VALUE.md`). What survives is
the **intraday residual** — the part of the observed basis left over after removing the deterministic carry
drift. `12_FAIR_VALUE_MODEL.md` established the carry baseline is well-fit (implied rate stable at 4.71%
across 7-day and 45-day windows, IQR only 13bp) and that roughly 23% of the average gap is unexplained by
SOFR alone. Neither of those facts says whether the **residual itself** — the quantity a mean-reversion
strategy would actually trade — reverts far enough, often enough, to clear costs. That is this document's
question, and until this pass it had never been measured, only assumed or speculated about (once by an
external proposal, `docs/Gold-Basis-EA-Strategy-and-System-Design.md`, reviewed `NOT READY` on exactly this
gap by `/arb-hostile-review`, 2026-09-18).

## 2. What is measured, sourced, and not re-derived here

See `.claude/skills/PROJECT_STATE.md` and the documents below for full derivations — cited, not repeated:

| Quantity | Value | Source |
|---|---|---|
| Implied annualized carry rate | 4.71% (median), IQR 13bp, stable across 7-day and 45-day windows | `12_FAIR_VALUE_MODEL.md` |
| Unexplained residual over SOFR | ~23% of the average ~$52 gap (~$11.90) | `12_FAIR_VALUE_MODEL.md` |
| Round-trip cost, 0.01/0.01 | $0.4975 (spread $0.3975 + futures commission $0.10) | `14_TRANSACTION_COST_MODEL.md` |
| Net carry, hold-to-convergence | −$0.3809/day, 95% CI entirely below zero | `17_EXPECTED_VALUE.md`, D-006 |
| Residual `x_t` dispersion (this session, new) | std $1.32 — 2.65× round-trip cost | §3 below |
| Median intraday carry-baseline range vs. residual range | $1.02 vs. $7.00 — ~99% of intraday range is residual, not carry decay | §3 below |

## 3. Residual dispersion — measured, refutes two prior speculative concerns

**Model:** for each row, `x_t = mid_basis_t − spot_ask_t · r̂ · T_years_t`, where `r̂ = 0.0471` (the
already-validated median implied rate, held **fixed** — a simplification stated explicitly in §5). Computed
over the 45-day/5,111,120-row canonical dataset via `tools/q3_q4_research.py`'s `analyze_residual_reversion()`.

| Stat | Value |
|---|---|
| n | 5,111,120 |
| mean | −$0.1123 |
| std | $1.32 |
| p05 / p25 / median / p75 / p95 | −$2.42 / −$0.84 / $0.05 / $0.79 / $1.81 |
| min / max | −$39.89 / $18.04 |

`residual_std / round_trip_cost = 2.65` — the residual's own dispersion is not thin relative to cost, and
the intraday range decomposition shows the median daily carry-baseline range is only $1.02 versus a $7.00
residual range — nearly all of the previously-cited "$7.91 median intraday range" is genuine residual
variance, not carry decay. **Both of these refute speculative concerns raised in `/arb-hostile-review`
against the external proposal**, not confirmed them — stated plainly since the point of measuring was to
check, not to guess correctly. Full account: `12_FAIR_VALUE_MODEL.md` "Residual dispersion and reversion."

**This does not by itself establish tradeable edge.** Dispersion is not the same as reversion, and reversion
is not the same as a *net-of-cost, executable* edge. §4 tests that directly.

## 4. Threshold-reversion event study — the actual test, new this pass

**Method:** `analyze_threshold_reversion()` (new, `tools/q3_q4_research.py`). For each of three entry
thresholds (the 90th/95th/99th percentile of `|x_t|`, computed on a 1-minute-resampled series to reduce tick
noise), find every **entry** — a bar where `|x_t|` first crosses above the threshold after being below it —
then measure `x_t` at three horizons (15/60/240 minutes) after entry. `capture = |x_t(entry)| −
|x_t(entry+horizon)|` is the dollar amount of the extreme that reverted; `net_capture = capture −
round_trip_cost` ($0.4975). **Gross of slippage** — stated explicitly, since Stage 2's own real execution
data (n=10 pairs) is nowhere near enough for a slippage distribution; this is an upper bound, not a
net-of-everything result.

**Result — mean net-of-round-trip capture, by threshold and horizon:**

| Threshold | n entries | 15min | 60min | 240min |
|---|---:|---:|---:|---:|
| p90 ($2.21) | 497 | −$0.28 | −$0.12 | **+$0.02** |
| p95 ($3.02) | 86 | −$0.33 | −$0.29 | −$0.09 |
| p99 ($4.16) | 54 | −$0.38 | −$0.31 | −$0.24 |

**Fraction of entries that even cleared the round-trip cost (gross of slippage), best case (p90, 240min):
46%.** Every other threshold/horizon combination clears cost less than half the time, several under 15%.

**Interpretation, stated plainly:** in this formulation — fixed `r̂`, simple threshold-crossing entry,
fixed-horizon exit, no direction-of-execution modeling — **there is no net-of-round-trip-cost edge**, even
before the additional, real, unmeasured cost of slippage is subtracted. The one near-zero result (p90, 240
minutes, +$0.02 mean) is not distinguishable from noise given it clears cost less than half the time, and
subtracting any real slippage (even the ~$0.10–0.20/leg range Stage 2's actual pairs showed at the high end)
would very likely push it negative too.

**This is a real, recorded result, not an inconclusive one.** The simplest, most natural version of "trade
the residual back toward its baseline" does not show an edge. It does not prove no formulation could —
see §5's unresolved questions — but it means the burden of proof is now on a more sophisticated version to
show what this simple one couldn't.

Reproducible: `python tools/q3_q4_research.py --basis-csv research/2026-09-16T140628Z/basis_synchronized.csv
--pairs-csv research/2026-09-16T140628Z/reconciled_pairs.csv --expiry-date 2026-11-25 --sofr-rate 0.0364
--sofr-rate-date 2026-09-15 --residual-r-hat 0.0471 --threshold-percentiles 90 95 99
--reversion-horizons-minutes 15 60 240`, output archived at
`research/2026-09-16T140628Z/threshold_reversion_report.json`.

## 5. Assumptions made, stated explicitly

- **`r̂` is fixed at the historical median (4.71%), not a rolling/lagged estimate.** The external proposal's
  own specification uses a "lagged robust estimate... freeze updates during a detected dislocation" — a
  fixed rate is a simplification that could materially change the result in either direction. Untested here.
- **Entry is a simple threshold crossing, not a robust z-score or percentile band with regime filtering.**
  The proposal's own design (§2 of `Gold-Basis-EA-Strategy-and-System-Design.md`) layers several refinements
  (volatility-adjusted spread, regime states, a mandatory transaction-cost gate on every candidate) that this
  first-pass test does not implement.
- **Exit is a fixed horizon, not "when the residual actually reverts" or a proper stop/target/deadline
  policy.** A real strategy would use its own exit logic, not a blind fixed-time exit — this could be
  materially better or worse.
- **Overlapping entries are not independent samples.** A single extreme excursion can trigger several nearby
  qualifying bars as it decays; reported `n` is a bar count, not an independent-observation count. Treat the
  reported distribution as indicative, not a rigorous confidence interval.
- **No slippage, no latency, no execution-direction modeling.** This is the single largest remaining gap —
  Stage 2's own real pairs are the only slippage evidence this project has, and n=10 is nowhere near enough
  for a distribution, let alone a conditional (signal-triggered) one.

## 6. Unresolved questions

- Does a rolling/lagged `r̂` (matching the proposal's own spec) change the threshold-reversion result?
- Does a smarter exit (actual reversion-to-baseline, or a stop/target pair) improve on the fixed-horizon
  result tested here?
- Is the ~23% unexplained-over-SOFR residual (`12_FAIR_VALUE_MODEL.md`) genuine mispricing or stable broker
  CFD markup? Still unresolved — no independent second broker quote exists to test it, and this bears
  directly on whether *any* residual-based signal has a real mechanism behind it or is chasing a stable
  dealer spread-construction artifact.
- What does the conditional (signal-triggered) slippage distribution actually look like? Completely
  unmeasured — Stage 3/4, which would have partially informed this, was retired (D-009) on cost grounds
  before ever running.

## 7. Risks

- **Reusing this project's own template attack on itself:** is the revenue term (reversion capture) measured
  or assumed? Measured, in §4 — this document does not repeat the EV-sign error that cost this project weeks
  once already (comparing a level to a change). The event study measures the actual quantity a trade would
  capture, net of the one cost that is sourced.
- **Overfitting risk in any future refinement:** three thresholds and three horizons were chosen as a
  reasonable first spread, not tuned to produce a favorable result — the table above reports all nine
  combinations tested, not a cherry-picked subset.
- **Multiple-comparisons risk if this expands:** testing many threshold/horizon/exit-rule combinations
  against the same 45-day window risks finding a spuriously favorable combination by chance. Any future
  refinement that finds a positive result needs out-of-sample validation before being trusted, not a report
  against the same window used to search for it.

## 8. Decisions proposed

**None.** This is evidence, not a decision. The natural candidates are: (a) refine the signal (rolling `r̂`,
better exit logic) and re-test before concluding no edge exists at all; or (b) treat this negative result as
sufficient and redirect research effort elsewhere. Neither is decided here — this document's job is to
report what was measured, not to choose the project's next move.

## 9. Smallest next empirical test

Re-run `analyze_threshold_reversion()` with a **rolling/lagged `r̂`** instead of the fixed median rate — the
single assumption in §5 most likely to change the result, since it directly affects what counts as
"residual" versus "baseline." This requires no new data collection, only a new estimator function against
the dataset already in hand, and would directly test whether the proposal's own specified design (not this
document's simplification of it) behaves differently.
