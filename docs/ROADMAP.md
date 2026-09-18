# Roadmap — research close-out → design → implementation

Status: **PROPOSED, 2026-09-16.** This is a routing and sequencing document. It approves nothing, calibrates
nothing, and authorizes no live trading. `docs/PROJECT_MANDATE.md` takes precedence over everything here.

Purpose: state honestly where the project is against the mandate, identify what actually gates implementation
(it is not documentation volume), and lay out the smallest ordered path to a go/no-go decision.

---

## 1. Where the project actually is

The mandate specifies 41 documents across six folders. Current state:

| Folder | Mandated | Exist | Have real content | Notes |
|---|---:|---:|---:|---|
| `01_research/` | 7 | 8 | 3 | `01`–`05` are **NOT STARTED** stubs. `06`, `07` IN PROGRESS. `08` is an extra (tick-collection design). |
| `02_quant/` | 8 | 7 | 7 | **`15_SIGNAL_RESEARCH.md` does not exist.** `17` is DRAFT; the rest IN PROGRESS. |
| `03_system_design/` | 10 | 2 | 2 | `20`, `22` both PROPOSED/uncalibrated. `21`, `23`–`29` missing. |
| `04_testing/` | 6 | 2 | 2 | `34` (demo mechanical validation) and `35` (live measurement trial), both PROPOSED. `30`–`33` missing. |
| `05_development/` | 5 | 0 | 0 | Empty. |
| `06_operations/` | 5 | 0 | 0 | Empty. |
| **Total** | **41** | **19** | **14** | |

Against the mandate's eight first-milestone questions: **none are fully answered.** Q2 (what relationship to
trade), Q4 (broker/instrument), Q5 ($1,000 feasibility) and Q6 (what data to collect) have substantive partial
answers. Q1 (is it exploitable), Q3 (edge after costs), Q7 (acceptable latency) and Q8 (unviability
conditions) do not.

**Gate status:**

- Economics gate — **NOT PASSED.** `17_EXPECTED_VALUE.md` is a component inventory, not a net-edge result.
- Design gate — **NOT PASSED.** `20_SYSTEM_ARCHITECTURE.md` says so itself.
- Implementation gate — **NOT PASSED.** No MQL5 may be written. `src/` stays empty.

### A sequencing irregularity worth naming

Work jumped to `02_quant/` while `01_research/01`–`05` stayed empty. That was defensible — live broker data
was available and perishable, and the quant work has produced real evidence. But `02_ARBITRAGE_TYPES.md` in
particular is not a formality: the project is named "arbitrage", and the evidence so far describes a **basis
/ relative-value trade on a broker CFD**, not a true arbitrage. `12_FAIR_VALUE_MODEL.md` already shows ~77% of
the gap is ordinary carry and cannot be captured. Writing `02` forces that distinction into the open before
the design assumes a risk-free structure that does not exist.

---

## 1a. Update, same day — A1/A2 executed, and they moved the gate

A1 and A2 (§4, §5) were run immediately after this roadmap was first drafted. They did not merely refine
inputs; they produced a **no-go on one of the two trade structures**, which changes what the rest of this
roadmap is for.

- The convergence trade's revenue term — the rate at which the basis actually decays — had never been
  measured. It is now: **−$0.3905/day** (95% CI −$0.4480 … −$0.3330, R²=0.83, 5,843,313 synchronized rows).
- Against one-sided spot swap of −$0.7714/day, net carry is **−$0.3809/day**, CI entirely negative.
- `17_EXPECTED_VALUE.md`'s original sensitivity table compared cost against the basis *level* rather than its
  *change*, and so reported +$33.60 for a 10-day hold where the corrected figure is −$4.31. Corrected there.

**Consequence for this roadmap:** Stage B's go/no-go is now partly pre-answered. The hold-to-convergence
structure is rejected (proposed D-006). What survives is intraday relative-value, which pays no swap and whose
measured daily range (median $7.91) is 8–20× the measured round-trip cost ($0.4975) — opportunity, not edge.
Stages C–E remain gated exactly as before, and now serve a *different* strategy than the one they were
sketched for, which means `20_SYSTEM_ARCHITECTURE.md` and `22_STATE_MACHINE.md` need re-reading against an
intraday, signal-driven structure rather than a hold-to-convergence one.

**B2 is resolved, not deferred.** Q-004 asked "how long until convergence". For the overnight structure the
answer is measured: never profitably. The remaining holding-period question applies only to intraday trades
and is a signal-design question (A4), not a basis-statistics question.

## 2. The binding constraint

The project is not blocked on document count. It is blocked on one question:

> **Is the true net edge positive, and is it large enough relative to its own uncertainty to justify risking
> capital?**

The mandate's own rule — reject a proposal whose edge is small relative to uncertainty — means this must be
answered before, not after, design. Three things block it:

| ID | Blocker | Why it is blocked | Can it be closed from existing data? |
|---|---|---|---|
| **B1** | Entry/exit slippage and latency-driven adverse movement | No execution has ever been measured. Nothing in 15M ticks proxies for fill quality. | **No.** Requires a live/demo execution trial. |
| **B2** | Time-to-convergence / holding period (Q-004) | n=8 realized pairs; the tick-level AR(1) proxy was tested at 45 days and **withdrawn as unreliable** (non-stationary series). | **Partly.** A de-trended re-implementation is possible now. The realized-pair count is not. |
| **B3** | Required Safety Margin | The mandate requires it and never defines it. `17_EXPECTED_VALUE.md` proposes a methodology but its input is B1. | **No**, it is downstream of B1. |

Everything else — architecture, state machines, risk engine, testing, ops — is downstream. Building it before
B1–B3 resolve risks producing a well-engineered system for a trade that does not pay.

---

## 3. The circular dependency, and how to break it

B1 creates a genuine circle:

```
EV cannot close        →  because slippage is unmeasured
slippage needs execution →  execution needs a built system
a built system needs a passed design gate
the design gate needs EV  →  back to the start
```

Resolving it by guessing a slippage number would violate "NO MAGIC VALUES". Resolving it by building the full
system first inverts the mandate's gate order.

**Proposed resolution — a measurement-only harness, scoped so narrowly it cannot become the strategy.**
This is put forward for `/arb-risk-review` and `/arb-hostile-review` to accept or reject; it is not
self-approved.

Constraints it must satisfy:

- ~~**Demo account only.** Never the live USD 1,000 account.~~ **Reversed 2026-09-16 (D-008).**
  `/arb-hostile-review` established that demo cannot price slippage or rejection, so a demo-only constraint
  would have guaranteed an invalid measurement. The trial runs on the live account at 0.01/0.01, budgeted and
  loss-capped. Demo retains mechanical validation only.
- **No signal logic whatsoever.** It does not decide when to trade. It opens a hedged 0.01/0.01 pair on a
  fixed schedule or manual trigger, records fills, and flattens immediately.
- **No profit objective.** Its output is a slippage and latency distribution, not P&L.
- **Bounded run count**, agreed in advance, with a hard kill switch.
- **Its code is a research instrument**, not a component of the eventual system, and must not be reused as
  one — the same quarantine logic this project applies to `legacy/`.

If that is rejected, the honest alternative is to close EV with an explicit, clearly-labelled slippage
*assumption* and a sensitivity band — and to accept that no net-edge claim can be signed off, only bounded.

---

## 4. The staged plan

### Stage A — close out research (no MQL5; `tools/` only)

| Task | Deliverable | Reads | Writes | Acceptance |
|---|---|---|---|---|
| **A1** | Promote the full terminal tick exports (6.52M futures + 8.80M spot ticks, 2026-07-27 → 2026-09-16) to the canonical dataset, superseding the API-collected 45-day run | `research/*.csv`, `tools/tick_export_loader.py` | `10_DATA_REQUIREMENTS.md`, `11_SPREAD_DEFINITION.md` | Row counts, coverage, gaps and the terminal-time↔UTC offset all documented; per-leg spread distributions published |
| **A2** | Correct the transaction cost model using **measured** per-leg spread distributions including tails, replacing the assumed ≈$0.30/leg | A1 output | `14_TRANSACTION_COST_MODEL.md`, `ASSUMPTIONS.md` | Every cost line is sourced or explicitly labelled an assumption with a sensitivity band |
| **A3** | Re-implement the Q-004 decay estimate on a stationary series (implied carry rate, or de-trended basis) | A1 output, `tools/q3_q4_research.py` | `13_BASIS_MODEL.md`, `OPEN_QUESTIONS.md` | Half-life is stable across resampling grids **and** across window widths, or the method is withdrawn again — both are valid outcomes |
| **A4** | Write the missing `15_SIGNAL_RESEARCH.md` | `11`–`14`, `16` | `02_quant/15_SIGNAL_RESEARCH.md` | Entry/exit expressed as functions of fair value and cost, every threshold marked UNCALIBRATED |
| **A5** | Close `17_EXPECTED_VALUE.md` as far as data permits; define the Required Safety Margin **methodology** even if its input is pending | A2, A3, A4 | `17_EXPECTED_VALUE.md` | Net edge stated as a range with named unknowns, not a point estimate |
| **A6** | Backfill `01_research/01`–`05` | existing research | those five files | `02_ARBITRAGE_TYPES.md` explicitly classifies this trade and says what it is *not* |

A1–A3 are mechanical and can proceed immediately. A4–A6 depend on them.

### Stage B — Gate 1: economics

`/arb-risk-review` then `/arb-hostile-review`, both against `17_EXPECTED_VALUE.md`. Output is a recorded
decision in `DECISION_LOG.md`, one of:

- **Proceed** — edge positive with margin; B1 closed or bounded acceptably.
- **Proceed to measurement only** — approve the §3 harness to close B1, nothing further.
- **Stop** — edge is not distinguishable from costs and uncertainty.

**Stop is a legitimate and expected outcome.** ~77% of the observed gap is already explained as ordinary
carry, and the ~23% residual may be broker markup rather than capturable mispricing — a question no amount of
single-broker data can settle. The plan must be able to end here.

### Stage C — design (only after Stage B says proceed)

Write, in order: `21_EXECUTION_ENGINE.md`, `23_ORDER_LIFECYCLE.md`, `24_RISK_ENGINE.md`,
`27_STATE_PERSISTENCE.md`, `28_FAILURE_RECOVERY.md`, `29_OBSERVABILITY.md`, then calibrate `22_STATE_MACHINE.md`
and `25_BROKER_ABSTRACTION.md`. Defer `26_MULTI_TERMINAL_DESIGN.md` — it is future scope at $1,000.

Two inputs are already earned and must be carried in:

- The legacy EA's **408 `OpenLeg FAIL` events in under 50 minutes across both legs** is the single strongest
  evidence in the project about what actually breaks. `21`/`23`/`28` must be designed against that failure
  rate, not against a happy path.
- **No successor contract symbol exists** in this terminal (R-005). Rollover is a design requirement, not an
  ops afterthought.

In parallel: `04_testing/30`–`31` (backtest limitations, tick replay against the 15M-tick dataset) and
`06_operations/53_KILL_SWITCH.md` plus a rollover runbook.

### Stage D — Gate 2: design

`/arb-hostile-review` against the design set. Every parameter must be calibrated-and-sourced or explicitly
deferred; no `UNCALIBRATED` value may reach code.

### Stage E — implementation

`/arb-implement`, bounded, in dependency order, against `05_development/40`–`44` and the demo/live test plans
in `34`/`35`. Live trading remains gated on the mandate's phased graduation criteria regardless of anything in
this document.

---

## 5. Immediate next task

~~A1 + A2~~ — **done 2026-09-16**, see §1a. Measured spreads: spot $0.1545 mean (p99.9 $2.13, max $12.15),
futures $0.2430 mean (p99.9 $0.44, max $5.04). Round trip $0.4975, not $0.70. Both legs quote at a near-fixed
floor with a rare, violent tail, which makes a spread gate unusually cheap and effective.

**Update 2026-09-16 (later) — the harness moved to a live account, and B1 changed shape.** Both reviews ran.
`/arb-risk-review` returned `APPROVE WITH CONDITIONS` (safe, but eight corrections). `/arb-hostile-review`
returned `NOT READY` on validity: the demo design measured the right variable over the wrong population, and
demo could not price rejection at all. The account owner elected to test on the live account, which resolves
that. New plan: `04_testing/35_1000_USD_LIVE_TEST_PLAN.md`, proposed as **D-008** — n=300, USD 149.25
guaranteed cost, latching USD 250 stop, stratified sampling.

**This changes B1's status from "blocked" to "partially unbuyable".** The conditional slippage tail needs
n≈26,500 (USD 13,208, 13.2× the capital ceiling) and is permanently out of reach. The trial can **refute** the
intraday thesis cheaply and can never **clear** it, and the mandate's Required Safety Margin is therefore not
derivable as `17_EXPECTED_VALUE.md` specifies. See R-008.

**Update 2026-09-16 (later still) — one of two blocking preconditions resolved.**
`06_operations/PHASE_GRADUATION_CRITERIA.md` fills the "no graduation criteria exist" gap: the mandate's stage
pipeline names an undefined LIVE OBSERVATION stage between demo and the forward test, and D-008's trial —
zero signal logic, zero profit objective — belongs there rather than at the USD 1,000/0.01 LOT FORWARD TEST,
since no strategy exists yet to forward-test. Completing D-008 does not graduate the project past LIVE
OBSERVATION.

**Update 2026-09-16 (later still) — account precondition decided.** The account owner chose a dedicated live
account (USD 1,000, no other positions) over closing the 4 existing pairs on the current account, isolating
the measurement's cost accounting from unrelated P&L. **Not yet satisfied** — opening and funding that account
is a broker KYC step outside this project's tooling, and is the account owner's to complete. See
`04_testing/35_1000_USD_LIVE_TEST_PLAN.md` section 7.

**Still open:** the new account actually being opened and funded, and risk/hostile verdicts re-run against
the live plan specifically, since the existing ones covered the demo-only design.

**Update 2026-09-16 (later still) — Stage 0 built and verified, 12/12 PASS.**
`measurement_harness/HarnessStage0_DryRun.mq5` implements the state machine, idempotency, journal, and restart
reconciliation from `34_DEMO_TEST_PLAN.md` sections 5–8, exercising all 12 acceptance tests against an
in-process simulated broker — no MT5 trading or account API call anywhere in the file, grep-verifiable. Four
real runs by the account owner, three real bugs found and fixed via diagnosis rather than assumption at every
step (a file-handle conflict, a wrong test design in T4, a journal-file-persists-across-attaches bug in T6),
confirmed 12/12 on the fourth. Full account in `measurement_harness/README.md` → "Verification". **This is
mechanical-correctness evidence only** — it proves the state machine, retry whitelist, and reconciliation
logic behave correctly against scripted broker responses. It is not, and was never meant to be, evidence about
real broker behaviour; that is what Stage 1 (demo) and Stages 2+ (live, D-008) still exist to measure, and
both remain gated exactly as above — this closes Stage 0 only.

**Update 2026-09-16 (later still) — risk review re-run against the live plan; Stage 2 planned in detail.**
`/arb-risk-review` returned `APPROVE WITH CONDITIONS` (C1–C6, not yet applied — see `RISK_REGISTER.md` and
`35_1000_USD_LIVE_TEST_PLAN.md` §12). One notable finding: the mandate's own "INITIAL LIVE TEST PHASE" section
describes D-008 almost verbatim, which materially strengthens the phase-position argument in
`06_operations/PHASE_GRADUATION_CRITERIA.md` — but also surfaces a real gap, that the mandate's "P95 slippage"
live-test success criterion cannot be fully answered at this budget (already known via R-008/§3.1, now tied
directly to mandate text rather than only to this project's own derivation).

`35_1000_USD_LIVE_TEST_PLAN.md` §8.1 now specifies Stage 2 (the first live pilot, 10 pairs) as a concrete,
checkable procedure — manual single-pair triggering, fixed zero dwell, a specific timing window that avoids
the R-004 Friday-13:30-UTC anomaly, a per-pair verification checklist, and explicit stop-and-diagnose rules
rather than a burst of 10 unattended fires.

**Update 2026-09-16 (later still) — both reviews now complete against the live plan; D-008 eligible for
acceptance.** Risk-review conditions C1–C6 applied. `/arb-hostile-review` re-run: `READY WITH CONDITIONS` for
**Stages 0–2 only**, explicitly no verdict on Stage 3/4 until Stage 2's real results exist. Its most useful
catch: the C4 credential fix had been silently undone by the acceptance test written to verify it — T17 still
said "compiled-in," so hardcoding the account number would have passed the test. Corrected, plus three new
tests (T18 manual-mode suppression, T19 slippage-vs-sequence trend, T20 stage-gate file) and one new risk
(L-9, broker-side adaptation to the trial's own repetitive pattern).

**Update 2026-09-16 (later still) — Stage 1 skipped; dedicated account stated open.** Both account-owner
decisions, both recorded: Stage 1 (20-pair demo shakedown, USD 0) is removed from the staged protocol — raised
as a concern first (it was the only zero-cost test of the real MT5 API integration, and the mandate says no
stage should be skipped) and reaffirmed, so recorded as the account owner's call, not overridden. Compensating
measure: Stage 2's pair 1 now carries elevated scrutiny (two extra checks) specifically because it is the
first real-API contact of any kind, narrowing but not eliminating the risk Stage 1 existed to remove for free.
New risk R-010. Separately, the account owner states the dedicated live account is now open — not
independently verified this session (no live MT5 connection available); the pre-flight checklist's
fresh-live-read requirement is unchanged and is the actual precondition, not the account owner's statement
alone. **What remains before the first live order, in order: D-008 accepted (the account owner's decision, now
eligible), the account's funding/zero-positions/mode confirmed via a fresh live read, then §8.1.2's pre-flight
checklist in full.**

**Update 2026-09-17 — D-008 accepted; Stage 2 implemented and compiles clean; never run.** The account owner
directed implementation ("continue with implementation so we can test with 1 pair of 0.01 lot") — treated as
D-008 acceptance in substance, since the request cannot be carried out without it, and stated back as such
rather than assumed silently. `measurement_harness/HarnessStage2_LivePilot.mq5` now exists: reuses Stage 0's
proven state machine, idempotency scheme and retry whitelist exactly, with every simulated call replaced by
the real MT5 equivalent (`OrderSend`, `HistoryDealsTotal`/`HistoryDealGetTicket` for idempotency checks
against actual broker history, `PositionsTotal` for startup reconciliation, `DEAL_TIME_MSC` for fill times).
Fires exactly one pair per manual button click, `InpMaxPairs` defaults to 1. Compiled 0 errors. Account
whitelist (C4) verified genuinely implemented — grep-confirmed no account number anywhere in source, read
only from a local config file outside the git working tree.

**This is not evidence it works.** Stage 0 needed four real runs and three real bug fixes before it was
trustworthy, against a fully scripted, deterministic simulated broker. This file has faced no broker at all
yet, simulated or real. One precondition remains genuinely open: live verification of the dedicated account's
funding and position count, which needs a live MT5 connection this project doesn't currently have. Everything
else the gate required is done.

**Update 2026-09-17 (same day) — pair 1 ran for real, found a real bug, then completed successfully.**
First attempt: both legs opened correctly, `HEDGED` reached, then the close failed on both legs
(`PositionSelectByTicket` given a deal ticket instead of a position ticket — they differ in Hedge mode).
Kill switch latched correctly rather than retrying blindly; both positions closed manually, no unhedged
exposure at any point. Fixed by reading the position ticket via `DEAL_POSITION_ID`. Re-run, same day: pair 1
**completed** cleanly — both legs opened, both closed, `retcode=DONE` throughout, zero errors. R-010 updated
with both events; new R-011 for a related, lower-severity gap (realized P&L, including exit fill prices on
the close path, isn't tracked yet — flagged, not yet fixed, `InpMaxPairs` stays at 1 until it is).

This is the outcome the design was built for: a real defect, found at the smallest possible scale, caught by
a control rather than causing damage, fixed from real evidence rather than assumption — the same pattern as
every one of Stage 0's four rounds, now demonstrated once on real capital.

**Earlier the same day — the harness design (Stage C item, §3) was pulled forward and is now written:**
`04_testing/34_DEMO_TEST_PLAN.md`, proposed as D-007. It is design-only and authorizes nothing; it needs
`/arb-risk-review` and `/arb-hostile-review` before any MQL5. Pulling it ahead of A4 is defensible because the
harness measures execution quality, which is independent of whichever signal A4 eventually finds — the two
tracks do not block each other and can proceed in either order.

**Next: A4 — write `15_SIGNAL_RESEARCH.md`**, ahead of A3 and A5.

The reordering is deliberate. A3 (de-trended decay re-run) was going to answer "how fast does the basis revert"
— but §1a shows the basis does not revert, it decays deterministically, so A3's original question is void. A5
(close EV) cannot finish without B1 regardless. The open question is now specifically: **is there an intraday
signal whose captured move exceeds $0.4975 plus unmeasured slippage, often enough to matter?** That is A4's
question, and the 5.8M-row synchronized dataset can address it directly without any new collection.

A3 is downgraded to a supporting task within A4: characterise the *residual* around the drift (std $2.77,
intraday structure), which is the quantity a signal would actually trade.

**Genuinely blocking question, for the user, not derivable from data:** the `XAUUSD.vx` price source (Q-002)
needs a broker-support answer. It does not block A1–A3, but it bounds how far Stage B's conclusion can be
trusted.

---

## 6. What this roadmap does not do

- It does not approve the §3 measurement harness — Stage B does, or does not.
- It does not assume Stage B says proceed.
- It does not promote any threshold, timeout or multiplier to a design value.
- It does not shorten the mandate's phased graduation to live capital.

## 7. Update 2026-09-18 — Stage 2 (the live measurement harness) is complete

Since the sections above were written, D-008 was accepted and the measurement harness (`measurement_harness/`,
quarantined, zero signal logic) was implemented and run. **Stage 2's 10-pair live pilot is now complete**:
10/10 pairs `COMPLETED`, total cost ≈$5.4–5.5 (consistent with the ≈$5 estimate), zero kill-switch trips.
`stage2_confirmed.flag` was written by the account owner 2026-09-18, with two known, explained gaps accepted
rather than fully closed (`clock_offset_ms` bound never derived — R-015; independent quote cross-check done
for one pair, not all ten). Full account: `docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md` §8.1.4 "results",
`RISK_REGISTER.md` R-015, `DECISION_LOG.md` D-008's 2026-09-18 update.

**This does not answer A4.** The harness measured execution cost/slippage against a live broker with zero
signal logic — `02_quant/15_SIGNAL_RESEARCH.md` is still missing, and remains the critical path for the
economics/strategy gate specifically. A candidate proposal exists (`docs/Gold-Basis-EA-Strategy-and-System-
Design.md`) but was reviewed `NOT READY` and is not accepted.

**Stage 3/4 (the automated 300-pair scheduler) will not be pursued — decided 2026-09-18 (D-009).** With Stage
2's real cost baseline in hand (≈$0.55/pair), the account owner chose not to spend the guaranteed ≈$150–250
that 300 more zero-signal-logic, certain-to-lose pairs would cost, especially since §3.1 already established
that even 300 pairs can't close the mandate's actual conditional-tail question at any affordable n. The
measurement-harness track ends at Stage 2. `35_1000_USD_LIVE_TEST_PLAN.md` §8.2 is retired, kept for the
record only.
