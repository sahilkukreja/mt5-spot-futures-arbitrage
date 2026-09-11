---
name: arb-design
description: Design the MT5 arbitrage platform architecture, execution engine, order lifecycle, state machine, broker abstraction, persistence, recovery, observability, and multi-terminal coordination. Use after relevant economic assumptions are documented; do not write production code.
---

# Arbitrage System Design

Design deterministic, testable components around approved economic assumptions.

## Load only what is needed

Read `docs/PROJECT_MANDATE.md`, the specific target under `docs/03_system_design/`, and only directly relevant quant documents. Search the decision and risk registers by keyword; avoid reading every document.

## Required boundaries

Preserve:

`Market Data → Normalization → Fair Value/Spread → Signal → Risk → Execution → Broker Adapter → MT5`

The strategy expresses hedge intent; it cannot send orders. Broker-specific symbols, fill modes, contract details, and terminal behavior belong behind adapters.

## Safety invariants

No duplicate orders, unknown positions, stale-quote entries, silent failures, unsafe margin, unbounded exposure, unmanaged orphan legs, or entries after a kill switch.

## For each design decision

Record current requirement, proposed design, alternatives, reason, failure modes, new risks, observability, recovery, test method, rollback, and invalidation condition.

Specify states, transitions, guards, commands, events, timeouts, idempotency keys, authoritative state, persisted fields, and restart reconciliation. Broker positions are authoritative over cached local state.

Do not select latency or slippage limits without measurement. Mark uncalibrated parameters explicitly.

## Deliverable

Modify one bounded design document plus material decision/risk/open-question entries. Include acceptance tests suitable for later simulation and fault injection. Do not implement MQL5 unless the design review gate is already recorded as passed.
