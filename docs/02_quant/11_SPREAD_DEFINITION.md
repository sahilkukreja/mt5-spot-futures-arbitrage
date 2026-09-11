# Spread Definition

Status: IN PROGRESS — definitions fixed for the VPFX pair; distributional study not yet done

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

## Still to define
- Normalization approach (absolute, percentage, ratio, z-score) — `15_SIGNAL_RESEARCH.md`
- How much of the ~41.8 gap is expected carry-to-expiry vs. abnormal/exploitable — `12_FAIR_VALUE_MODEL.md`,
  `13_BASIS_MODEL.md`
