# Project state — shared skill context

Every `arb-*` skill loads this first. It exists so a session starts informed instead of re-deriving what the
project already established.

**This file is a cache, not source of truth.** `docs/` wins on every conflict. If something here contradicts a
document, the document is right and this file is stale — fix it. Last synced: **2026-09-18**.

---

## Gate status (the short version)

| Gate | Status |
|---|---|
| Economics | **NOT PASSED** — D-006 rejects the overnight structure; **D-010 (accepted 2026-09-18) defines the Required Safety Margin** as a deterministic two-tier ceiling (1.5×/≈$81 de-risk, 2.0×/≈$108 hard stop over the ≈$54 R-004 worst-event anchor), closing one specific gap in this gate — Net Executable Edge is still not computable (slippage/latency unmeasured), so the gate itself remains not passed |
| Design | **NOT PASSED** — `20_SYSTEM_ARCHITECTURE.md`, `22_STATE_MACHINE.md` are still PROPOSED/uncalibrated. **2026-09-18: three of the Gold-Basis-EA hostile-review's analytical conditions closed on paper** (execution leg ordering + explicitly-UNCALIBRATED `Leg2_Timeout_Ms` in `22_STATE_MACHINE.md`; session interlock using the real measured ~21:58–23:00 UTC daily quote blackout, not an assumed exchange calendar, in `20_SYSTEM_ARCHITECTURE.md`; margin liquidation tripwires formalized by extending the already-real `GuardMarginLevelLogic()`/R-014 pattern) — no calibrated numeric threshold was added by this work, and the signal (A4) remains the blocking condition regardless |
| Implementation | **NOT PASSED for the production system** — `src/` is empty and stays empty. **D-008's measurement instrument is a stated exception**: `measurement_harness/HarnessStage0_DryRun.mq5` verified (12/12). **`HarnessStage2_LivePilot.mq5` completed all 10/10 required Stage 2 pairs** (2026-09-17 x2, 2026-09-18 x8) — the required run, already sufficient for `stage2_confirmed.flag`. **2 additional real pairs since (11–12, 2026-09-18/19)** exercised the new pre-Leg-2 fast-market guard: pair 11 `REJECTED_BROKER` (AutoTrading toggle off on VPS, retcode 10027, zero cost, not a code issue), pair 12 `COMPLETED` (−$0.51, verified) and the first real pass of the new guard check (clean, as expected — its trip/rollback branch still unexercised). Total tracked cost now ≈$5.44 (pairs 2–12) — consistent with per-pair cost holding steady. R-011 fixed and verified. `HarnessStage2_Guards.mqh`/`HarnessStage2_SelfTest.mq5` pure-logic coverage: 17/17 PASS, real execution 2026-09-18. `GuardFastMarket()` (R-004) exercised for real 4 times: 3 blocks (plausible genuine spot-feed staleness, zero exposure created each time), 7 clean passes — real, still-limited evidence. R-013's retry/timeout logic still not exercised (no transient retcode occurred in any of the 10). **§8.1.4 exit criteria: 4/6 checkable items fully clean; 2 open** — `clock_offset_ms` has no stated bound (new R-015) and its outliers are likely spot-staleness-contaminated, not clock drift; the independent quote cross-check was only done for pair 3, not all 10. Nothing observed indicates anything unsafe occurred in any pair. **`stage2_confirmed.flag` WRITTEN by the account owner, 2026-09-18**, explicitly accepting the two open items above as known limitations. This satisfies T20's code-level mechanism only — no Stage 3/4 code exists yet to check for the file, and Stage 3/4 itself remains separately blocked (see next row) regardless of this sign-off. D-008 accepted 2026-09-17. See `04_testing/35_1000_USD_LIVE_TEST_PLAN.md` §8.1.4 results and `RISK_REGISTER.md` R-015. |
| **Account isolation (R-014)** | **Likely resolved 2026-09-18, not independently confirmed.** The legacy `MMT_TradePannel_Pro` EA's 2 pairs (which had been blocking Stage 2 pair 3 via the margin guard — a real, correctly-functioning block, not a bug) were closed by the account owner the same day. Pair 3 then fired successfully. **Not yet re-verified via a fresh whole-account `PositionsTotal()` sweep** — only inferred from the margin guard passing. Check `RISK_REGISTER.md` R-014 before fully trusting the account is isolated again. |
| Stage 3/4 (automated scheduler) | **RETIRED — will not be pursued (D-009, 2026-09-18).** Account owner's decision, made with Stage 2's real per-pair cost in hand (≈$0.55/pair): 300 more guaranteed-loss-by-design pairs would cost ≈$150–250 for information that can't even close the mandate's own conditional-tail question at any affordable n (§3.1). `35_1000_USD_LIVE_TEST_PLAN.md` §8.2 is kept for the record, not an active plan. Do not propose resuming this without a new decision superseding D-009. |

Full picture, always current: **`docs/ROADMAP.md`**. Read it before answering any "what next" question.

Mandated doc tree is 41 files; 17 exist, 12 have content (13 as of 2026-09-18, see below). `01_research/01`–`05`
are empty stubs. `04_testing/` has real, extensive content (`34_DEMO_TEST_PLAN.md`,
`35_1000_USD_LIVE_TEST_PLAN.md`) — not empty, corrected 2026-09-18. `06_operations/` has
`PHASE_GRADUATION_CRITERIA.md` — not empty, corrected 2026-09-18. `05_development/` is still empty.

**`02_quant/15_SIGNAL_RESEARCH.md` — RETRACTED, 2026-09-19. The rolling-r̂ "promising lead" does not survive a
corrected data merge, even in-sample.** Chain: first genuine OOS test came back negative (0/9 combinations
cleared cost) → held up under raw-tick resolution and a proper union-of-both-legs tick merge (fixing a real
gap: the canonical merge, `compute_synchronized_basis()`, was undercounting real spot ticks project-wide, now
`Q-005`) → **re-running that same corrected union merge against the ORIGINAL 45-day in-sample window reversed
the original headline result entirely: +$0.65 mean net capture/86% clearing becomes −$0.85/0.4% clearing,
same window, same construction, only the merge fixed.** The lead was very likely a merge artifact from the
start, not a real pattern that failed to generalize. **A4 has no surviving candidate signal.** `Q-005` is **closed**: the merge bias is real and material for
timing-sensitive statistics (confirmed to reverse the A4 signal headline result), but confirmed NOT to affect
the aggregate decay-rate regression underlying D-006 (−$0.3873/day union vs. −$0.3877/day futures-anchored,
agree to within $0.0004/day) — D-006's rejection of hold-to-convergence stands, unaffected. Prior passes for context: momentum hypothesis
refuted; reverse-hedge inconclusive; a "weekly" extension debunked; a real-pair counterfactual replay
disqualified by clustering + one-sided bias (surviving output: $1.87 max adverse excursion, supports D-010); a
double-barrier test corrected same day (checking the complementary direction caught a wrong-null bug) showing
no directional edge either way. First pass: fixed-`r̂` threshold-crossing
event study found no net-of-round-trip-cost edge in any of 9 combinations (gross of slippage), best case
cleared cost only 46% of the time. Second pass tested a **causal rolling 24h carry-rate estimate** instead —
categorically different result: **p99 threshold, 240min exit: mean net capture +$0.65, clearing round-trip
cost in 86% of 145 entries** (`analyze_signal_variants()`, `tools/q3_q4_research.py`). A gap-extension/momentum
variant was cleanly refuted (uniformly negative, worst -$1.02 net) and a reverse-hedge (executable
`reverse_basis`) variant was inconclusive. Third pass: a held-out intraday slice of the same window confirmed
the lead holds up in character (p90/p95 nearly unchanged); a weekly Wednesday-truncation extension produced
striking headline numbers that collapsed to ~7-10 independent events under cluster analysis and were
explicitly flagged as not citable. **Still a lead, not a finding** — every test so far shares the same
2026-07-27..2026-09-16 collection window (real multiple-comparisons exposure), still gross of slippage.
**Genuine out-of-sample validation is calendar-blocked**, not just undone: it needs real ticks collected after
2026-09-16, which do not exist yet. No execution engine may be designed around this signal until that
validation exists and holds. An external candidate proposal, `docs/Gold-Basis-EA-Strategy-and-System-Design.md`
(tracked, not accepted, `/arb-hostile-review` NOT READY, conditions tracked in its own header), motivated the
rolling-rate test but its own fuller specification (regime filtering, proper exit policy) remains unexplored.

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
| Spot swap | −60 pts/day long, +40 short; **confirmed flat ×7/7 weekly average, resolved 2026-09-18** | futures swap disabled. Resolved via Strategy Tester backtest (`docs/ASSUMPTIONS.md` A-002 — real MT5 swap engine, real broker-configured fields, zero live capital): Mon/Tue/Thu/Fri −$0.60, Wed −$1.80 (3×, confirmed across two independent weeks), weekend $0.00. That's `×7/7`, flat **−$0.60/day**, not the earlier `×9/7` (−$0.7714/day) figure, which was wrong. Net carry on hold-to-convergence is now **−$0.2095/day** (was −$0.3809/day) — D-006 unaffected, still negative. Reverse-carry credit is now **+$0.0095/day** (was +$0.1238/day), near-zero, reinforcing its "not recommended" status. Propagated to `14_TRANSACTION_COST_MODEL.md`, `17_EXPECTED_VALUE.md`, `RISK_REGISTER.md` R-002, `DECISION_LOG.md` D-006 |
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
