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
| `04_testing/` | 6 | 0 | 0 | Empty. |
| `05_development/` | 5 | 0 | 0 | Empty. |
| `06_operations/` | 5 | 0 | 0 | Empty. |
| **Total** | **41** | **17** | **12** | |

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

- **Demo account only.** Never the live $1,000 account.
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

**Update 2026-09-16 — the harness design (Stage C item, §3) was pulled forward and is now written:**
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
