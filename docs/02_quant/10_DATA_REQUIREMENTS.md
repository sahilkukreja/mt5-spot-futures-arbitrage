# Data Requirements

Status: IN PROGRESS — collection tooling exists; distributional study not yet done

## Purpose
Define exactly what tick/quote/trade data is needed to study the spread before any modeling begins.

## Instruments and symbols in scope
`XAUUSD.vx` (spot) and `GC-Z26` (futures) on VPFX — see `01_research/07_BROKER_RESEARCH.md`.

## Collection tool
`tools/mt5_data_collector.py` (read-only; see `tools/README.md`) connects to the running VPFX MT5 terminal
and pulls: full symbol specs, live margin-required figures (via `order_calc_margin`, no order placed), and a
first-pass M1-bar gap history with summary statistics. Output lands in `research/<timestamp>/` (gitignored —
working data, not source of truth). Run it, review the output, then hand-transcribe anything decision-relevant
into this document and `11_SPREAD_DEFINITION.md`.

## Required granularity (tick vs bar) and history length
- The script currently pulls **M1 bar closes** as a first-pass approximation, explicitly flagged as not true
  executable bid/ask.
- For any conclusion that feeds `14_TRANSACTION_COST_MODEL.md` or `17_EXPECTED_VALUE.md`, this must be
  redone from **tick-level bid/ask** (`copy_ticks_range` in the same script, not yet implemented) — mid or
  bar-close data cannot answer what's actually executable, per the mandate's `REAL EXECUTABLE PRICES` section.
- History length: not yet decided. Needs to span enough time to see multiple sessions, and ideally a period
  approaching the `GC-Z26` expiry (25 Nov 2026) to observe how the basis behaves as time-to-expiry shrinks —
  a single week of M1 bars (the script's current default) is a starting point, not sufficient for a real
  distribution or for `13_BASIS_MODEL.md`'s time-to-convergence statistics.

## Bid/ask vs mid capture requirements
Trading-relevant statistics (spread cost, executable gap, entry/exit thresholds) must use tick-level bid/ask.
Mid-price series may be used only for exploratory correlation/regression work, always labeled as such (as the
legacy "Gap Radar" tooling did — see `01_research/06_EXISTING_SYSTEM_RESEARCH.md`).

## Data sources
VPFX's own MT5 price feed, pulled live via the terminal (no third-party vendor data yet). This means all
statistics collected so far reflect VPFX's specific quotes, not a broader market reference — worth keeping in
mind if VPFX's feed has broker-specific artifacts (stale quotes, requotes, wider spreads at rollover) that a
cleaner reference feed wouldn't show.

## Storage format and pipeline
Script output: JSON (specs, margin, summary stats) + CSV (raw gap history) under `research/<timestamp>/`,
gitignored. No pipeline beyond this ad hoc script yet — acceptable for Phase 0; would need a real pipeline
before any ongoing monitoring/live-test phase.

## Known data quality issues to watch for
- Stale quotes / broker feed gaps — not yet checked for in the collected data.
- Session boundaries — `GC-Z26`'s quote/trade session windows (`07_BROKER_RESEARCH.md`) differ slightly from
  `XAUUSD.vx`'s; any gap statistic spanning a session boundary on one leg but not the other needs care.
- Futures expiry/rollover — `GC-Z26` expires 25 Nov 2026; a long-running data collection will eventually need
  a rollover plan (see the open rollover-process question, `docs/OPEN_QUESTIONS.md` Q-002) or the basis
  behavior will reflect an expiring contract, not steady-state carry.
- The M1-bar-close approximation itself is a known limitation (see above) until tick data is used.
