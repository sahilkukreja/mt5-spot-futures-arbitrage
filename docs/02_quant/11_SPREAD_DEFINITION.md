# Spread Definition

Status: IN PROGRESS — definitions fixed; **real tick-level executable distribution now collected**
(2026-09-15, 707,580 synchronized rows over 7 days). Satisfies `10_DATA_REQUIREMENTS.md`'s bid/ask
requirement and the `08_TICK_DATA_COLLECTION.md` acceptance criteria. Still needed: fair-value decomposition
(`12_FAIR_VALUE_MODEL.md`) and time-to-convergence (`13_BASIS_MODEL.md`, Q-004).

## Purpose
Precisely define the spread(s) being studied, using executable prices, not mid prices.

## Instruments (see `01_research/07_BROKER_RESEARCH.md`)
- S1 (futures leg): `GC-Z26` on VPFX
- S2 (spot leg): `XAUUSD.vx` on VPFX
- Observed 2026-09-11/12: `GC-Z26` trades at a **premium** to `XAUUSD.vx` (e.g. bid 4389.65–4389.75 vs spot
  ask 4347.82–4347.93) — consistent with contango / positive cost-of-carry to the 25 Nov 2026 expiry. This is
  an observation from a couple of snapshots, not yet a studied distribution.

## Executable spread definitions

Because `GC-Z26` trades above `XAUUSD.vx`, the convergence trade is to **sell the rich leg (futures), buy the
cheap leg (spot)**, expecting the premium to shrink as expiry approaches (or on any transient overreaction).

- **Convergence entry gap** (SELL futures / BUY spot): `Bid(GC-Z26) − Ask(XAUUSD.vx)`
  — this is what's actually receivable/payable if both legs fill at the current best executable prices.
- **Reversal/exit or opposite-direction gap** (BUY futures / SELL spot): `Ask(GC-Z26) − Bid(XAUUSD.vx)`
  — always ≥ the convergence gap, since it crosses the spread on both legs; this is the cost of *unwinding*
  or of taking the opposite-direction trade, not a second source of edge.
- **Mid-price gap** (research/statistics only, never a trading price): `Mid(GC-Z26) − Mid(XAUUSD.vx)`

## Observed snapshot values (not a distribution — single points in time)

| Time (server, approx) | Bid(GC-Z26) | Ask(XAUUSD.vx) | Convergence gap |
|---|---|---|---|
| 2026-09-11 21:33 | 4389.65 | 4347.82 | 41.83 |
| 2026-09-11 21:35 | 4389.75 | 4347.93 | 41.82 |

Two snapshots ~90 seconds apart, gap essentially flat (41.82–41.83). Not remotely sufficient to characterize
mean, variance, or convergence behavior — see `10_DATA_REQUIREMENTS.md` for what's needed before thresholds
can be derived (per the mandate's `NO MAGIC OAG/CAG VALUES` section).

## M1 bar-close gap distribution (2026-09-15, approximation)

`tools/mt5_data_collector.py`'s default (non-`--ticks`) run pulled 7 days of M1 bars for both symbols and
computed `gap_close_to_close = fut_close − spot_close` (6,883 matched bars):

| Stat | Value |
|---|---|
| mean | 41.79 |
| median | 41.57 |
| std | 1.69 |
| min | 39.01 |
| max | 45.58 |
| p05 / p25 / p75 / p95 | 39.74 / 40.24 / 43.38 / 44.71 |

Source: `research/2026-09-15T170138Z/gap_summary.json` (gitignored raw output; this table is the promoted
record). **This is still an approximation, not the executable distribution**: it uses bar CLOSE prices, not
true bid/ask, and close-to-close differencing can mask intra-bar divergence between the two feeds. It
supersedes the two-snapshot table above as a first-pass sanity check (same ~41–42 range, now with visible
variance) but does **not** satisfy `10_DATA_REQUIREMENTS.md`'s bid/ask requirement — the `--ticks` run
(`mt5.copy_ticks_range()` + `pd.merge_asof()`) is still required before this feeds
`14_TRANSACTION_COST_MODEL.md` or `17_EXPECTED_VALUE.md`.

## Tick-level executable distribution (2026-09-15) — real data, supersedes the M1 approximation

`tools/mt5_data_collector.py --ticks` (fixed and run this session) pulled 7 days of true bid/ask ticks for
both symbols via `mt5.copy_ticks_range()` and merged them with `pd.merge_asof()` (backward, 500ms tolerance).
Source: `research/2026-09-15T181953Z/basis_summary.json` (gitignored; table below is the promoted record).

| Stat | `convergence_basis` (Bid fut − Ask spot) | `reverse_basis` (Ask fut − Bid spot) |
|---|---|---|
| n | 707,580 | 707,580 |
| mean | 41.45 | 41.85 |
| median | 41.24 | 41.65 |
| std | 1.60 | 1.59 |
| min | **5.07** | 20.27 |
| max | 48.28 | 48.68 |
| p05 / p25 / p75 / p95 | 39.54 / 40.01 / 42.73 / 44.27 | 39.94 / 40.41 / 43.13 / 44.67 |

`quote_skew_ms` (time between the matched spot/futures ticks): mean 130.6ms, median 108ms, p95 384ms, max
500ms (the merge tolerance) — mostly tight, with a real tail approaching the tolerance boundary.
`convergence_basis` was never negative (0 of 707,580 rows) — consistent with sustained contango over this
window, satisfying `08_TICK_DATA_COLLECTION.md` AC-6/AC-7.

**This is the real distribution this project has needed since `10_DATA_REQUIREMENTS.md` was written** —
executable bid/ask, not bar closes or point-in-time snapshots. Mean/median (~41.2–41.5) are close to both
prior approximations (M1-bar mean 41.79, two-snapshot ~41.8), which is a good consistency check across three
independent methods.

**Anomaly, not yet explained:** `convergence_basis.min = 5.07` — a collapse to roughly an eighth of the
typical gap, far outside the p05 of 39.54 and nowhere near the rest of the distribution. This is almost
certainly a stale/asynchronous-quote artifact (one leg's quote lagging badly at that instant) rather than a
real tradeable event — **directly the failure mode `docs/RISK_REGISTER.md` R-004 describes**, now with a real
occurrence in the data rather than a hypothetical. Not yet isolated to a specific timestamp or investigated
further; a signal engine that reacted to this row at face value would have proposed a very wrong trade. See
R-004 update.

## Still to define
- Normalization approach (absolute, percentage, ratio, z-score) — `15_SIGNAL_RESEARCH.md`
- How much of the ~41.8 gap is expected carry-to-expiry vs. abnormal/exploitable — `12_FAIR_VALUE_MODEL.md`,
  `13_BASIS_MODEL.md`
