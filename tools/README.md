# Research Tools

Read-only Python scripts that pull data from a running MT5 terminal to answer Phase 0 research questions
(`docs/01_research/`, `docs/02_quant/`) with real numbers instead of guesses or invented values, per the
project mandate.

These are research/data-collection tools, not the trading system itself. Nothing here places, modifies, or
closes an order — see the safety note in each script's docstring.

## `mt5_data_collector.py`

Connects to an already-running, already-logged-in MT5 terminal (VPFX-Live) and:

1. Dumps the full symbol specification for `XAUUSD.vx` and `GC-Z26` (contract size, tick value, margin
   calculation mode, swap, expiry, session hours) via `symbol_info()`.
2. Computes the actual required margin at 0.01 lot for both symbols, both directions, via
   `order_calc_margin()` — the same figure the New Order ticket shows, without opening a position. This is
   the direct cross-check that `docs/RISK_REGISTER.md` R-001 flagged as still outstanding.
3. Pulls recent M1 bar history for both symbols and computes summary statistics (mean, median, std,
   percentiles) of the futures-minus-spot gap, as a first-pass replacement for the two point-in-time
   snapshots currently in `docs/02_quant/11_SPREAD_DEFINITION.md`.

### Requirements

- **Windows**, with the MT5 terminal installed, running, and logged into the VPFX-Live account already. The
  `MetaTrader5` pip package talks to that local terminal process — it does not accept a login/password itself
  and does not work headless, on macOS, or on Linux.
- `pip install MetaTrader5 pandas`

### Run

```
python tools/mt5_data_collector.py
```

### Output

Writes JSON/CSV to `research/<UTC timestamp>/` — gitignored, working data only, not source of truth. Review
the numbers yourself, then hand-transcribe whatever is decision-relevant into the actual `docs/` documents
(the same discipline as the manual Specification-window transcription already done in
`docs/01_research/07_BROKER_RESEARCH.md`). Do not treat script output as an approved research document, and
do not commit the `research/` output folder's contents.

### What this does *not* answer

`symbol_info()` does not expose commission (that's account/group-level, not queryable this way) or a plain
"price source" string. Those remain open items (`docs/OPEN_QUESTIONS.md` Q-002) requiring broker
documentation or a support ticket, not a script.

The gap-history statistics use M1 bar **close** prices, not true tick-level bid/ask — an approximation good
enough for a first look, explicitly flagged as such in the script's output. Rebuilding from
`copy_ticks_range` would be the next step before this feeds a final cost/EV number.
