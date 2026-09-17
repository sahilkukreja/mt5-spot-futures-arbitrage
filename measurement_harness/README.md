# measurement_harness/

Quarantined MQL5 code for the execution measurement harness designed in
[`docs/04_testing/34_DEMO_TEST_PLAN.md`](../docs/04_testing/34_DEMO_TEST_PLAN.md) and
[`docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md`](../docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md).

## Quarantine policy

Same rule as `legacy/`: **this directory is never a source of architecture, strategy, or parameters for
`src/`.** It may inform the production design once one exists; it must never become it, and no file here is
ever imported by or copied wholesale into `src/`. This is stated in every file's own header comment too, not
just here.

Reason: this code's job is to be a disposable measurement instrument, cheaply rewritten if the design changes.
Letting it quietly become "the execution engine" would smuggle a Stage-0 prototype's shortcuts (no telemetry
richness, simulated-only I/O, single-pair concurrency assumptions baked in as constants) into a component that
needs a full, reviewed design first.

## Files

| File | Stage | Status |
|---|---|---|
| `HarnessStage0_DryRun.mq5` | Stage 0 — dry run | **Verified.** 12/12 PASS, confirmed by real execution, 2026-09-16. |
| `HarnessStage2_LivePilot.mq5` | Stage 2 — live pilot | **Pairs 1 and 2 both completed successfully, 2026-09-17.** Pair 2 also verified the R-011 realized-P&L fix against a real broker (-$0.61, correctly accumulated). `InpMaxPairs` now 2 — see "Third real run" below before raising it further. **2026-09-18: `GuardFastMarket()` (R-004) added and compiled clean** — see "Fast-market guard" below. Not yet exercised on a real pair. Places real orders. |
| `HarnessStage2_Guards.mqh` | Stage 2 — pure decision logic | 12/12 PASS (G1–G12) via `HarnessStage2_SelfTest.mq5`, confirmed by real execution, 2026-09-17. **2026-09-18: 5 new functions added (`TickVelocityPtsPerSec`, `QuoteAgeMs`, `CrossLegSkewMs`, `GuardFastMarketLogic`) for the R-004 guard — compiled clean, G13–G17 written, not yet run for real.** No broker/account API call anywhere in it (checkable by grep). |
| `HarnessStage2_SelfTest.mq5` | Stage 2 — guard self-test | 12/12 PASS (G1–G12), confirmed by real execution on the VPS terminal, 2026-09-17. **2026-09-18: G13–G17 added, including G17 — a replay of the actual 2026-09-11 13:30 UTC anomaly's recorded prices/timestamps — compiled clean, not yet run for real.** Tests every function in the `.mqh` above; does not touch a broker. |

Stage 1 (demo shakedown) was skipped by explicit account-owner decision — see `RISK_REGISTER.md` R-010 and
`docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md` section 8. No Stage 1 file exists or will.

## What Stage 0 is

A self-contained correctness test of the harness's state machine, idempotency, retry whitelist, journal, and
restart reconciliation logic (`docs/04_testing/34_DEMO_TEST_PLAN.md` sections 5–8), run entirely against a
simulated in-process broker. On attach, it executes acceptance tests T1–T12 (section 10) and reports PASS/FAIL
for each to the Experts log and to a CSV file.

**It contains no call to any MT5 trading or account API** — no `OrderSend`, `OrderSendAsync`, `OrderCheck`,
`CTrade`, `PositionOpen`, `AccountInfo*`, `SymbolInfoTick`, nothing that reads or touches a real or demo
account. This is checkable directly: `grep -niE "OrderSend|CTrade|AccountInfo|SymbolInfoTick" HarnessStage0_DryRun.mq5`
returns matches only inside comments. It is incapable of placing an order **by construction**, not by a
runtime flag that could be misconfigured or bypassed.

## Verification

- **Compiled successfully** with MetaEditor64 (`C:\Program Files\MetaTrader 5 IC Markets Global\MetaEditor64.exe
  /compile`), 0 errors, across four rounds.
- **Executed end-to-end by the account owner, three times.** Real bugs found and fixed at every stage —
  nothing here was fixed by weakening an assertion; every fix made the corresponding test *more* strict about
  the invariant it claims to prove, not less.
  - **Run 1: 8/12 PASS, 4 FAIL** (T4, T6, T7, T8).
    - T6/T7/T8 failed with a misleading "no journal file" note on a file that demonstrably existed —
      `StartupReconciling()` tried to open the journal for reading while `OnInit`'s own handle still held it
      open for writing, and MQL5 returned `INVALID_HANDLE` for the second open regardless of
      `FILE_SHARE_READ` on both sides. Fixed by having `StartupReconciling()` close the write handle before
      reading and reopen it afterward.
    - T4 failed because the *test* was wrong, not the harness: it pre-seeded the simulated broker ledger
      *before* calling the scenario, so the top-of-loop idempotency check (meant for post-restart resumption)
      adopted the fill without any send ever happening — never exercising the ack-timeout-then-reconcile path
      it claimed to cover. Fixed by attaching the fill to the `SIM_ACK_TIMEOUT` event itself, so it only
      becomes visible to the ledger as a side effect of processing that specific attempt's result.
  - **Run 2 (after the above fixes): 11/12 PASS, 1 FAIL** (T6 only — `sends=1 (expect 2) outcome=COMPLETED`).
    T4/T7/T8 confirmed fixed. T6's failure signature (a "successful" outcome with a missing send) was
    ambiguous enough that a from-source guess risked being wrong in a third, different way, so a pure-logic
    port of the algorithm to Python was traced by hand first — it came out correct, meaning the bug was
    something MQL5-specific the port didn't capture, not a flaw in the algorithm. Diagnostic `Print()`
    statements were added at the two points that could distinguish the remaining hypotheses, rather than
    guessing again.
  - **Diagnosis, from the account owner's third run's `[DIAG T6]` output:** `resumed_state=HEDGED,
    ledger_size=1`. Ledger size 1 means only leg 1 had ever been sent — yet reconciliation concluded leg 2
    was already filled, from the *journal file*, not the ledger. Root cause: the journal is opened
    `FILE_READ|FILE_WRITE` (append-preserving — required within one run, since T6/T7 simulate a restart by
    reading it back mid-run), but it is **never cleared between separate EA attaches**, and every run reuses
    the same `run_id` strings ("T1".."T12"). A leg 2 row written by an *earlier* attach's T6 stayed in the
    file and got read back by the *current* attach's `StartupReconciling("T6", 1)` as if it were current.
  - **Fixed:** `OnInit` now deletes the journal file before opening it, so every self-test run starts from a
    clean slate. This is correct only for this self-test harness, where each invocation must be an
    independent, repeatable pass — the eventual production harness must never do this, since a journal that
    survives a real restart is the entire point of section 7's persistence contract.
  - **Run 4 (after the fix): 12/12 PASS.** Confirmed by the account owner, 2026-09-16 23:12. Full Experts log
    reviewed line by line, not just the summary count — every `[DIAG]` line is consistent with the intended
    behaviour (e.g. `[DIAG T6] ... resumed_state=ORPHANED ... ledger_size=1` then a genuine second send, vs.
    the earlier run's incorrect `HEDGED`/`ledger_size=1` combination). **Stage 0 is verified, not merely
    compiled.**
- Two more defects, unrelated to PASS/FAIL, were found and fixed while diagnosing T6 and cleaned up before
  this final run: a leg-2 detection check in `StartupReconciling()` that matched a state name (`"HEDGED"`)
  `ExecuteLeg()` never actually journals (silently masked by a working fallback check beside it, now made
  consistent with leg 1's own check), and an unused `SetEvents()` helper, removed.
- Two `Print("[DIAG ...]")` call sites remain in `RunPairAttempt()`, left in deliberately. They only fire
  during the restart-path tests (T3, T4, T6, T9) and add real transparency about which branch was taken and
  the send count at each step, at the cost of a few extra lines in an otherwise-clean 12/12 log. Remove them
  if a future maintainer finds them noisy; nothing depends on their presence.

## How to run it

1. Copy `HarnessStage0_DryRun.mq5` into your terminal's `MQL5/Experts/` folder (MetaEditor's *File → Open Data
   Folder* shows you where that is).
2. Open it in MetaEditor and press **Compile** (F7). Expect 0 errors, 1 harmless warning about the version
   string format.
3. Attach it to **any chart, on any account — demo, live, even one with no account logged in.** It makes no
   account calls, so which account is active is irrelevant to what it does.
4. Open the **Experts** tab (View → Toolbox → Experts). You'll see all 12 results immediately — it runs once,
   synchronously, in `OnInit`, and finishes in well under a second.
5. Two files are written to `MQL5/Files/` in that terminal's data folder: `arb_harness_stage0_journal.csv`
   (every simulated state transition) and `arb_harness_stage0_selftest_results.csv` (the PASS/FAIL summary).

If anything shows `FAIL`, that's a real defect in the code, not a false alarm to dismiss — please report it
back rather than re-running and hoping.

## Known limitation, disclosed rather than hidden

A true MT5 terminal kill cannot be reproduced from inside one running script. T6 and T7 simulate a "restart"
by wiping all in-memory harness state and reconstructing solely from the journal file and the (unwiped)
simulated broker ledger — which proves the **persistence contract** (file + broker state is sufficient to
reconstruct correctly), but not OS-level crash safety of the file write itself (e.g., a write that's flushed
to the OS but not yet durable to disk when power is lost). A real Stage 1 supervised-restart test would still
be worth doing later for that reason.

## What Stage 2 is

`HarnessStage2_LivePilot.mq5` places real orders. It reuses Stage 0's proven state machine, idempotency
scheme, and retry whitelist exactly, with every simulated call replaced by the real MT5 equivalent —
`OrderSend` against `MqlTradeRequest`, `HistoryDealsTotal`/`HistoryDealGetTicket` for idempotency checks
against actual broker history, `PositionsTotal`/`PositionSelectByTicket` for startup reconciliation, and
`HistoryDealGetInteger(..., DEAL_TIME_MSC)` for authoritative fill times. Full design:
`docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md` sections 5, 6, 8.1, 9.

**It fires exactly one pair per explicit button click on the chart — never on a timer, tick, or init.**
`InpMaxPairs` defaults to **1**. Raise it only after that first pair has been fully verified against every
item in section 8.1.3's checklist.

**Run once, real bug found and fixed. Not yet re-run since the fix.** See "First real run" below for the
full account. Stage 0 needed four real runs and three real bug fixes before it was trustworthy, against a
fully scripted, deterministic simulated broker with zero real-world variance — this file's very first real
run against an actual broker found a real bug just as fast, which is exactly why a clean compile was never
treated as evidence it works. Pair 1's elevated-scrutiny procedure in the design doc exists specifically
because of this gap: Stage 1 (the demo shakedown that would normally have absorbed this risk for zero cost)
was skipped by explicit account-owner decision (`RISK_REGISTER.md` R-010), so pair 1 is
the very first contact any of this project's code has had with a real MT5 API.

### Setup required before this file can run at all

1. **Create the whitelist config file, in the terminal's own `MQL5/Files/` folder — not in this repository.**
   One line: `AccountNumber=<your account number>`. This file lives entirely outside the git working tree
   (a different folder on disk), so it can never be accidentally committed regardless of `.gitignore`. The EA
   refuses to initialise if this file is missing, malformed, or doesn't match the account currently logged in.
2. **Verify the dedicated live account's funding and position count yourself, directly in the terminal.**
   This project has no live MT5 connection available to do that independently. The account owner stated the
   account is open (`docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md` §7) — this has not been independently
   confirmed, and the EA's own `StartupReconciling()` will refuse to start if it finds any open position
   bearing its magic number, but it cannot verify funding or confirm the account is otherwise empty of
   *unrelated* positions.
3. **Read `docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md` section 8.1.2's full pre-flight checklist** before
   attaching this EA to a chart. It is not optional reading.

### First real run, 2026-09-17 — a real bug found, exactly as expected

Pair 1 fired against the live account. Both legs **opened correctly** — idempotency key construction,
retcode handling, and deal confirmation via `HistoryDealSelect` all worked on the first real attempt, and
`HEDGED` was reached correctly. Then `CloseLegByTicket()` failed on **both** legs (`err=4753`).

**Root cause:** `ExecuteLeg()` returned `result.deal` (the deal ticket) as the ticket to close by, but
`PositionSelectByTicket()` needs the *position* ticket. These are not the same value in Hedge mode, which
this account uses — they can coincide in Netting mode, which is presumably where the original assumption
came from. The kill switch latched correctly rather than retrying blindly into a failing close path; both
positions were closed manually by the account owner. **No unhedged directional exposure occurred at any
point** — both legs stayed open and mutually offsetting the entire time the bug was active.

**Fixed:** the position ticket is now read via `DEAL_POSITION_ID`, MT5's documented mechanism for resolving
a deal to its position, correct in both Hedge and Netting modes — not inferred or assumed. Recompiled clean
(0 errors). **Not yet re-run.** See `docs/RISK_REGISTER.md` R-010's realized-risk update for the full
account, and R-011 for a related, separately-tracked gap (realized P&L isn't summed yet, so loss guards work
from a worst-case estimate, not actuals).

This is exactly the outcome the design predicted: a real-API defect, found at pair 1 because Stage 1 was
skipped, caught by the kill switch rather than causing silent damage, costing a manual intervention rather
than money. Treat whatever fires next as **pair 1 again**, not pair 2 — the elevated pair-1 scrutiny in
`docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md` §8.1.3 was not yet exercised against a successful close.

### Second real run, 2026-09-17 — pair 1 completed successfully

Same day, re-run with the position-ticket fix in place. Both legs opened (`GC-Z26` SELL @4399.73 vs
ref 4399.74, `+0.01` adverse; `XAUUSD.vx` BUY @4360.39, zero slippage), reached `HEDGED`
(positions 34236921 / 34236922), and both closed cleanly — `EMERGENCY FLATTEN` on each leg returned
`retcode=10009 (DONE)`. Final line: **`PAIR 1 outcome: COMPLETED`**. Zero errors, zero kill-switch trips.
The position-ticket fix held on its first real retry.

**A logging gap surfaced in reviewing this run, not a safety defect:** `CloseLegByTicket()` reports
`sent`/`retcode` but never captures the exit fill price or time the way `ExecuteLeg()` does for entries via
`HistoryDealSelect`. This pair's actual realized P&L cannot be computed from the journal or the Experts log
alone — only from the terminal's own Trade History. Same root cause as R-011 (realized P&L isn't tracked);
worth fixing together, not yet done.

**This run came from a different environment than the failed one** — a different Windows user profile and
terminal data folder than the `sahil`-user run that hit the ticket bug. Functionally irrelevant (the EA
trades its input symbols regardless of which chart it's attached to), but it means the earlier run's
kill-switch state file is untouched and would still show latched if that terminal is used again — it lives
in a different `MQL5/Files/` folder entirely and was never actually cleared, just not present here.

### Realized P&L tracking — fixed 2026-09-17, not yet re-run

Reviewing pair 1's successful run surfaced two real defects, both fixed the same day:

1. **The loss counters never accumulated at all.** Not "only a worst-case estimate" as first characterized —
   `g_daily_loss_usd`/`g_cumulative_loss_usd` were never written to after a pair completed, for as long as
   this file existed. `InpMaxDailyLossUsd` and `InpMaxCumulativeLossUsd` could not trip regardless of real
   losses. `InpMaxPairs=1` meant this hadn't mattered yet in either real run. See `docs/RISK_REGISTER.md`
   R-011 for the full account.
2. **The `LEG_PARTIAL` branch didn't actually branch on flatten failure** — it fell through to
   `CLOSED_ORPHAN`/`IDLE` regardless, unlike the other two failure paths. Never triggered (`r1` was always
   `LEG_FILLED`), caught on review.

**Fixed:** `CloseLegByTicket()` now captures the exit deal's confirmed price via `HistoryDealSelect`, exactly
like `ExecuteLeg()` does for entries. A new `GetDealPnL()` and `RecordRealizedPnL()` compute and accumulate
each pair's true realized P&L. **Only the loss portion accumulates — profits never offset the counters**,
deliberately: letting profits fund a later loss is loss-recovery/martingale-adjacent, which the mandate
prohibits. A new `arb_harness_stage2_pairs.csv` records one row per pair — entry/exit prices, realized P&L,
running daily/cumulative totals — so a pair's outcome is readable without cross-referencing the terminal.

Recompiled clean (0 errors). **Verified by real execution, 2026-09-17 18:40 — pair 2.** This exercises code
paths pair 1's two real runs never touched. Same standard as always: a clean compile is not evidence it works.

### Third real run, 2026-09-17 — pair 2, first real exercise of the R-011 fix

With `InpMaxPairs` raised to 2, pair 2 fired: `GC-Z26` SELL @4390.23 (−0.09 adverse), `XAUUSD.vx` BUY @4351.03
(zero slippage), reached `HEDGED` (positions 34236977 / 34236978), both legs flattened cleanly
(`retcode=10009 DONE` on each). **Realized P&L: −$0.61**, computed by `GetDealPnL()` summing all four legs'
`DEAL_PROFIT + DEAL_SWAP + DEAL_COMMISSION` via `HistoryDealSelect` — the first time this code path has ever
run against a real broker. `RecordRealizedPnL()` correctly accumulated the full $0.61 into both
`g_daily_loss_usd` and `g_cumulative_loss_usd` (Experts log: `daily loss $0.61/40.0, cumulative loss
$0.61/250.0`), consistent with the loss-only asymmetry the self-test verified in isolation (G10). A row was
written to `arb_harness_stage2_pairs.csv` with `outcome=COMPLETED`, entry/exit prices for both legs, and
`pnl_status=confirmed`.

This closes R-011's real-API gap: both halves of the fix — the pure loss-only arithmetic (self-test, 12/12
PASS) and the real `HistoryDealSelect`/`GetDealPnL`/`RecordRealizedPnL` wiring (this run) — are now verified.
`InpMaxPairs=2` is the current ceiling; raise it again only with the same scrutiny as before.

### Testability architecture — pure logic split out for self-testing, 2026-09-17

Unlike Stage 0 (pure logic from inception), Stage 2's guard functions originally called real MT5 APIs
directly (`AccountInfoInteger`, `SymbolInfoTick`, `AccountInfoDouble`, etc.), which made them impossible to
exercise without a live broker connection — exactly the "a clean compile is not evidence it works" gap this
project keeps running into, except this time for logic that had never been run at all, adversarial or
otherwise.

**Fix:** every piece of pure decision logic — the retry whitelist, retcode name mapping, idempotency key
format, and all five section-6 guards (account whitelist, live-account-only, expiry, spread, margin level,
budgets) plus the loss-only realized-P&L arithmetic R-011 depends on — moved into `HarnessStage2_Guards.mqh`.
Every function there takes its inputs as plain parameters and returns a decision; none of them call
`AccountInfo*`, `SymbolInfoTick`, `OrderSend`, `PositionSelectByTicket`, or any other MT5 trading/account/
market-data API. This is checkable directly, the same way Stage 0's claim is:
`grep -niE "AccountInfo|SymbolInfoTick|OrderSend|PositionSelect|CTrade" HarnessStage2_Guards.mqh` returns
nothing outside comments.

`HarnessStage2_LivePilot.mq5`'s own guard functions (`GuardAccountWhitelisted()`, `GuardSpread()`, etc.) are
now thin wrappers: gather the real values, call the matching `*Logic()` function in the `.mqh`, translate the
result to a `Print()` plus bool/enum. The wrapper's own gathering code is *not* covered by the self-test below
— only a real run exercises `AccountInfoInteger`, `SymbolInfoTick`, `OrderCalcMargin`, `OrderSend`, and
`PositionSelectByTicket` themselves.

`HarnessStage2_SelfTest.mq5` is the actual test suite, structured like `HarnessStage0_DryRun.mq5`: it
`#include`s the `.mqh`, calls every function in it with injected values — including deliberately adversarial
and boundary cases — and reports PASS/FAIL to the Experts log and to
`arb_harness_stage2_selftest_results.csv`. What it covers:

- **G1–G3**: retry whitelist (every transient retcode, a representative set of non-transient ones, and one
  unmapped value to confirm the `default:false` fail-closed path), retcode-name mapping, idempotency key
  format.
- **G4–G8**: each of the five section-6 guards, including their fail-closed edge cases specifically —
  unset/negative whitelist, non-real account modes, the expiry cutoff boundary (one second before vs. exactly
  at), spread exactly at the max (strict `<`, not `<=`), and the `projected_margin<=0` edge case in the margin
  guard.
- **G9**: the budget guard's all six distinct outcomes individually, plus the priority ordering — kill switch
  must win even when another block condition is also true, since it's checked first.
- **G10–G11**: the loss-only P&L asymmetry (a profit must contribute exactly 0 to the loss counters, never a
  negative "credit"), and the deal P&L component arithmetic.
- **G12**: a local file write/read round-trip, included because it's free to test and touches no broker, not
  because it belongs conceptually in the `.mqh` (file I/O is deliberately left out of the pure-logic file).

**Compiled clean**, MetaEditor64, 0 errors, 1 harmless warning (version-string format) — same standard as
every other file here. **Executed by the account owner on the VPS terminal, 2026-09-17 18:30: 12/12 PASS**
(`GC-Z26,H1` chart, `HarnessStage2_SelfTest`), every one of G1–G12 reporting `PASS` with its full diagnostic
detail in the Experts log, matching the expected values exactly (e.g. G9's budget-guard priority test showed
`priority=KILL_SWITCH` even with a simultaneous max-pairs condition, confirming the kill switch is checked
first as designed). Results also written to `arb_harness_stage2_selftest_results.csv` in that terminal's
`MQL5/Files/` folder. Attach it to any chart on any account — like Stage 0, it makes no account calls, so
which account is logged in is irrelevant.

**What this does not cover, stated explicitly so it isn't mistaken for full coverage:** `ExecuteLeg()`,
`CloseLegByTicket()`, `BrokerHasKey()`, `StartupReconciling()`, and the real-value-gathering half of every
guard wrapper. Those touch `OrderSend`, `PositionSelectByTicket`, and `HistoryDealSelect` against a real
broker connection, and can only be validated by an actual pair run — the same boundary Stage 0's own
"Known limitation" section already draws for its own restart-simulation logic.

### Fast-market/stale-quote guard (R-004) — added 2026-09-18, compiled clean, not yet run for real

Both `/arb-risk-review` and `/arb-hostile-review` rejected `docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md`
§8.2 (Stage 3/4) on the same finding: `GuardSpreadLogic()` checks only each leg's own bid-ask spread, never
quote age or cross-leg staleness, and would **not** have caught the 2026-09-11 13:30 UTC anomaly — the
futures leg repriced ~54 points in ~10 seconds while the spot leg's ask stayed frozen at a normal, narrow
spread. `docs/02_quant/13_BASIS_MODEL.md`'s own conclusion: "per-leg price velocity would have caught it,
with a large margin" (the documented extreme is 161.6 pts/sec vs. a measured p99.9 of 8.08 pts/sec across
707,467 rows; the anomaly's own `quote_skew_ms` of 238 sits *inside* the still-unapproved 400ms staleness
candidate, confirming skew alone would have missed it).

**Added to `HarnessStage2_Guards.mqh`:** `TickVelocityPtsPerSec()`, `QuoteAgeMs()`, `CrossLegSkewMs()`, and
`GuardFastMarketLogic()` — pure functions, no broker API calls, same testability pattern as everything else
in that file. Every threshold is an `input` in `HarnessStage2_LivePilot.mq5`
(`InpMaxVelocityPtsPerSec=20.0`, `InpMaxQuoteAgeMs=2000`, `InpMaxCrossLegSkewMs=400`), each labeled
**UNCALIBRATED** in its own comment, same status as `InpMaxSpreadUsd` — reasoned starting candidates
(20 pts/sec is roughly 2.5× the measured p99.9 and ~8× below the one observed extreme), not values this
project claims authority for. **NO MAGIC VALUES**: nothing here is a literal baked into the logic itself.

**Added to `HarnessStage2_LivePilot.mq5`:** `MaxVelocityInWindow()` scans real ticks via `CopyTicksRange()`
over `InpVelocityLookbackMs` (3000ms) and finds the highest tick-to-tick velocity in that window; `GuardFastMarket()`
gathers real values (velocity on both legs, quote age on both legs, cross-leg skew) and delegates the decision
to `GuardFastMarketLogic()`. Wired into `RunOnePair()`'s guard chain, right after `GuardMarginLevel()` and
before `GuardBudgets()`. A data gap (fewer than 2 ticks in the lookback window, or an unusable timestamp pair)
returns the same -1 "invalid, fail closed" sentinel `TickVelocityPtsPerSec()` itself uses for `dt<=0` — this
guard blocks on missing data, it never waves a data gap through as "no movement detected."

**Verification status, stated precisely:**

- `HarnessStage2_Guards.mqh`'s 4 new functions: compiled clean.
- `HarnessStage2_SelfTest.mq5`'s new tests G13–G17: compiled clean, **not yet run.** G17 is the load-bearing
  one — it replays the *actual recorded prices and timestamps* from the 2026-09-11 13:30 UTC anomaly
  (`docs/02_quant/13_BASIS_MODEL.md`'s own row-level table, not a synthetic case) through
  `GuardFastMarketLogic()` and asserts it blocks. G16 separately confirms skew alone (238ms, matching the
  anomaly's own documented value) would **not** have blocked it — reproducing this project's own prior
  finding, not contradicting it.
- `HarnessStage2_LivePilot.mq5`'s `GuardFastMarket()`/`MaxVelocityInWindow()`: compiled clean, **never
  exercised against a real broker connection.** `CopyTicksRange()`'s actual behavior against this specific
  broker — tick availability, timestamp granularity, whether the lookback window reliably contains enough
  ticks in quiet conditions — is unverified. Same standard as always: a clean compile is not evidence it
  works.

**What this does and does not resolve:** this satisfies Stage 3/4 review mitigation 1's core ask — a named,
implemented guard, tested against the specific historical event that motivated it — but Stage 3/4 itself
remains blocked behind mitigations 2–7 and a full re-review, unchanged by this addition alone. It does
directly strengthen Stage 2's own posture for pairs 3–10, once the self-test actually runs and the guard is
exercised on a real pair without incident.

### Timeout/retry enforcement (R-013) — fixed 2026-09-18, compiled clean, not yet run for real

`InpAckTimeoutMs`, `InpFillTimeoutMs`, and `InpOrphanTimeoutMs` were declared inputs that nothing in the file
ever referenced — confirmed by grep. In particular, `InpMaxTradeLossUsd=15`'s own documented justification
(`35_1000_USD_LIVE_TEST_PLAN.md` §6) depends on `InpOrphanTimeoutMs` bounding worst-case unhedged exposure at
~$4.85; the actual code flattened an orphaned leg in a single attempt with no timeout at all, so that
derivation described a mechanism that didn't exist.

**Fixed:** `CloseLegByTicket()` now retries on the same `IsTransientRetcode` whitelist `ExecuteLeg()` already
uses, bounded by `InpOrphanTimeoutMs` as a wall-clock ceiling — a real bound on how long the EA will keep
trying to flatten an orphan before giving up and tripping the kill switch, matching the design doc's own
arithmetic for the first time. `ExecuteLeg()`'s retry loop now also checks elapsed wall-clock time against
`InpFillTimeoutMs`, not just `InpMaxOpenRetries`. `InpAckTimeoutMs` was **removed** rather than fixed — this
file's `OrderSend()` dispatch is synchronous, so there's no separate "waiting for ack" phase distinct from
"waiting for fill" to bound; keeping a declared-but-unenforceable input was judged worse than removing it.

Recompiled clean (0 errors). **Not yet run for real** — no pair so far (n=2) has ever hit a transient retcode
on either the open or close path, so this new retry logic has never actually executed against a real broker.
Full account: `docs/RISK_REGISTER.md` R-013.

### What is intentionally not yet implemented

- **The Stage 3/4 automated scheduler and the `stage2_confirmed.flag` stage-gate file (T20) do not exist in
  this file.** This build is scoped to Stage 2's manual single-pair procedure only, matching the account
  owner's explicit request to test with one pair first. Building the automated scheduler is separate,
  later work, gated on Stage 2's own results.
