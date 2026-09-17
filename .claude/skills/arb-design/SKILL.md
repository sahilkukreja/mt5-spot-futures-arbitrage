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
- **A spread gate is cheap, but it cannot eliminate the execution tail — corrected 2026-09-18.** Both legs
  quote at a near-fixed floor (spot p99 = median = USD 0.15) with a rare violent tail (spot max USD 12.15).
  Rejecting entry above roughly 2x median rejects well under 1% of ticks and is worth having, but it does
  **not** catch the specific failure mode that matters most: the confirmed 2026-09-11 13:30 UTC R-004 anomaly
  had a **normal, narrow spread on both legs** throughout — futures repriced ~54 points in ~10 seconds while
  spot stayed frozen at an unremarkable spread. A spread gate alone would have passed that event straight
  through. Both `/arb-risk-review` and `/arb-hostile-review` rejected `35_1000_USD_LIVE_TEST_PLAN.md` §8.2 on
  exactly this finding, 2026-09-17. Design any spread-based guard as one layer among several, not the tail
  defense.
- **Skew alone has a confirmed blind spot; velocity is what actually catches it — mitigation implemented
  2026-09-18.** The R-004 anomaly's own skew was 238 ms — inside the 400 ms candidate. Per-leg price velocity
  is the layer that actually catches it (the anomaly's futures leg moved at 161.6 pts/sec, ~20x the measured
  p99.9 of 8.08 pts/sec). A working implementation exists —
  `HarnessStage2_Guards.mqh`'s `GuardFastMarketLogic()`, real-tick-history wrapper `GuardFastMarket()` in
  `HarnessStage2_LivePilot.mq5` — replay-tested against the actual recorded anomaly (self-test G17), compiled
  clean, **not yet exercised against a real broker connection.** Reference this before redesigning a fast-
  market guard from scratch; do not treat this as still a from-abstract design problem.
- **The strategy being designed for has changed.** D-006 rejects hold-to-convergence.
  `20_SYSTEM_ARCHITECTURE.md` and `22_STATE_MACHINE.md` were sketched for that structure and need re-reading
  against an intraday, signal-driven one.

## The measurement harness — corrected 2026-09-18, no longer a proposal

The measurement-only harness is not a future design item: it is **accepted (D-008, 2026-09-17), reviewed, and
partially executed.** `measurement_harness/` — quarantined, zero signal logic, zero profit objective — has
Stage 0 verified (12/12, simulated broker) and Stage 2 (live, single-pair manual trigger) at **2 of 10
required pairs, both `COMPLETED`**, on a real account. Its code remains a research instrument and must not be
reused as a system component (same quarantine rule as `legacy/`) — that boundary hasn't changed, only its
implementation status has. Check `.claude/skills/PROJECT_STATE.md`'s gate table for the current pair count
before describing this as unapproved or undesigned; it was designed, reviewed, and is now producing real
execution evidence.

**Stage 3/4 (the automated multi-pair scheduler) is a separate, still-blocked item** — `REJECT`/`NOT READY`
from both reviews, 2026-09-17 (`35_1000_USD_LIVE_TEST_PLAN.md` §8.2), pending 6 more mitigations and a full
re-review. Do not conflate "the harness is approved and running" with "the automated scheduler is available."

**Design coverage this project's own real execution has already found necessary, not hypothetical** — any
future execution-design work should explicitly address these, since each one is tied to a real, either
already-encountered or already-analyzed failure mode, not a generic checklist item:
- **Frozen prices / stale quotes on one leg** — the R-004 anomaly's actual signature; a spread gate alone
  does not catch it (see above).
- **Asynchronous fills and partial exits** — `HarnessStage2_LivePilot.mq5`'s `ExecuteLeg()`/
  `CloseLegByTicket()` already distinguish `LEG_FILLED`/`LEG_PARTIAL`/failure paths; a real bug here (the
  `LEG_PARTIAL` branch not checking flatten success) was found and fixed 2026-09-17, caught on review, not
  from a failure — reference `RISK_REGISTER.md` R-011 before assuming this class of bug is already fully
  covered elsewhere.
- **Two-symbol event handling** — MT5's `OnTick` only wakes on the attached chart's symbol; a design that
  assumes both legs' price changes are observed symmetrically is wrong by construction.
- **Deadline/session-boundary exits** — closing before a trading boundary, not just entering after checking
  one; `HarnessStage2_LivePilot.mq5`'s expiry/session guards are pre-trade checks only, not exit-side
  deadline enforcement, and that gap is real, not yet built.
