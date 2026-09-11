---
name: arb-plan
description: Plan and route the next task in the MT5 spot–futures arbitrage project. Use for status, next steps, phase selection, documentation sequencing, or coordinating research/design/implementation work.
---

# Arbitrage Project Planner

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
