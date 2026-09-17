---
name: arb-research
description: Research and document gold spot–futures economics for the MT5 arbitrage project, including instruments, executable spread, fair value, basis, costs, data, hedge ratio, and expected value. Do not use for MQL5 implementation.
---

# Arbitrage Research

## Load first

Read `.claude/skills/PROJECT_STATE.md` before anything else. It carries the current gate status, the measured
constants, the canonical dataset, and the pitfalls that have already cost this project time. It is a cache —
`docs/` wins on any conflict.

Produce evidence-backed research, not trading claims.

## Context budget

Read `docs/PROJECT_MANDATE.md`, then only the target document and its direct dependencies:

- Instrument mechanics → `docs/01_research/`
- Data/spread/fair value/basis/costs/signals/hedge ratio/EV → `docs/02_quant/`
- Existing accepted decisions → search `docs/DECISION_LOG.md` for the relevant term before loading more.

Do not read source code or prior-bot material unless the user explicitly requests comparison or empirical extraction.

## Required reasoning

- Distinguish true arbitrage, basis, relative value, statistical arbitrage, latency arbitrage, broker dislocation, and mean reversion.
- Use executable bid/ask prices for trade eligibility; label mid-price analysis separately.
- Explain expected basis through carry, time to expiry, funding, settlement, hours, and contract structure.
- Calculate notional and tick-value exposure independently. Never assume equal lot numbers imply a hedge.
- Include spreads, commissions, entry/exit slippage, swap/funding, rollover, FX, latency uncertainty, and an execution-risk buffer.
- Separate sourced facts, calculations, assumptions, and hypotheses.
- Reject a proposal whose edge is small relative to uncertainty.

## Deliverable

Update one primary research document. Include objective, evidence, formulas with units, assumptions, unresolved questions, risks, validation data, and decisions proposed. Update `docs/OPEN_QUESTIONS.md` and `docs/DECISION_LOG.md` only for material changes; do not duplicate the full analysis there.

Do not invent broker specifications or magic thresholds. End with the smallest next empirical test.

## What is established, and when to reopen it (updated 2026-09-18)

See `.claude/skills/PROJECT_STATE.md` for the measured constants, the decisive D-006 finding, and the
canonical 5.8M-row dataset. Do not silently re-run an established measurement out of habit — but **do reopen
a finding when the request specifically challenges its assumptions or arithmetic**, and say plainly whether
the challenge holds up or not. Two examples so far: `12_FAIR_VALUE_MODEL.md` "Residual dispersion and
reversion" (2026-09-18) reopened whether the carry-baseline residual has measurable dispersion/opportunity —
it did, refuting a specific speculative concern rather than just re-confirming the original finding. A
proposal's swap-calendar critique (`docs/Gold-Basis-EA-Strategy-and-System-Design.md` §4.3) was checked
against MQL5's own triple-swap documentation rather than accepted or dismissed on authority alone. Re-deriving
on request is not the failure mode this section originally guarded against; *accepting an unchallenged
re-assertion of a wrong number* is. Key methodological lessons earned here:

- **Model the revenue term, not just costs.** The EV model's sign was wrong for weeks because it compared
  costs against the basis *level* instead of its *change*. Before reporting any edge, ask what quantity the
  trade actually captures and whether it has been measured.
- **Test a short-window estimate at a longer window before trusting it.** The AR(1) half-life looked plausible
  at 7 days and inflated 13–55x at 45 days. The series was non-stationary.
- **Distinguish carry unwinding from mean reversion.** This basis decays deterministically toward zero as
  `T` approaches 0; it does not revert to a level. About 77% of the gap is ordinary carry and is not
  capturable.
- The ~23% residual over SOFR may be broker CFD markup rather than mispricing. No second broker's quotes
  exist, so this cannot be settled — say so rather than implying edge.
- **A number marked "Sourced" in `docs/` can still be worth re-verifying if an external, specific critique
  arrives** — check it against a primary source before accepting or rejecting the critique, don't just trust
  whichever side asserted more confidently. The swap-calendar item above is currently flagged for
  reconciliation, not settled, precisely for this reason.

## Feasibility / strategy-comparison requests

When asked "is this strategy feasible" or to compare candidate approaches (not just measure one thing):
deliver a comparison table of candidate mechanisms with what each one's edge would actually come from, its
main weakness, and a design/economic recommendation — not just a single measurement. Distinguish "useful
model/representation" from "proven edge" explicitly for each candidate; a technique can be a legitimate
building block (e.g. a robust z-score, a Kalman baseline) without itself establishing that a profitable
signal exists. End with a decision or a clearly stated recommendation, not just an open question, when the
request was framed as a feasibility judgment call.

## Reproduction

`tools/tick_export_loader.py` (terminal exports, offline) and `tools/mt5_data_collector.py --ticks` (live API)
produce identical column semantics. `tools/q3_q4_research.py` does decay/anomaly/fair-value analysis, plus
(added 2026-09-18) `analyze_residual_reversion()` for carry-baseline residual dispersion/reversion.
Cross-validated: quote skew p95 387 ms (export) vs 384 ms (API).
