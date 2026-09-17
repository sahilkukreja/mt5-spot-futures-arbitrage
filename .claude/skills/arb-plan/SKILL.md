---
name: arb-plan
description: Plan and route the next task in the MT5 spot–futures arbitrage project. Use for status, next steps, phase selection, documentation sequencing, or coordinating research/design/implementation work.
---

# Arbitrage Project Planner

## Load first

Read `.claude/skills/PROJECT_STATE.md` before anything else. It carries the current gate status, the measured
constants, the canonical dataset, and the pitfalls that have already cost this project time. It is a cache —
`docs/` wins on any conflict.

Act as the project router. Keep the response and loaded context minimal.

## Load context

1. Read `README.md`.
2. Read `docs/DECISION_LOG.md`, `docs/OPEN_QUESTIONS.md`, and `docs/RISK_REGISTER.md` only when the task depends on current decisions, unknowns, or risks.
3. Read only the specific phase document being changed. Do not preload all `docs/`.

## Route

- Market mechanics, data, fair value, basis, costs, signals, hedge ratio, or EV → use `/arb-research`.
- Architecture, execution, state machine, failure recovery, broker adapters, or telemetry → use `/arb-design`.
- Capital, margin, exposure, limits, kill switches, or release gates → use `/arb-risk-review`.
- Code or tests → use `/arb-implement`, only after the design gate.
- Readiness or economic challenge → use `/arb-hostile-review`.

## Output

Return:

1. Current phase and gate status.
2. One bounded next task.
3. Files that task may read and write.
4. Questions that truly block the task.
5. Acceptance checks.

Do not solve the routed task unless explicitly asked. Never authorize live trading or silently advance a phase.

## Project-specific routing (2026-09-18)

`docs/ROADMAP.md` is the authoritative gate status and staged plan. Read it before answering "what next", and
also check `.claude/skills/PROJECT_STATE.md`'s gate-status table for the current, dated position — this
section is a routing pattern, not a status snapshot, and will go stale exactly the way it already has once
before (it previously said the harness was "not approved" and unimplemented after D-008 had already accepted
it and pairs had already run — corrected 2026-09-18). **Route to the next unmet requirement, checked fresh
each time, not to a fixed position in the list below.**

Current critical path for the economics/strategy gate: **`02_quant/15_SIGNAL_RESEARCH.md` does not exist.**
D-006 rejects the hold-to-convergence structure, so any plan that assumes overnight basis convergence is
already answered — do not re-plan it. A candidate proposal exists (`docs/Gold-Basis-EA-Strategy-and-System-
Design.md`, reviewed `NOT READY` 2026-09-18) but is not accepted and does not fill this gap by existing.

**The circular dependency, and how it actually breaks — corrected 2026-09-18:** EV cannot close without
slippage, slippage needs execution evidence, execution needs a passed design gate, and the design gate needs
EV. The break is the **measurement-only harness** (`measurement_harness/`, D-008, quarantined, zero signal
logic, zero profit objective) — **this is no longer a proposal.** It is accepted, reviewed, and partially
executed: Stage 0 verified (12/12), Stage 2 has 2 of 10 required pairs completed successfully, and a fast-
market guard (R-004) is implemented and replay-tested but not yet run for real. **Stage 3/4 (the automated
scheduler) remains `REJECT`/`NOT READY`** — two full reviews, 2026-09-17, on the same finding; do not treat it
as available regardless of Stage 2's progress. Check `PROJECT_STATE.md`'s gate table for the current pair
count before answering anything about harness status.

**Correction, 2026-09-18: harness execution evidence informs B1 (slippage measurement); it does not
automatically close EV.** Completing Stage 2 (or even Stage 3/4, once unblocked) produces a slippage/latency
distribution — a necessary input to `17_EXPECTED_VALUE.md`, not a sufficient one. EV also needs A4 (signal
research, still missing) and a net-of-cost expected-value calculation that has not been done for any specific
signal, because no signal has cleared review yet. Do not imply that finishing the harness alone opens the
design gate.

When someone asks to "build the EA": identify which of these is actually the next unmet step — A4 signal
research (missing), harness execution (in progress, 2/10 Stage 2 pairs), Stage 3/4 unblocking (blocked on 6
mitigations, `35_1000_USD_LIVE_TEST_PLAN.md` §8.2), or EV closure (blocked on both A4 and full slippage
evidence) — and say which one, with its current dated status. Do not recite the whole chain as if it always
starts from the beginning; most of it has already moved.
