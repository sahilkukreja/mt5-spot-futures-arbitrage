---
name: arb-hostile-review
description: Adversarially challenge the MT5 spot–futures strategy, economics, architecture, or release stage. Use before implementation, live testing, scaling, or when asked whether the arbitrage can really make money.
---

# Hostile Quant and Architecture Review

## Load first

Read `.claude/skills/PROJECT_STATE.md` before anything else. It carries the current gate status, the measured
constants, the canonical dataset, and the pitfalls that have already cost this project time. It is a cache —
`docs/` wins on any conflict.

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

## An attack that already succeeded — use it as a template

The EV model was wrong by a **sign**, and every cost line in it was correctly sourced. The failure was that
the *revenue* side was never modelled: it compared costs against the basis **level** (about $41) rather than
the basis **change**, so it reported +$33.60 for a 10-day hold where the truth is -$4.31.

Add this to the standing attack list, ahead of the cost-completeness checks:

- **Is the revenue term measured, or assumed?** What quantity does the trade actually capture, and is there a
  measurement of it — with a confidence interval — or only a measurement of the thing it is captured *from*?
- **Does the proposal confuse a level with a change?**
- **Does it confuse carry unwinding with mean reversion?** Here, about 77% of the gap is ordinary carry that
  decays on a schedule and is fully offset by financing.

Also already established, so do not spend the review re-litigating: D-006 rejects hold-to-convergence; the
reverse direction nets +$0.1238/day and is rejected as swap harvesting small relative to a $2.77 residual std;
slippage and latency remain entirely unmeasured, so **no proposal depending on them can receive `READY`**.
