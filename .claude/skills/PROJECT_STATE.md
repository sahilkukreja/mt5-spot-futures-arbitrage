# Project state — shared skill context

Every `arb-*` skill loads this first. It exists so a session starts informed instead of re-deriving what the
project already established.

**This file is a cache, not source of truth.** `docs/` wins on every conflict. If something here contradicts a
document, the document is right and this file is stale — fix it. Last synced: **2026-09-18**.

---

## Gate status (the short version)

| Gate | Status |
|---|---|
| Economics | **NOT PASSED** — but see D-006: one structure is now definitively rejected |
| Design | **NOT PASSED** — `20_SYSTEM_ARCHITECTURE.md`, `22_STATE_MACHINE.md` are PROPOSED/uncalibrated |
| Implementation | **NOT PASSED for the production system** — `src/` is empty and stays empty. **D-008's measurement instrument is a stated exception**: `measurement_harness/HarnessStage0_DryRun.mq5` verified (12/12). `HarnessStage2_LivePilot.mq5` has run **2 of 10 required Stage 2 pairs successfully** (2026-09-17), both `COMPLETED`, R-011 (realized-P&L tracking) fixed and verified against a real pair. `HarnessStage2_Guards.mqh`/`HarnessStage2_SelfTest.mq5` provide pure-logic test coverage — **17/17 PASS (G1–G17), confirmed by real execution 2026-09-18**, including the R-004 fast-market guard (G13–G17) and its replay of the real 2026-09-11 anomaly (G17). The `GuardFastMarket()`/`MaxVelocityInWindow()` real-API wrappers and the R-013 timeout/retry fix are both compiled clean but still **not yet exercised against a real broker** — no pair so far has hit a transient retcode or needed the velocity guard live. D-008 accepted 2026-09-17. See `04_testing/35_1000_USD_LIVE_TEST_PLAN.md` §12. |
| **Account isolation (R-014) — actively blocking Stage 2 right now** | **BROKEN, and the account owner has decided not to fix it by closing the legacy position** (it's at a loss — a legitimate, separate trading call, not something to push against). `MMT_TradePannel_Pro` (2 pairs open) is consuming real margin on the same account Stage 2 uses. **Direct observed consequence, 2026-09-18: firing Stage 2 pair 3 was correctly `BLOCKED: projected margin level below InpMinMarginLevelPct` — this is the guard working, not a bug, and lowering the threshold is not the fix.** Two paths forward, both an account-owner decision: wait for the legacy bot's own positions to close/margin to improve, or open a genuinely separate, independently-funded account for Stage 2/3/4 (the original §7 intent). Neither chosen yet. Check `RISK_REGISTER.md` R-014 before assuming Stage 2 can fire. |
| Stage 3/4 (automated scheduler) | **REJECTED / NOT READY** — `/arb-risk-review` (REJECT) and `/arb-hostile-review` (NOT READY), 2026-09-17, on the same finding: no guard existed against a cross-leg stale-quote/fast-repricing event (now addressed at the design level, see above). **2026-09-18: concrete design-level resolutions proposed for mitigations 2, 3, 5, 7 (weekly drawdown, dual stratum quotas, stratum B cooldown, expiry-timeline feasibility); mitigation 4 (sampling weight) has a proposed but unverified formula; mitigation 6 (broker ToS) is explicitly blocked on the account owner.** None of this is a passed re-review — `35_1000_USD_LIVE_TEST_PLAN.md` §8.2 still needs both `/arb-risk-review` and `/arb-hostile-review` to run again before Stage 3/4 moves at all. Do not treat Stage 3/4 as available regardless of Stage 2's own progress. |

Full picture, always current: **`docs/ROADMAP.md`**. Read it before answering any "what next" question.

Mandated doc tree is 41 files; 17 exist, 12 have content. `02_quant/15_SIGNAL_RESEARCH.md` is **still missing**
and is the current critical path for the strategy/economics gate specifically — **not** the same as "no work
exists" (see below). `01_research/01`–`05` are empty stubs. `04_testing/` has real, extensive content
(`34_DEMO_TEST_PLAN.md`, `35_1000_USD_LIVE_TEST_PLAN.md`) — **not empty**, corrected 2026-09-18. `06_operations/`
has `PHASE_GRADUATION_CRITERIA.md` — **not empty**, corrected 2026-09-18. `05_development/` is still empty.

**A candidate A4 signal proposal exists but is not accepted:** `docs/Gold-Basis-EA-Strategy-and-System-Design.md`
(external proposal, tracked 2026-09-18) — `/arb-hostile-review` verdict NOT READY as a basis for adoption; its
central premise (residual mean-reversion) has partial supporting measurement now (`12_FAIR_VALUE_MODEL.md`
"Residual dispersion and reversion," 2026-09-18) but no net-of-cost expected-value evidence. Its architecture
sections are a credible reference regardless. Do not treat this as filling the `15_SIGNAL_RESEARCH.md` gap.

## The decisive finding (2026-09-16) — do not re-derive this

The convergence trade (SELL `GC-Z26` / BUY `XAUUSD.vx`, held overnight) is **negative expected value at every
holding period**, and this is measured, not estimated:

| | $/day |
|---|---|
| Basis decay captured | +0.3905 (95% CI 0.3330–0.4480, R²=0.83, n=5,843,313) |
| Spot swap paid | −0.7714 (−60 pts/day, ×3 Wednesdays) |
| Futures swap | 0.0000 (`swap_mode` disabled) |
| **Net carry** | **−0.3809**, CI entirely below zero |

`E[P&L] = −0.3809·H − 0.4975`. Proposed **D-006** rejects this structure.

**The error that hid it for weeks:** the EV model compared costs against the basis **level** (~USD 41), which
assumes the whole gap is capturable. A pair opened at `B₀` and closed at `B₁` earns `B₀ − B₁`. The revenue term
— the decay rate — had never been measured. *Generalize this: always check that the revenue side of a model is
measured, not just the cost side.*

**What survives:** intraday. Swap accrues only overnight. Median daily range of `convergence_basis` is **USD 7.91**
against a **USD 0.4975** round trip, and all 38 full sessions exceeded 4× the round trip. That is opportunity, not
demonstrated edge — no signal exists and slippage is unmeasured.

**The reverse direction** (BUY futures / SELL spot) nets +USD 0.1238/day. Recorded, **not recommended**: it is
swap harvesting on a broker-set credit that can change without notice, and is small against a USD 2.77 residual
std. See `17_EXPECTED_VALUE.md`.

## Measured constants (sourced — never re-assume these)

| Quantity | Value | Note |
|---|---|---|
| Spot spread | mean **USD 0.1545**, median 0.15, p99 0.15, max **12.15** | near-fixed floor, violent rare tail |
| Futures spread | mean **USD 0.2430**, median 0.24, p99 0.25, max **5.04** | same shape |
| Round trip, 0.01/0.01 | **USD 0.4975** | spread USD 0.3975 + futures commission USD 0.10 |
| Spot commission | USD 0.00 | live deal history |
| Futures commission | USD 10/lot round trip → USD 0.10 at 0.01 | |
| Spot swap | −60 pts/day long, +40 short; ×3 Wednesdays, giving a ×9/7 weekly average | futures swap disabled. The ×9/7 convention matches standard MT5 triple-swap practice (compensating for two weekend nights with no separate charge, not double-counting them) and this project's own `14_TRANSACTION_COST_MODEL.md` marks the Wednesday triple-charge as *Sourced*, not assumed — but an external proposal (`docs/Gold-Basis-EA-Strategy-and-System-Design.md` §4.3, 2026-09-18) disputes it. Treat as **needing reconciliation against the actual broker charging schedule**, not settled either way by this note |
| Combined margin, 1 pair | ≈USD 129.67 | 0.01/0.01 |
| Quote skew | p95 **387 ms**, p99 460 ms | 400 ms is a *candidate*, not approved |
| Contract size | 100 for **both** legs | why 0.01/0.01 is delta-flat (D-002) |
| Implied carry rate | 4.71% | stable across 7-day and 45-day windows |

Superseded, do not use: USD 0.30/leg spread, USD 7.50 futures commission, any AR(1) half-life.

## Canonical dataset

`research/export-full/` — built by `tools/tick_export_loader.py` from the MT5 terminal exports
`research/GC-Z26_202607270922_202609161526.csv` and `research/XAUUSD.vx_202607270600_202609161540.csv`.
6,520,722 futures + 8,798,113 spot ticks, 2026-07-27 → 2026-09-16, **5,843,313 synchronized rows** at 500 ms.

`research/` is version-controlled (large CSVs via Git LFS) so work moves between machines. It is still **not
source of truth** — promote findings into `docs/` by hand.

⚠ Terminal exports are in **server time**; `copy_ticks_range()` returns **UTC**. Not directly comparable, and
the offset has not been established yet.

## Pitfalls that have already cost real time

1. **Measure the revenue side.** See above. This one inverted a conclusion's sign.
2. **Timestamp units.** pandas parses these exports as `datetime64[us]`, not `[ns]`. `astype("int64") // 1e6`
   silently yields *seconds*. Cast the dtype explicitly. This made a merge tolerance 1000× too permissive.
3. **Non-stationary series.** AR(1)/half-life on the raw dollar basis measures the drift, not mean-reversion.
   The basis decays deterministically; there is no fixed mean.
4. **Windows console is cp1252.** `→` (U+2192) in a `print()` crashes a long run. Em-dash is safe. Prefer ASCII
   in `tools/` output.
5. **Legacy logs are UTF-16.** Plain grep silently returns zero matches. Decode explicitly.
6. **After context compaction, run `git log` and `git diff HEAD` before building anything** — work has been
   duplicated this way before.
7. **Cross-references go stale.** Documents have claimed files "do not exist" that did. Sweep with
   `/arb-doc-sync`.

## Hard constraints (non-negotiable)

- USD 1,000 experimental ceiling. Capital preservation outranks return.
- No martingale, grid averaging, loss-recovery sizing, or hidden directional exposure.
- No live trading **of a strategy**. No MQL5 for the production system before the design gate. D-008's
  bounded, quarantined measurement instrument (zero signal logic, zero profit objective) is a stated
  exception, reviewed and accepted on its own terms — never precedent for anything else. See D-008,
  condition C6.
- `legacy/` is reference and lessons-learned **only** — never an architecture, strategy, or parameter baseline.
- Never reproduce or commit the credentials found in `legacy/` (MT5 demo password, Telegram bot token).
- Never print or commit the account number.
- Commit only when the user asks.

## Live account facts

Symbol universe is **exactly 2 symbols**: `XAUUSD.vx`, `GC-Z26`. No other gold-futures month exists — so no
successor contract to roll into before the 25 Nov 2026 expiry, and `expiration_time` reads 0 (no
machine-readable expiry). This is a **design** requirement, not an ops afterthought (R-005).

4 concurrent pairs were observed open on 2026-09-16 (not this project's output), margin ≈USD 525, margin level
≈191%.
