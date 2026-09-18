# Assumptions Register

Every assumption underpinning the strategy, model, or design must be tracked here with a stable ID so it can be
validated, challenged, or retired explicitly rather than silently baked into later work.

## Format

### A-000: <statement>
- **Status:** open | validated | invalidated | retired
- **Evidence / validation owner:** who/what validates this and how
- **Result:** outcome once validated

---

### A-001: `point = 0.01` for both `XAUUSD.vx` and `GC-Z26`
- **Status:** open
- **Evidence / validation owner:** derived from `digits=2` and `trade_tick_size=0.01` (both directly sourced
  from `symbol_info()`), used to convert quoted swap "points" into the same price units as the basis in
  `02_quant/14_TRANSACTION_COST_MODEL.md`. Not independently checked against a documented "1 point = X price
  units" statement from the broker beyond the `symbol_info()` fields themselves.
- **Result:** not yet validated; low risk of being wrong given two independent sourced fields agree, but not
  confirmed by broker documentation.

### A-002: Swap accrues once per calendar day held overnight, with the standard MT5 triple-charge on the day
indicated by `swap_rollover3days=3` (Wednesday)
- **Status:** **resolved 2026-09-18, via Strategy Tester simulation (not a live deal yet — see caveat below).**
  A minimal probe EA (`measurement_harness`-adjacent, `MQL5/Experts/SwapScheduleProbe.mq5`, never touches
  live capital) opened one `XAUUSD.vx` position at the start of a 2-week backtest (2026-08-03 to 2026-08-17)
  and logged cumulative `POSITION_SWAP` once per simulated day. Daily deltas, confirmed identically across
  both Wednesdays in range: Mon −$0.60, Tue −$0.60, **Wed −$1.80 (exactly 3×)**, Thu −$0.60, Fri −$0.60,
  Sat/Sun **$0.00 (confirmed zero, no separate weekend charge)**. Weekly total: `1+1+3+1+1 = 7` units over 7
  calendar days — **exactly `×7/7`, flat `$0.60/day`, no markup.** This directly refutes the repository's prior
  `×9/7` (`$0.7714/day`) figure and confirms the standard-MT5-practice reading this project's own earlier
  analysis (`/arb-risk-review`, 2026-09-18) had derived independently before this test ran.
  **Caveat, stated precisely:** this is MT5's own client-side swap-simulation engine, driven by the same
  `swap_long`/`swap_rollover3days` broker-configured fields a real position uses — strong, mechanism-level
  evidence, not a rumor or a guess — but it is still not the same as a real `HistoryDealGetDouble(...,
  DEAL_SWAP)` sequence from an actual held position (checked directly, 2026-09-18: this account's entire real
  deal history has zero Wednesday-crossing or weekend-crossing positions to confirm against). Treat this as
  resolved with high confidence, not as a live-verified certainty.
- **Evidence / validation owner:** standard MT5 swap convention, applied to the sourced `swap_long=-60`/
  `swap_short=+40` points/day fields in `02_quant/14_TRANSACTION_COST_MODEL.md`. Not confirmed against an
  actual multi-day-held position — no position has ever been opened by this project.
- **2026-09-18 — resolved by backtest simulation** (see Status above for the full method and caveat). The
  `×9/7` figure was traced (`git log -S"0.7714"`) to an unreviewed formula, never independently derived or
  confirmed — the backtest confirms the standard-MT5-practice `×7/7` reading was correct and `×9/7` was the
  repository's own double-counting error, not the external proposal's misunderstanding.
- **Result:** the spot swap drag is **`−$0.60/day` flat (`×7/7`)**, not `−$0.7714/day`. Propagated to
  `14_TRANSACTION_COST_MODEL.md`, `17_EXPECTED_VALUE.md`, `RISK_REGISTER.md` R-002, and `DECISION_LOG.md` D-006
  (2026-09-18). Net carry on the hold-to-convergence structure is now `−$0.2095/day` (was `−$0.3809/day`) —
  **D-006's conclusion is unchanged, still negative**, only the magnitude moves. The reverse-carry figure moves
  from `+$0.1238/day` to a near-zero `+$0.0095/day`, reinforcing its existing "not recommended" status.

### A-003: A single-day SOFR snapshot (3.64% on 2026-09-15, sourced FRED series `SOFR`,
https://fred.stlouisfed.org/series/SOFR) is used as the risk-free/financing-rate comparison for the
implied-carry decomposition in `02_quant/12_FAIR_VALUE_MODEL.md`, rather than a rate matched to each tick's
own timestamp across the 7-day collection window (2026-09-08 to 2026-09-15).
- **Status:** open
- **Evidence / validation owner:** SOFR moves daily; over a 7-day window the day-to-day difference is expected
  to be small, but this was not checked row-by-row. Validate by re-running
  `tools/q3_q4_research.py`'s `analyze_fair_value()` with a full matched daily SOFR series if the ~110bp
  unexplained residual becomes load-bearing for a future decision.
- **Result:** not yet validated; the ~110bp/~$9.67 unexplained-residual finding in `12_FAIR_VALUE_MODEL.md`
  should be treated as approximate until this is checked.

### A-004 (superseded, kept for traceability): `$7.50` futures commission charged on both entry and exit
- **Status:** invalidated
- **Evidence / validation owner:** originally read literally from the VPFX spec window's wording
  (`01_research/07_BROKER_RESEARCH.md`); struck through in `02_quant/14_TRANSACTION_COST_MODEL.md`'s
  "Assumptions" section on 2026-09-16.
- **Result:** invalidated by real deal history with an explicit `Commission` column — confirmed **$10/lot
  round trip total** (not $7.50 in/out) for trades opened from 2026-09-14 onward. Do not cite $7.50 going
  forward.
