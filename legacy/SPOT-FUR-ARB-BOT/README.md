# SPOT-FUT ARB BOT

Gold Spot vs Futures arbitrage trading system for MetaTrader 5.

**Strategy:** Exploit the price gap between a gold futures contract (e.g. GCM26) and spot gold (XAUUSD). When the gap widens beyond a threshold (OAG), enter a pairs trade. When the gap compresses to a target (CAG), close for profit.

---

## Quick Start

### Production Files (use these)

| File | Role |
|---|---|
| [`best_code.cpp`](best_code.cpp) | **Trade Panel EA v3.26** — attach to any chart, handles open/close of all pairs |
| [`GapMonitor/GapMonitorV1.mq5`](GapMonitor/GapMonitorV1.mq5) | **Gap Monitor v3.10** — stat dashboard, run on a second chart |
| [`mmt/spot_future_arb_code/latest code/MMT_Gap_Alerts_TG.mq5`](mmt/spot_future_arb_code/latest%20code/MMT_Gap_Alerts_TG.mq5) | **Alert EA v3.20** — optional Telegram alerts |

### How to Run

1. Open MT5. Attach `best_code.cpp` (compiled as `.ex5`) to the XAUUSD or GCM26 chart.
2. Set `InpSymbol1=GCM26.u` and `InpSymbol2=XAUUSD.u` (adjust suffix for your broker).
3. Open a second chart. Attach `GapMonitorV1.ex5`. This shows live gap statistics.
4. Watch the gap stats to decide on OAG/CAG levels.
5. In the Trade Panel, enter LOT, OAG, CAG then press **OPEN / SCHEDULE**.

---

## Documentation

| Document | Description |
|---|---|
| [`CODE_VERSIONS.md`](CODE_VERSIONS.md) | **Full version history** — every file catalogued, features compared, duplicates flagged |
| [`trade_history/README.md`](trade_history/README.md) | Trade logging guide and folder structure |
| [`trade_history/templates/`](trade_history/templates/) | CSV and markdown templates for trade journals |

---

## Folder Structure

```
SPOT-FUR-ARB-BOT/
│
├── best_code.cpp                      ← PRODUCTION: Trade Panel EA v3.26
├── MMT_TradePannel_Pro_v283.cpp       ← Trade Panel v2.83 (stable refactor)
├── MMT_TradePannel_Pro_v284.cpp       ← Trade Panel v2.84 (async engine)
├── mmt_FX.c                           ← Trade Panel v2.81 (OAG/CAG baseline)
│
├── GapMonitor/
│   ├── GapMonitorV1.mq5              ← PRODUCTION: Gap Monitor EA v3.10
│   └── GapMonitorV1.set              ← Saved settings
│
├── PairGap_UITradePanel/
│   └── PairGap_UITradePanel.mq5      ← Trade Panel v1.20 (archived, 5-pair)
│
├── CODE_VERSIONS.md                  ← Version guide (START HERE)
├── README.md                         ← This file
│
├── trade_history/                    ← All trade records
│   ├── README.md                     ← Logging guide
│   ├── templates/                    ← Copy these for each session
│   │   ├── session_log.csv
│   │   ├── pair_journal.md
│   │   └── daily_summary.md
│   ├── sessions/                     ← Raw MT5 log files (one per day)
│   │   ├── 2026-03-01_session.log
│   │   └── 2026-03-02_session.log
│   └── analysis/                     ← Post-session analysis
│       └── 2026-03-01_analysis.md
│
└── mmt/                              ← Development / archive folder
    ├── final trading bot/
    │   └── best_code.cpp             ← Duplicate of root best_code.cpp
    ├── spot_future_arb_code/         ← Earlier versions (see CODE_VERSIONS.md)
    │   ├── latest code/
    │   └── unq_code/
    └── logs to analysis/             ← Original log location (moved to trade_history/)
```

---

## Key Concepts

| Term | Definition |
|---|---|
| **Gap** | `Bid(Futures) - Ask(Spot)` for SELL_ONLY direction |
| **OAG** | Open At Gap — gap level that triggers a scheduled entry |
| **CAG** | Close At Gap — gap level that triggers auto-close (profit target) |
| **OAG Confirm** | Gap must hold at OAG for X ms before the order fires (anti-spike filter) |
| **CAG Confirm** | Gap must hold at CAG for Y ms before close fires |
| **Spread Filter** | Blocks entries if bid-ask spread is too wide (news/thin liquidity) |
| **TRANSIT** | v2.84+ pair state while async orders are in flight |

---

## Version Summary

| What you want | Use |
|---|---|
| Live trading (production) | `best_code.cpp` v3.26 |
| Stable synchronous execution | `MMT_TradePannel_Pro_v283.cpp` v2.83 |
| Gap statistics dashboard | `GapMonitor/GapMonitorV1.mq5` v3.10 |
| Telegram alerts | `mmt/spot_future_arb_code/latest code/MMT_Gap_Alerts_TG.mq5` v3.20 |
| Pre-session OAG/CAG planning | `mmt/spot_future_arb_code/MMT_GapRadar_v1.mq5` (statistical indicator) |

See [`CODE_VERSIONS.md`](CODE_VERSIONS.md) for the complete version history with feature comparisons.
