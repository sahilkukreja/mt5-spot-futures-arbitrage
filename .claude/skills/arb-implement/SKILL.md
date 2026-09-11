---
name: arb-implement
description: Implement or test a bounded component of the MT5 arbitrage system after its design gate has passed. Use for MQL5, coordinator, adapters, simulation, tests, or telemetry; refuse premature production implementation.
---

# Arbitrage Implementation

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
