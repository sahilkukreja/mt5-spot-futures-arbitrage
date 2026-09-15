# Execution State Machine

Status: **PROPOSED - design-only, uncalibrated, and not approved for implementation.**

This document specifies deterministic pair lifecycle behavior within the architecture boundary:

`Market Data -> Normalization -> Fair Value/Spread -> Signal -> Risk -> Execution -> Broker Adapter -> MT5`

The Signal Engine expresses hedge intent. It cannot send orders. Only the Broker Adapter communicates with
MT5. Broker positions and orders are authoritative over local state.

## Gate status

This state machine does not establish a trading edge or authorize live trading. The following values remain
`UNCALIBRATED` until the research and testing gates close:

- quote age and cross-leg skew limit;
- signal-to-fill and orphan-leg timeout;
- retry count and retry spacing;
- slippage and adverse-divergence limits;
- margin-stress multiplier;
- maximum holding period and time-based exit policy.

Q-002, Q-003, and Q-004 remain open. No transition may use a placeholder as an approved runtime value.

## Design requirements

- One economic pair is the lifecycle unit, identified by `pair_id`.
- Every accepted signal has a unique `signal_id`; duplicate signals are rejected or attached to the existing
  lifecycle and never create another pair.
- Each leg has a stable `leg_id` and an idempotency key containing `pair_id`, `leg_id`, and `attempt`.
- Broker observations are reconciled before acting after startup, reconnect, timeout, or ambiguous response.
- Partial fills are exposure events, not successful completion. The state machine must represent the filled
  volume actually reported by the broker.
- No new pair may enter the lifecycle while the kill switch is active.
- No state may silently discard an order response, position, rejection, timeout, or reconciliation mismatch.

## States

| State | Meaning | New order allowed? |
|---|---|---:|
| `STARTUP_RECONCILING` | Broker orders and positions are being queried and matched to persisted pair intents. | No |
| `IDLE` | No active pair and no unresolved broker exposure. | No |
| `SIGNAL_PENDING` | A new signal is being deduplicated and validated for freshness. | No |
| `RISK_CHECKING` | Margin, exposure, kill switch, instrument, and quote guards are evaluated. | No |
| `RISK_APPROVED` | One hedge intent is approved for execution. | Only the approved pair |
| `LEG1_SUBMITTED` | The first leg request has been accepted by the adapter and awaits a broker result. | No unrelated pair |
| `LEG1_PARTIAL` | The first leg has filled partially; residual volume is unresolved. | Recovery only |
| `LEG1_FILLED` | The first leg is fully filled; the second leg must be submitted. | Second leg only |
| `LEG2_SUBMITTED` | The second leg request is awaiting broker confirmation/fill. | No unrelated pair |
| `LEG2_PARTIAL` | The second leg has filled partially; residual mismatch exists. | Recovery only |
| `HEDGED` | Both legs are present at the required pair volume within the configured exposure tolerance. | Exit only |
| `EXIT_PENDING` | A valid exit intent has been accepted and checked. | Exit only |
| `UNWINDING` | Exit orders are active and broker state is being reconciled. | Exit/recovery only |
| `ORPHANED` | The pair has directional or volume mismatch after a leg failure, timeout, or ambiguous result. | Recovery only |
| `EMERGENCY_FLATTENING` | The system is attempting to remove residual exposure using broker-confirmed commands. | Flatten only |
| `CLOSED` | Both legs are closed and final pair attribution is recorded. | No |
| `CLOSED_ORPHAN` | Recovery closed the pair after a legging incident; incident evidence is retained. | No |
| `RECONCILIATION_REQUIRED` | Local intent and broker state disagree or broker state is incomplete. | No new entry |
| `HALTED` | Kill switch or unrecoverable safety condition prevents new activity. | No |

## Events and commands

### Input events

- `SignalReceived(signal_id, pair_id, direction, proposed_volume, quote_timestamps)`
- `RiskApproved(signal_id, approval_snapshot)`
- `RiskRejected(signal_id, reason)`
- `OrderAccepted(pair_id, leg_id, attempt, broker_order_id)`
- `OrderFilled(pair_id, leg_id, filled_volume, fill_price, broker_deal_id)`
- `OrderPartiallyFilled(pair_id, leg_id, filled_volume, remaining_volume)`
- `OrderRejected(pair_id, leg_id, reason)`
- `OrderTimedOut(pair_id, leg_id, elapsed)`
- `BrokerStateObserved(orders, positions)`
- `ExitRequested(pair_id, reason)`
- `KillSwitchActivated(reason)`
- `KillSwitchCleared()`
- `ConnectionLost()` / `ConnectionRestored()`
- `ReconciliationMismatch(details)`

### Adapter commands

- `QueryBrokerState()`
- `SubmitLegOrder(pair_id, leg_id, attempt, symbol, side, requested_volume, price_policy)`
- `CancelPendingOrder(pair_id, leg_id, broker_order_id)` when supported and safe
- `SubmitFlattenOrder(pair_id, leg_id, residual_volume, emergency=true)`
- `RecordBrokerResult(result)`

The adapter must return an explicit result for every command: accepted, rejected, partially filled, filled,
not found, or unknown. An exception or connection loss is an unknown result and requires reconciliation before
retry.

## Transition rules

| From | Event/guard | To | Required action |
|---|---|---|---|
| `STARTUP_RECONCILING` | Broker state matches no active intent | `IDLE` | Persist clean reconciliation result. |
| `STARTUP_RECONCILING` | State matches an active hedged pair | `HEDGED` | Rebuild pair from broker positions; do not resubmit. |
| `STARTUP_RECONCILING` | State shows one leg or ambiguous orders | `RECONCILIATION_REQUIRED` | Freeze entries and raise an incident. |
| `IDLE` | New signal | `SIGNAL_PENDING` | Validate schema and deduplicate `signal_id`. |
| `SIGNAL_PENDING` | Duplicate signal with known outcome | `IDLE` or existing state | Do not submit orders. |
| `SIGNAL_PENDING` | Freshness and pair guards pass | `RISK_CHECKING` | Snapshot quotes, specs, account, and kill-switch state. |
| `SIGNAL_PENDING` | Kill switch or invalid signal | `HALTED` or `IDLE` | Emit rejection reason; no order. |
| `RISK_CHECKING` | All guards pass | `RISK_APPROVED` | Persist approval snapshot and idempotency keys. |
| `RISK_CHECKING` | Any guard fails | `IDLE` | Persist rejection reason; no order. |
| `RISK_APPROVED` | Leg 1 command accepted | `LEG1_SUBMITTED` | Persist broker order ID and request snapshot. |
| `LEG1_SUBMITTED` | Full fill | `LEG1_FILLED` | Reconcile broker position and actual filled volume. |
| `LEG1_SUBMITTED` | Partial fill | `LEG1_PARTIAL` | Stop normal progression; calculate residual volume. |
| `LEG1_SUBMITTED` | Reject, timeout, or unknown result | `ORPHANED` or `RECONCILIATION_REQUIRED` | Never blindly retry; query broker state first. |
| `LEG1_FILLED` | Leg 2 command accepted | `LEG2_SUBMITTED` | Submit only the required second-leg volume. |
| `LEG1_PARTIAL` | Recovery cannot complete residual safely | `ORPHANED` | Freeze new entries and begin exposure recovery. |
| `LEG2_SUBMITTED` | Full fill and exposure check passes | `HEDGED` | Persist both broker positions and pair attribution. |
| `LEG2_SUBMITTED` | Partial fill, reject, timeout, or unknown result | `LEG2_PARTIAL`, `ORPHANED`, or `RECONCILIATION_REQUIRED` | Reconcile before any retry or flatten. |
| `HEDGED` | Exit signal | `EXIT_PENDING` | Validate exit conditions and current pair state. |
| `EXIT_PENDING` | Exit approved | `UNWINDING` | Submit both exit legs under one pair lifecycle. |
| `UNWINDING` | Both legs closed | `CLOSED` | Record realized P&L, costs, basis, and timestamps. |
| `UNWINDING` | Mismatch or failed exit | `ORPHANED` | Treat residual exposure as an incident. |
| `ORPHANED` | Broker state known and residual exists | `EMERGENCY_FLATTENING` | Submit flatten command for actual residual only. |
| `ORPHANED` | Broker state unknown | `RECONCILIATION_REQUIRED` | Do not issue duplicate flatten commands. |
| `EMERGENCY_FLATTENING` | All residual exposure closed | `CLOSED_ORPHAN` | Record incident and retain all evidence. |
| `EMERGENCY_FLATTENING` | Flatten rejected, partial, or unknown | `RECONCILIATION_REQUIRED` | Escalate; no silent completion. |
| Any entry state | Kill switch activated | `HALTED` or recovery state | Cancel safe pending requests; never accept a new pair. |
| Any active state | Connection lost | current state held, then `RECONCILIATION_REQUIRED` on restore | No retry until broker state is authoritative. |

A transition to `RECONCILIATION_REQUIRED` always blocks new entries. A transition out of it requires a
fresh broker query, an explicit disposition, and a persisted reconciliation event.

## Guards

Every entry or recovery action evaluates:

1. **Identity:** pair, signal, leg, attempt, and broker identifiers are consistent.
2. **Quote validity:** both quote timestamps, quote age, cross-leg skew, and feed liveness pass measured
   criteria. Values are `UNCALIBRATED` until Q-003 closes.
3. **Instrument validity:** symbol, contract size, tick size/value, volume step, trading mode, expiry, and
   fill mode match the approved instrument snapshot.
4. **Exposure:** actual broker-filled volume is used to calculate spot exposure, futures exposure, net delta,
   and residual mismatch; equal lots are not assumed to be neutral for other pairs.
5. **Margin:** current account and order-calculated margin are checked against the approved capital policy.
   Stress multiplier remains `UNCALIBRATED`.
6. **Economics:** entry and exit costs, swap, rollover, slippage buffer, and expected value must be available
   before an economic signal is approved. Until then, the signal path remains research-only.
7. **Kill switch:** active kill switch rejects new entries and keeps recovery actions available.

## Persistence and idempotency

Persist at minimum:

- `pair_id`, `signal_id`, direction, requested volumes, and current state;
- symbol and instrument-spec snapshot used for approval;
- quote timestamps, basis values, and freshness measurements;
- account/margin snapshot and risk decision;
- per-leg `leg_id`, side, requested volume, filled volume, attempt, idempotency key;
- broker order IDs, position IDs, deal IDs, order/deal responses, and timestamps;
- transition history, rejection reasons, recovery commands, and final pair P&L/cost attribution.

The idempotency key is deterministic for a logical command. A retry after an unknown result must first query
broker state and reuse the logical command identity; it must not create a new independent order by default.

## Restart and reconciliation procedure

1. Enter `STARTUP_RECONCILING` before accepting signals.
2. Query all relevant broker positions and pending orders for the configured symbols.
3. Load local intents only as correlation hints; never treat them as proof of broker state.
4. Match broker objects by broker IDs, client tags where available, pair IDs, symbol, side, volume, and time.
5. Rebuild `HEDGED`, `UNWINDING`, `ORPHANED`, or `RECONCILIATION_REQUIRED` state.
6. Persist the reconciliation result and an operator-visible incident when any mismatch remains.
7. Enter `IDLE` only when no unknown exposure or pending order remains.

## Failure modes and observability

Each transition emits a structured event containing `pair_id`, `signal_id`, state before/after, event type,
reason, broker identifiers, requested/filled volume, quote timestamps, local receipt time, and latency when
measured. Metrics must include:

- state-transition counts and dwell times;
- order acceptance, rejection, partial-fill, timeout, and unknown-result counts;
- signal-to-order and order-to-fill latency distributions;
- quote age and cross-leg skew distributions;
- residual delta and orphan exposure duration;
- flatten success/failure and restart mismatch counts;
- pair-level realized P&L and all recorded costs.

No average may replace a tail distribution for a safety limit. Missing timestamps or broker responses are data
quality failures, not zeros.

## Acceptance tests for simulation and fault injection

1. A duplicate `signal_id` results in one lifecycle and no duplicate leg orders.
2. A stale or asynchronous quote is rejected before `RISK_APPROVED`.
3. A leg-1 partial fill creates `LEG1_PARTIAL` and calculates residual exposure from actual filled volume.
4. A leg-2 rejection or timeout reaches `ORPHANED` and then emergency flattening without a blind retry.
5. An unknown order response forces reconciliation before another order command.
6. Restart with a broker-open pair and missing local state reconstructs the pair from broker positions.
7. Restart with an unknown broker position blocks `IDLE` and raises `RECONCILIATION_REQUIRED`.
8. Kill-switch activation blocks new signals but permits flattening and reconciliation.
9. A completed pair records both leg fills, swap, commission, spread/slippage fields, basis change, and final
   pair-level P&L.
10. A parameterized test fixture verifies that every timing/latency/stress value is marked `UNCALIBRATED` until
    supplied by an approved evidence source.

## Design decisions

### DS-001: Broker-authoritative pair lifecycle

- **Requirement:** Local state must not create unknown positions or duplicate orders after restart or failure.
- **Design:** Broker positions/orders are authoritative; local persistence is an audit and correlation layer.
- **Alternative:** Trust the local event log and replay unconfirmed commands. Rejected because broker state may
  differ after disconnects, partial fills, terminal restarts, or manual activity.
- **Failure mode:** Broker query unavailable or ambiguous. Transition to `RECONCILIATION_REQUIRED`; freeze entries.
- **Observability/recovery:** Persist query results, identifiers, and mismatch details; require a fresh query.
- **Test:** Delete local state while retaining broker positions and verify reconstruction.
- **Rollback:** Documentation-only; no account state depends on this document.
- **Invalidation:** A future broker adapter may provide stronger transactional guarantees, but it must still prove
  authoritative reconciliation before this rule changes.

### DS-002: Recovery is exposure-first

- **Requirement:** A partial or failed hedge must not be treated as a normal retry path.
- **Design:** Reconcile actual filled volumes, enter `ORPHANED`, and flatten residual exposure through an explicit
  recovery path.
- **Alternative:** Retry the missing leg immediately. Rejected because an unknown first command could duplicate
  exposure and because Q-003 has no measured safe timeout.
- **Failure mode:** Flatten is rejected or partially filled. Remain in reconciliation/recovery and escalate.
- **Observability/recovery:** Record residual delta, exposure duration, command results, and final disposition.
- **Test:** Inject leg rejection, partial fill, timeout, disconnect, and duplicate response.
- **Rollback:** Documentation-only.
- **Invalidation:** Only measured, broker-specific transactional execution evidence may justify a different policy.

## Open inputs and risks

- Q-002: settlement, rollover, price source, and simultaneous-position restrictions.
- Q-003: quote staleness, orphan timeout, and margin-stress parameters.
- Q-004: holding-time distribution and censoring treatment.
- R-003: unmatched or partially filled hedge leg.
- R-004: stale or asynchronous quote basis.
- R-005: expiry and rollover transition.
- R-006: cost-aware signal gate is not enforceable until the economics documents exist.

## Scope boundary

This document defines a testable state contract only. It does not define signal thresholds, broker-specific
order syntax, MQL5 code, production retries, live limits, or a trading approval.
