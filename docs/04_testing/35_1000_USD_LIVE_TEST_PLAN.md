# USD 1,000 / 0.01 Lot Live Test Plan — Execution Measurement Trial

Status: **PROPOSED — design only. NOT APPROVED. NOT IMPLEMENTED.**
Supersedes the live-measurement scope of `34_DEMO_TEST_PLAN.md` (D-007), which is reduced to mechanical
validation only. Proposed as **D-008**. Requires a re-run `/arb-risk-review`, a re-run `/arb-hostile-review`,
written Phase graduation criteria (§2), and D-008 accepted in `DECISION_LOG.md` before any MQL5 is written.

**This document does not authorize live trading.** It specifies what a live trial would have to look like to
be worth its cost. The decision to fund it is the account owner's alone.

---

## 1. Why live, and what that costs

The demo-based design was reviewed and found structurally unable to deliver its own headline outputs:
demo servers typically fill at the requested price and rarely reject, so **slippage and rejection rates
measured on demo would be artefacts**, not measurements (`34_DEMO_TEST_PLAN.md` §3, R-007, hostile review
FF-2/FF-3). Live fills remove that objection entirely.

Live replaces it with a different one: **every measurement costs real money and buys no return.**

| | Value |
|---|---|
| Cost per pair, stratum A (unconditional, n=200) | **USD 0.4975** — spread USD 0.3975 + futures commission USD 0.10, at the *median* spread |
| Cost per pair, stratum B (condition-triggered, n=100) | **Somewhat higher, not stated as a single number** — see note below |
| Target sample | **n = 300** (200 + 100) |
| Guaranteed cost at n=300, lower bound | **USD 149.25 — 14.93% of the USD 1,000 ceiling** |
| Plus slippage (the unknown being bought) | at USD 0.50/pair → USD 299 total (29.9%); at USD 1.00/pair → USD 449 (44.9%) |
| Hard cumulative-loss stop | **USD 250 (25% of capital)** — latching, see §6 |

**Correction (risk review C5, 2026-09-16):** the USD 149.25 lower bound assumes every pair pays the
*unconditional median* spread. That holds for stratum A by construction, but stratum B (§4) deliberately
fires when spread already exceeds 1.5× median or velocity exceeds p99 — by design, its 100 pairs sample
*above-median* spread conditions, so their average round-trip cost will run somewhat higher than USD 0.4975.
This is not stated as a precise number here because it depends on exactly how far above threshold each
trigger fires, which is not knowable in advance — but it should not be read as uniform across all 300 pairs.
It does not change the safety picture: the USD 250 cumulative-loss stop bounds the true worst case regardless
of which line item absorbs it.

This is a deliberate, budgeted purchase of information. It is **not** a trade, has **no** profit objective,
and its P&L is a cost line, never a success criterion.

## 2. Phase position — resolved 2026-09-16, one item still open

**Update 2026-09-16:** `06_operations/PHASE_GRADUATION_CRITERIA.md` now fills the gap this section originally
flagged as a blocking mandate violation. Summary of what changed:

- The mandate actually specifies **two** frameworks — a phase list (0–6) and a separate stage pipeline that
  names an undefined **LIVE OBSERVATION** stage between DEMO TESTING and the USD 1,000/0.01 LOT FORWARD TEST.
  This trial belongs at LIVE OBSERVATION, not at the forward test: it is live and capital-bounded, but has
  **zero signal logic and zero profit objective** (§1, §3), so it observes the venue, not a strategy. There is
  no strategy yet to forward-test — `15_SIGNAL_RESEARCH.md` is unwritten and D-006 has already rejected one
  candidate structure. Completing this trial does **not** graduate the project to the forward test; that
  transition has its own separate criteria, none of which this trial satisfies by itself.
- Graduation criteria for DEMO TESTING → LIVE OBSERVATION are now written. Restated here: Stage 0 (dry run)
  passes T1–T12; Stage 1 (20 demo pairs) completes with zero reconciliation mismatches, its slippage/rejection
  output discarded per §1 above; `/arb-risk-review` and `/arb-hostile-review` verdicts recorded **against this
  live plan specifically** (the existing verdicts were recorded against the demo-only design and do not cover
  live capital); D-008 accepted; the account precondition (§7) resolved; the capital owner explicitly
  authorizes the budget before the first live order.

**What remains open:** the account precondition (§7) and re-run risk/hostile verdicts against this document.
Everything else that blocked implementation is now written.

## 3. What this trial can and cannot deliver

**This is a refutation instrument.** Stated plainly so the result is not over-read later.

| Output | Deliverable? |
|---|---|
| Median / IQR of round-trip slippage, unconditional | **Yes** |
| Order-to-fill latency distribution | **Yes** |
| Legging window and legging drift (first real bound on R-003) | **Yes** |
| Live rejection / requote rates and retcodes | **Yes** — the main thing demo could never give |
| Slippage conditional on elevated spread/velocity — median, rough spread | **Partially** — see §4, stratum B |
| **Conditional tail p95 for the Required Safety Margin** | **NO — and not at any affordable n** |

### 3.1 The Required Safety Margin cannot be derived as currently specified

`17_EXPECTED_VALUE.md` defines `Required Safety Margin = k × p95(round-trip slippage + latency-driven adverse
movement)`. The p95 that matters is of the **conditional** distribution — slippage at the moments a signal
would actually fire, which are disproportionately fast, wide-spread moments.

Elevated-spread conditions occur in **0.113%** of spot ticks (>3× median). Collecting 30 such observations by
unconditional sampling needs **n ≈ 26,500**, costing **USD 13,208 — 13.2× the entire capital ceiling.**

**This is not a budget problem; it is permanent at this capital base.** The consequence must be recorded in
`17_EXPECTED_VALUE.md` rather than discovered at the gate: either the Required Safety Margin gets a different,
affordable methodology, or the mandate's gate `Net Executable Edge > Required Safety Margin` cannot be closed
as written and the project stops on that basis. Both are legitimate outcomes. Quietly substituting the
unconditional p95 is not — it would understate the margin and look rigorous doing it.

**The asymmetry that makes the trial worth buying anyway:** a distribution biased *low* that still shows large
slippage is conclusive. If median slippage alone exceeds roughly USD 3–4 against the measured USD 7.91 median
intraday basis range, no intraday signal on this pair can work, and n≈100 settles it for about USD 50. The
trial can **kill** the thesis cheaply and correctly. It can never **clear** it.

**Condition C1, applied 2026-09-16 — this is also a mandate gap, not just a project-derived one.**
`PROJECT_MANDATE.md` → "LIVE TEST SUCCESS CRITERIA" asks explicitly *"What is P95 slippage?"* as one of the
questions the first live phase should answer. This trial, at this budget, **cannot fully answer that
question** — only a conditional median/IQR and a rough p90 (§4, stratum B), never a defensible conditional
p95. This must not be discovered later by someone checking that mandate criterion off against an
unconditional or weakly-conditional number. Record it here, explicitly, before Stage 3 begins: **the mandate's
own "P95 slippage" success criterion will be answered only partially by this trial**, for the structural
reason given above, not from any shortfall in execution. The same note must appear in `17_EXPECTED_VALUE.md`
wherever this trial's output is used to inform the Required Safety Margin.

## 4. Sampling design — stratified, with recorded weights

Hostile review FF-1 established that pure unconditional firing would place roughly **1.2 pairs** in the
elevated-spread region across the whole n=300 run. That supports no conditional estimate at all. The fix that
fits the budget is stratification, not more pairs.

| Stratum | n | Trigger | Purpose |
|---|---:|---|---|
| **A — unconditional** | 200 | randomised interval, session-stratified | unbiased estimate of the unconditional distribution; reweighting reference |
| **B — condition-triggered** | 100 | fire when spot spread > 1.5× median **or** futures spread > 1.5× median **or** per-leg velocity > p99 (8.08 pts/sec) | populates the region the strategy would actually trade in |

Every pair records its `stratum`, the trigger that fired it, and a **sampling weight**. Stratum B's trigger
conditions occur in roughly 0.9% of ticks combined — thousands of opportunities per session — so 100 pairs is
comfortably collectable.

What stratum B buys: a conditional **median and IQR**, and a rough p90. What it does not buy: a reliable
conditional p95. n=100 in the tail region is not enough, and no affordable n is. §3.1 stands.

Stratum A remains randomised and session-stratified rather than fixed-interval, because this dataset contains
a known periodic event — the R-004 stale-quote anomaly clusters on Fridays near 13:30 UTC — and a fixed
schedule would either systematically hit or systematically miss it.

## 5. Measurement definitions — corrected per hostile review

All prices USD, all times ms. **Two reference prices are recorded, not one** (FF-4):

| Field | Definition |
|---|---|
| `ref_at_decide_i` | executable price for leg `i` at `t_decide` — ask for BUY, bid for SELL |
| `ref_at_send_i` | the same, re-read immediately before `OrderSend` |
| `fill_i` | broker-reported fill price |

```
slippage_total_i  = (fill_i - ref_at_decide_i) * dir_i     our latency + broker fill quality, summed
slippage_broker_i = (fill_i - ref_at_send_i)   * dir_i     broker fill quality alone
drift_internal_i  = (ref_at_send_i - ref_at_decide_i) * dir_i    market moved during our own overhead
```

Recording only `slippage_total` — as the demo design did — irreversibly sums a defect in our code with a
property of the broker. They have different causes and different fixes.

### 5.1 Clock domains (FF-5)

This project has already been bitten by clock mixing: `open_pairs_censored.csv` produced negative
`duration_hours_at_snapshot` values from a local-vs-server offset.

- `t_decide`, `t_send` — **local monotonic**, `GetMicrosecondCount()`.
- `t_ack` — local monotonic, captured on `OrderSend` return.
- `t_fill` — **broker server time, and must be `DEAL_TIME_MSC`, never `DEAL_TIME`.** `DEAL_TIME` has
  1-second resolution and cannot measure a latency distribution at all.
- Every row records `clock_offset_ms`, sampled at run start and end. Any cross-domain subtraction is stored
  **with its offset correction shown separately**, never silently applied.

## 6. Live-specific risk controls

Beyond the demo design's guards, all of which still apply:

| Control | Value | Rationale |
|---|---|---|
| `InpMaxPairs` | 300 | budget |
| `InpMaxCumulativeLossUsd` | **250** | 25% of capital. Latching. Caps the "slippage is USD 1/pair" scenario, which would otherwise reach USD 449 unremarked |
| `InpMaxDailyLossUsd` | **40** | 4% of capital/day; forces the run across multiple sessions and limits single-day damage |
| `InpMaxTradeLossUsd` | **15** *(new, condition C2)* | per-pair fail-safe. Round trip (~USD 0.50) + worst-case orphan exposure (~USD 4.85, from the orphan-timeout row below) + headroom for a single elevated-spread/slippage event, rounded up. Should almost never bind in normal operation — it exists to catch the single anomalous pair, not to be a routine limit. UNCALIBRATED like every other value here |
| `InpMaxPairsPerDay` | **50** *(new, condition C2)* | closes a real gap: `InpMaxDailyLossUsd` bounds dollars/day but not *count*/day — if realized cost per pair runs unexpectedly low, a dollar-only cap would not stop an unexpectedly large number of fires in one session. 50/day still completes the full n=300 well within a week even if hit every day |
| `InpMaxConsecutiveFailures` | 3 | legacy risk-control taxonomy |
| `InpOrphanTimeoutMs` | **3,000** (was 30,000) | at max observed velocity 1.616 USD/sec, 30 s of unhedged exposure costs USD 48.48 — 4.85% of capital in one event. 3 s caps it near USD 4.85 |
| `InpMinMarginLevelPct` | 300 | fail-safe; see §7 — **currently blocks every fire on this account** |
| Expiry hard stop | refuse init within 14 days of 2026-11-25 | `GC-Z26.expiration_time` reads 0; nothing machine-readable will stop it (R-005) |
| Account whitelist | explicit account number, **read from the same local, gitignored runtime config as connection credentials** *(corrected, condition C4)* | prevents running against the wrong account, without putting the account number in a committed source file. The original "compiled in" phrasing directly conflicted with §7's own credential-handling rule — a literal in `measurement_harness/`'s `.mq5` source would enter git history the moment that file is committed. See §8.1.1 |

Every limit here is **fail-safe**: each one only ever stops activity, never permits it. That is the standard
an uncalibrated limit must meet to be acceptable.

**Kill switch is latching** — manual operator action to clear, following the legacy taxonomy's
equity-drawdown-pause pattern rather than an auto-clearing one.

**No per-order slippage cap exists, and none is possible under this account's execution mode (condition C3).**
`PROJECT_MANDATE.md` → "INITIAL RISK LIMITS" requires a maximum-slippage limit. `GC-Z26` and `XAUUSD.vx` both
report `trade_exemode = SYMBOL_TRADE_EXEMODE_MARKET` — market execution, which does not honour a deviation
parameter at the order level at all; there is no MT5 mechanism to reject a fill for being too far from the
requested price under this mode. The mitigation is entirely pre-trade and indirect: the spread circuit breaker
(`InpMaxSpreadUsd`, D-H1) rejects *entry* when the visible spread is already wide, which correlates with but
does not guarantee bounded slippage, and provides no protection on exit legs at all. This gap is accepted for
a bounded, small-size measurement trial (worst case per pair is bounded by `InpMaxTradeLossUsd` regardless of
its cause) but must not be carried forward silently into any future production execution engine design, where
a genuine per-order risk control would be required.

## 7. Account preconditions — decided 2026-09-16, not yet satisfied

**The existing account currently holds 4 open pairs** (not this project's output): margin used USD 524.56,
equity USD 1,000.61, free margin USD 476.05, **margin level 191%**. Adding one harness pair (USD 129.67) would
take margin level to **153%** — below the `InpMinMarginLevelPct` guard of 300%, so the harness would reject
every single fire on that account as currently loaded.

**Decision: a separate, dedicated live account, funded to USD 1,000, with no other positions.** This isolates
the measurement's cost accounting from unrelated P&L, and removes any interaction between the harness's margin
guard and positions it does not control. The existing account and its 4 pairs are untouched by this decision
and continue independent of D-008.

**This is not yet satisfied — it requires the account owner to actually open and fund the account.** That is
outside what this project's tooling or this session can do: it requires broker KYC/account-opening steps
taken by the account owner directly with VPFX (or, if evaluated as an alternative, another broker — no
alternative has been evaluated; see D-001's own "Risks" on single-broker comparison bias).

**Handling the new account's credentials once it exists:** the same safeguard this project already applies
holds without exception — the account number and any login credentials are never printed to a committed file,
never pasted into a doc, and never logged by the harness. Connection details belong in a local, gitignored
config (the pattern `tools/` already uses), read by the harness at runtime, never hardcoded and never
committed. When the account exists, the concrete next step is updating this section with the confirmed account
mode (`ACCOUNT_TRADE_MODE_REAL` for this dedicated account, since the account itself is live even though the
*first* stages of the staged protocol below still run against a demo account for mechanical validation) and
funding confirmation — not the credentials themselves.

## 8. Staged protocol

Each stage gated on the previous. **Stages 0–1 involve no live capital.**

| Stage | Where | n | Cost | Exit criterion |
|---|---|---:|---:|---|
| **0 — dry run** | none, simulated injector | — | USD 0 | all of T1–T15 pass |
| **1 — demo shakedown** | demo | 20 | USD 0 | journal-to-broker reconciliation, zero mismatches. **Slippage output discarded — not valid, see §1** |
| **2 — live pilot** | live | 10 | ≈ USD 5 | supervised; fills, timestamps, both reference prices, clock offset all sane |
| **3 — live stratum A** | live | 200 | ≈ USD 100 | unconditional distribution collected |
| **4 — live stratum B** | live | 100 | ≈ USD 50 | condition-triggered quota collected |
| **5 — analysis** | — | — | — | feeds `17_EXPECTED_VALUE.md`, Q-003, R-003 |

Stage 2 is where a live-only defect would surface; it is deliberately small and supervised.

## 8.1 Stage 2 — operational procedure (planned 2026-09-16, not yet executable)

**Status: planned, not authorized.** This section makes "supervised; fills, timestamps, both reference
prices, clock offset all sane" concrete and checkable. It does not change the gate: Stage 2 still requires,
in order, `/arb-hostile-review` re-run against this document, conditions C1–C6 from the 2026-09-16
`/arb-risk-review` applied, D-008 accepted, the dedicated account opened and funded, and Stage 1 (20 demo
pairs) completed with zero reconciliation mismatches. None of those are done yet.

### 8.1.1 Design decisions specific to Stage 2

- **Manual, single-pair triggering — not the Stage 3/4 randomised scheduler.** Stage 2 exists to catch a
  live-only defect before committing to 300 automated pairs. That requires a human to verify each pair before
  the next one fires. Concretely: `InpStage2Mode=true` disables the timer-based scheduler entirely; each pair
  fires only on an explicit operator action (a chart button click or a manually re-applied input), never on a
  timer. This is slower than the production design and that is the point.
- **Fixed minimal dwell, `InpDwellMs=0` for all 10 pairs.** Dwell-time variation (D-H4) is Stage 3/4's
  question. Stage 2 is validating the mechanism, not sampling behaviour across conditions — holding dwell
  constant removes one variable from what's already a small, noisy sample.
- **Scheduled for a specific, unremarkable window.** Not Friday, and not within roughly an hour of 13:30 UTC
  — R-004's two documented anomalies both cluster there, and Stage 2's job is to validate normal operation,
  not stress-test into a known irregular window on the very first live run. Not within the session's first or
  last 15 minutes either (thinner liquidity, wider typical spread). Recommended: a London/NY-overlap weekday
  session, well clear of both boundaries.
- **Credentials and the account whitelist (C4) are load-bearing here, not just a documentation note.** Stage 2
  is the first time any of this runs against a real account number. The connection details and the whitelist
  value must both come from the same local, gitignored runtime config — never a literal in the committed
  `.mq5` source. This must be verified as actually implemented (not just documented) before Stage 2 begins;
  it is the one condition from the risk review that a document edit alone cannot satisfy.

### 8.1.2 Pre-flight checklist (all must be true before pair 1)

- [ ] `/arb-hostile-review` verdict recorded against this document, and any conditions it adds are applied
- [ ] Risk-review conditions C1–C6 applied to this document
- [ ] D-008 accepted in `DECISION_LOG.md`
- [ ] Dedicated account open, funded to USD 1,000, zero other positions, confirmed via a fresh
      `AccountInfoInteger`/`AccountInfoDouble` read immediately before starting
- [ ] Stage 1 (20 demo pairs) completed, zero reconciliation mismatches, its slippage/rejection output
      explicitly discarded (not treated as evidence)
- [ ] `HarnessStage0_DryRun.mq5`'s successor Stage 1/2 code compiled from the exact reviewed commit, 0 errors
- [ ] Account whitelist and credentials confirmed loaded from the gitignored runtime config, not source
- [ ] Current session/time checked against 8.1.1's window guidance (not Friday, not near 13:30 UTC, not near
      a session boundary, not within 14 days of the 25 Nov 2026 expiry hard stop)
- [ ] Operator present and able to watch the run continuously — Stage 2 is not a "start and walk away" stage

### 8.1.3 Per-pair procedure (repeated 10 times, one at a time)

1. Operator triggers one pair manually.
2. Operator notes, independently of the EA, the quoted bid/ask for both legs at that moment (a screenshot or
   manual note in the terminal — a second, human-sourced data point to cross-check the EA's own recorded
   reference prices against).
3. Pair runs to completion (`CLOSED` or `CLOSED_ORPHAN`) or hits a timeout/guard.
4. **Before triggering the next pair**, operator verifies for this pair:
   - fill prices in the EA's CSV row are within a plausible band of the independently-noted quote (not
     wildly off — a sanity check, not a formal statistical test at n=1);
   - `t_fill` used `DEAL_TIME_MSC` (millisecond-resolution, not the 1-second `DEAL_TIME`) — check directly
     against the terminal's own Trade History for that ticket;
   - `clock_offset_ms` is small and stable, not drifting between this pair and the last;
   - the retcode was one of the expected/whitelisted values, not something new and unhandled;
   - the terminal's own Trade History/Journal tab for this ticket agrees with the EA's journal row — an
     independent cross-check, not just trusting the EA's own bookkeeping;
   - no kill switch trip, no `RECONCILIATION_REQUIRED`, no unexpected `ORPHANED`.
5. If any check fails: **stop. Do not trigger pair 6 through 10.** Diagnose first, exactly as Stage 0's three
   real bugs were diagnosed from evidence rather than guessed at. A failure at pair 3 is a more valuable,
   cheaper finding than the same failure discovered at pair 47.
6. If all checks pass: proceed to the next pair.

### 8.1.4 Exit criteria, made concrete

The table's "supervised; fills, timestamps, both reference prices, clock offset all sane" means, checkably:

- 10/10 pairs reach a terminal state (`CLOSED` or `CLOSED_ORPHAN`) — no pair left hanging.
- 0 kill-switch trips, 0 `RECONCILIATION_REQUIRED` states.
- 0 `DEAL_TIME` (second-resolution) rows where `DEAL_TIME_MSC` should have been used — T13's check, now
  against real data instead of a scripted result.
- `clock_offset_ms` stays within a stated bound across all 10 pairs (not drifting) — T14's check, against
  real data.
- Every fill price is within a small, stated multiple of the independently-noted quote from step 2 above —
  the first real evidence, however small, of whether `ref_at_send`/`fill` attribution (FF-4) behaves as
  designed against a real broker.
- Total realized cost is consistent with the ≈USD 5 estimate, not wildly over — if it isn't, that's itself a
  finding worth understanding before committing to 200 more pairs at Stage 3.

**On success:** the 10-pair CSV and the operator's cross-check notes are retained as the record (not
committed — account/ticket-identifying detail stays local, consistent with existing safeguards), and Stage 3
requires its own go decision, not an automatic continuation.

**On failure:** return to design/Stage 0–1. Stage 3's 200-pair automated run does not begin from a Stage 2
that needed a workaround to pass.

## 9. Acceptance tests

T1–T12 from `34_DEMO_TEST_PLAN.md` carry over unchanged. Added per hostile review:

| # | Scenario | Required behaviour |
|---|---|---|
| **T13** | Timestamp resolution | `DEAL_TIME_MSC` is used; a known injected delay is recovered to ±10 ms |
| **T14** | Clock-offset probe | server-vs-local offset measured at start and end; abort if drift exceeds a stated bound |
| **T15** | Sampling-weight integrity | reweighted stratum A+B covariate distribution reproduces the population distribution measured from the 5,843,313-row dataset |
| **T16** | Cumulative-loss stop | simulated losses trip `InpMaxCumulativeLossUsd` and latch; no further fires |
| **T17** | Account whitelist | refuses to initialise against any account number other than the compiled-in one |

## 10. Risks

| ID | Risk | Mitigation |
|---|---|---|
| L-1 | **Real capital spent on a measurement that cannot clear the gate** (§3.1) | Scoped and budgeted as refutation-only; cumulative-loss stop; staged so it can be abandoned after Stage 2 |
| L-2 | Orphan leg on a live account | 3 s orphan timeout, emergency flatten, latching kill switch, T3/T4/T9 |
| L-3 | Phase skipped without criteria | §2 — blocking precondition |
| L-4 | Margin interaction with unrelated positions | §7 — blocking precondition |
| L-5 | Harness code reused as production execution | quarantine; separate directory; no shared module with `src/` |
| L-6 | Results over-generalised from one broker, one pair, one contract, one regime | stated as a scope limit in the analysis, not discovered later |
| L-7 | Partial fills unmeasurable | `volume_min = volume_step = 0.01` and `filling_mode = FOK\|IOC` make `LEG1_PARTIAL` unreachable at this size. R-003's partial-fill branch stays unmeasured — the trial must not be reported as having validated it |
| L-8 | No per-order slippage cap | `trade_exemode = 2` (market execution): deviation parameters are not honoured. Slippage can only be limited by pre-trade gating, never by the order itself |

## 11. Decisions proposed

**D-008 (proposed): move the execution measurement trial from demo to the live USD 1,000 / 0.01-lot account,
budgeted at n=300 and USD 149.25 guaranteed cost, capped by a latching USD 250 cumulative-loss stop.**

- **Alternatives considered:** (a) demo-only, per D-007 — rejected on validity, since demo cannot price
  slippage or rejection; (b) n=100 refutation-minimum at USD 50 — viable and strictly cheaper, rejected in
  favour of better resolution on the median and rejection rates; (c) abandon measurement and close EV with an
  assumed slippage figure plus a sensitivity band — rejected as the fabrication the mandate prohibits, but it
  remains the fallback if this is not funded.
- **Reason:** slippage and latency are the only `17_EXPECTED_VALUE.md` inputs no historical data can supply,
  and demo cannot supply them either.
- **Risks:** §10, principally L-1 — real money spent on a measurement that, by §3.1, cannot clear the
  mandate's gate even if favourable.
- **Invalidation condition:** Stage 2 reveals that live fills cannot be attributed to reference prices
  reliably; or the Required Safety Margin methodology is revised such that this measurement is no longer its
  input; or the account owner withdraws the budget.
- **Scope of any approval (condition C6, applied 2026-09-16):** any `/arb-risk-review` or `/arb-hostile-review`
  verdict recorded against this document covers **D-008 as a bounded, quarantined measurement instrument
  only** — see the quarantine policy in `measurement_harness/README.md`. It is not a review of, and sets no
  precedent for, any future production execution engine. A reviewer citing this document's verdict later must
  restate that scope explicitly, not assume it carries forward to `21_EXECUTION_ENGINE.md` or any other
  design document once one exists.

## 12. Gate status

Authorizes nothing. Requires, in order: Phase graduation criteria written (§2, done) → account precondition
resolved (§7, decided, not yet satisfied) → `/arb-risk-review` re-run (done 2026-09-16, `APPROVE WITH
CONDITIONS` C1–C6, **applied to this document 2026-09-16**) → `/arb-hostile-review` re-run (not yet done) →
D-008 accepted → `/arb-implement` Stage 0 only.

**Stage 0 is separately verified** (`measurement_harness/HarnessStage0_DryRun.mq5`, 12/12 PASS, confirmed
2026-09-16 — see `34_DEMO_TEST_PLAN.md`). That satisfies "Stage 0 only" above. **Stage 2 specifically** is
additionally gated on §8.1's pre-flight checklist, which restates and extends the items above with Stage
2-specific items (account funding confirmed live, credential/whitelist implementation verified, timing
window checked). Nothing beyond Stage 0 is authorized by anything in this document as it stands.
