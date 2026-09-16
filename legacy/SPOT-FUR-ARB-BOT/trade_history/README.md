# Trade History

This folder contains all trade records, session logs, and analysis for the Spot-Futures Arbitrage Bot.

## Folder Structure

```
trade_history/
├── README.md              ← This file
├── templates/             ← CSV / markdown templates to copy for new sessions
│   ├── session_log.csv    ← Per-session trade log template
│   ├── pair_journal.md    ← Manual trade journal template
│   └── daily_summary.md  ← End-of-day summary template
├── sessions/              ← One file per trading session
│   └── YYYY-MM-DD_session.csv
└── analysis/              ← Post-session analysis notes and stats exports
    └── YYYY-MM-DD_analysis.md
```

## How to Log Trades

### Automated (MT5 EA file logs — v3.26)
The production EA (`best_code.cpp` v3.26) writes structured event logs to:
```
MT5_Data_Folder\MQL5\Logs\
```
Copy the daily `.log` file from MT5 into `sessions/` at end of day and rename it:
```
sessions/YYYY-MM-DD_session.log
```

### Manual session CSV
Copy `templates/session_log.csv`, rename to `sessions/YYYY-MM-DD_session.csv`, and fill in each trade row as you go.

### End of day
1. Export the MT5 Account History report to `analysis/YYYY-MM-DD_mt5_history.xlsx`.
2. Fill in `analysis/YYYY-MM-DD_analysis.md` with your observations and param adjustments for next day.

## Column Definitions (session_log.csv)

| Column | Description |
|---|---|
| `pair_idx` | EA pair slot number (1–20) |
| `open_time` | UTC time the pair was opened (ISO 8601) |
| `close_time` | UTC time the pair was closed |
| `hold_min` | Minutes held |
| `symbol1` | S1 symbol name |
| `symbol2` | S2 symbol name |
| `direction` | SELL_ONLY or BUY_ONLY |
| `lot` | Lot size |
| `open_gap` | Gap at open (fill prices) |
| `oag_level` | Scheduled OAG trigger level |
| `cag_level` | Target CAG close level |
| `close_gap` | Gap at close (fill prices) |
| `gap_compression` | `open_gap - close_gap` |
| `pl_s1` | P/L on S1 leg (account currency) |
| `pl_s2` | P/L on S2 leg (account currency) |
| `pl_total` | Combined P/L |
| `close_reason` | MANUAL / AUTOCLOSE / CANCEL / WATCHDOG |
| `ea_version` | EA version used (e.g. 3.26) |
| `notes` | Free text |

## OAG / CAG Level Planning

Use `GapMonitorV1.mq5` (v3.10) or `MMT_Gap_Alerts_TG.mq5` (v3.20) to determine:

- **OAG candidate**: P85–P95 of the active window (e.g., 1h or 4h) = where gap is historically wide
- **CAG target**: P40–P60 of the same window = mean-reversion level

Record planned levels in `pair_journal.md` before the session.
