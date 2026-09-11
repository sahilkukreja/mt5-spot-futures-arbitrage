---
name: arb-hostile-review
description: Adversarially challenge the MT5 spot–futures strategy, economics, architecture, or release stage. Use before implementation, live testing, scaling, or when asked whether the arbitrage can really make money.
---

# Hostile Quant and Architecture Review

Try to disprove the proposal. Do not optimize it until its failure case is clear.

## Context selection

Read the proposal, its directly cited evidence, cost and hedge-ratio models, relevant execution design, and applicable risk entries. Do not preload unrelated documents or prior implementations.

## Attack surfaces

- Normal basis or carry mistaken for abnormal edge
- Mid-price or stale-quote profit that cannot be executed
- Missing spread, commission, swap, funding, rollover, FX, or exit cost
- Slippage and latency distributions replaced by averages
- Unequal contract exposure or minimum-lot residual delta
- Asynchronous fills, rejected/partial legs, race conditions, retries, and duplicate orders
- Look-ahead, survivorship, timestamp, synchronization, and backtest bias
- Regime change, expiry, session boundaries, liquidity withdrawal, disconnects, and margin stress
- Broker terms, last-look behavior, trade cancellation, and strategy restrictions
- USD 1,000 capital made unsafe by tail loss or combined margin

Continuously ask: if this edge is obvious, why has competition not eliminated it?

## Verdict

Classify `READY`, `READY WITH CONDITIONS`, or `NOT READY`.

List fatal flaws first, then unsupported assumptions, sensitivity/break-even analysis, evidence that would change the verdict, mandatory tests, and optional improvements. A missing critical input cannot receive `READY`. Never authorize live trading.
