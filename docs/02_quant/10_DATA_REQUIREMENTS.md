# Data Requirements

Status: IN PROGRESS — collection method specified (see `docs/01_research/08_TICK_DATA_COLLECTION.md`); distributional study not yet done

## Purpose
Define exactly what tick/quote/trade data is needed to study the spread before any modeling begins.

## Instruments and symbols in scope
`XAUUSD.vx` (spot) and `GC-Z26` (futures) on VPFX — see `01_research/07_BROKER_RESEARCH.md`.

## Collection tool
`tools/mt5_data_collector.py` (read-only; see `tools/README.md`) connects to the running VPFX MT5 terminal
and pulls: full symbol specs, live margin-required figures (via `order_calc_margin`, no order placed), and
(with `--ticks`) true tick-level bid/ask history via `copy_ticks_range()` for both symbols. Output lands in
`research/<timestamp>/` (gitignored — working data, not source of truth). Review the output, then
hand-transcribe anything decision-relevant into this document and `11_SPREAD_DEFINITION.md`.

**Platform requirement:** the MetaTrader5 Python package is Windows-only. On macOS: run inside a Windows
VMware Fusion VM with MT5 installed. Full setup and validation steps are in
`docs/01_research/08_TICK_DATA_COLLECTION.md`.

## Required granularity (tick vs bar) and history length
- The script's default mode (`python tools/mt5_data_collector.py`) pulls **M1 bar closes** as a first-pass
  approximation, explicitly flagged as not true executable bid/ask.
- The `--ticks` mode (`python tools/mt5_data_collector.py --ticks`) uses `mt5.copy_ticks_range()` to pull
  true **tick-level bid/ask** for both symbols and merges them into a synchronized executable-basis series
  via `pd.merge_asof()` (tolerance: 500 ms). This is the required granularity before any conclusion can
  feed `14_TRANSACTION_COST_MODEL.md` or `17_EXPECTED_VALUE.md`. The implementation is in place;
  running it requires the Windows VMware environment (see `docs/01_research/08_TICK_DATA_COLLECTION.md`).
- History length: `TICK_HISTORY_DAYS = 7` by default. Actual depth depends on what the terminal has stored;
  a freshly installed terminal may have only hours. Run `--ticks` after a full session to build up history.
  Longer history (covering several weeks and the approach to `GC-Z26` expiry on 25 Nov 2026) is needed for
  `13_BASIS_MODEL.md`'s time-to-convergence statistics — acceptable to collect incrementally.

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
