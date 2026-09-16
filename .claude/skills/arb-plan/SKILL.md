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

## Project-specific routing (2026-09-16)

`docs/ROADMAP.md` is the authoritative gate status and staged plan. Read it before answering "what next".

Current critical path: **`02_quant/15_SIGNAL_RESEARCH.md` does not exist**, and it is the only thing that can
establish whether an intraday edge exists. D-006 (proposed) rejects the hold-to-convergence structure, so any
plan that assumes overnight basis convergence is already answered — do not re-plan it.

The circular dependency to be aware of when routing: EV cannot close without slippage, slippage needs
execution, execution needs a passed design gate, and the design gate needs EV. The proposed break is a
**measurement-only harness** (demo, no signal logic, bounded runs). It is not approved; route it through
`/arb-risk-review` and `/arb-hostile-review` before any code.

When someone asks to "build the EA": the honest route is A4 (signal research), then harness design, then
risk/hostile review, then harness implementation, which closes B1, which closes EV, which opens the design
gate, which permits the EA. Say which step is actually next rather than refusing or jumping ahead.
