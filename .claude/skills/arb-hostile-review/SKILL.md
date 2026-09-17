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
the *revenue* side was never modelled: it compared costs against the basis **level** (about USD 41) rather than
the basis **change**, so it reported +USD 33.60 for a 10-day hold where the truth is -USD 4.31.

Add this to the standing attack list, ahead of the cost-completeness checks:

- **Is the revenue term measured, or assumed?** What quantity does the trade actually capture, and is there a
  measurement of it — with a confidence interval — or only a measurement of the thing it is captured *from*?
- **Does the proposal confuse a level with a change?**
- **Does it confuse carry unwinding with mean reversion?** Here, about 77% of the gap is ordinary carry that
  decays on a schedule and is fully offset by financing.

**Already established — cite rather than re-derive from scratch, but do not refuse to recheck the arithmetic
if a proposal specifically challenges it.** D-006 rejects hold-to-convergence; the reverse direction nets
+USD 0.1238/day and is rejected as swap harvesting small relative to a USD 2.77 residual std. **Both figures
depend on the ×9/7 swap-calendar convention, which an external proposal disputed 2026-09-18
(`docs/Gold-Basis-EA-Strategy-and-System-Design.md` §4.3) — checked against MQL5's own triple-swap
documentation and found to match standard practice, but flagged for reconciliation against the actual broker
schedule, not settled by that check alone.** If a future proposal's challenge to either number holds up under
the same scrutiny, correct it and update `DECISION_LOG.md`/`RISK_REGISTER.md` accordingly — "established"
means "verified, not re-derived on request," not "immune to a specific, checkable challenge."

**Slippage/latency status, corrected 2026-09-18: no longer entirely unmeasured, but still far too little to
rely on.** Two real Stage 2 pairs have run (2026-09-17), producing the first real fill/slippage data this
project has ever had. n=2 is nowhere near enough for a defensible distribution — **a proposal still cannot
receive `READY` on the strength of it** — but "entirely unmeasured" is no longer literally accurate; say "n=2,
not yet a distribution" rather than "unmeasured," and check `PROJECT_STATE.md`'s gate table for the current
pair count before citing this.

## Additional attack patterns (added 2026-09-18, from a real review)

Found while hostile-reviewing `docs/Gold-Basis-EA-Strategy-and-System-Design.md` — add these to the standing
list, they generalize beyond that one document:

- **Double-counted costs.** Check whether spread is subtracted once (via executable bid/ask entry/exit
  formulas) or twice (once implicitly in the bid/ask spread, again as a separate mid-price adjustment). A
  proposal can get every individual cost line right and still double-count by combining a bid/ask-based P&L
  formula with an additive spread-cost term.
- **Conditional vs. unconditional returns.** A baseline/rate that is stable *on average* (e.g. this project's
  own 4.71% implied carry, IQR only 13bp) does not by itself establish that *deviations* from that baseline —
  the actual quantity a mean-reversion strategy trades — behave the same way. Ask whether the evidence cited
  supports the unconditional baseline's stability or the conditional residual's own dispersion/reversion;
  these are different claims and the second is usually the one that matters and the one least likely to have
  been measured.
- **Overlapping samples.** A "7-day" and a "45-day" dataset that share the same underlying 7 days are not two
  independent confirmations — say so explicitly rather than letting a second, larger number read as
  independent replication when it isn't.
- **Profit-only exits.** A strategy with a "take profit at target" rule but no clearly specified loss/max-
  hold/model-invalidity/deadline exit is not a complete strategy — it silently becomes an unplanned
  hold-to-convergence trade on exactly its losing positions, the structure D-006 already rejected.
