# Signal Research (A4)

Status: **SECOND PASS, 2026-09-18 — one promising candidate found (rolling carry-rate estimate), NOT yet
validated out-of-sample; the momentum/extension hypothesis is refuted; the reverse-hedge direction is
inconclusive.** §9's refinement (rolling `r̂`) produced the first genuinely positive gross-of-slippage result
this project has found — treat this as a lead requiring out-of-sample validation before it means anything,
not as a finding. See §10 for the full account and why the multiple-comparisons risk is real here.

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

## 10. Second pass, 2026-09-18 — three variants tested, one promising lead, one hypothesis refuted

`analyze_signal_variants()` (new, `tools/q3_q4_research.py`) generalizes §4's event study along three axes:
`r_hat_mode` (fixed vs. a causal rolling median, no lookahead), `basis_column` (statistical `mid_basis` vs.
the executable `convergence_basis`/`reverse_basis`), and `capture_mode` (`reversion` vs. `extension` —
betting the residual keeps moving away from baseline rather than back toward it). Three variants run, same
45-day dataset, same 3 thresholds (p90/p95/p99) × 3 horizons (15/60/240min) = 27 more combinations tested.

### 10.1 Variant A — rolling 24h carry-rate estimate: the first positive gross-of-slippage result

Same reversion test as §4, but `r̂` is now a **causal 24-hour trailing median** of the implied annual rate
(`_rolling_implied_rate()`) instead of the fixed 4.71%, matching the external proposal's own "lagged robust
estimate" specification for the first time.

| Threshold | 15min net | 60min net | 240min net | 240min: fraction clearing cost |
|---|---:|---:|---:|---:|
| p90 ($1.17) | −$0.28 | −$0.16 | **+$0.13** | 63.0% |
| p95 ($1.47) | −$0.26 | −$0.09 | **+$0.35** | 72.0% |
| p99 ($2.06) | −$0.21 | +$0.15 | **+$0.65** | **86.2%** |

**This is categorically different from the fixed-`r̂` result in §4 — the rolling estimate matters, and it
matters a lot, specifically at longer horizons and higher thresholds.** The p99/240min cell is the strongest
single result this project has produced: mean net capture $0.65 (gross of slippage), clearing round-trip
cost in 86% of 145 qualifying entries.

**Why this is a lead, not a finding, stated as firmly as §4's negative result was:**
- **Same window, no out-of-sample split.** Every test in this document — §4's 9 combinations, this section's
  27 more — has been run against the identical 45-day period. A pattern that holds within one window is not
  yet shown to hold outside it, and `12_FAIR_VALUE_MODEL.md` already notes the underlying spot price moved
  ~8% over this exact window — a trending regime, not necessarily a representative one.
- **Real multiple-comparisons exposure.** 36 threshold/horizon/variant combinations have now been tested
  against one window. Some fraction of them looking favorable by chance is expected even if no true edge
  exists anywhere. The p99/240min cell being the single best-looking result out of 36 is exactly the pattern
  a spurious finding would produce.
- **Still gross of slippage.** Unchanged from §4 — this project's only real execution data (Stage 2, n=10
  pairs) is nowhere near a slippage distribution, and a 240-minute hold is long enough that adverse price
  movement during entry/exit could plausibly exceed the differences between the net-capture numbers above.
- **n=145 at the p99 threshold is not large**, and per §5's caveat, overlapping excursions mean even 145 is
  an overcount of independent observations, not an undercount.

### 10.2 Variant B — reverse hedge (executable `reverse_basis`, BUY futures/SELL spot): inconclusive

Same rolling-vs-fixed question is not yet tested here — this variant used the fixed `r̂` and swapped
`mid_basis` for the properly executable `reverse_basis` (`Ask(futures) − Bid(spot)`, the correct price for
the BUY-futures/SELL-spot direction, rather than the mid-price approximation used elsewhere). Result: mixed,
mostly negative. Best cell (p90/240min): +$0.15 net, 54% clearing — not compelling on its own, and no
consistent pattern across thresholds the way Variant A showed. Untested combination worth doing before
concluding anything: rolling `r̂` on the reverse-hedge executable basis, since Variant A suggests the rolling
estimate is what unlocks a signal, and this variant hasn't tried it yet.

### 10.3 Variant C — gap-extension (momentum): refuted, cleanly

Instead of betting the residual reverts, this tests betting an already-large residual **keeps growing**.
Result: uniformly, strongly negative across every threshold and horizon — worst cell -$1.02 net, best cell
still -$0.03 net, clearing round-trip cost in 0–22% of cases depending on cell. **This is a clean refutation
of the momentum hypothesis**, and indirectly supportive of reversion being the right direction to trade *if*
a real signal exists at all — betting against the extreme has never looked this bad in any variant tested.

### 10.4 What this changes for §8 (decisions proposed)

Still none — but the honest next step is now sharper than §9 originally stated. **Before treating Variant A
as anything more than a lead:** re-run it on a genuinely held-out window (e.g., collect a fresh few days of
ticks the discovery process never touched, or split the existing 45 days into a discovery half and a
confirmation half decided *before* looking at the confirmation half's results) and check whether the
p99/240min pattern survives. If it doesn't survive a real out-of-sample check, this was multiple-comparisons
noise, and that itself would be a useful, recordable result — not a failure of the research process, exactly
what the process exists to catch.
