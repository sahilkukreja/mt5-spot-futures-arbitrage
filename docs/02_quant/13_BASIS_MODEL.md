# Basis Model

Status: IN PROGRESS — distribution stats computed against real data across two independent window widths
(7-day and 45-day). The tick-level mean-reversion ("decay") proxy was re-tested at 45 days and found **not
robust** — its half-life estimates are window-length artifacts, not a real measurement (see below); it is
withdrawn as usable Q-004 evidence pending a de-trended re-implementation. A real, distinct finding survived
this update: the R-004 stale-quote anomaly now has 2 occurrences clustering at the same time of day (13:30
UTC) on two Fridays 7 days apart. Time-to-convergence (Q-004) is still not resolved to a durable conclusion.

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

### Update 2026-09-16 — two more occurrences found, and they cluster suspiciously: same time of day, same weekday

Re-running `find_basis_anomaly()` against the wider 45-day/5,111,120-row dataset
(`research/2026-09-16T140628Z/q3_q4_decay_fairvalue_report.json`) with a broader net (`convergence_basis < 25`,
vs. the original `< 10`) finds **two more anomalous rows, both at 2026-09-04, both within the same ~10-second
window of 13:30 UTC** as the original 2026-09-11 event:

| Date (UTC) | Weekday | Time | `convergence_basis` |
|---|---|---|---|
| 2026-09-04 | Friday | 13:30:01.354 | 3.95 |
| 2026-09-04 | Friday | 13:30:07.947 | 24.60 |
| 2026-09-11 | Friday | 13:30:11.218 | 5.07 (the original finding) |

**All three rows fall within a 17-second window of 13:30 UTC, on two dates exactly 7 days apart, both
Fridays.** 13:30 UTC = 8:30am US Eastern (EDT) — the standard release time for several major US economic
indicators. This is now a real pattern, not a single anomalous tick: 2 of the (roughly 6-7) Fridays in the
45-day window show this exact signature (futures leg repricing sharply while the spot leg's quote lags by
several seconds, producing a momentarily too-small basis). **This is not yet a confirmed root cause** — this
project has not checked which specific data release, if any, was scheduled at 8:30am ET on either date, and
n=2 dates is still a small sample; it could reflect two Fridays that happened to share this property for
unrelated reasons (e.g. some other Friday-specific session/liquidity-provider transition, not a data release).
But it materially raises the anomaly from "one observed instance" to "a plausible recurring, roughly-timed
event." **Actionable implication for signal design:** if this pattern holds, a simple, defensible mitigation is
a fixed no-entry window around 13:30 UTC (needs a proper backtest across more weeks to size the window
correctly — not proposed as a numeric candidate yet, per the mandate's `NO MAGIC` rule) — cheaper and more
targeted than relying solely on the still-unproposed per-leg velocity threshold discussed below.

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

**2. Tick-level mean-reversion ("decay") proxy — first computed on 7 days, re-run on 45 days 2026-09-16, and
the re-run reveals the method itself is not robust at this window length.** `tools/q3_q4_research.py
analyze_basis_decay()` fits an AR(1) model (`Δbasis_t = a + b·basis_{t-1}`, half-life = `ln(2)/(-b)`) to the
`convergence_basis` series resampled onto several fixed grids, plus autocorrelation of the 1-minute series at
increasing lags.

| Resample grid | 7-day half-life (n=707,467) | 45-day half-life (n=5,111,120) |
|---|---|---|
| 1 min | 112 min (≈1.9h) | **1,437 min (≈23.9h)** |
| 5 min | 417 min (≈6.9h) | **4,878 min (≈3.4d)** |
| 15 min | 687 min (≈11.4h) | **9,408 min (≈6.5d)** |
| 30 min | 771 min (≈12.9h) | **11,866 min (≈8.2d)** |
| 60 min | 888 min (≈14.8h) | **22,281 min (≈15.5d)** |
| 240 min | 1,491 min (≈24.9h) | **82,987 min (≈57.6d)** |

Every half-life estimate grew substantially — by roughly 13x at the finest (1-min) grid and by more than 55x at
the coarsest (240-min) grid — simply from widening the observation window, with no change in method.
Autocorrelation at 24h also rose sharply, from 0.60 (7-day pass) to **0.9386** (45-day pass). The AR(1) fit's
own *implied local mean* is the smoking gun: at the 1-min grid it's 51.11, but at the 240-min grid it's
**15.78** — a 35-point swing depending purely on which resampling grid is used, on the *same* underlying
series. Compare this to the fair-value analysis above: the *implied annualized rate* stayed nearly constant
(4.74% → 4.71%) across the identical window widening. **Conclusion: the raw dollar `convergence_basis` series
is not stationary enough, at multi-week scale, for a level-based AR(1)/autocorrelation half-life to mean what
it's supposed to mean.** Gold's spot price moved roughly 8% over this 45-day window, and the basis rode that
trend upward alongside it (mean mid-basis $41.6 → $52.2, tracking `12_FAIR_VALUE_MODEL.md`'s corresponding
finding) — the AR(1) fit at coarse grids is mostly fitting that trend, not genuine mean-reversion speed, so its
half-life estimate balloons. **The 7-day estimate (≈112 min at the 1-min grid) should not be trusted as a
stable number either** — it was likely already somewhat contaminated by the same effect at a smaller scale,
and now demonstrably fails to replicate at a larger one.

**What this does establish, still:** autocorrelation at the 1-minute grid stays extremely high through short
lags in both passes (0.994 at 1 min in both), consistent with real, fast intraday persistence at the shortest
horizons — that part of the finding survives. What does **not** survive is any of the specific half-life
numbers, at any grid — they are artifacts of window length, not a property of the basis series itself.

**Smallest next fix for this specific method (not yet done):** re-run `analyze_basis_decay()` on the *implied
annualized rate* series (already shown to be far more stationary — tight std of 0.09–0.11 pp across both
window lengths) instead of the raw dollar `convergence_basis`, or explicitly de-trend the basis series (e.g.
subtract a rolling mean) before fitting AR(1). Until one of those is done, this decay proxy should be treated
as **not usable evidence for Q-004** — a correction from its prior "additional, distinct evidence" framing.

### Resolved 2026-09-16 — the trend the AR(1) fit kept hitting is now measured, and it is deterministic

The diagnosis above ("the series is not stationary, it rides a trend") was correct but incomplete: it treated
the trend as contamination to be removed. Measuring the trend directly shows it is not noise at all — **it is
the signal, and it has the wrong sign for the trade.**

Source: `research/export-full/basis_summary.json` (`tools/tick_export_loader.py`, full terminal tick exports,
6,520,722 futures + 8,798,113 spot ticks, 2026-07-27 → 2026-09-16, 5,843,313 synchronized rows at 500 ms).
OLS of daily mean `convergence_basis` on calendar day across the 38 full sessions (thin Sunday sessions with
<20,000 ticks excluded):

| Quantity | Value |
|---|---|
| Slope | **−$0.3905/day** (1 s.e. $0.0293; 95% CI −$0.4480 … −$0.3330) |
| R² | 0.8312 |
| Residual std about the trend | $2.77 |
| Fitted start → end | $62.43 → $42.52 over 51 days |

`12_FAIR_VALUE_MODEL.md`'s carry model independently predicts −$0.4832/day over the same window (4.71% implied
rate, `T` falling 0.3313 → 0.1916 years). Same sign, same magnitude. **The basis is not mean-reverting around
a level; it is decaying monotonically toward zero as the contract approaches expiry, because it is carry
unwinding.**

That resolves the AR(1) puzzle completely. A level-based AR(1) fit on a series with a strong deterministic
drift will always report a long and window-dependent "half-life", because there is no fixed mean to revert to
— the mean itself is moving at $0.39/day. The half-lives were not measuring a slow mean-reversion; they were
measuring the drift. Widening the window made the drift dominate more, which is exactly why every estimate
inflated. **The de-trended re-run proposed above is still worth doing** to characterise the *residual* around
the drift (std $2.77, and the intraday behaviour that matters for a signal), but it will not rescue the
original interpretation, and Q-004 should no longer be framed as "how long until the basis reverts".

**Update 2026-09-19 (`OPEN_QUESTIONS.md` Q-005) — this decay rate is confirmed robust to a later-discovered
merge-methodology bias.** The canonical futures-anchored tick merge was found to materially distort a
different, timing-sensitive statistic (an A4 signal candidate's threshold-crossing test, reversed entirely
under a corrected union merge — `15_SIGNAL_RESEARCH.md` §14). Re-deriving this decay regression on the same
union merge gives −$0.3873/day (R²=0.794, n=5,843,313 futures-anchored) vs. −$0.3877/day (R²=0.797,
n=15,184,998 union) — agreement to within $0.0004/day. This aggregate, slow-moving 51-day trend does not
share the signal-timing statistic's sensitivity to which ticks the merge kept. Treat this figure, and D-006's
conclusion built on it, as unaffected by Q-005.

**Why this matters more than the method fix:** at −$0.3905/day of decay captured against −$0.7714/day of
one-sided spot swap paid, the hold-to-convergence trade is negative-carry at every holding period, with a 95%
confidence interval that does not touch zero. The full derivation and its consequences are in
`17_EXPECTED_VALUE.md` → "Correction 2026-09-16". Q-004's original question — *how long to hold* — has a
measured answer for this structure: **not overnight**, because the decay never outruns the swap.

**What this does not show, unchanged:** even a correctly-detrended version of this proxy would still be a
statistical persistence measure of the raw tick series, not the duration of an actual entry/exit-threshold-conditioned
trade. It would remain additional evidence alongside the n=7/n=8 realized-pair sample, not a replacement for
it.

## Persistent pair tracking (Q-004, 2026-09-16, updated same day)

`tools/pair_ledger.py` merges each run's `reconciled_pairs.csv` and `open_pairs_censored.csv` into a durable,
PairID-keyed ledger at `research/pair_ledger.csv` (gitignored like all other raw research output — periodically
promote its summary stats here by hand). PairID = `{spot_position_id}_{fut_position_id}`, stable since MT5
position IDs are immutable. **Confirmed working as intended, same day:** the 45-day collection run found the
previously-"currently open" 8th pair (`34231073`/`34231072`) had since closed (entry basis 40.37, exit 40.22,
duration 2.16h, net +$0.05) — the shortest-held pair in the sample so far — and found **4 new pairs opened and
still open** (real, live positions on the account, not this project's output; see
`14_TRANSACTION_COST_MODEL.md` "Currently open positions"). Re-running the ledger against this data correctly
grew it from 7 closed to **8 closed + 4 open = 12 total tracked pairs**, transitioning the 8th pair from `open`
to `closed` in place rather than duplicating it — exactly the behavior this mechanism was built for. **Data
quality note:** three of the four open pairs' snapshot `duration_hours_at_snapshot` came out slightly negative
(as low as −0.65h) in this run, almost certainly a small clock-sync offset between this machine and the MT5
terminal/broker server rather than a real negative duration; does not affect any closed-pair statistic (which
use `close_time − open_time`, immune to any single clock's absolute offset).

**Updated n=8 closed-pair statistics** (`Q_004` in `research/2026-09-16T140628Z/research_questions_summary.json`):
durations 2.16–12.74h, median 11.13h, mean 8.95h (down slightly from 9.91h with n=7, pulled down by the new
2.16h pair), 5 of 8 profitable, still net positive. Still far too small a sample for a multi-week conclusion —
this is expected to keep growing slowly as the ledger is re-run over the coming weeks.

## Main risk
The measured basis is only valuable if we know whether it is an actual economic edge or merely a normal
carry pattern — see `12_FAIR_VALUE_MODEL.md`'s implied-carry decomposition, now validated across two window
widths (~77% of the average gap consistent with SOFR-based carry; ~23% is not, confirmed stable at both 7-day
and 45-day sample sizes). The key missing evidence is the broker settlement/rollover story (Q-002) and real
holding-period statistics beyond both the n=8 closed-pair sample and a still-usable decay/persistence measure
(the current one is withdrawn as unreliable — see above).

## Current evidence status
- Margin and tick-level executable basis distribution are collected at two window widths
  (`11_SPREAD_DEFINITION.md`, and the 45-day/5.1M-row extension referenced above).
- The R-004 anomaly now has 3 occurrences across 2 dates, both Fridays, clustering within 17 seconds of 13:30
  UTC — upgraded from a single isolated event to a plausible recurring pattern.
- The tick-level mean-reversion decay proxy was tested at 45 days and found **not robust** (half-life estimates
  are window-length artifacts) — withdrawn as usable Q-004 evidence pending a de-trended re-implementation
  (proposed: run it on the implied-rate series instead of raw dollar basis).
- The persistent pair ledger (`tools/pair_ledger.py`) is confirmed working end-to-end: correctly transitioned
  a pair from open to closed and grew from 7 to 12 tracked pairs (8 closed, 4 open) across two real runs.
- Q-004 remains open until a materially larger sample of holding periods is observed — the ledger mechanism now
  exists to accumulate that over time, but n=8 is still far too small for a multi-week conclusion.
