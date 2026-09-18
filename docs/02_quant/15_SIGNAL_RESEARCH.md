# Signal Research (A4)

Status: **RETRACTED, 2026-09-19 — the rolling-r̂ "promising lead" (§10) does not survive a corrected data
merge, even in-sample.** Chain of events, same day: the first genuine out-of-sample test came back negative
(§13, 0 of 9 combinations cleared cost); re-running the OOS check at raw-tick resolution and on a proper
union-of-both-legs tick merge confirmed the failure and deepened it; re-running that same corrected union
merge against the *original 45-day in-sample window* (§14) reversed the original headline result entirely —
**+$0.65 mean net capture / 86% clearing becomes −$0.85 / 0.4% clearing**, same window, same signal
construction, only the merge corrected. The lead was very likely a merge artifact from the start, not a
real pattern that failed to generalize. §11's weekly extension remains separately disqualified (~7–10
independent events). §12's real-pair replay remains disqualified (clustering, one-sided bias); its surviving
risk-side data point ($1.87 max adverse excursion) still supports D-010. §12.2's double-barrier test, corrected
after checking the complementary direction, showed no directional edge either way. Q-005 (`OPEN_QUESTIONS.md`)
is substantially answered: the futures-anchored merge bias is real and material. **A4 has no surviving
candidate signal.**

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
| Net carry, hold-to-convergence | −$0.2095/day (corrected 2026-09-18, was −$0.3809/day — swap confirmed flat `×7/7` by backtest, `ASSUMPTIONS.md` A-002); decay term's 95% CI still entirely below zero | `17_EXPECTED_VALUE.md`, D-006 |
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

## 11. Third pass, 2026-09-18 — a same-window confirmation check, a weekly extension, and why the weekly
numbers should not be trusted

Genuine fresh out-of-sample data is not available yet — MT5 cannot supply ticks from a date that hasn't
happened, so real confirmation requires waiting for calendar time to pass (see the account owner's exchange
recorded in the session this document was produced in). As an interim, weaker-but-immediate check: re-ran
§10's exact rolling-`r̂` parameters (no re-tuning) against a **held-out slice of the existing window** —
2026-09-01 through 2026-09-16, the last portion of the 45-day dataset. This is not true out-of-sample (that
slice already contributed to the original full-window statistics), but it is at least a check that nothing
falls apart on a narrower cut.

### 11.1 Intraday result, held-out slice — holds up in character

| Threshold | 240min net (full window, §10) | 240min net (held-out slice) |
|---|---:|---:|
| p90 | +$0.13 | +$0.14 |
| p95 | +$0.35 | +$0.34 |
| p99 | +$0.65 | +$0.13 |

p90 and p95 are essentially unchanged. p99 is weaker on the smaller slice (35 entries here vs. 145 on the
full window) but still positive. **This is expected and not very informative** — as stated above, this isn't
real out-of-sample evidence, just a narrower cut of the same data. It rules out "the result falls apart
immediately on any subset," nothing stronger.

### 11.2 Weekly extension, closing before the Wednesday swap — striking numbers, not to be trusted

Requested test: extend the horizon to multi-day ("weekly") scale, but avoid the tripled Wednesday swap charge
by force-closing before that day's rollover rather than holding through it (`exclude_wednesday_swap=True`,
`analyze_signal_variants()`) — the trade is truncated to close just before the next Wednesday, not discarded,
matching what a real swap-avoiding strategy would do. Horizons tested: 1, 2, and 5 days (1440/2880/7200
minutes), same rolling-`r̂` model, full 45-day window.

**Headline result, before the caveat below:** p99 threshold, 1-day nominal horizon: mean net capture
**+$1.30**, clearing round-trip cost in **89%** of 75 entries, **100%** positive gross capture. p90 and p95
show the same pattern at smaller magnitude.

**Why these numbers should not be trusted or repeated anywhere as evidence of edge:** a same-day independence
check (clustering entries more than 24 hours apart into one event) shows the underlying sample is far smaller
than it looks:

| Threshold | Reported `n_entries` | Independent clusters (>24h gap) |
|---|---:|---:|
| p90 | 771 | **9** |
| p95 | 460 | **10** |
| p99 | 145 | **7** |

**The "75 independent entries, 100% positive" at p99 is actually ~7 real events, each counted roughly 10
times over** because multi-day horizons vastly exceed the typical spacing between threshold-crossing entries
— many nearby entries are measuring nearly the same underlying price path, not independent draws. This is
the same caveat §5 already named ("overlapping entries are not independent samples"), but for weekly horizons
it is not a minor caveat — it is disqualifying. A 100%-positive result from ~7 real events over a 45-day
window in which the underlying spot price is independently known to have moved ~8% (`12_FAIR_VALUE_MODEL.md`)
is at least as consistent with "this window happened to contain a few large one-directional moves" as with
"a repeatable reversion pattern exists at weekly scale." Seven events cannot distinguish between those
explanations.

**Disposition: do not cite the weekly-horizon numbers as evidence of anything, in this document or
elsewhere, until they can be computed from a genuinely larger number of independent events** — either a much
longer collection window, or accepting that weekly-scale reversion is simply not testable with 45 days of
data the way the intraday version is. The intraday result (§10, §11.1) does not have this specific problem
at the same severity — its entry counts (86–497 at the relevant thresholds) are still overlapping to some
degree but nowhere near as collapsed as the weekly test's, since 15–240 minute horizons are much closer to
the typical spacing between crossings.

### 11.3 What actually changed

Nothing here moves the project past "one lead, not validated" (§10's status stands). The weekly extension
was worth trying and worth recording — including the negative methodological finding that it doesn't have
enough independent data to say anything, which is itself useful: it means any future attempt at a
multi-day-horizon signal needs either much more history or a fundamentally different test design (e.g.,
testing the underlying *rate* of excursion events rather than per-event capture), not just a longer horizon
bolted onto the existing entry-detection method.

## 12. Fourth pass, 2026-09-19 — real-pair counterfactual replay, disqualified on two independent grounds

**Setup:** for each of the 12 real Stage 2 pairs' actual entry fills (`arb_harness_stage2_journal.csv`), replayed
real subsequent tick data (fresh read-only collection, since the archived dataset ends 2026-09-16 and all 12
real pairs post-date it) forward up to 30 minutes, asking: how long until `entry_basis − current_basis ≥
$0.61` (the $0.4975 round-trip cost + a $0.1125 net-target convention used for this pass)? 10 of 11 pairs with
usable forward data (pair 11 never opened) "hit" the target, median ≈140s, and maximum adverse excursion
across all 12 pairs was **$1.87** — nowhere near D-010's Tier 1 $81 cap.

**Disqualified before it could be read as a finding, on two independent grounds — same discipline as §11's
weekly-test debunk:**

1. **Clustering pseudoreplication.** 8 of the 11 usable pairs (pairs 3–10) have `run_id`s spanning barely 39
   minutes on the same day — one continuous market window, not 8 independent trials. If the underlying price
   was drifting in one direction through that window, every entry inside it "converges" for the same shared
   reason. Real independent observations: pair 1 (did not converge in 30min), pair 2, the pairs-3–10 cluster
   as a single point, and pair 12 — **N_eff ≈ 4**, not 11.
2. **One-sided first-passage bias.** The replay only checked the favorable direction from real entries. Given
   this basis's own measured short-term dispersion (residual std ≈$2.77, §3), a $0.61 move within 30 minutes
   is not inherently surprising as ordinary two-sided noise — without checking how often a *symmetric* adverse
   move of the same size happens just as fast from an arbitrary point, "10 of 11 converged favorably" cannot
   be distinguished from noise. This is the same class of error as comparing a signal against its own
   one-sided outcome instead of a null distribution.

**What survives, and is recorded as real:** the **$1.87 maximum observed adverse excursion across all 12 live
pairs** is a genuine empirical data point (not clustering-sensitive — it's a single worst-case figure, not an
averaged rate) supporting D-010's deterministic ceiling: the $81/$108 tiers were never remotely threatened by
any real pair run so far. This is risk-side evidence, not profit-side evidence, and should be cited only as
that.

**What replaces this attempt going forward: `tools/evaluate_double_barrier.py` (§12.1)**, a proper symmetric
double-barrier (first-passage) test against the full 5.84M-row archive, addressing ground 2 directly by
design (both barriers evaluated together, not just the favorable one) and ground 1 by using the full 45-day
window's many genuinely-spaced entries rather than 12 clustered real pairs.

### 12.1 `tools/evaluate_double_barrier.py` — design, not yet a finding

Evaluates, for a large sample of entry points across the full archive, `P(τ_TP < τ_SL)` — whether a favorable
barrier (take-profit) is reached before an adverse barrier (stop-loss), symmetric by construction. This
directly answers the question §12's replay could not: does the basis have genuine directional/mean-reverting
tendency beyond what a two-sided random walk with the same volatility would produce, before any of it is
tested against real capital.

- **Entry points:** regular-interval sampling across the full 45-day archive (same approach as
  `simulate_execution.py`), plus the existing threshold-crossing entries from §4/§10 for comparison.
- **Barriers:** symmetric (`±X`) and asymmetric (`+TP, −SL` independently sized) configurations, both required
  — asymmetric-only would reintroduce this section's exact one-sided bias.
- **Null comparison:** a matched Brownian-motion/random-walk simulation using the basis's own measured
  volatility (residual std ≈$2.77, §3) as the null model's diffusion parameter — `P(τ_TP < τ_SL)` under the
  null is computable in closed form for symmetric barriers (≈0.5 by construction) and must be checked, not
  assumed, for any asymmetric configuration. The real question is whether the *measured* first-passage
  probability differs from this null by more than sampling noise explains.
- **Independence handling:** entries must be declustered (minimum spacing, or explicit cluster-robust variance)
  before reporting any hit-rate statistic — this section's own N_eff≈4 failure is the reason that requirement
  is now explicit, not optional.
- **Output:** `P(τ_TP < τ_SL)` for each barrier configuration, with a confidence interval that accounts for
  cluster/overlap structure, compared against the null model's value — not a raw hit-rate percentage on its
  own, which is exactly what made this section's fourth pass look misleadingly strong.

This is read-only research against the existing archive — no live capital, no new data collection required
beyond what's already used elsewhere in this document.

### 12.2 `tools/evaluate_double_barrier.py` — run, 2026-09-19, corrected same day after checking the reverse
direction

**First cut used the wrong null and reached a wrong directional conclusion — corrected below, same day,
prompted by explicitly testing the complementary BUY-futures/SELL-spot direction.** The first run compared
measured `P(TP first)` against the closed-form gambler's-ruin formula (`sl/(tp+sl)`, ≈0.5 for symmetric
barriers), found measured rates 5–19 combined-SE below that, and reported this as evidence *against* the
SELL-futures/BUY-spot direction. Checking the complementary outcome (`P(SL first)` — exactly what a
BUY-futures/SELL-spot variant would capture) surfaced the error: that rate is *also* suppressed below its own
naive null, symmetrically. A single-direction comparison couldn't reveal this; asking about the other
direction did.

**Corrected method:** a Monte Carlo null matched to the actual finite 60-minute horizon (bootstrap-resampled,
demeaned real 5-second increments, 20,000 simulated paths per config), rather than the infinite-horizon
closed form.

| Config | Real P(TP first) vs. matched null | Real P(SL first) vs. matched null | Real fraction "neither" vs. null |
|---|---|---|---|
| Symmetric $0.61 | 0.354 vs 0.503 | 0.307 vs 0.497 | 0.342 vs ~0.00 |
| Symmetric $1.00 | 0.189 vs 0.495 | 0.142 vs 0.505 | 0.669 vs ~0.00 |
| Asym TP0.61/SL1.00 | 0.438 vs 0.607 | 0.109 vs 0.393 | 0.456 vs ~0.00 |
| Asym TP0.61/SL0.31 | 0.184 vs 0.378 | 0.533 vs 0.622 | 0.284 vs ~0.00 |

**Both directions are suppressed relative to their own null, in every configuration, by comparable margins.**
This is not a directional edge for either SELL-futures/BUY-spot or BUY-futures/SELL-spot — it means the real
basis spends far more time inside the barrier band ("neither" hit within 60 minutes) than an i.i.d. bootstrap
of its own price increments predicts. Shuffling destroys serial correlation; the real series clearly has
materially stronger short-term structure than pure noise — consistent with ordinary bid-ask-bounce/dealer-
inventory microstructure mean-reversion, not a directional statistical arbitrage signal. **Neither direction
tested here shows a distinguishable advantage over the other.**

**Limitation, still present regardless of the correction above:** all 52 day-blocks are drawn from one
continuous 45-day window, which independently coincided with a sustained directional move in gold (~8% over
the period, per earlier chat record). Statistically robust within-sample is not the same as externally valid
across regimes.

**Net effect on A4's status at the time:** unchanged — still `RESEARCH/UNVALIDATED, calendar-blocked`. What
this pass actually contributed was a genuine microstructure observation (real range-bound behavior exceeds
what i.i.d. noise predicts) alongside a corrected, honest negative result (no directional edge shown either
way) and a documented methodology error worth remembering: **a one-sided test can hide the exact kind of
mistake this one made — checking the complementary direction is what caught it.**

## 13. Fifth pass, 2026-09-19 — genuine out-of-sample test, first one this project has ever run: the lead does
not replicate

**Setup:** fresh tick collection (`tools/mt5_data_collector.py --ticks --days 3`) covering real market data
strictly after the original 45-day archive's end (2026-09-16 15:26/15:40 UTC) through 2026-09-18 21:49 UTC —
**genuinely unseen data, not a held-out slice of the same window** (§11.1's "held-out" check was still drawn
from the same 2026-07-27..2026-09-16 archive; this is the first test on data that did not exist when the
rolling-r̂ lead was found). Same exact parameters as the second/third pass, no retuning: rolling 24h causal
median implied rate, `mid_basis`, reversion capture, percentiles (0.90, 0.95, 0.99), horizons (15, 60, 240
minutes).

**Result: uniformly negative, all 9 combinations.**

| Percentile | Horizon | n | Mean net-of-cost | Fraction clearing round trip |
|---|---|---|---|---|
| p90 | 15min | 26 | −$0.59 | 0% |
| p90 | 60min | 24 | −$0.68 | 0% |
| p90 | 240min | 24 | −$0.93 | 0% |
| p95 | 15min | 27 | −$0.59 | 0% |
| p95 | 60min | 25 | −$0.68 | 0% |
| p95 | 240min | 25 | −$0.94 | 0% |
| p99 | 15min | 28 | −$0.59 | 0% |
| p99 | 60min | 26 | −$0.68 | 0% |
| p99 | 240min | 26 | −$0.94 | 0% |

**At the 240-minute horizon — the exact configuration that produced the second pass's headline +$0.65
in-sample result — this OOS window shows *negative gross capture* (−$0.43 to −$0.44) before the round-trip
cost is even subtracted.** Not one of the 9 combinations cleared cost even once.

**Honest limitations, stated plainly rather than let the negative result stand unqualified either:**
- **Small window.** Only ~2.3 days of genuinely new data exist as of this writing (the local terminal's
  tick-history cache and elapsed calendar time both bound how much is available). n=24–28 per cell is thin,
  same order of magnitude as the counterfactual replay this document already disqualified for thinness (§12)
  — though the *pattern* here (uniform failure across every configuration) is a materially different, less
  ambiguous signal than a headline hit-rate on a handful of entries would be.
  - **Short-window market conditions may not represent all regimes.** Same caveat as §12.2 — this OOS slice
  is one continuous ~2.3-day period, not multiple independent regimes.

**What this does establish, without needing a bigger sample:** the specific rolling-r̂/mid_basis/reversion
construction that looked promising in-sample and held up on a same-window "held-out" check has now failed its
first genuine test against data it never touched. This is exactly the failure mode out-of-sample testing
exists to catch, and it caught it. **A4's status is downgraded from "one promising lead, not yet validated"
to "the tested lead failed its first out-of-sample check."** More OOS data, as it accumulates, would either
corroborate this failure (further downgrading the lead) or — less likely given the uniformity above — reveal
this window was itself unusual. Either way, this specific signal construction should not be treated as a
live candidate going forward without a materially different result on a larger OOS sample.

**Follow-up same day: re-ran at finer resolution, result strengthens rather than softens.** The table above
uses `analyze_signal_variants()`'s existing 1-minute-bar resampling (keeps only the last tick each minute for
both threshold and entry detection), which was a reasonable default for the original 45-day/multi-comparison
passes but discards most of the real information a thin ~2.3-day OOS window actually has. Added an optional
`resample_freq` parameter (default unchanged, so every prior pass in this document stays reproducible) and
re-ran at 5-second bars and at true raw-tick resolution (every synchronized row, no resampling):

| Resolution | n (240min, p99) | Mean net-of-cost (240min) | Fraction clearing cost |
|---|---|---|---|
| 1-min | 26 | −$0.94 | 0% |
| 5-second | 291 | −$1.14 | 0% |
| Raw tick (every row) | 2,823 | −$1.37 | 0.04% |

Using >100x more of the actual data makes the result **more negative, not less**, and the round-trip-clearing
rate stays effectively zero at every resolution. Caveat: at raw-tick resolution, consecutive entries can be
milliseconds apart and highly overlapping (the same threshold-crossing episode counted many times), so
`n=2823` is not 2823 independent observations — this affects precision, not direction. The direction is
consistent and unambiguous across all three resolutions, which is stronger evidence than the 1-minute result
alone, not weaker.

**Second follow-up, same day: the merge itself was structurally dropping most real spot-tick events.**
`compute_synchronized_basis()` — the canonical merge used across this entire project — anchors every row on a
**futures** tick, backward-asof-matching the nearest prior spot tick. Spot-only tick events (spot price
changes with no new futures tick) never get their own row. Measured in this exact OOS window: 975,287 raw
spot ticks vs. 454,269 raw futures ticks — since the merge can have at most one row per futures tick, well
over half of all real spot price-change events were invisible to every check above, not just this one.

Rebuilt the basis series as a **union** of both legs' ticks (every tick from either symbol gets its own row,
each side forward-filled from its own last known quote) and re-ran:

| Merge / resolution | n (240min, p99) | Mean net-of-cost (240min) | Fraction clearing cost |
|---|---|---|---|
| Futures-anchored, 1-min | 26 | −$0.94 | 0% |
| Futures-anchored, raw tick | 2,823 | −$1.37 | 0.04% |
| Union (both legs), 1-min | 28 | −$1.28 | 0% |
| Union (both legs), raw tick | 9,964 | **−$1.39** | 0.12% |

Using the union merge at raw-tick resolution — the most complete real-data test currently possible, ~400x the
entries of the original 1-minute futures-anchored check — the result holds and deepens slightly further. This
closes out "the futures-anchored merge was hiding something" as an explanation for the negative result. The
fifth pass's conclusion stands on the strongest evidentiary basis this project has produced for any signal
check so far: **the tested rolling-r̂ lead fails out-of-sample, consistently, across every merge methodology
and resolution tried.**

## 14. Sixth check, same day — the original IN-SAMPLE "+$0.65" result itself does not survive the corrected
merge

**This changes the interpretation of everything from section 10 onward.** Q-005 (`OPEN_QUESTIONS.md`) flagged
that the futures-anchored merge might bias results generally, but left open whether it affected the original
45-day in-sample second-pass finding specifically. It does, decisively. Re-running the exact same
rolling-r̂/mid_basis/reversion configuration, exact same 45-day archive (2026-07-27–2026-09-16), exact same
percentiles/horizons — the only change is the union merge (15,184,998 rows, every real tick from both legs,
vs. the original futures-anchored merge's 5,843,313 rows):

| | Original futures-anchored merge (in-sample) | Union merge (same in-sample window) |
|---|---|---|
| p99, 240min mean net capture | **+$0.65** | **−$0.85** |
| p99, 240min fraction clearing round trip | **86%** | **0.4%** |
| n at p99 | 145 | 477 |

**The sign flips entirely, on the same window, the same signal construction, the same everything except which
ticks the merge kept.** This is not a subtle effect — it is the difference between the headline finding that
motivated three subsequent research passes and its near-complete opposite.

**What this means:** the "promising lead" reported in §10 was very likely never a real property of the
basis's behavior. It was consistent with an artifact of the futures-anchored merge — plausibly because
anchoring exclusively on futures-tick events selects for moments correlated with futures-side price activity
in a way that isn't representative of the joint process, systematically distorting the residual `x_t`
wherever it depends on the spot leg's true state between futures ticks. This is a more complete and more
satisfying explanation for §13's out-of-sample failure than "the pattern was real in-sample but didn't
generalize" — the corrected picture is that **it very likely wasn't real in-sample either.**

**Status update:** `15_SIGNAL_RESEARCH.md`'s rolling-r̂ lead is retracted, not merely downgraded. Every result
from §10 through §11 that relied on the futures-anchored merge should be treated as unreliable pending
re-derivation (not done here — out of scope for this check, and A4 has no surviving candidate regardless).
**Q-005 is substantially answered**: the merge bias is real and material, confirmed to reverse at least one
headline result. The document's outstanding open item going forward is not "does this bias matter" but
"re-derive `12_FAIR_VALUE_MODEL.md`/`13_BASIS_MODEL.md`/`14_TRANSACTION_COST_MODEL.md`'s own aggregate
statistics against the union merge before trusting their exact figures for anything precision-sensitive" —
those are more likely to be robust to this bias (aggregate distributional stats vs. this section's
threshold-crossing timing-sensitive tests), but that is now an assumption to verify, not something to take on
faith.
