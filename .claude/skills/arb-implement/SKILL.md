---
name: arb-implement
description: Implement or test a bounded component of the MT5 arbitrage system after its design gate has passed. Use for MQL5, coordinator, adapters, simulation, tests, or telemetry; refuse premature production implementation.
---

# Arbitrage Implementation

## Load first

Read `.claude/skills/PROJECT_STATE.md` before anything else. It carries the current gate status, the measured
constants, the canonical dataset, and the pitfalls that have already cost this project time. It is a cache —
`docs/` wins on any conflict.

Implement only approved, documented behavior.

## Gate

Before editing code, locate the relevant design decision and design-review verdict. If the component is not approved as `READY` or `READY WITH CONDITIONS` with satisfied conditions, stop and name the missing design work. Prototypes must be explicitly labeled and incapable of live order submission by default.

## Context budget

Read only:

1. The relevant design document.
2. The linked decision/risk entries.
3. The files being changed and their direct interfaces/tests.

Do not load the entire repository or prior bot. Use repository search to locate symbols before opening files.

## Engineering rules

- Keep strategy, risk, execution, and broker adapters separate.
- Use deterministic state transitions, idempotent commands, unique correlation IDs, explicit time units, configuration validation, and structured telemetry.
- Default to monitor/demo behavior. Live trading requires an explicit runtime gate and validated configuration.
- Never log credentials or account secrets.
- No duplicate orders, hidden state, swallowed errors, or orphan-leg paths without recovery.
- A strategy-assumption change requires a documentation and decision-log update in the same change.

## Change protocol

State the approved behavior, bounded implementation plan, files changed, tests added, failure paths exercised, and remaining risks. Run the narrowest meaningful tests first, then relevant integration/fault tests. Do not claim broker behavior was tested without evidence from that environment.

## Project-specific implementation notes

**The gate is currently closed.** No component has a `READY` design verdict. `src/` is empty and stays empty.
The only implementation work that could be authorized soon is the **measurement-only harness** described in
`arb-design` — and only after `/arb-risk-review` and `/arb-hostile-review` clear it.

`tools/` is different: read-only research scripts are permitted and expected. They never place, modify, or
close an order. When working there:

- Windows console is **cp1252** — a right-arrow character in a `print()` will crash a long run. Keep `tools/`
  output ASCII.
- pandas parses MT5 terminal exports as `datetime64[us]`. Cast dtypes explicitly before epoch arithmetic; a
  hardcoded `// 1_000_000` silently produces seconds.
- Check `git log` / `git diff HEAD` before building anything that might already exist.
- Reuse `compute_synchronized_basis()` rather than reimplementing the merge, so both collection paths keep
  identical column semantics.

If MQL5 is eventually authorized: the legacy evidence (408 failures in 50 minutes, no retry logic in the
"canonical" file) means retry/rollback/orphan handling is the *first* thing to implement correctly, not a
later hardening pass.
