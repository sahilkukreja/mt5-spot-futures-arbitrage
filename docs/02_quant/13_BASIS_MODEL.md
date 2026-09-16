# Basis Model

Status: IN PROGRESS — distribution stats and a tick-level mean-reversion proxy are now computed against real
data. Time-to-convergence (Q-004) is still not resolved to a durable conclusion — see below.

## Purpose
Model the observed spot/futures basis statistically: distribution, mean reversion, and time-to-convergence.

## Basis definitions
For the project, the working basis definitions are:

- `convergence_basis = Bid(GC-Z26) - Ask(XAUUSD.vx)`
- `reverse_basis = Ask(GC-Z26) - Bid(XAUUSD.vx)`
- `mid_basis = Mid(GC-Z26) - Mid(XAUUSD.vx)`

The executable trade is the convergence case when the futures bid is sufficiently above the spot ask to
cover costs and execution friction.

## Distribution metrics (sourced, 2026-09-15/16)

`convergence_basis`, n=707,467, `research/2026-09-15T190918Z/basis_synchronized.csv` (promoted table already
in `11_SPREAD_DEFINITION.md`): mean 41.43, median 41.20, std 1.59, p05/p25/p75/p95 = 39.54/40.01/42.64/44.25,
min 5.07 (isolated anomaly, see below), max 48.28. Not repeated in full here — see `11_SPREAD_DEFINITION.md`
for `reverse_basis` and `mid_basis` too. Skewness/kurtosis not yet computed — not needed for the mean-reversion
analysis below and no downstream document currently depends on it.

Stale-quote rate at `quote_skew_ms > 200`: 131,684 of 707,467 rows (18.6%) — see `01_research`/R-004 note
below; most of the distribution's tail is well inside the 500ms merge tolerance (p95 = 384ms).

## Anomaly isolated (resolves an open item from `11_SPREAD_DEFINITION.md` / R-004)

`tools/q3_q4_research.py`'s `find_basis_anomaly()` (`research/2026-09-15T190918Z/q3_q4_decay_fairvalue_report.json`
→ `R_004_anomaly`) locates the `convergence_basis = 5.07` row precisely: **2026-09-11 13:30:11.218 UTC**, with
context:

| Time (UTC) | `fut_bid` | `fut_ask` | `spot_bid` | `spot_ask` | `convergence_basis` | `quote_skew_ms` |
|---|---|---|---|---|---|---|
| 13:30:01.369 | 4393.18 | 4396.43 | 4352.04 | 4352.39 | 40.79 | 52 |
| 13:30:01.581 | 4360.33 | 4360.78 | 4322.16 | 4334.31 | 26.02 | 52 |
| **13:30:11.218** | **4339.38** | **4342.43** | 4322.16 | 4334.31 | **5.07** | 238 |
| 13:30:17.439 | 4337.83 | 4338.28 | 4296.43 | 4301.02 | 36.81 | 5 |
| 13:30:17.540 | 4338.98 | 4339.43 | 4296.43 | 4301.02 | 37.96 | 106 |

The futures leg repriced sharply three times within ~10 seconds (4393 → 4360 → 4339, a ~54-point drop) while
the spot leg's ask stayed frozen at 4334.31 for that entire window, only catching up to the new level (~4301)
about 6 seconds after the anomalous row. `quote_skew_ms = 238` at the anomalous row is elevated (above the
708k-row median of 108ms) but not extreme (below the p95 of 384ms) — confirming the document's earlier caution
that "a large skew isn't the only way a false basis can appear": this looks like a genuine fast-market
repricing event where the futures feed led and the spot feed lagged by several seconds, not a single
badly-desynchronized tick pair. **Conclusion: real, not a data-quality bug** — a signal engine must guard
against exactly this pattern (leg-level price velocity / a multi-tick confirmation window), not just a static
quote-age threshold, since the skew value alone would not have flagged this row at the 384ms/452ms p95/p99
candidates from Q-003.

## Quote-staleness threshold — research candidate, and why skew alone isn't enough (Q-003, 2026-09-16)

`quote_skew_ms` distribution (n=707,467, `research/2026-09-15T190918Z/q3_q4_decay_fairvalue_report.json`):
p95=384ms, p99=452ms. Stale-rate table already in `11_SPREAD_DEFINITION.md`'s source data shows the tradeoff
directly: a 100ms threshold would reject 53.2% of all ticks (far too restrictive to trade on), while a 400ms
threshold rejects only 4.1%. **Proposed research candidate: 400ms** (close to p95, well clear of the typical
case, still keeps >95% of ticks eligible) — explicitly a research candidate only, not an approved live limit,
per the mandate's `NO MAGIC` rule.

**Known blind spot, confirmed not just hypothesized:** the R-004 anomaly row's own `quote_skew_ms` was 238ms —
comfortably *inside* both the 400ms candidate and the p95 of 384ms. A skew-only gate at any of these candidate
values would **not** have caught it. This was already flagged as a caution; here is the concrete follow-up.

**New finding: per-leg price velocity would have caught it, with a large margin.** Computing tick-to-tick
`|Δfutures_mid| / Δt` across the full 707,467-row series: median 0.25 pts/sec, p95 1.75 pts/sec, p99 3.57
pts/sec, p99.9 8.08 pts/sec, **max 161.6 pts/sec**. That single maximum-velocity event in the *entire 7-day
dataset* occurs at 2026-09-11 13:30:01.581 UTC — the tick immediately **before** the R-004 anomaly row
(13:30:11.218 UTC) — where the futures mid price moved ~34.25 points in 212ms (4394.8 → 4360.6). This is
roughly **20x the p99.9 velocity** anywhere else in the dataset, occurring exactly adjacent to the exact event
a skew-only check misses. This is strong (not conclusive — n=1 extreme event) evidence that a per-leg velocity
check is a better-targeted complementary signal than tightening the skew threshold alone. **Not proposing a
numeric velocity limit yet** — one extreme event doesn't establish a defensible threshold the way the 707k-row
skew distribution does; this needs more occurrences (or a deliberately designed test) before a candidate number
is responsible to propose.

Reproducible via the same `basis_synchronized.csv` used throughout this document; velocity computed as
`fut_mid.diff().abs() / (fut_time_msc.diff()/1000)`.

## Orphan-leg timeout — confirmed still blocked (Q-003, 2026-09-16)

No change from `research_questions_summary.json`'s `insufficient_data` status. Closed-trade durations (hours)
and tick-level quote timing (milliseconds) are both the wrong unit and the wrong measurement for this: an
orphan-leg timeout needs *signal-to-fill* latency from an actual order submission, which requires a live or
demo execution trial that hasn't happened under this project. No proxy in any currently-collected data
measures this — stated plainly rather than substituted with an adjacent number.

## Time-to-convergence: two distinct kinds of evidence, neither sufficient alone

**1. Realized-pair evidence (n=7, unchanged from `14_TRANSACTION_COST_MODEL.md`):** durations ~3–13h, mean
9.91h, 4 of 7 profitable, net +$1.57 after commission, 2026-09-11 through 2026-09-15. Too small to conclude
anything about multi-week behavior; see Q-004 in `OPEN_QUESTIONS.md`.

**2. Tick-level mean-reversion ("decay") proxy — new, this update.** `tools/q3_q4_research.py
analyze_basis_decay()` fits an AR(1) model (`Δbasis_t = a + b·basis_{t-1}`, half-life = `ln(2)/(-b)`) to the
`convergence_basis` series resampled onto several fixed grids, plus autocorrelation of the 1-minute series at
increasing lags. Source: `research/2026-09-15T190918Z/q3_q4_decay_fairvalue_report.json` →
`Q_004_decay_proxy`.

| Resample grid | n bars | AR(1) half-life |
|---|---|---|
| 1 min | 6,883 | **112 min (≈1.9h)** |
| 5 min | 1,381 | 417 min (≈6.9h) |
| 15 min | 461 | 687 min (≈11.4h) |
| 30 min | 231 | 771 min (≈12.9h) |
| 60 min | 116 | 888 min (≈14.8h) |
| 240 min | 32 | 1,491 min (≈24.9h) |

Autocorrelation of the 1-minute series: 0.994 at 1 min, 0.96 at 1h, 0.90 at 4h, 0.80 at 8h, 0.71 at 12h, 0.60
at 24h — decays slowly, never crossing 0.5 within the measured lags.

**What this shows:** the half-life estimate is not stable across resampling grids — it grows roughly 13x from
the 1-minute grid to the 4-hour grid. Combined with the slowly-decaying autocorrelation (still 0.60 after 24h),
this is consistent with two layered effects: a fast, partially mean-reverting intraday component (snapping
back over roughly 2 hours) sitting on top of a slower-moving level that does not fully revert within this
single ~7-day window. The AR(1) fit at coarse grids is likely contaminated by that slow drift (its own implied
long-run mean falls from 41.47 at the 1-min grid to 40.36 at the 4-hour grid, tracking the same week-over-week
drift visible in `14_TRANSACTION_COST_MODEL.md`'s note about the underlying price moving materially over the
week).

**What this does not show:** this is a statistical persistence measure of the raw tick series, not the
duration of an actual entry/exit-threshold-conditioned trade — it does not use, and is not constrained by, any
particular entry or exit rule. It is offered as additional, distinct evidence alongside the n=7 realized-pair
sample, not a replacement for it. Together, both pieces of evidence point the same direction (intraday-to-single-day
resolution is plausible; multi-week behavior remains untested) but neither is individually sufficient to close
Q-004.

## Persistent pair tracking (Q-004, 2026-09-16)

`tools/pair_ledger.py` (new) merges each run's `reconciled_pairs.csv` into a durable, PairID-keyed ledger at
`research/pair_ledger.csv` (gitignored like all other raw research output, same as every other artifact in
this project — periodically promote its summary stats here by hand). PairID = `{spot_position_id}_
{fut_position_id}`, stable since MT5 position IDs are immutable. Re-running it against future `--pairs`
collections lets the realized-pair sample keep growing across weeks instead of resetting to whatever a single
run's account-history window covers — directly addresses Q-004's "n=7 is too small" limitation by making
n grow over time rather than requiring one large one-off collection. Seeded and verified idempotent this
session against the existing 7-pair sample (re-running against the same input leaves the ledger at 7 pairs,
not 14 — confirmed by testing).

## Main risk
The measured basis is only valuable if we know whether it is an actual economic edge or merely a normal
carry pattern — see `12_FAIR_VALUE_MODEL.md`'s implied-carry decomposition (~77% of the average gap is
consistent with SOFR-based carry; ~23% is not). The key missing evidence is the broker settlement/rollover
story (Q-002) and real holding-period statistics beyond both the n=7 sample and the decay proxy's ~7-day
window.

## Current evidence status
- Margin and tick-level executable basis distribution are collected (`11_SPREAD_DEFINITION.md`).
- The R-004 anomaly is now isolated to a specific timestamp and mechanism (fast-market leg lag), not just a
  hypothetical.
- A tick-level mean-reversion decay proxy now exists (this update) as additional Q-004 evidence.
- Q-004 remains open until a materially larger sample of holding periods, or a wider-`T` tick dataset spanning
  weeks rather than days, is observed.
