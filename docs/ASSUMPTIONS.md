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
- **Status:** open
- **Evidence / validation owner:** standard MT5 swap convention, applied to the sourced `swap_long=-60`/
  `swap_short=+40` points/day fields in `02_quant/14_TRANSACTION_COST_MODEL.md`. Not confirmed against an
  actual multi-day-held position — no position has ever been opened by this project.
- **2026-09-18 — disputed, not resolved:** an external proposal (`docs/Gold-Basis-EA-Strategy-and-System-
  Design.md` §4.3) argues this convention double-counts the weekend. Checked against MQL5's own
  `SYMBOL_SWAP_ROLLOVER3DAYS` documentation and found consistent with standard practice (compensating for two
  uncharged weekend nights, not double-counting them) — but this is still not the same as confirming *this
  broker's actual* charging schedule, which remains the real open item. Status stays **open**.
- **Result:** not yet validated; needs a real multi-day-held demo/live position, or a direct read of this
  broker's per-weekday swap multipliers, to confirm before this feeds a production cost calculation.

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
