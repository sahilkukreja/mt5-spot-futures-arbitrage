---
name: arb-risk-review
description: Review capital, hedge exposure, margin, failure loss, limits, kill switches, broker constraints, and stage-graduation safety for the MT5 arbitrage project. Use for the USD 1,000 and 0.01-lot test constraint or any risk-sensitive change.
---

# Arbitrage Risk Review

## Load first

Read `.claude/skills/PROJECT_STATE.md` before anything else. It carries the current gate status, the measured
constants, the canonical dataset, and the pitfalls that have already cost this project time. It is a cache —
`docs/` wins on any conflict.

Assume capital preservation outranks return.

## Minimal context

Read `docs/PROJECT_MANDATE.md`, the proposal under review, and relevant entries from `docs/RISK_REGISTER.md`. Read broker/quant documents only when their numbers feed the risk calculation.

## Mandatory checks

- Identify both legs' contract size, tick size/value, currency, lot step, margin method, and leverage.
- Calculate notional, delta/tick-value mismatch, combined margin, free margin, margin level, and residual exposure.
- Stress normal divergence, abnormal divergence, delayed hedge, rejected hedge, worst observed slippage, disconnect, and emergency flatten.
- Evaluate per-trade, daily, weekly, drawdown, concurrency, holding-time, quote-age, latency, slippage, margin, expiry, and position-mismatch limits.
- Reject unexplained numerical limits.
- Confirm no martingale, grid averaging, loss-recovery sizing, or hidden directional exposure.
- Check broker terms and applicable regulatory constraints before live approval.

The target `0.01 lot` is not approval to trade equal lots. USD 1,000 is a hard experimental-capital ceiling, not proof of adequate margin.

## Verdict

Return `APPROVE`, `APPROVE WITH CONDITIONS`, or `REJECT`, followed by decisive evidence, breached invariants, required mitigations, unresolved inputs, and the exact re-test needed. Update the risk register only when the repository change is requested.

## Project-specific risk inputs (2026-09-16)

- **R-002 has materialized, not just been identified.** Net carry on the overnight convergence structure is
  **-$0.3809/day with a 95% CI entirely below zero**. See D-006. Any proposal relying on overnight basis
  convergence should be rejected on this basis alone.
- Margin: about $129.67 combined per 0.01/0.01 pair. 4 concurrent pairs gives about $525, margin level about
  191% (vs about 771% for one). Margin-stress is **not** the binding risk at this size — a 20% adverse move
  adds only about $26. The binding risk is notional directional exposure during a leg mismatch (R-003).
- Swap is asymmetric and one-sided: spot -60 pts/day long, +40 short; futures disabled.
- Rollover: no successor symbol exists (R-005). Expiry 25 Nov 2026 with no machine-readable expiry field.
- Orphan-leg timeout remains **uncalibrated and unmeasurable** without a live/demo execution trial. Do not
  accept a proposed number for it.
- A useful risk-control taxonomy extracted from the legacy project (as reference only): daily-loss-percent
  *plus* a separate consecutive-loss count, weekly drawdown percent, and an equity-drawdown pause that
  requires manual restart rather than auto-clearing.
