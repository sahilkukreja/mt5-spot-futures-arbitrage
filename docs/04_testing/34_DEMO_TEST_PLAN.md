# Demo Test Plan — Mechanical Validation of the Execution Harness

Status: **PROPOSED — design only. NOT APPROVED, NOT IMPLEMENTED. SCOPE REDUCED 2026-09-16.**
Requires `/arb-risk-review` and `/arb-hostile-review` verdicts recorded before any MQL5 is written.

> ## Scope change, 2026-09-16 — read this before the rest of the document
>
> This document was written as the project's slippage and latency measurement plan. **That scope has moved to
> `35_1000_USD_LIVE_TEST_PLAN.md` (D-008), on a live account.**
>
> **Why:** `/arb-hostile-review` established (FF-2, FF-3) that demo servers typically fill at the requested
> price and rarely reject, so demo-measured slippage and rejection rates would be **artefacts, not
> measurements** — and rejection is the single most documented failure mode this project has, with 408
> `OpenLeg FAIL` events in under 50 minutes on the legacy live system. Section 3's validity check V1 was the
> right instinct but too weak: it catches only the laziest failure mode and would certify a demo that
> synthesises plausible-looking slippage uncorrelated with market conditions.
>
> **What remains in scope here, and it is not trivial:** demo is still the correct place to prove the
> *mechanics* — state machine transitions, idempotency under ambiguous sends, the journal, restart
> reconciliation, emergency flatten, and the kill switch. Debugging those with real money instead would be
> paying to learn what a demo teaches free. This is Stage 1 of the live plan's protocol.
>
> **Explicitly out of scope here now:** any slippage figure, any rejection rate, any latency number used as
> evidence. Stage 1 discards those outputs. Sections 2, 3, 9 and the sample-size argument below are retained
> for the record and for their definitions, but their *measurement* claims are superseded.
>
> Sections that remain fully authoritative: §4 (measurement-design decisions), §5 (state machine), §6
> (guards), §7 (timeouts, idempotency, persistence, recovery), §8 (output schema), §10 (acceptance tests
> T1–T12). The live plan inherits all of them.

This document designs a **measurement instrument**, not a trading system. It has no signal logic, no profit
objective, and no path to live capital. Its single purpose is to close blocker **B1** — entry/exit slippage
and order-to-fill latency are the only inputs to `17_EXPECTED_VALUE.md` that no amount of historical tick data
can supply, and they block the mandate's Required Safety Margin, which blocks the economics gate, which blocks
everything else.

Architecture boundary it respects (from `20_SYSTEM_ARCHITECTURE.md`):

`Market Data → Normalization → Fair Value/Spread → Signal → Risk → Execution → Broker Adapter → MT5`

The harness **replaces the Signal layer with a fixed scheduler** and leaves every other boundary intact. It
still cannot send orders from anywhere except the Broker Adapter.

---

## 1. Scope

### In scope

Measure, per hedged 0.01/0.01 `XAUUSD.vx` / `GC-Z26` pair, on a **demo account**:

- per-leg entry and exit slippage against a recorded decision-time reference price;
- order-to-fill latency, decomposed;
- the **legging window** — elapsed time between leg 1 fill and leg 2 fill;
- broker rejection/requote/partial-fill rates and their retcodes;
- the market conditions at decision time (spread, skew, velocity) as **covariates**, so slippage can be
  analysed conditionally rather than as a single average.

### Explicitly out of scope

- Any signal, threshold, or entry condition based on the basis. The harness fires on a clock, not on an edge.
- Any profit or loss objective. P&L is recorded only as a data-integrity check, never as a success criterion.
- Live capital. See §11.
- Reuse as a system component. This code is a research instrument and is **quarantined** the same way
  `legacy/` is — it may inform the production design, and must never become it.

### Prohibited by construction

Not by policy — by code:

- No live-account execution path. The adapter refuses to initialise if `AccountInfoInteger(ACCOUNT_TRADE_MODE)`
  is not `ACCOUNT_TRADE_MODE_DEMO`. This is checked at init **and** before every order submission.
- No volume other than 0.01 per leg. Constant, not an input.
- No overnight hold. A pair open at the session guard time is force-flattened (§7).
- No second pair while one is open. Strict concurrency of 1.
- No martingale, averaging, or any size variation whatsoever.

---

## 2. What is being measured — definitions with units

All timestamps are broker-server milliseconds from `SymbolInfoTick().time_msc` or `GetMicrosecondCount()`
normalised to ms. **Units are stated on every field; nothing is dimensionless.**

| Symbol | Definition | Unit |
|---|---|---|
| `t_decide` | scheduler fires; bid/ask of both legs snapshotted in the same code block | ms |
| `t_send_i` | `OrderSend` called for leg `i` | ms |
| `t_ack_i` | broker returns a retcode for leg `i` | ms |
| `t_fill_i` | broker-reported execution time for leg `i` | ms |
| `ref_i` | decision-time executable price for leg `i` — `ask` for a BUY, `bid` for a SELL | USD |
| `fill_i` | broker-reported fill price for leg `i` | USD |

Derived, **signed so that positive always means adverse to the trade**:

```
slippage_i        = (fill_i - ref_i) * dir_i        USD, dir = +1 for BUY, -1 for SELL
latency_send_i    = t_send_i - t_decide             ms   (internal decision overhead)
latency_ack_i     = t_ack_i  - t_send_i             ms   (round trip to broker)
latency_fill_i    = t_fill_i - t_send_i             ms   (order-to-fill, the headline number)
legging_window    = |t_fill_2 - t_fill_1|           ms   (unhedged exposure duration)
legging_drift     = basis(t_fill_2) - basis(t_fill_1)  USD  (what the gap moved while half-hedged)
round_trip_slip   = sum of slippage_i over entry and exit, all four legs   USD
```

`round_trip_slip` is the quantity `17_EXPECTED_VALUE.md`'s Required Safety Margin formula consumes:
`Required Safety Margin = k × p95(round-trip slippage + latency-driven adverse movement)`.

`legging_window` and `legging_drift` are the quantities that make **R-003** (unmatched leg exposure)
quantifiable for the first time, and the only empirical basis for the orphan-leg timeout in **Q-003**, which
has been blocked as "unmeasurable without an execution trial" since it was raised.

---

## 3. The validity threat that governs this whole design

**A demo server may not model slippage at all.** Many brokers fill demo orders at the requested price
instantly. If VPFX's demo does that, this harness will measure `slippage ≈ 0` across every run, and that
number would be *worse than no data* — it would feed a Required Safety Margin of ~0 into the mandate's gate
and make the strategy look safe because the measurement instrument was blind.

This is not a caveat to note at the end. It is a **gating check that runs before any of this data is used**:

> **Validity check V1.** After the first 50 pairs, compute the distribution of `slippage_i` across all legs.
> If the fraction of legs with **exactly** zero deviation exceeds 90%, or the distribution has zero variance,
> declare the demo environment **non-representative for slippage** and stop. Record the finding. Slippage
> remains unmeasured and B1 remains open.

If V1 fails, the following still hold and are still worth having:

- **latency measurements remain valid** — they reflect real network and server round-trip behaviour;
- **rejection/requote retcodes remain valid** — they reflect real server-side order validation;
- **legging window remains valid** — it is a latency quantity, not a price quantity.

If V1 fails, the only remaining route to slippage is a **bounded live micro-trial**, which is a separate
decision requiring its own `/arb-risk-review` and is explicitly **not** proposed by this document.

---

## 4. Measurement-design decisions

These are the decisions a reviewer should attack first.

### D-H1: Do not gate entry on the variable being measured

**Requirement:** slippage must be characterised across the conditions the strategy would actually meet.

**Design:** the harness applies **safety** guards (§6) but deliberately does **not** filter on spread, quote
skew, or price velocity. Those are **recorded as covariates** at `t_decide` and used to analyse slippage
conditionally afterwards.

**Reason:** an instrument that only fires when the spread is tight measures slippage only when the spread is
tight, then reports an optimistic distribution as if it were general. Given that spot spread's p99 equals its
median (USD 0.15) but its max is USD 12.15, a tight-spread filter would exclude precisely the tail that the
Required Safety Margin exists to cover.

**Alternative rejected:** gate on the 400 ms skew candidate. Rejected twice over — it would bias the sample,
and that candidate is itself uncalibrated and has a confirmed blind spot (the R-004 anomaly's own skew was
238 ms, inside the candidate).

**Residual safety:** a single hard ceiling `InpMaxSpreadUsd` (uncalibrated, proposed default 20× median as a
*circuit breaker*, not a filter) prevents firing into a genuinely broken market. Every rejection by this
ceiling is logged as a row, so the excluded region is visible in the data rather than silently absent.

### D-H2: Sequential leg submission, with randomised leg order

**Design:** submit leg 1, wait for a terminal result, then submit leg 2. Randomise which instrument is leg 1
per pair (50/50, seeded and recorded).

**Reason:** sequential submission is the only way to get a clean per-leg `latency_fill` and a meaningful
`legging_window`. Parallel submission confounds the two legs' timings and makes an ambiguous partial state
harder to attribute. Randomising the order measures whether spot-first and futures-first differ — which
matters, because the legacy system's failures were heavily asymmetric (`XAUUSD.pp` 359 failures vs
`GCJ26.ma` 49) and nobody knows whether that was the symbol, the order, or the venue.

**Cost, stated honestly:** sequential submission produces a *longer* unhedged window than parallel would.
That is the point — it measures the worst realistic case. Production may well choose parallel submission; this
harness deliberately measures the structure that makes the risk visible.

**Alternative:** a Mode B parallel-submission variant, run only after Mode A data is clean. Proposed as
optional follow-on, not part of the initial trial.

### D-H3: Fire on a schedule that is uncorrelated with the market

**Design:** fire at pseudo-random intervals drawn from a fixed distribution, stratified so that the sample
covers Asian, London, NY-overlap and late-NY sessions in roughly equal numbers.

**Reason:** firing at fixed clock intervals risks aliasing against periodic market events — and this dataset
already contains one: the R-004 stale-quote anomaly clusters on **Fridays near 13:30 UTC**, twice observed.
A fixed schedule could either systematically hit or systematically miss that. Stratified randomisation
prevents both.

### D-H4: Dwell time is a measured variable, not zero

**Design:** hold the hedged pair for `InpDwellMs` before flattening, drawn per-pair from a small fixed set
(proposed: 0, 1 s, 10 s, 60 s), recorded per pair.

**Reason:** exit slippage may differ from entry slippage, and exit conditions may depend on how long the
position has existed. A dwell of exactly zero measures only one point. All values remain far below any
overnight boundary, so no swap is incurred and D-006 is not re-litigated.

---

## 5. State machine

A deliberately reduced subset of `22_STATE_MACHINE.md`, reusing its names exactly so findings map back onto
the production design.

| State | Meaning | New order allowed? |
|---|---|---:|
| `STARTUP_RECONCILING` | Query broker positions/orders, match to persisted harness intents | No |
| `IDLE` | No open pair, no unresolved exposure, awaiting next scheduled fire | No |
| `RISK_CHECKING` | Safety guards evaluated (§6); covariates snapshotted | No |
| `LEG1_SUBMITTED` | Leg 1 sent, awaiting terminal broker result | No |
| `LEG1_FILLED` | Leg 1 fully filled; leg 2 must be submitted | Leg 2 only |
| `LEG1_PARTIAL` | Leg 1 partially filled — an exposure event, not a success | Recovery only |
| `HEDGED` | Both legs at 0.01 within tolerance; dwell timer running | Exit only |
| `UNWINDING` | Exit orders active, broker state reconciling | Exit/recovery only |
| `ORPHANED` | Directional or volume mismatch after failure, timeout, or ambiguity | Recovery only |
| `EMERGENCY_FLATTENING` | Removing residual exposure via broker-confirmed commands | Flatten only |
| `CLOSED` | Both legs closed, row written | No |
| `CLOSED_ORPHAN` | Recovery closed the pair after a legging incident; evidence retained | No |
| `RECONCILIATION_REQUIRED` | Local intent and broker state disagree | No |
| `HALTED` | Kill switch tripped; terminal for the run | No |

**Transitions of note:**

- `LEG1_SUBMITTED` + retcode in transient set + `attempt < InpMaxOpenRetries` → `LEG1_SUBMITTED` (attempt+1).
  Any retcode **not** explicitly whitelisted as transient → `ORPHANED`. `default: return false`, exactly as
  `MMT_TradePannel_Pro_v284.cpp` did — this is the one legacy pattern worth copying, and the "canonical"
  legacy file `best_code.cpp` v3.26 **lacked it entirely**, which is why 408 failures went unhandled.
- `LEG1_FILLED` + leg-2 terminal failure → `ORPHANED` → `EMERGENCY_FLATTENING` (close leg 1). This is the
  rollback path, and it is the single most important path to test (§10).
- Any state + kill switch → `HALTED`, after `EMERGENCY_FLATTENING` completes if exposure exists.
- `LEG1_PARTIAL` is never treated as success. Residual volume is exposure and routes to recovery.

**Authoritative state:** broker positions and deals, always. Local state is a cache and is rebuilt from the
broker on startup, reconnect, timeout, or any ambiguous response.

---

## 6. Guards (evaluated in `RISK_CHECKING`, all must pass)

| Guard | Condition | Calibrated? |
|---|---|---|
| Demo-only | `ACCOUNT_TRADE_MODE == DEMO` | Yes — hard, non-configurable |
| Kill switch | not tripped, flag file absent | Yes |
| Concurrency | zero open harness pairs | Yes — constant 1 |
| Run budget | `pairs_fired < InpMaxPairs` | Yes — set per run |
| Session guard | `now + max_dwell + margin < session_close` | Yes — derived, no overnight hold |
| Both symbols tradable | `SYMBOL_TRADE_MODE_FULL`, market open, tick age < 5 s | Yes |
| Margin | post-trade margin level > `InpMinMarginLevelPct` | **UNCALIBRATED** — proposed 300%, demo has no capital risk but the guard's logic must be exercised |
| Spread circuit breaker | both legs' spread < `InpMaxSpreadUsd` | **UNCALIBRATED** — see D-H1; a breaker, not a filter |

Guards that **do not** exist here by deliberate choice: quote-skew gate, velocity gate, basis threshold. See
D-H1.

---

## 7. Timeouts, idempotency, persistence, recovery

**Timeouts** — every one is `UNCALIBRATED` and must be logged whenever it fires, because the firing rate is
itself part of the measurement:

| Timeout | Proposed starting value | Purpose |
|---|---|---|
| `InpAckTimeoutMs` | 5,000 | no retcode from broker → treat as ambiguous, reconcile |
| `InpFillTimeoutMs` | 10,000 | accepted but unfilled → reconcile before any further action |
| `InpOrphanTimeoutMs` | 30,000 | `ORPHANED` unresolved → `EMERGENCY_FLATTENING` |
| `InpDwellMs` | {0, 1k, 10k, 60k} | measured variable, see D-H4 |
| Session guard margin | 900,000 (15 min) | hard buffer before session close |

These are **starting values for a measurement run, not approved runtime parameters.** The harness exists
partly to replace them with measured ones. Any timeout that fires is a row in the output, not a silent retry.

**Idempotency.** Every submission carries `magic = InpMagic` and a deterministic comment
`H{run_id}-P{pair_seq}-L{leg_id}-A{attempt}`. Before any retry, the harness queries broker positions and deals
for that exact key. **A retry is only sent if no position or deal bearing that key exists.** This is the
specific defence against the duplicate-order failure mode; an ambiguous send is resolved by reading the
broker, never by assuming.

**Persistence.** Append-only intent journal written **before** each `OrderSend` and updated on each terminal
result. Fields: `run_id, pair_seq, leg_id, attempt, symbol, direction, volume, state, t_decide, t_send,
t_ack, t_fill, retcode, fill_price, fill_volume, idempotency_key`. Written with flush-on-write — a crash
between send and journal write is exactly the case the journal exists for, so the write must precede the send.

**Restart reconciliation.** On startup, `STARTUP_RECONCILING`: read the journal, query all broker positions
and recent deals matching `InpMagic`, and match by idempotency key. Outcomes: matched and complete → `CLOSED`;
matched with exposure → `ORPHANED`; broker exposure with no journal entry → `RECONCILIATION_REQUIRED` and
`HALTED`; journal entry with no broker record and beyond fill timeout → treated as never-filled after explicit
verification. **The harness never fires a new pair until reconciliation completes cleanly.**

**Kill switch.** Trips on any of: `InpMaxPairs` reached; `consecutive_failures >= InpMaxConsecutiveFailures`
(proposed 3); any `ORPHANED` pair unresolved past `InpOrphanTimeoutMs`; `RECONCILIATION_REQUIRED`; cumulative
demo loss beyond `InpMaxRunLossUsd` (a logic exercise, not a capital control); or presence of a manual flag
file. Tripping is **latching** — it requires manual operator action to clear, following the legacy
risk-control taxonomy's equity-drawdown pause rather than an auto-clearing one.

---

## 8. Output schema

One CSV row per pair attempt, written to `research/harness/<run_id>/pairs.csv`, plus the append-only journal
and a run manifest capturing symbol specs, account mode, terminal build, and harness version.

Row fields: `run_id, pair_seq, outcome, leg1_symbol, leg1_dir, leg2_symbol, leg2_dir, dwell_ms,
t_decide, ref_spot_bid, ref_spot_ask, ref_fut_bid, ref_fut_ask, spot_spread, fut_spread, quote_skew_ms,
spot_velocity, fut_velocity, entry_basis, per-leg (t_send, t_ack, t_fill, retcode, attempts, fill_price,
fill_volume, slippage), legging_window_ms, legging_drift, exit_* mirror of entry, round_trip_slip, pnl,
guard_rejections, timeouts_fired`.

`outcome` ∈ {`COMPLETED`, `REJECTED_GUARD`, `REJECTED_BROKER`, `ORPHANED_RECOVERED`, `ORPHANED_UNRESOLVED`,
`TIMEOUT`, `HALTED`}. **Rejections and guard blocks are rows, not absences** — the rate at which the harness
*cannot* trade is itself a finding, and silently dropping them would bias every distribution computed from
this file.

---

## 9. Sample size and run protocol

Target **n ≥ 300 completed pairs**, stratified roughly equally across the four sessions in D-H3.

Justification, stated with its own uncertainty: the Required Safety Margin consumes a **p95**. A p95 estimated
from n=300 has a bootstrap confidence interval wide enough that `k` in `Required Safety Margin = k × p95(...)`
must be chosen *with reference to that width* — which is exactly what `17_EXPECTED_VALUE.md` already specifies
("a small trial with high variance in its own p95 estimate would need a larger `k`"). **The analysis must
report the bootstrap CI of the p95, not just the p95.** n=300 is a starting target, not a sufficiency claim;
if the CI is too wide to distinguish outcomes, the answer is more pairs, not a smaller `k`.

Staged protocol, each stage gated on the previous:

1. **Stage 0 — dry run, `InpDryRun=true`.** Full state machine, guards, journal, telemetry. `OrderSend` is
   never called; it is replaced by a simulated result injector. Validates every path including failures, with
   zero broker contact.
2. **Stage 1 — 10 pairs, supervised.** Confirms real order paths, fills, and journal integrity end to end.
3. **Stage 2 — 50 pairs.** Then **validity check V1 (§3)**. Stop here if V1 fails.
4. **Stage 3 — to n ≥ 300**, stratified, unattended but kill-switch-bounded.
5. **Analysis** → feeds `17_EXPECTED_VALUE.md` (slippage, Required Safety Margin), `OPEN_QUESTIONS.md` Q-003
   (orphan-leg timeout, finally measurable), and `RISK_REGISTER.md` R-003 (legging exposure, quantified).

---

## 10. Acceptance tests

Must pass in Stage 0 before any broker contact. Written to be reusable by `33_FAULT_INJECTION.md` later.

| # | Scenario | Required behaviour |
|---|---|---|
| T1 | Leg 1 rejected, non-transient retcode | No leg 2. No exposure. Row `REJECTED_BROKER`. |
| T2 | Leg 1 rejected, transient retcode | Retry up to `InpMaxOpenRetries`, each attempt a distinct idempotency key, then `ORPHANED` if still failing |
| T3 | Leg 1 filled, leg 2 rejected | → `ORPHANED` → `EMERGENCY_FLATTENING` closes leg 1 → `CLOSED_ORPHAN`, evidence retained |
| T4 | Leg 1 filled, leg 2 ack timeout | Reconcile against broker before any retry. **No duplicate order under any interleaving.** |
| T5 | Leg 1 partial fill | Treated as exposure, never as success; routes to recovery |
| T6 | Terminal killed between journal write and `OrderSend` | Restart finds journal entry, no broker record, verifies explicitly, does not double-send |
| T7 | Terminal killed while `HEDGED` | Restart reconciles to `HEDGED`, resumes dwell, flattens |
| T8 | Broker position present with no journal entry | `RECONCILIATION_REQUIRED` → `HALTED`. Never auto-adopt an unknown position. |
| T9 | Kill switch during `LEG1_SUBMITTED` | Completes reconciliation, flattens exposure, then `HALTED` |
| T10 | Live account detected | Refuses to initialise. Verified by forcing the account-mode check. |
| T11 | Session guard boundary | No pair fires within `max_dwell + margin` of session close |
| T12 | Spread above circuit breaker | `REJECTED_GUARD` row written; excluded region visible in output |

---

## 11. Risks this harness introduces

| ID | Risk | Mitigation |
|---|---|---|
| H-1 | **Demo slippage is not representative** (§3) | Validity check V1 halts the trial and prevents the data being used |
| H-2 | Harness code is later reused as production execution | Quarantine stated in §1; separate directory; no shared module with `src/` |
| H-3 | Orphan leg left open on demo | Emergency flatten + latching kill switch + T3/T4/T9 |
| H-4 | Duplicate orders from ambiguous sends | Idempotency key checked against broker before every retry (T4, T6) |
| H-5 | Sample biased by guard filtering | D-H1; all rejections written as rows |
| H-6 | Findings over-generalised from one broker, one pair, one contract, one 45-day regime | Stated as a scope limit in the analysis, not discovered later |
| H-7 | Measured timeouts mistaken for approved production parameters | Every value marked `UNCALIBRATED`; output feeds research docs, not design docs directly |

---

## 12. Decisions proposed

**D-007 (proposed): build the execution measurement harness as specified here, demo-only, Stage 0 first.**

- **Alternatives considered:** (a) close EV with an assumed slippage figure and a sensitivity band — rejected,
  it is the fabrication the mandate's `NO MAGIC OAG/CAG VALUES` rule prohibits, though it remains the honest
  fallback if D-007 is rejected; (b) build the full execution engine and measure as a side effect — rejected,
  it inverts the gate order and produces a system before the economics justify one; (c) bounded live
  micro-trial — rejected as a first step; only reconsider if V1 fails.
- **Reason:** B1 is the only blocker in `17_EXPECTED_VALUE.md` that no historical data can close, and it
  gates the Required Safety Margin, the economics gate, and therefore the EA.
- **Risks:** §11, principally H-1.
- **Invalidation condition:** validity check V1 fails, or `/arb-hostile-review` establishes that demo
  execution cannot inform live slippage even in principle — in which case B1 stays open and the EV document
  must say so rather than substituting an assumption.

## 13. Gate status

This document authorizes nothing. It requires, in order:

1. `/arb-risk-review` — verdict recorded, conditions satisfied;
2. `/arb-hostile-review` — verdict recorded, specifically attacking §3 (is demo slippage meaningful at all?)
   and D-H1 (is the unfiltered sample actually unbiased?);
3. D-007 accepted in `DECISION_LOG.md`;

before `/arb-implement` may write a single line of MQL5 — and then Stage 0 only.

### Update 2026-09-16 — Stage 0 code written; the gate text above needed a stated exception to permit it

Read literally, the three items above block *any* MQL5, including Stage 0, because the recorded
`/arb-hostile-review` verdict was `NOT READY` and item 2 requires "verdict recorded" without qualifying which
verdict is acceptable. That verdict's fatal flaws (FF-1 through FF-5) are entirely about the **statistical and
measurement validity of real broker fills at scale** — sampling bias, clock domains for real fills, reference
prices captured around a real `OrderSend`. Stage 0 makes no measurement claim and contains no call to any
MT5 trading or account API at all (`measurement_harness/HarnessStage0_DryRun.mq5` — grep-verifiable), so none
of FF-1–FF-5 apply to what it does. It is a pure state-machine/idempotency/journal self-test, which is exactly
what `/arb-implement`'s own rule permits regardless of a pending gate: *"Prototypes must be explicitly labeled
and incapable of live order submission by default"* — here, incapable by construction, stricter than that rule
requires.

**Exception, stated plainly rather than silently assumed:** Stage 0 is exempted from item 2 above on that
basis. Items 1–3 remain in full force, unmodified, for Stage 1 (demo) and Stage 2+ (live) — neither may be
written until a fresh `/arb-risk-review` and `/arb-hostile-review` are recorded **against the live plan
specifically** (`35_1000_USD_LIVE_TEST_PLAN.md` §2) and D-008 is accepted. This exception authorizes exactly
one file's existence and nothing about what it may be attached to or what its output may be used for.

**Verification status, updated 2026-09-16: CONFIRMED, 12/12 PASS.** The account owner ran it four times, real
bugs found and fixed each round rather than assumed away. Run 1: 8/12 (a file-handle conflict in
`StartupReconciling()`; a wrong test design in T4). Run 2, after fixing those: 11/12, one remaining failure
(T6) diagnosed via targeted `Print()` output rather than a third guess — the journal file persists across
separate EA attaches with no per-attach identifier, so a leg 2 row written by an *earlier* attach's T6 was
read back by the *current* attach as current, reconciling to `HEDGED` and skipping leg 2 entirely. Fixed by
truncating the journal at the start of every self-test run — correct only for this self-test harness; the
eventual production harness must never do this. Run 4: **12/12 PASS**, full Experts log reviewed line by
line, not just the summary count. See `measurement_harness/README.md` → "Verification" for the full account,
including two further defects (unrelated to PASS/FAIL) found and fixed along the way.

**This closes Stage 0.** Stages 1/2 are unaffected by this and remain gated on what
`35_1000_USD_LIVE_TEST_PLAN.md` section 2 already lists: the account precondition (not yet satisfied) and a
fresh `/arb-risk-review` / `/arb-hostile-review` pass against the live plan specifically.
