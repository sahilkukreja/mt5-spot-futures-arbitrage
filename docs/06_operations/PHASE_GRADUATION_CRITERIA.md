# Phase Graduation Criteria

Status: **PROPOSED — fills a gap the mandate names but leaves undefined. Not yet reviewed by
`/arb-risk-review`.** This document itself does not authorize any transition; it defines what a transition
requires, and the requirements still have to be met.

## Why this document exists

`docs/PROJECT_MANDATE.md` defines two overlapping frameworks and states a rule for each, without ever filling
either in:

1. **The stage pipeline** — RESEARCH → ... → SIMULATION → IMPLEMENTATION → UNIT TESTING → TICK REPLAY →
   DEMO TESTING → LIVE OBSERVATION → USD 1,000/0.01 LOT FORWARD TEST → REVIEW → ITERATION → PRODUCTION
   CONSIDERATION, with the rule *"No stage should be skipped merely to reach live trading faster."*
2. **The phase list** — Phase 0 (data collection) through Phase 6 (production consideration), with the rule
   *"Each phase requires explicit graduation criteria."*

Neither framework says what "LIVE OBSERVATION" means, or what evidence closes any transition. That gap was
flagged as a blocking precondition when `D-008` (the live execution-measurement trial) was proposed: it places
real orders on the live account while the project sits in Phase 0, and no criteria existed to say whether that
is permitted. This document closes that gap for the transitions that matter right now, and states honestly
which later ones are deferred and why.

## The two frameworks, reconciled

| Stage pipeline | Phase list | Relationship |
|---|---|---|
| RESEARCH → SIMULATION | Phase 0 — data collection | Same thing, different granularity |
| IMPLEMENTATION → UNIT TESTING → TICK REPLAY | (within Phase 0/1 boundary) | Code exists, no capital at risk |
| DEMO TESTING | Phase 1 — demo trading | Same thing |
| **LIVE OBSERVATION** | **(not named in the phase list)** | See below — this is the gap |
| USD 1,000/0.01 LOT FORWARD TEST | Phase 2 — USD 1,000/0.01 lot | Same thing |
| REVIEW → ITERATION | (between phases) | Recurring, not a one-time gate |
| PRODUCTION CONSIDERATION | Phase 6 — production consideration | Same thing |
| (not named) | Phase 3 — extended 0.01 validation | Sits inside "REVIEW → ITERATION", repeated |
| (not named) | Phase 4 — limited sizing increase | Same |
| (not named) | Phase 5 — multiple pairs | Same |

**LIVE OBSERVATION has no defined content anywhere in the mandate.** Its position in the pipeline — after
demo, before the forward test — is the only evidence of intent: it is live, but it precedes the stage where the
*strategy* is actually forward-tested.

### What LIVE OBSERVATION is, for this project

**A live-account activity that places real orders under the USD 1,000/0.01-lot capital constraint, but does
not constitute the strategy's forward test, because no strategy exists yet to test.** `15_SIGNAL_RESEARCH.md`
is unwritten, D-006 has already rejected one candidate structure, and `17_EXPECTED_VALUE.md`'s economics gate
is open. There is nothing to forward-test.

D-008's execution-measurement trial is exactly this: real fills, real broker responses, bounded capital, **zero
signal logic and zero profit objective** (`35_1000_USD_LIVE_TEST_PLAN.md` §1, §3). It belongs at LIVE
OBSERVATION, not at the USD 1,000/0.01 LOT FORWARD TEST, because it observes the *venue*, not a *strategy*.

This resolves the phase-skip concern without stretching either framework: the pipeline already names a live,
pre-forward-test stage; D-008 is the first thing to occupy it.

## Graduation criteria — the transitions relevant now

### DEMO TESTING → LIVE OBSERVATION (unblocks D-008)

All of the following, in order:

1. `04_testing/34_DEMO_TEST_PLAN.md` Stage 0 (dry run) passes every acceptance test T1–T12.
2. Stage 1 (20 demo pairs) completes with **zero journal-to-broker reconciliation mismatches**. Its slippage
   and rejection-rate outputs are discarded per that document's own scope note — they do not count as evidence
   here, only mechanical correctness does.
3. `/arb-risk-review` verdict recorded against the **live** plan specifically (the existing verdict was
   recorded against the demo-only design and does not cover live capital — see `RISK_REGISTER.md` note below).
4. `/arb-hostile-review` verdict recorded against the **live** plan specifically, for the same reason.
5. `D-008` accepted in `DECISION_LOG.md`.
6. The account precondition in `35_1000_USD_LIVE_TEST_PLAN.md` §7 resolved (dedicated account, or existing
   positions closed) — **open, the account owner's decision, not resolvable by this document.**
7. The capital owner explicitly authorizes the budget (USD 149.25 guaranteed, USD 250 hard stop) before Stage
   2 (the first live order) fires.

Criterion 6 and 7 are the only two remaining before implementation may begin. This document does not resolve
either — it only establishes that they, specifically, are what stands between here and LIVE OBSERVATION.

### LIVE OBSERVATION → USD 1,000/0.01 LOT FORWARD TEST (not triggered by D-008)

Stated explicitly so completing D-008 is never mistaken for graduation to the forward test:

1. `15_SIGNAL_RESEARCH.md` exists and identifies a candidate structure.
2. `17_EXPECTED_VALUE.md`'s economics gate closes — Net Executable Edge exceeds a Required Safety Margin
   derived by a methodology that has itself survived review (the margin's current methodology is not
   achievable at this capital base — see `17_EXPECTED_VALUE.md` → "Update 2026-09-16" and `RISK_REGISTER.md`
   R-008 — so this criterion cannot be met until that is resolved, independent of anything D-008 produces).
3. `03_system_design/` reaches a design-gate `READY` or `READY WITH CONDITIONS` verdict from
   `/arb-hostile-review`, with every UNCALIBRATED parameter either calibrated from D-008's output or
   explicitly and separately justified.
4. `/arb-risk-review` APPROVE or APPROVE WITH CONDITIONS on the complete system, not the harness alone.
5. `06_operations/53_KILL_SWITCH.md` and `06_operations/54_RECOVERY_RUNBOOK.md` exist and are exercised in
   simulation or tick replay (`04_testing/31`–`33`).
6. A rollover runbook exists and is exercised, given R-005 (no successor `GC-Z26` contract month is currently
   visible in this account).

**None of these exist yet.** D-008's own output feeds criterion 2 and 3 but satisfies neither by itself.

## Deferred — Phases 3 through 6

Extended validation, sizing increases, multi-pair scaling, and production consideration each need their own
graduation criteria, derived from evidence that does not exist yet (there is no forward-test track record to
derive them from). Writing those criteria now would mean inventing numbers ahead of any data to derive them
from — exactly what `NO MAGIC OAG/CAG VALUES` prohibits. They are deferred, not skipped: this document will be
extended when the USD 1,000/0.01 LOT FORWARD TEST produces the evidence to derive them from.

## Regression — what forces a return to an earlier stage

Per the mandate's `REVIEW → ITERATION` loop and consistent with the kill-switch designs already specified:

- Any `HALTED` kill-switch trip during LIVE OBSERVATION returns the project to DEMO TESTING for root-cause
  analysis before any further live order is placed.
- R-007/R-008-class findings — a measurement later shown to be invalid or unachievable — return the affected
  conclusion to research status, not forward.
- A `RECONCILIATION_REQUIRED` state that cannot be resolved against broker records halts the trial and forces
  a design review before resuming.

## What this document does not do

It does not authorize D-008, resolve the account precondition, or approve any budget. It exists so that when
those are resolved, "no graduation criteria exist" is no longer the reason to stop.
