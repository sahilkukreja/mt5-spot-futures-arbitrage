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
| Cost per pair (measured, not assumed) | **USD 0.4975** — spread USD 0.3975 + futures commission USD 0.10 |
| Target sample | **n = 300** |
| Guaranteed cost at n=300 | **USD 149.25 — 14.93% of the USD 1,000 ceiling** |
| Plus slippage (the unknown being bought) | at USD 0.50/pair → USD 299 total (29.9%); at USD 1.00/pair → USD 449 (44.9%) |
| Hard cumulative-loss stop | **USD 250 (25% of capital)** — latching, see §6 |

This is a deliberate, budgeted purchase of information. It is **not** a trade, has **no** profit objective,
and its P&L is a cost line, never a success criterion.

## 2. Phase position — an explicit gap that must be closed first

The mandate defines Phase 0 as *data collection only*, Phase 1 as *demo trading*, Phase 2 as
*USD 1,000 / 0.01 lot*, and states that **"each phase requires explicit graduation criteria."**

This trial is a Phase 2 activity. The project is in Phase 0. It skips Phase 1, and **no graduation criteria
exist anywhere in this project for any phase transition.** That is a live, blocking mandate violation, not a
formality.

Two things must be true before implementation:

1. **Phase graduation criteria are written** (proposed home: `docs/06_operations/` or a new
   `04_testing/30_BACKTEST_LIMITATIONS.md` companion). At minimum: what must be demonstrated to enter Phase 2,
   what evidence closes it, and what forces a return to an earlier phase.
2. **Phase 1 is either satisfied or explicitly waived with a recorded reason.** The recommended route is
   *satisfied, not waived*: run `34_DEMO_TEST_PLAN.md`'s reduced mechanical-validation scope on demo first
   (§8 Stage 1). Demo cannot price slippage, but it can prove the state machine, idempotency, journal and
   reconciliation work — and doing that with real money instead is simply paying to debug.

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
| `InpMaxConsecutiveFailures` | 3 | legacy risk-control taxonomy |
| `InpOrphanTimeoutMs` | **3,000** (was 30,000) | at max observed velocity 1.616 USD/sec, 30 s of unhedged exposure costs USD 48.48 — 4.85% of capital in one event. 3 s caps it near USD 4.85 |
| `InpMinMarginLevelPct` | 300 | fail-safe; see §7 — **currently blocks every fire on this account** |
| Expiry hard stop | refuse init within 14 days of 2026-11-25 | `GC-Z26.expiration_time` reads 0; nothing machine-readable will stop it (R-005) |
| Account whitelist | explicit account number, compiled in | prevents running against the wrong account |

Every limit here is **fail-safe**: each one only ever stops activity, never permits it. That is the standard
an uncalibrated limit must meet to be acceptable.

**Kill switch is latching** — manual operator action to clear, following the legacy taxonomy's
equity-drawdown-pause pattern rather than an auto-clearing one.

## 7. Account preconditions — blocking

**The account currently holds 4 open pairs** (not this project's output): margin used USD 524.56, equity
USD 1,000.61, free margin USD 476.05, **margin level 191%**.

Adding one harness pair (USD 129.67) takes margin level to **153%** — below the `InpMinMarginLevelPct` guard
of 300%, so **the harness would reject every single fire on this account as currently loaded.**

Before the trial can run, one of:

1. Close the 4 existing positions. Note they are in the convergence direction and, per D-006, carry at
   approximately −USD 0.38/day each if held overnight; and/or
2. Run the trial on a separate, dedicated USD 1,000 account with no other positions.

Option 2 is strongly preferred: it isolates the measurement from unrelated P&L, makes the cost accounting
unambiguous, and removes any interaction between the harness's margin guard and positions it does not control.

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

## 12. Gate status

Authorizes nothing. Requires, in order: Phase graduation criteria written (§2) → account precondition
resolved (§7) → `/arb-risk-review` re-run → `/arb-hostile-review` re-run → D-008 accepted → `/arb-implement`
Stage 0 only.
