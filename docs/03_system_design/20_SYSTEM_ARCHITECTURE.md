# System Architecture

Status: PROPOSED — structural skeleton only. **Not cleared by `/arb-risk-review` or `/arb-hostile-review`.**
No MQL5 exists; nothing here is implemented.

## Gate status (read before using this document)

This document defines component boundaries, responsibilities, state ownership, and safety-invariant
enforcement points. It deliberately does **not** assign calibrated numeric parameters (thresholds, timeouts,
safety margins), because the economics milestone that must produce them is incomplete:

| Prerequisite | Status |
|---|---|
| `02_quant/12_FAIR_VALUE_MODEL.md` | NOT STARTED |
| `02_quant/13_BASIS_MODEL.md` | NOT STARTED |
| `02_quant/14_TRANSACTION_COST_MODEL.md` | NOT STARTED |
| `02_quant/15_SIGNAL_RESEARCH.md` | Does not exist yet |
| `02_quant/17_EXPECTED_VALUE.md` | Does not exist yet |
| `docs/OPEN_QUESTIONS.md` Q-002 (commission/settlement/rollover) | Open |
| D-001 (broker/instrument pair), D-004 (tick collection method) | `proposed`, not cleared by risk/hostile review |

Only D-002 (exact delta-neutrality at 0.01/0.01 for this specific pair, `accepted`) and D-003 (pair-level P&L
unit, `proposed`) have enough grounding to inform structure below. Every parameter that depends on the missing
documents is marked **UNCALIBRATED** and must not be treated as a real limit. This document does not authorize
proceeding to `21_EXECUTION_ENGINE.md`/`22_STATE_MACHINE.md` with real numbers — it only gives those later
documents a boundary to fill in once the economics milestone closes.

## Purpose

Fix the layered structure required by `docs/PROJECT_MANDATE.md` ("SOFTWARE DESIGN PRINCIPLES") and this skill's
required boundaries, so later documents (execution engine, state machine, risk engine, broker abstraction) have
a stable interface to design against.

## Required pipeline (fixed, not open for reinterpretation)

```
Market Data → Normalization → Fair Value/Spread Engine → Signal Engine → Risk Engine → Execution Engine → Broker Adapter → MT5
```

The strategy (Signal Engine) expresses hedge intent only; it cannot send orders. Only the Broker Adapter talks
to MT5.

## Components

### 1. Market Data Layer
- **Responsibility:** ingest live bid/ask ticks for both legs via the Broker Adapter (read-only). Timestamp
  every tick with broker server time (`time_msc`) and local receipt time. Tag quote age per symbol.
- **Owns:** feed liveness detection, per-symbol last-tick timestamp.
- **Does not:** compute spread, decide anything, or touch orders.
- **Failure modes:** feed disconnect, stale quote, symbol not subscribed in Market Watch, clock skew between
  local machine and broker server (see R-004).
- **Observability:** log feed-gap events; expose quote-age metric per symbol.
- **Test method:** replay recorded tick files (design pending in `04_testing/31_TICK_REPLAY_DESIGN.md`) and
  confirm timestamps are preserved and no gap is silently dropped.

### 2. Normalization Layer
- **Responsibility:** convert broker-specific raw ticks into a common internal representation (a `PairLeg`
  abstraction carrying contract size, tick value, tick size, currency) so every layer above this one is
  broker/instrument-agnostic.
- **Depends on:** verified specs from `01_research/07_BROKER_RESEARCH.md` (already captured for the current
  pair: contract size 100/100, tick value $1/$1).
- **Test method:** golden-value regression — given the known specs, computed notional/exposure must match
  `02_quant/16_HEDGE_RATIO.md`'s manually-derived numbers exactly (spot notional ≈$4,347.75, physical delta
  0 XAU at 0.01/0.01).

### 3. Fair Value / Spread Engine
- **Responsibility:** compute the two executable basis values fixed in `02_quant/11_SPREAD_DEFINITION.md`:
  `convergence_basis = Bid(fut) − Ask(spot)`, `reverse_basis = Ask(fut) − Bid(spot)`, plus `mid_basis` for
  statistics only.
- **Explicit limitation:** cannot yet decompose basis into expected-carry vs. abnormal component —
  `12_FAIR_VALUE_MODEL.md` is NOT STARTED. Until then this engine reports raw executable basis only; nothing
  above it may claim to know how much of the gap is "abnormal."
- **Test method:** unit test recomputation from fixed bid/ask fixtures; assert `reverse_basis ≥
  convergence_basis` always (crosses the spread on both legs).

### 4. Signal Engine
- **Responsibility:** says "I want this hedge" — proposes a `SignalEvent`, never sends orders.
- **Interface only, not calibrated:**
  ```
  SignalEvent {
    pair_id           // stable ID per D-003, ties both legs together for P&L attribution
    signal_id         // idempotency key
    direction         // CONVERGE (sell fut/buy spot) | REVERSE (buy fut/sell spot)
    basis_observed
    spot_quote_ts, fut_quote_ts
    proposed_volume
  }
  ```
- **Blocked:** cannot be given real entry/exit thresholds until `14_TRANSACTION_COST_MODEL.md` and
  `17_EXPECTED_VALUE.md` exist — the mandate's "NO MAGIC OAG/CAG VALUES" rule is not satisfiable yet. Any
  threshold implemented before then must be explicitly labeled a benchmark placeholder, not a real signal.

### 5. Risk Engine
- **Responsibility:** gatekeeper. Receives a `SignalEvent`, checks it against capital/margin/exposure/kill-switch
  state, approves or rejects. The strategy does not decide whether a hedge is permitted.
- **Decision points fixed now (thresholds UNCALIBRATED):**
  - margin check — mechanism available now (live `order_calc_margin()`, see `07_BROKER_RESEARCH.md`; combined
    ≈$130 at 0.01/0.01 confirmed); stress-scenario multiplier is UNCALIBRATED.
  - quote-staleness check — max quote age is UNCALIBRATED (blocked on R-004).
  - exposure/delta check — recompute per trade from `16_HEDGE_RATIO.md`'s method; do not hardcode "0.01/0.01 is
    neutral" as a constant, since it only holds for this specific pair's equal contract sizes.
  - kill-switch check — binary, not economics-dependent: no `SIGNAL_PENDING → RISK_APPROVED` transition is
    permitted while a kill switch is active (mandate invariant, always enforceable regardless of calibration
    state).
- **Test method:** unit tests at boundary conditions (exactly at margin limit, kill-switch active, quote at
  staleness cutoff).

### 6. Execution Engine
- **Responsibility:** turn an approved hedge intent into two broker orders; own legging risk, timeouts,
  retries, emergency flatten. Directly addresses the gap `16_HEDGE_RATIO.md` explicitly flagged and left
  unsolved ("legging risk... execution-design problem") and `RISK_REGISTER.md` R-003.
- **Idempotency:** every hedge attempt carries `pair_id` (D-003) and each leg order carries a client-generated
  tag so a restart can reconcile orders to pair-intents without resubmission.
- **Authoritative state:** broker positions/orders (queried live through the Broker Adapter) are authoritative
  over any locally cached state. On restart, reconciliation queries MT5's actual open positions/orders first
  and rebuilds pair state from that; a persisted local file is an audit hint, never trusted blindly.
- **State machine:** lifecycle skeleton; deterministic transitions, reconciliation, and recovery details are
  specified in the proposed `22_STATE_MACHINE.md`:
  ```
  IDLE → SIGNAL_PENDING → RISK_APPROVED → LEG1_SUBMITTED → LEG1_FILLED → LEG2_SUBMITTED → HEDGED
    → EXIT_SIGNAL → UNWINDING → CLOSED

  LEG1_FILLED --(leg2 rejected/timeout)--> ORPHANED → EMERGENCY_FLATTENING → CLOSED_ORPHAN

  any state --(kill switch)--> no new SIGNAL_PENDING accepted; existing pairs continue per
    a flatten-or-run-to-completion policy — UNCALIBRATED, not yet decided
  ```
- **Test method:** fault injection — leg2 timeout, leg2 rejection, duplicate signal_id, restart mid-pair (see
  acceptance tests below).

### 7. Broker Adapter
- **Responsibility:** the only layer that calls `order_send`/`order_check`/position queries against MT5.
  Everything above this line must be broker- and instrument-agnostic.
- **Encapsulates:** symbol name mapping (`XAUUSD.vx`/`GC-Z26` for VPFX specifically), fill-mode quirks, margin
  calculation calls, position/order queries.
- **Test method:** must be mockable/swappable for simulation (`04_testing/`) without touching any engine
  logic above it — this is the seam that makes tick replay and fault injection possible without a live
  terminal.

## Safety invariants → enforcement point

| Invariant (from `PROJECT_MANDATE.md`) | Enforced by |
|---|---|
| No duplicate orders | Execution Engine idempotency key per leg attempt |
| No unknown positions | Restart reconciliation queries broker positions first |
| No unbounded directional exposure | Execution Engine orphan timeout + emergency flatten; Risk Engine delta check |
| No silent execution failures | Every `order_send` response logged and surfaced to observability (`29_OBSERVABILITY.md`, not yet written); no swallowed errors |
| No trading on stale quotes | Risk Engine quote-age check (threshold UNCALIBRATED) |
| No trading when costs remove edge | Signal Engine gate depends on `17_EXPECTED_VALUE.md` — **not yet enforceable**; flagged, not solved |
| No trading when margin is unsafe | Risk Engine margin check using live `order_calc_margin()` |
| No orphaned hedge leg without recovery | `ORPHANED` state + emergency flatten path |
| No new entry after kill-switch activation | Risk Engine kill-switch check blocks `SIGNAL_PENDING → RISK_APPROVED` |

## Acceptance tests (for later simulation / fault injection)

1. Given fixed bid/ask fixtures for both legs, Normalization + Fair Value layers reproduce `16_HEDGE_RATIO.md`'s
   manually-computed notional and `11_SPREAD_DEFINITION.md`'s basis values exactly (regression test).
2. Given a `SignalEvent` while the kill switch is active, the Risk Engine rejects it; it never reaches the
   Execution Engine.
3. Given Leg1 fills and Leg2 times out (simulated Broker Adapter), the Execution Engine transitions to
  `ORPHANED` then `EMERGENCY_FLATTENING` within the configured (UNCALIBRATED) orphan timeout, and emits a
  logged failure event — not a silent one; see `22_STATE_MACHINE.md`.
4. Given a process restart with one open, unreconciled pair in broker history, startup reconciliation rebuilds
  pair state from live broker positions/orders, not from a deleted/corrupted local cache file; unresolved
  mismatches remain in `RECONCILIATION_REQUIRED` and block new entries.
5. Given two rapid duplicate `SignalEvent`s with the same `signal_id`, the Execution Engine sends exactly one
   pair of leg orders.

## Rollback

Documentation only — no system, terminal, or account state depends on this file. Rollback is a normal git
revert.

## Invalidation condition

If D-001 changes (different broker/instrument pair adopted), the Normalization/Fair-Value layer's golden-value
tests must be redone against the new pair's specs, but the layer boundaries themselves are written to be
broker/instrument-agnostic and should not need to change. If D-002's exact delta-neutrality result turns out
not to generalize when a second pair is added (expected — it's flagged in `16_HEDGE_RATIO.md` as specific to
equal contract sizes), the Normalization layer's exposure calculation must be generalized before that second
pair is onboarded.

## What this document does not do

- Does not select any numeric threshold, timeout, or safety margin — those require `14_TRANSACTION_COST_MODEL.md`,
  `17_EXPECTED_VALUE.md`, and measured latency/slippage data first.
- Does not authorize writing `21_EXECUTION_ENGINE.md` or any other detail document with calibrated parameters;
  `22_STATE_MACHINE.md` is design-only and follows the same UNCALIBRATED marking discipline used here.
- Does not authorize any MQL5 implementation (`docs/PROJECT_MANDATE.md` "FIRST DEVELOPMENT MILESTONE" gate is
  still open).
