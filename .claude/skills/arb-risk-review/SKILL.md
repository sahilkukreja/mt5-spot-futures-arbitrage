---
name: arb-risk-review
description: Review capital, hedge exposure, margin, failure loss, limits, kill switches, broker constraints, and stage-graduation safety for the MT5 arbitrage project. Use for the USD 1,000 and 0.01-lot test constraint or any risk-sensitive change.
---

# Arbitrage Risk Review

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
