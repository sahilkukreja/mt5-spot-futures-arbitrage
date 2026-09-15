# Research Tools

Read-only Python scripts that pull data from a running MT5 terminal to answer Phase 0 research questions
(`docs/01_research/`, `docs/02_quant/`) with real numbers instead of guesses or invented values, per the
project mandate.

These are research/data-collection tools, not the trading system itself. Nothing here places, modifies, or
closes an order — see the safety note in each script's docstring.

## Platform requirement

The `MetaTrader5` Python package communicates with the running MT5 terminal via a Windows-only IPC channel.
**These scripts must run on Windows**, with the VPFX MT5 terminal installed and logged in.

On macOS: run inside a Windows VMware Fusion (or Parallels) VM, or any cloud Windows instance. See
`docs/01_research/08_TICK_DATA_COLLECTION.md` for the complete VMware setup and validation checklist.

## `mt5_data_collector.py`

Connects to an already-running, already-logged-in MT5 terminal (VPFX-Live or VPFX-Demo) and:

1. **Symbol specifications** — dumps the full spec for `XAUUSD.vx` and `GC-Z26` (contract size, tick value,
   margin calculation mode, swap, expiry, session hours) via `symbol_info()`.

2. **Actual required margin** — computes the margin at 0.01 lot for both symbols, both directions, via
   `order_calc_margin()` — the same figure the New Order ticket shows, without opening a position. Resolves
   the residual cross-check in `docs/RISK_REGISTER.md` R-001.

3. **M1 bar gap history** (first-pass approximation) — pulls recent M1 bar history and computes summary
   statistics (mean, median, std, percentiles) of the futures-minus-spot gap. Uses bar *close* prices,
   not tick-level bid/ask — labeled as an approximation; see Section 4 for the real thing.

4. **Tick-level bid/ask collection** (primary data, requires `--ticks` flag) — pulls true bid/ask tick
   history via `copy_ticks_range()`, merges the two symbol streams by timestamp using `pd.merge_asof()`,
   and outputs the synchronized executable basis series:
   - `convergence_basis = Bid(GC-Z26) − Ask(XAUUSD.vx)` — executable for SELL futures / BUY spot
   - `reverse_basis = Ask(GC-Z26) − Bid(XAUUSD.vx)` — executable for BUY futures / SELL spot
   This is what `docs/02_quant/14_TRANSACTION_COST_MODEL.md` and `17_EXPECTED_VALUE.md` require.

### Requirements

- **Windows** with the MT5 terminal installed, running, and logged into the VPFX account already. The
  `MetaTrader5` pip package talks to that local terminal process — it does not accept a login/password
  itself and does not work headless, on macOS, or on Linux.
- Python 3.10 or 3.11, **64-bit build** (verify: `python -c "import struct; print(struct.calcsize('P')*8)"` → 64).
- `pip install MetaTrader5 pandas`

### Run

```
# M1-bar first-pass only (existing behaviour):
python tools/mt5_data_collector.py

# Full run including tick-level bid/ask collection (requires VMware setup):
python tools/mt5_data_collector.py --ticks
```

See `docs/01_research/08_TICK_DATA_COLLECTION.md` for the step-by-step validation checklist before
running `--ticks` for the first time.

### Output

Writes CSV/JSON to `research/<UTC timestamp>/` — gitignored, working data only, not source of truth.

| File | Produced by | Contents |
|---|---|---|
| `symbol_specs.json` | always | Full `symbol_info()` dump for both symbols |
| `margin_required.json` | always | `order_calc_margin()` results at 0.01 lot, BUY and SELL |
| `gap_history.csv` | always | M1 bar closes and `gap_close_to_close` column |
| `gap_summary.json` | always | Percentile statistics on M1 bar gap (approximation) |
| `ticks_XAUUSD.vx.csv` | `--ticks` | Per-tick: `time_msc, bid, ask, flags, time_utc` |
| `ticks_GC-Z26.csv` | `--ticks` | Per-tick: `time_msc, bid, ask, flags, time_utc` |
| `basis_synchronized.csv` | `--ticks` | Merged: `fut_time_msc, fut_bid, fut_ask, spot_time_msc, spot_bid, spot_ask, convergence_basis, reverse_basis, mid_basis, quote_skew_ms` |
| `basis_summary.json` | `--ticks` | Descriptive statistics for all basis columns |

Review the numbers yourself, then hand-transcribe whatever is decision-relevant into the actual `docs/`
documents (same discipline as the manual Specification-window transcription in
`docs/01_research/07_BROKER_RESEARCH.md`). Do not treat script output as an approved research document,
and do not commit the `research/` output folder's contents.

### What this does *not* answer

`symbol_info()` does not expose commission (account/group-level, not queryable this way) or a plain
"price source" string. Those remain open items (`docs/OPEN_QUESTIONS.md` Q-002) requiring broker
documentation or a support ticket.

The M1-bar statistics (without `--ticks`) are a close approximation — not true tick-level executable
bid/ask. The `--ticks` run is required before this output feeds a final cost/EV conclusion.

`copy_ticks_range()` returns only what the terminal has stored in its local tick history. If the
history is shallow (e.g., a freshly installed terminal), leave it running with Market Watch open for
a full trading session before running `--ticks`.
