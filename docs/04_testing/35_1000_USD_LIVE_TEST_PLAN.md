# USD 1,000 / 0.01 Lot Live Test Plan — Execution Measurement Trial

Status: **ACCEPTED (D-008, 2026-09-17).** Reviews done, conditions applied, D-008 accepted.
`measurement_harness/HarnessStage2_LivePilot.mq5` compiles clean; 2 of Stage 2's 10 pairs have run
successfully (§8.1.4 exit criteria not yet met). Supersedes the live-measurement scope of
`34_DEMO_TEST_PLAN.md` (D-007), which is reduced to mechanical validation only. **§8.2 (Stage 3/4) has been
reviewed and rejected in its current form** (`/arb-risk-review` REJECT, `/arb-hostile-review` NOT READY,
2026-09-17 — see §8.2's "Review findings" for the 7 required mitigations, most load-bearing: no guard exists
against the R-004-class fast-market event once the human operator is removed). Revision and re-review
required before implementation, in addition to Stage 2 reaching 10/10.

**Compiling clean does not authorize firing it.** §12's pre-flight checklist is the actual gate, and its one
remaining open item — live verification of the dedicated account's funding and position count — has not been
done. The decision to actually click the trigger button is the account owner's alone, same as the decision
to fund the trial was.

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
- Graduation criteria for DEMO TESTING → LIVE OBSERVATION are now written in
  `06_operations/PHASE_GRADUATION_CRITERIA.md`. **Status as of 2026-09-16:** Stage 0 done (12/12 PASS);
  Stage 1 **removed by explicit account-owner decision** (§8 — compensating measure at Stage 2 pair 1, not a
  substitute); `/arb-risk-review` and `/arb-hostile-review` both done against this live plan specifically
  (`APPROVE WITH CONDITIONS` and `READY WITH CONDITIONS` for Stages 0–2, respectively); D-008 not yet
  accepted; the account precondition (§7) stated open by the account owner, not yet independently verified;
  the capital owner has not yet explicitly authorized the budget for the first live order.

**What remains open:** D-008 acceptance, the account precondition's actual live verification (§7), and the
capital owner's explicit budget authorization before pair 1. Everything else that blocked implementation —
including both reviews — is now done.

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
| `InpMaxTradeLossUsd` | **15** *(new, condition C2)* | per-pair fail-safe. Round trip (~USD 0.50) + worst-case orphan exposure (~USD 4.85, from the orphan-timeout row below) + headroom for a single elevated-spread/slippage event, rounded up. Should almost never bind in normal operation — it exists to catch the single anomalous pair, not to be a routine limit. UNCALIBRATED like every other value here. **Fixed 2026-09-18 (R-013):** `InpOrphanTimeoutMs` was a declared-but-unenforced input until this date — the derivation below described a mechanism that did not exist in code. `CloseLegByTicket()` now genuinely bounds unhedged-exposure duration by this timeout (see that row), so this line's own arithmetic is now accurate, not just aspirational |
| `InpMaxPairsPerDay` | **50** *(new, condition C2; rationale corrected per hostile review UA-1)* | a guard against a **scheduler bug** causing runaway fire attempts, independent of per-pair cost. The original rationale ("if realized cost per pair runs unexpectedly low") does not survive this project's own data — round-trip cost has a measured, near-fixed floor (commission USD 0.10 fixed + median spread USD 0.3975, spot's p99 equal to its median), so `InpMaxDailyLossUsd=40` already caps count near 80/day at the cheapest plausible cost. A count cap is still worth having because a scheduler defect (a loop, a timer misfire, a re-entrancy bug) could attempt far more fires than intended regardless of what each one costs, and a dollar cap only catches that *after* the money is spent. 50/day still completes the full n=300 well within a week |
| Stage-gate file *(new, hostile review UA-3)* | `stage2_confirmed.flag`, written only by explicit operator sign-off | Stage 3/4's automated scheduler refuses to start unless this file exists. It is never written by the harness itself — only by the operator, after §8.1.4's exit criteria are met. This moves the staged protocol's sequencing guarantee from procedure into code: without it, a single input flag change (`InpStage2Mode=false`) could run the 290-pair automated schedule as the very first live action, bypassing Stage 2 entirely. Tested by T20 |
| `InpMaxConsecutiveFailures` | 3 | legacy risk-control taxonomy |
| `InpOrphanTimeoutMs` | **3,000** (was 30,000) | at max observed velocity 1.616 USD/sec, 30 s of unhedged exposure costs USD 48.48 — 4.85% of capital in one event. 3 s caps it near USD 4.85. **Fixed 2026-09-18 (R-013):** was declared but never referenced in `HarnessStage2_LivePilot.mq5`'s logic until this date, confirmed by grep — `CloseLegByTicket()` flattened in a single attempt with no timeout at all, so this cap existed only in this document, not in code. Now `CloseLegByTicket()` retries on the same transient-retcode whitelist `ExecuteLeg()` uses, bounded by this input as a wall-clock ceiling (not an attempt count) — a genuinely bounded worst-case unhedged-exposure duration, matching this row's own arithmetic for the first time. `InpFillTimeoutMs` received the same fix on `ExecuteLeg()`'s own retry loop. `InpAckTimeoutMs` was removed rather than fixed — it had no real enforcement point in this file's synchronous `OrderSend()` dispatch design; keeping a declared-but-unenforceable input was judged worse than removing it |
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

## 7. Account preconditions — dedicated account opened 2026-09-16, funding/mode not independently verified

**The existing account currently holds 4 open pairs** (not this project's output): margin used USD 524.56,
equity USD 1,000.61, free margin USD 476.05, **margin level 191%**. Adding one harness pair (USD 129.67) would
take margin level to **153%** — below the `InpMinMarginLevelPct` guard of 300%, so the harness would reject
every single fire on that account as currently loaded. This account and its 4 pairs remain untouched by
anything in this document.

**Decision: a separate, dedicated live account, funded to USD 1,000, with no other positions.** This isolates
the measurement's cost accounting from unrelated P&L, and removes any interaction between the harness's margin
guard and positions it does not control.

**Status update 2026-09-16: the account owner states this dedicated account is now open.** This was not
independently verified in this session — there is no live MT5 connection available here to confirm it, and
none was requested. **The pre-flight checklist (§8.1.2) still requires a fresh, live
`AccountInfoInteger`/`AccountInfoDouble` read — funded to USD 1,000, zero other positions, correct account
mode — immediately before Stage 2 fires.** "The account owner says it's open" and "a fresh read confirms it's
open, funded, and empty" are different levels of evidence; only the second satisfies the checklist. This is
the same standard applied throughout this project to every other claim — see, for instance, why Stage 0 was
run four times before being trusted rather than accepted on the first PASS.

**Handling the new account's credentials:** the same safeguard this project already applies holds without
exception — the account number and any login credentials are never printed to a committed file, never pasted
into a doc, and never logged by the harness. Connection details belong in a local, gitignored config (the
pattern `tools/` already uses), read by the harness at runtime, never hardcoded and never committed. This is
condition C4, and is load-bearing now that a real account number exists — see §8.1.1.

### 7.1 Execution environment — standardized on a VPS, 2026-09-17

The account owner is standardizing on a VPS for stable execution and lower latency — the same environment
pair 1's successful run already used (Administrator user profile, terminal
`D0E8209F77C8CF37AD8BF550E51FF075`). This is a sound operational decision independent of this trial: lower,
more stable latency is directly relevant to what Stage 2 measures, and a VPS closer to the broker is a normal
precondition for any eventual production system (`06_operations/50_VPS_ARCHITECTURE.md`, not yet written, is
where that would be formally designed).

**This creates a real risk, recorded as R-012: every budget guard (`InpMaxDailyLossUsd`,
`InpMaxCumulativeLossUsd`, `InpMaxPairsPerDay`) is tracked in a file local to whichever terminal runs the
EA.** Running from two terminals — even the original local-machine one, even once, even by accident — gives
each its own independent counters with no shared view of the other's spend, defeating the aggregate budget
the guards exist to enforce.

**Rule, effective now: the VPS is the sole environment this EA ever runs from.** The local machine's copy of
`stage2_live_config.txt` should be deleted or renamed so it cannot fire even by accident. This is procedural,
not enforced in code — a genuine cross-terminal shared-state mechanism (e.g. deriving budget state from the
broker's own account history rather than a local file) is future work, not attempted here.

## 8. Staged protocol

Each stage gated on the previous.

| Stage | Where | n | Cost | Exit criterion |
|---|---|---:|---:|---|
| **0 — dry run** | none, simulated injector | — | USD 0 | all of T1–T15 pass |
| ~~**1 — demo shakedown**~~ | ~~demo~~ | ~~20~~ | ~~USD 0~~ | **SKIPPED — account owner's explicit decision, 2026-09-16. See note below.** |
| **2 — live pilot** | live | 10 | ≈ USD 5 | supervised; fills, timestamps, both reference prices, clock offset all sane |
| **3 — live stratum A** | live | 200 | ≈ USD 100 | unconditional distribution collected |
| **4 — live stratum B** | live | 100 | ≈ USD 50 | condition-triggered quota collected |
| **5 — analysis** | — | — | — | feeds `17_EXPECTED_VALUE.md`, Q-003, R-003 |

**Stage numbering is kept as originally assigned, including the gap, rather than renumbered** — `InpStage2Mode`,
`stage2_confirmed.flag`, T18, and every other cross-reference in this document already name "Stage 2"
specifically. Renumbering would touch all of them and risk the exact kind of drift already caught once in this
document (hostile review FF-6, where a correction in one section silently failed to propagate to another).

**Stage 1 was removed by explicit account-owner decision, not a design choice.** Recorded plainly: Stage 1 cost
**zero dollars** (demo account) and was the only test of this code's real MT5 API integration —
`OrderSend`/retcode behaviour, `DEAL_TIME_MSC` population, reconciliation against actual (not scripted) broker
state — before any of it touched live capital. This was raised explicitly and reaffirmed; per this project's
own practice, a reaffirmed decision is the account owner's to make and is recorded, not silently overridden.
**The compensating measure:** Stage 2 now begins with a single pair, treated with materially higher scrutiny
than pairs 2–10, since it is not just the first *live* pair but the first *real-API* contact of any kind in
this project's execution code — see §8.1.1 and §8.1.3. This narrows the blast radius of a real-API integration
bug from "discovered somewhere in 10 pairs" to "discovered at pair 1, ≈USD 0.50 at risk" — smaller than
skipping straight to a full Stage 2 burst, but still strictly more exposure than the USD 0 that Stage 1 would
have cost. That trade-off is explicit, not hidden.

Stage 2 is where a live-only defect would surface; it is deliberately small and supervised, and now carries
more weight than originally designed for exactly that reason.

## 8.1 Stage 2 — operational procedure (planned 2026-09-16, not yet executable)

**Status: planned, not authorized.** This section makes "supervised; fills, timestamps, both reference
prices, clock offset all sane" concrete and checkable. It does not change the gate: Stage 2 still requires,
in order, D-008 accepted and the dedicated account's funding/mode confirmed via a fresh live read (§7). Both
reviews are done against this document — `/arb-risk-review` (`APPROVE WITH CONDITIONS`, C1–C6 applied) and
`/arb-hostile-review` (`READY WITH CONDITIONS` for Stages 0–2 only, FF-6/UA-1/UA-2/UA-3/AS-1 applied). Stage 1
(20-pair demo shakedown) is **removed by explicit account-owner decision** (§8) — not satisfied, not
applicable. The two remaining items are not done.

**Pair 1 carries more weight than pairs 2–10, precisely because Stage 1 was skipped.** With the demo shakedown
in place, pair 1 of Stage 2 would have been merely the first *live* pair, following 20 pairs' worth of
real-API validation on demo. Without it, pair 1 is the first time `OrderSend`, retcode handling,
`DEAL_TIME_MSC`, and broker-state reconciliation have run against any real MT5 server at all in this
project's execution code — Stage 0 touched none of them, by design. §8.1.3 treats pair 1 accordingly.

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

- [x] `/arb-hostile-review` verdict recorded against this document (`READY WITH CONDITIONS`, Stages 0–2 only,
      2026-09-16), and its conditions applied (T17 corrected, T18–T20 added, L-9 added, `InpMaxPairsPerDay`
      rationale corrected, stage-gate file added)
- [x] Risk-review conditions C1–C6 applied to this document (2026-09-16)
- [x] D-008 accepted in `DECISION_LOG.md` (2026-09-17, triggered by the account owner's implementation request)
- [x] Dedicated account open, funded, zero other positions — **satisfied by evidence, not just the account
      owner's earlier statement.** `GuardAccountWhitelisted()`/`GuardAccountIsReal()` performed a fresh
      `AccountInfoInteger` read at `OnInit` on both real runs (pairs 1 and 2), and `StartupReconciling()`
      found no pre-existing position on either attach. This is the fresh-read precondition the checklist
      asked for, now satisfied by two actual runs rather than a prior statement alone.
- [x] ~~Stage 1 (20 demo pairs) completed~~ — **removed by explicit account-owner decision (§8).** Not
      satisfied, not applicable. Compensating measure: pair 1 of this checklist's own run gets the elevated
      scrutiny described above and in §8.1.3, since it is now the first real-API contact of any kind
- [x] Stage 2's successor code, `measurement_harness/HarnessStage2_LivePilot.mq5`, compiled 0 errors and **has
      now run twice against the real account, both times to a clean `COMPLETED` outcome** (2026-09-17) — see
      `measurement_harness/README.md` "Second real run" and "Third real run."
- [x] Account whitelist and credentials confirmed loaded from the gitignored runtime config, not source —
      the config file exists locally and has been read successfully on both real runs (`Ready. Account
      whitelist OK.` in the Experts log each time); no account number appears in any committed file
      (grep-verified).
- [x] *(satisfied for pairs 1–2, must be re-verified before each of pairs 3–10, not a one-time gate item)*
      Current session/time checked against 8.1.1's window guidance (not Friday, not near 13:30 UTC, not near
      a session boundary, not within 14 days of the 25 Nov 2026 expiry hard stop).
- [x] *(satisfied for pairs 1–2, must be re-verified before each of pairs 3–10, not a one-time gate item)*
      Operator present and able to watch the run continuously — Stage 2 is not a "start and walk away" stage.

### 8.1.3 Per-pair procedure (repeated 10 times, one at a time)

**Pair 1 gets an additional round of checks before pair 2 is ever attempted, because Stage 1 was skipped.**
With no demo shakedown behind it, pair 1 is where a defect in the real-API integration itself — not just the
state-machine logic Stage 0 already proved — would first appear. Steps 1–4 below apply to every pair; the
**bold** items in step 4 apply to pair 1 specifically, in addition to the rest.

1. Operator triggers one pair manually.
2. Operator notes, independently of the EA, the quoted bid/ask for both legs at that moment (a screenshot or
   manual note in the terminal — a second, human-sourced data point to cross-check the EA's own recorded
   reference prices against).
3. Pair runs to completion (`CLOSED` or `CLOSED_ORPHAN`) or hits a timeout/guard.
4. **Before triggering the next pair**, operator verifies for this pair:
   - **(pair 1 only) the exact retcode returned by the broker for each leg is looked up directly against
     current MT5 documentation, not matched against this design's whitelist on faith** — the whitelist
     (`IsTransientRetcode`, `ShouldRetry`-style) was written from the legacy system's experience and this
     project's own reading of MT5's retcode reference, never against this specific broker's actual live
     responses, because nothing in this project has ever received one before pair 1;
   - **(pair 1 only) the journal file, the terminal's Trade History, and the account's own statement/report
     are cross-checked three ways, not two** — the extra check specifically validates that `FileWriteString`
     behaves identically against a live account's file sandbox as it did in Stage 0's, since Stage 0 never
     exercised this under real trading conditions;
   - fill prices in the EA's CSV row are within a plausible band of the independently-noted quote (not
     wildly off — a sanity check, not a formal statistical test at n=1);
   - `t_fill` used `DEAL_TIME_MSC` (millisecond-resolution, not the 1-second `DEAL_TIME`) — check directly
     against the terminal's own Trade History for that ticket;
   - `clock_offset_ms` is small and stable, not drifting between this pair and the last;
   - the retcode was one of the expected/whitelisted values, not something new and unhandled;
   - the terminal's own Trade History/Journal tab for this ticket agrees with the EA's journal row — an
     independent cross-check, not just trusting the EA's own bookkeeping;
   - no kill switch trip, no `RECONCILIATION_REQUIRED`, no unexpected `ORPHANED`.
5. **All of pair 1's checks — the standard set and the two additional ones above — must pass before pair 2 is
   ever triggered.** This is the single most load-bearing checkpoint in this whole document, precisely because
   it is the first point where this project's own Stage 0 evidence (compiled clean, 12/12 PASS, entirely
   simulated) meets a real broker for the first time. Pair 1 passing does not mean "the mechanism works" the
   way Stage 0 passing did — it means one specific set of conditions produced one clean result. Do not
   generalise from it any further than that.
6. If any check fails, at pair 1 or any later pair: **stop. Do not trigger the next pair.** Diagnose first,
   exactly as Stage 0's three real bugs were diagnosed from evidence rather than guessed at. A failure at
   pair 3 is a more valuable, cheaper finding than the same failure discovered at pair 47 — and a failure at
   pair 1 specifically is the cheapest and most valuable of all, at roughly USD 0.50 of exposure.
7. If all checks pass: proceed to the next pair.

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
requires its own go decision, not an automatic continuation. **That go decision is expressed in code as the
operator writing `stage2_confirmed.flag`** (§6, T20) — a deliberate manual action, never something the
harness does for itself. Until that file exists, the Stage 3/4 scheduler will not start regardless of any
input setting.

**On failure:** return to design/Stage 0–1. Stage 3's 200-pair automated run does not begin from a Stage 2
that needed a workaround to pass.

## 8.2 Stage 3/4 — operational procedure (design draft, 2026-09-17 — `/arb-risk-review` REJECT, `/arb-hostile-review` NOT READY)

**Status: reviewed, rejected in current form, revision required.** Stage 2 has completed 2 of its required 10
pairs as of this writing (§8.1.4 is not yet met). This section exists so Stage 3/4's design can be thought
through and reviewed ahead of time, the same way Stage 2's design (§8.1) was written, risk-reviewed, and
hostile-reviewed *before* a single line
of `HarnessStage2_LivePilot.mq5` was written — not so it can be implemented now. **Three gates stand between
this section and any code, one of them now failed and requiring a revision:**

1. **Stage 2 must reach its own exit criteria (§8.1.4) — 10/10 pairs, not 2/10 — and the operator must
   explicitly write `stage2_confirmed.flag` (T20).** No input setting, code change, or argument overrides
   this; it is a deliberate manual sign-off action, never something the harness or this document does for
   itself.
2. **`/arb-risk-review` and `/arb-hostile-review` both ran against this section, 2026-09-17. Verdicts: REJECT
   and NOT READY respectively.** Both converged independently on the same core finding: automating firing
   removes the human safety net that currently substitutes for a guard that does not exist in code at either
   stage. See "Review findings, 2026-09-17" below for the full list. **This section requires a revision
   addressing those findings before either review can be re-run.**
3. **The revision itself must then pass both reviews again**, exactly as Stage 2's design did before any of
   its code was written.

### Review findings, 2026-09-17 — blocking, must be addressed in a revision

Both reviews are recorded here in full rather than only in chat, per this project's own standing practice
(every prior review's conditions were applied directly to the document they reviewed, not left implicit).

**The blocking finding, found independently by both reviews:** `GuardSpreadLogic()` in
`HarnessStage2_Guards.mqh` checks only each leg's own bid-ask spread — it has no cross-leg basis check and no
quote-age/velocity check. It would not have caught the R-004 anomaly (2026-09-11 13:30:11 UTC: futures
repriced 54 points in ~10 seconds while the spot leg's ask stayed frozen and its own spread stayed narrow —
stale, not wide). `RISK_REGISTER.md` uses that same event to compute a worst case of **≈$54, 5.4% of capital,
from one ordinary fast-market sequence in a quiet 7-day sample.** `InpMaxTradeLossUsd=15` was explained in §6
as covering round-trip cost plus worst-case orphan exposure (~$4.85) — an honest explanation for a context
where a human is watching every pair (Stage 2), but it was never sized against this tail, and $15 does not
cover $54. Stage 2 survives this gap only because a human is present and the operational window is
deliberately scheduled away from Friday/~13:30 UTC (§8.1.1). Stage 3/4 removes the human and, by stratum A's
own design intent (an *unconditional* reference distribution), cannot simply avoid that window without
biasing the very thing it exists to measure.

Required mitigations, in priority order:

1. **[IMPLEMENTED 2026-09-18, unverified against real execution]** A real-time quote-age/velocity/cross-leg-
   skew guard, sized and tested against the 2026-09-11 anomaly specifically — proven against that historical
   row, not designed in the abstract. `GuardFastMarketLogic()` added to `HarnessStage2_Guards.mqh`,
   `GuardFastMarket()` wired into `HarnessStage2_LivePilot.mq5`'s guard chain; `HarnessStage2_SelfTest.mq5`'s
   new G17 replays the actual recorded 2026-09-11 prices/timestamps and asserts the guard blocks them.
   Compiled clean; **the self-test has not yet been run, and `GuardFastMarket()` has never touched a real
   broker connection.** See `measurement_harness/README.md` "Fast-market/stale-quote guard" and
   `RISK_REGISTER.md` R-004's 2026-09-18 update for the full account. Satisfying this mitigation's *design*
   ask does not by itself clear Stage 3/4 — mitigations 2–7 below and a full re-review still stand.
2. **A weekly drawdown limit**, separate from the existing daily/cumulative ones — named in this project's own
   risk-review inputs (legacy taxonomy: daily-loss-percent *plus* a separate weekly drawdown percent) and
   more relevant here than at Stage 2's single-session scale.
3. **Fix the budget-guard code claim.** §8.2.1 originally asserted `GuardBudgetsLogic()` "needs no new logic"
   for dual stratum quotas. On inspection this is wrong: the function takes one `pairs_total`/`InpMaxPairs`
   ceiling, and stratum A (200) and stratum B (100) need two independent, non-blocking quotas. This needs
   either two guard calls or a parameterized version — a real code change, not a reuse.
4. **The stratum B sampling-weight formula**, currently undefined — blocks T15 (sampling-weight integrity)
   regardless of the safety findings above; a missing critical input on its own.
5. **A minimum inter-fire spacing/cooldown for stratum B**, to prevent a single fast-market event from
   producing a burst of autocorrelated fires that inflate n without adding independent information — the same
   R-004-class event that motivates mitigation 1 is exactly the kind of event that would otherwise cluster
   stratum B fires.
6. **Broker terms-of-service check for automated/higher-frequency trading**, not done at any stage of this
   project so far, and materially more relevant once firing goes from ~10 manual clicks to up to 300
   automated fires.
7. **Expiry-timeline feasibility check** — confirm n=300 actually fits before the ~2026-11-11 buffer cutoff,
   accounting for Stage 2's remaining 8 pairs and this review cycle itself. Not computed anywhere yet.

Once addressed, `/arb-risk-review` and `/arb-hostile-review` both re-run against the revised section — the
same cycle Stage 2's design went through, not a one-time exception for this stage.

### 8.2.1 What changes from Stage 2 to Stage 3/4

- **Automated, not manual.** Stage 2's `InpStage2Mode=true` disables the timer/condition scheduler entirely
  and requires a human click per pair (§8.1.1) — that was deliberate, to let a human catch a live-API defect
  before it could repeat automatically. Stage 3/4 is the opposite: stratum A (200 pairs) fires on a
  randomised, session-stratified schedule and stratum B (100 pairs) fires when its trigger condition is met
  (§4) — both without a human clicking anything per pair. This only becomes acceptable once Stage 2 has shown
  the mechanism itself is sound across 10 supervised pairs; it is not a design choice available earlier.
- **Dwell-time variation (D-H4), deferred from Stage 2 specifically for this stage.** Stage 2 held
  `InpDwellMs=0` for all 10 pairs (§8.1.1) to avoid adding a variable to an already-small, noisy sample. Stage
  3/4 draws dwell per-pair from `{0, 1000, 10000, 60000}` ms, as originally specified in
  `34_DEMO_TEST_PLAN.md`'s D-H4 — every value stays far below any overnight/swap boundary, so D-006 is not
  re-litigated. The draw and the actual realised dwell must both be recorded per pair (not just the target),
  since a guard trip or broker delay could make them differ.
- **Two independent firing mechanisms, not one — evaluated within a single-threaded `OnTick()`, not a real
  concurrency problem.** Stratum A's scheduler and stratum B's condition-watcher both check
  `g_state == STATE_IDLE` before firing, the same structural guard Stage 2 already uses; MQL5 EAs are
  single-threaded, so whichever check runs first in code order wins deterministically — there is no race to
  design around, only an evaluation-order choice to make explicit when this is implemented.
- **Per-pair record grows two new required fields**, needed by T15 (sampling-weight integrity): `stratum`
  (`A` or `B`), the specific trigger reason if `B` (which of the three OR conditions in §4 fired), and a
  **sampling weight**. **Mitigation 4 above (weight formula undefined) blocks this row from being written
  correctly — not resolved in this draft.**
- **Budget guards do not carry over unchanged, despite this draft originally claiming otherwise.**
  `GuardBudgetsLogic()` in `HarnessStage2_Guards.mqh` takes one `pairs_total`/`InpMaxPairs` ceiling; Stage 3/4
  needs two independent, non-blocking quotas (stratum A stops at 200, stratum B at 100, neither blocks the
  other). **See mitigation 3 above — this is a real code change**, not a reuse. The operational
  budget-headroom arithmetic ($0.61 of $250 spent after 2 Stage 2 pairs, ≈$150 target ahead, comfortable
  headroom) is still correct and not in question — only the per-stratum *counting* mechanism needs to change.
- **Unattended operation needs controls Stage 2 doesn't, precisely because Stage 2 was designed to avoid
  needing them.** §8.1's whole premise is "a human verifies each pair before the next fires" — that premise
  is gone once firing is automatic. A heartbeat/dead-man's-switch (halt if the journal hasn't been written to
  within a stated window) and the session-boundary guard Stage 0's demo design already specified
  (`34_DEMO_TEST_PLAN.md`'s `now + max_dwell + margin < session_close`) are both still needed, but **neither
  addresses the blocking finding above** — see "Review findings" for the actual gap and its required fix.
  A reduced but nonzero operator check-in cadence is also still undecided.

### 8.2.2 Pre-flight checklist for Stage 3 start (draft — none of these are satisfied yet)

- [ ] Stage 2 exit criteria (§8.1.4) fully met: 10/10 pairs reach a terminal state, 0 kill-switch trips, 0
      `RECONCILIATION_REQUIRED`, `DEAL_TIME_MSC` used throughout, `clock_offset_ms` stable, fills within a
      plausible band of independently-noted quotes, total realized cost consistent with the ≈USD 5 estimate.
      **Currently 2/10.**
- [ ] Operator has written `stage2_confirmed.flag` (T20) — deliberate manual action.
- [x] `/arb-risk-review` run against this section (8.2), 2026-09-17 — **REJECT.** Not yet re-run against a
      revision.
- [x] `/arb-hostile-review` run against this section (8.2), 2026-09-17 — **NOT READY.** Not yet re-run against
      a revision.
- [ ] All 7 required mitigations in "Review findings, 2026-09-17" above addressed in a revision, most load-
      bearing: the quote-age/velocity/cross-leg-skew guard (mitigation 1) and the weekly drawdown limit
      (mitigation 2).
- [ ] Revised section re-reviewed (`/arb-risk-review` + `/arb-hostile-review`) with a passing verdict.
- [ ] Unattended-operation controls (heartbeat, session-boundary guard, and the new quote-age guard)
      implemented in code and covered by a Stage-0-style self-test before any real firing — same standard
      already applied to Stage 2's guards (`HarnessStage2_SelfTest.mq5`).
- [ ] Remaining budget re-verified against Stage 2's actual realized cost at 10/10, not the 2/10 figure above.

## 9. Acceptance tests

T1–T12 from `34_DEMO_TEST_PLAN.md` carry over unchanged. Added per hostile review:

| # | Scenario | Required behaviour |
|---|---|---|
| **T13** | Timestamp resolution | `DEAL_TIME_MSC` is used; a known injected delay is recovered to ±10 ms |
| **T14** | Clock-offset probe | server-vs-local offset measured at start and end; abort if drift exceeds a stated bound |
| **T15** | Sampling-weight integrity | reweighted stratum A+B covariate distribution reproduces the population distribution measured from the 5,843,313-row dataset |
| **T16** | Cumulative-loss stop | simulated losses trip `InpMaxCumulativeLossUsd` and latch; no further fires |
| **T17** | Account whitelist *(corrected, hostile review FF-6)* | refuses to initialise against any account number other than the one **read from the gitignored runtime config**; and refuses to initialise at all if that config is absent or the whitelist entry is missing. **Explicitly fails if the account number appears anywhere in the compiled source** — grep the `.mq5` for it as part of the test. The original wording ("the compiled-in one") contradicted C4 and would have been satisfied by exactly the hardcoding C4 prohibits |
| **T18** *(new, hostile review UA-2)* | Stage 2 mode suppresses automatic firing | with `InpStage2Mode=true`, zero fires occur over an extended idle period (at least one full scheduler interval × 10); exactly one fire occurs per explicit manual trigger; no fire occurs on timer, tick, or init |
| **T19** *(new, hostile review AS-1 — analysis stage, not pre-trade)* | Slippage-vs-sequence trend | at Stage 5, regress `slippage_broker_i` on pair sequence number across the full run. A flat trend supports stable execution quality. A worsening trend is evidence of broker-side adaptation to this account's repetitive pattern and **must be reported as a limitation on every headline number, never averaged into one** |
| **T20** *(new, hostile review UA-3)* | Stage-gate enforcement in code | Stage 3/4's automated scheduler refuses to run unless a persisted `stage2_confirmed.flag` exists; that file is written only by an explicit operator sign-off action after Stage 2's exit criteria (§8.1.4) are met, never by the harness itself. Test: delete the flag, attempt Stage 3 start, confirm refusal |

## 10. Risks

| ID | Risk | Mitigation |
|---|---|---|
| L-1 | **Real capital spent on a measurement that cannot clear the gate** (§3.1) | Scoped and budgeted as refutation-only; cumulative-loss stop; staged so it can be abandoned after Stage 2 |
| L-2 | Orphan leg on a live account | 3 s orphan timeout, emergency flatten, latching kill switch, T3/T4/T9 |
| L-3 | Phase skipped without criteria | §2 — blocking precondition |
| L-4 | Margin interaction with unrelated positions | §7 — blocking precondition |
| L-5 | Harness code reused as production execution | quarantine; separate directory; no shared module with `src/` |
| L-6 | Results over-generalised from one broker, one pair, one contract, one regime | stated as a scope limit in the analysis, not discovered later |
| L-9 *(new, hostile review AS-1)* | **The trial's own pattern is a detectable signature.** 300 small, near-identical hedged pairs from one account is exactly what a broker's last-look or behavioural-pricing logic could detect and adapt to — so the measured slippage could reflect *this account's treatment once flagged*, not general retail execution. Sharper than L-6: adaptation *during* the run, not just non-generalisation after it | T19 at analysis stage — regress `slippage_broker_i` on pair sequence number. A worsening trend is evidence of adaptation and is reported as a limitation on every headline number, never averaged away. No pre-trade mitigation exists; the design does not attempt to disguise the pattern, because doing so would itself bias what is being measured |
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

Updated 2026-09-17. Requires, in order: Phase graduation criteria written (§2, done) → account precondition
(§7, dedicated account **stated** open by the account owner, still not independently verified — the one item
below that remains genuinely open) → `/arb-risk-review` re-run (done 2026-09-16, `APPROVE WITH CONDITIONS`
C1–C6, applied) → `/arb-hostile-review` re-run (done 2026-09-16, `READY WITH CONDITIONS` for Stages 0–2
only — FF-6, UA-1, UA-2, UA-3, AS-1, all applied; **no verdict on Stage 3/4**, which requires its own review
once Stage 2's results exist) → **D-008 accepted, 2026-09-17** (see `DECISION_LOG.md`) → `/arb-implement`
Stage 0 (done, verified) **and Stage 2's code** (`HarnessStage2_LivePilot.mq5`, compiled 0 errors, **never
run**).

**What this means concretely: every written precondition is satisfied except one.** The only thing standing
between this document and a real order is §8.1.2's pre-flight checklist — principally the live account
funding/position-count verification, which requires a live MT5 connection this project does not currently
have, and creating the local (never-committed) whitelist config file. Compiling clean is not the same
standard of evidence this project has held itself to elsewhere — Stage 0 needed four real runs to be trusted.
Pair 1 of Stage 2 is where that same standard gets applied to real capital for the first time.

**Stage 0 is separately verified** (`measurement_harness/HarnessStage0_DryRun.mq5`, 12/12 PASS, confirmed
2026-09-16 — see `34_DEMO_TEST_PLAN.md`). That satisfies "Stage 0 only" above. **Stage 2 specifically** is
additionally gated on §8.1's pre-flight checklist, which restates and extends the items above with Stage
2-specific items (account funding confirmed live, credential/whitelist implementation verified, timing
window checked). Nothing beyond Stage 0 is authorized by anything in this document as it stands.
