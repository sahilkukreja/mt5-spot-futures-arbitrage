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
| `HarnessStage0_DryRun.mq5` | Stage 0 — dry run | Compiles clean (MetaEditor64, 0 errors). See "Verification" below. |

Stage 1 (demo) and Stage 2+ (live) code does not exist yet and is blocked — see `docs/ROADMAP.md` and
`docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md` for exactly what's still open before either can be written.

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
- **Executed end-to-end by the account owner, twice.** First real run: **8/12 PASS, 4 FAIL** (T4, T6, T7, T8).
  Both failure clusters were real bugs, not flaky tests:
  - **T6, T7, T8** — `StartupReconciling()` tried to open the journal file for reading while `OnInit`'s own
    handle still held it open for writing; MQL5 returned `INVALID_HANDLE` for the second open regardless of
    `FILE_SHARE_READ` on both sides, producing the misleading "no journal file" note on a file that
    demonstrably existed. Fixed by having `StartupReconciling()` close the write handle before reading and
    reopen it afterward — which is also more faithful to what it's testing, since a real restart holds no
    handle to begin with.
  - **T4** — the test itself was wrong, not the harness: it pre-seeded the simulated broker ledger *before*
    calling the scenario, so the top-of-loop idempotency check (meant for post-restart resumption) adopted the
    fill without any send ever happening, which doesn't exercise the ack-timeout-then-reconcile path the test
    claims to cover. Fixed by attaching the fill to the `SIM_ACK_TIMEOUT` event itself, so it only becomes
    visible to the ledger as a side effect of processing that specific attempt's result — strictly after the
    send has already happened and been counted.
  - Fixes committed, recompiled clean (0 errors), **not yet re-run** — the account owner's second confirmed
    run should show 12/12 PASS; if it doesn't, that's a new, real finding and should be reported rather than
    assumed away.
- Nothing here was fixed by weakening an assertion. Both fixes made the corresponding test *more* strict about
  the invariant it claims to prove, not less.

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
