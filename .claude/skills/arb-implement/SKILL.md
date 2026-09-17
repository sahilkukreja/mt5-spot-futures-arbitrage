---
name: arb-implement
description: Implement or test a bounded component of the MT5 arbitrage system after its design gate has passed. Use for MQL5, coordinator, adapters, simulation, tests, or telemetry; refuse premature production implementation.
---

# Arbitrage Implementation

## Load first

Read `.claude/skills/PROJECT_STATE.md` before anything else. It carries the current gate status, the measured
constants, the canonical dataset, and the pitfalls that have already cost this project time. It is a cache —
`docs/` wins on any conflict.

Implement only approved, documented behavior.

## Gate

Before editing code, locate the relevant design decision and design-review verdict. If the component is not approved as `READY` or `READY WITH CONDITIONS` with satisfied conditions, stop and name the missing design work. Prototypes must be explicitly labeled and incapable of live order submission by default.

## Context budget

Read only:

1. The relevant design document.
2. The linked decision/risk entries.
3. The files being changed and their direct interfaces/tests.

Do not load the entire repository or prior bot. Use repository search to locate symbols before opening files.

## Engineering rules

- Keep strategy, risk, execution, and broker adapters separate.
- Use deterministic state transitions, idempotent commands, unique correlation IDs, explicit time units, configuration validation, and structured telemetry.
- Default to monitor/demo behavior. Live trading requires an explicit runtime gate and validated configuration.
- Never log credentials or account secrets.
- No duplicate orders, hidden state, swallowed errors, or orphan-leg paths without recovery.
- A strategy-assumption change requires a documentation and decision-log update in the same change.

## Change protocol

State the approved behavior, bounded implementation plan, files changed, tests added, failure paths exercised, and remaining risks. Run the narrowest meaningful tests first, then relevant integration/fault tests. Do not claim broker behavior was tested without evidence from that environment.

## Project-specific implementation notes (updated 2026-09-18 — check authorization per component/stage, not as one global gate)

**The production EA gate remains closed, without exception.** `src/` is empty and stays empty. No component of
a signal-driven production strategy has a `READY` design verdict; `02_quant/15_SIGNAL_RESEARCH.md` (A4) does
not exist. This restriction is never lifted by the measurement harness's own progress below — the two are
separate authorizations and must stay separate.

**The measurement harness (`measurement_harness/`) is a stated, bounded exception (D-008, accepted
2026-09-17) — check its current per-stage status before saying it's unauthorized:**
- **Stage 0** (simulated broker, `HarnessStage0_DryRun.mq5`): verified, 12/12 PASS.
- **Stage 2** (live, single manual-triggered pair, `HarnessStage2_LivePilot.mq5`): authorized and **running**
  — 2 of 10 required pairs completed successfully as of this writing. Its pure guard logic
  (`HarnessStage2_Guards.mqh`) has its own self-test (`HarnessStage2_SelfTest.mq5`), 12/12 PASS confirmed by
  real execution. A fast-market guard (R-004) was added 2026-09-18, compiled clean, replay-tested, not yet
  run for real — check `PROJECT_STATE.md` for the current count before assuming any of this is still 0/10 or
  unimplemented.
- **Stage 3/4** (automated multi-pair scheduler): **`REJECT`/`NOT READY`** from both reviews, 2026-09-17
  (`35_1000_USD_LIVE_TEST_PLAN.md` §8.2) — explicitly not authorized regardless of Stage 2's own progress.
  6 mitigations and a full re-review remain outstanding.

Check `.claude/skills/PROJECT_STATE.md`'s gate table and `docs/ROADMAP.md` for the current dated status before
telling anyone a component is unauthorized — this section went stale once already (it previously said the
harness itself needed authorization it had already received) and will again; verify, don't recite.

`tools/` is different: read-only research scripts are permitted and expected. They never place, modify, or
close an order. When working there:

- Windows console is **cp1252** — a right-arrow character in a `print()` will crash a long run. Keep `tools/`
  output ASCII.
- pandas parses MT5 terminal exports as `datetime64[us]`. Cast dtypes explicitly before epoch arithmetic; a
  hardcoded `// 1_000_000` silently produces seconds.
- Check `git log` / `git diff HEAD` before building anything that might already exist.
- Reuse `compute_synchronized_basis()` rather than reimplementing the merge, so both collection paths keep
  identical column semantics.

If MQL5 is eventually authorized: the legacy evidence (408 failures in 50 minutes, no retry logic in the
"canonical" file) means retry/rollback/orphan handling is the *first* thing to implement correctly, not a
later hardening pass.
