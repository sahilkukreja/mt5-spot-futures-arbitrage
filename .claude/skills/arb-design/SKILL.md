---
name: arb-design
description: Design the MT5 arbitrage platform architecture, execution engine, order lifecycle, state machine, broker abstraction, persistence, recovery, observability, and multi-terminal coordination. Use after relevant economic assumptions are documented; do not write production code.
---

# Arbitrage System Design

## Load first

Read `.claude/skills/PROJECT_STATE.md` before anything else. It carries the current gate status, the measured
constants, the canonical dataset, and the pitfalls that have already cost this project time. It is a cache —
`docs/` wins on any conflict.

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

## Project-specific design inputs (2026-09-16)

These are earned evidence, not suggestions. Carry them into every design document.

- **Design against the measured failure rate, not a happy path.** The legacy EA produced **408 `OpenLeg FAIL`
  events in under 50 minutes**, hitting both legs, recurring across separate days. One rollback observed. The
  file the legacy README calls canonical production (`best_code.cpp` v3.26) has **no retry logic at all** —
  single-attempt `OrderSend` per leg. A retry matrix exists only in a different file
  (`MMT_TradePannel_Pro_v284.cpp`: `ShouldRetry()`, whitelisted transient codes, `default: return false`,
  capped by `InpMaxOpenRetries=3`). Treat that as a lessons-learned reference, never a baseline.
- **Rollover is a design requirement.** This account's symbol universe is exactly 2 symbols. There is **no
  successor contract month to roll into**, and `GC-Z26.expiration_time` reads 0 — no machine-readable expiry.
  The system cannot assume a successor symbol will appear (R-005).
- **A spread gate is unusually cheap here.** Both legs quote at a near-fixed floor (spot p99 = median = $0.15)
  with a rare violent tail (spot max $12.15). Rejecting entry above roughly 2x median would reject well under
  1% of ticks and eliminate the tail. Derive the actual threshold; do not adopt that number.
- **Skew alone has a confirmed blind spot.** The R-004 anomaly's own skew was 238 ms — inside the 400 ms
  candidate. A per-leg price-velocity check is a better-targeted complementary signal, but one extreme event
  is not enough to derive a threshold.
- **The strategy being designed for has changed.** D-006 rejects hold-to-convergence.
  `20_SYSTEM_ARCHITECTURE.md` and `22_STATE_MACHINE.md` were sketched for that structure and need re-reading
  against an intraday, signal-driven one.

## The measurement harness

The first legitimate MQL5-shaped artifact is a **measurement-only harness**: demo account, no signal logic,
opens a hedged 0.01/0.01 pair on a fixed trigger and flattens immediately, bounded run count, hard kill switch,
output is a slippage/latency distribution rather than P&L. Its code is a research instrument and must not be
reused as a system component. It is **not approved** — it needs `/arb-risk-review` and `/arb-hostile-review`.
