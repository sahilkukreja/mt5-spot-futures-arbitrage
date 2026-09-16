# SPOT-FUT ARB BOT — Code Versions Reference

> **Purpose:** Every `.mq5 / .cpp / .c` file in this repo is catalogued here with its version, capabilities, and relationship to other versions. Duplicates are flagged. The canonical/production files are highlighted.

---

## Code Families

The codebase splits into two distinct families of programs:

| Family | Role | Language |
|---|---|---|
| **Trade Panel (EA)** | Opens, monitors, and closes pair positions | MQL5 Expert Advisor |
| **Gap Radar / Monitor** | Samples the live gap, computes statistics, and fires alerts | MQL5 Indicator or EA |

---

## Family 1 — Trade Panel (Execution Engine)

These files share the same core logic: compute the bid/ask execution-aware gap between Symbol1 and Symbol2, manage arbitrage pair positions via a UI panel, and auto-close when a target gap (CAG) is hit.

### Version Map (chronological)

```
v1.20  ──► v2.81  ──► v2.82  ──► v2.83  ──► v2.84  ──► v3.26 (PRODUCTION)
 Basic       OAG/CAG   Confirm    Refactor   Async      Full engine
 5 pairs     logic     timers     cleanup    engine     + spread filter
```

---

### v1.20 — Basic Pair UI Panel
**File:** `PairGap_UITradePanel/PairGap_UITradePanel.mq5`
**Compiled:** `PairGap_UITradePanel/PairGap_UITradePanel.ex5`

**What it does:**
- Earliest working version. Hard-capped at 5 pairs.
- Manual OPEN NEXT / CLOSE ALL / CLOSE 1..N buttons.
- Displays live gap (Bid1−Ask2 or Ask1−Bid2) without scheduling logic.
- Dark UI theme (0x202020 background).
- No OAG/CAG — purely manual operation.

**Key limitations:**
- No scheduled entries (no OAG trigger)
- No auto-close on target (no CAG logic)
- Maximum 5 pairs hardcoded
- No confirm timers, no hold-time constraints

**Status:** Archived / educational reference only.

---

### v2.81 — Top-Down OAG/CAG Control
**File:** `mmt_FX.c`

**What it does:**
- Introduced the `OAG` (Open At Gap) / `CAG` (Close At Gap) concept.
- Single button: **OPEN / SCHEDULE** — if OAG=0 opens immediately, else schedules entry.
- CAG drives auto-close when the gap compresses to target.
- Up to 20 pairs, AliceBlue light UI theme.
- Pair state stored in MT5 GlobalVariables (persistent across restarts).
- Idle pairs hidden; only ACTIVE or SCHEDULED rows shown.
- Header shows Terminal Total P/L vs List Sum P/L.

**Key limitations vs later versions:**
- No OAG confirm timer — entry fires on first tick that hits OAG (susceptible to spikes)
- No CAG confirm timer — auto-close fires on first tick at target
- No minimum hold time before auto-close
- No rollback protection on partial opens

**Status:** Superseded by v2.82.

---

### v2.82 — Time-at-Level Confirmation (STABLE)
**Files (all identical content — duplicates):**
- `mmt/spot_future_arb_code/MMT_TradePannel_Pro.mq5` ← original
- `mmt/mm_v3.mq5` ← duplicate
- `mmt/spot_future_arb_code/MMT_V3.mq5` ← duplicate
- `mmt/spot_future_arb_code/latest code/MMT_TradePannel_Pro.mq5` ← duplicate

**What it adds over v2.81:**
- `InpOagConfirmMs` (default 800 ms): gap must stay at/above OAG continuously for this duration before the scheduled entry fires. Eliminates spike-triggered false entries.
- `InpCagConfirmMs` (default 800 ms): gap must stay at/below CAG continuously before auto-close fires. Eliminates spike-triggered premature exits.
- `InpMinHoldMinutes`: minimum time a pair must be held before any auto-close is allowed.
- Hit timers reset on: schedule cancel, open, manual close, auto-close.
- OAG/CAG are absolute gap levels (no delta arithmetic).

**Key limitations vs later versions:**
- Synchronous trade execution (blocking — during open/close, timer pauses)
- No rollback retry if second leg fails
- Opening lock expires after 5 000 ms (hard-coded)

**Status:** Last widely-tested stable version. Good production baseline. Superseded by v2.83.

---

### v2.83 — Refactored Architecture
**File:** `MMT_TradePannel_Pro_v283.cpp`
**Also in:** `mmt/spot_future_arb_code/unq_code/MMT_TradePannel_Pro.mq5` (same content)

**What it adds over v2.82:**
- Full structural refactor — all sections clearly separated with `//====` dividers.
- Safer state cleanup: `ClearScheduleState()`, `ClearLiveMeta()`, `ClearPairState()` — explicit and composable.
- Stronger logging: `LogPair()`, `LogTradeResult()` — consistent format with pair index and action.
- `ReconcilePairState()` / `ReconcileAllPairStates()` — on-init reconciliation prevents stale state after restarts.
- `SetOpeningLock()` / `SetClosingLock()` — explicit locking with timeout-based auto-expiry.
- `GetBestFilling()` — queries broker for FOK/IOC/RETURN support before placing orders.
- `HandleOpenRollback()` — if second leg fails, first leg is closed and state is cleaned.
- `SanitizeNumberString()` — robust edit-field input parsing (strips commas, handles decimals).
- No duplicate auto-rule execution (timer re-entry guard).

**Status:** Cleanest synchronous version. Recommended starting point for customisation. Superseded by v2.84 for latency-sensitive use.

---

### v2.84 — Hybrid-Async Execution Engine
**File:** `MMT_TradePannel_Pro_v284.cpp`

**What it adds over v2.83:**
- **Non-blocking async leg execution** on the auto-rules path — timer does not block while orders are in flight.
- **Parallel Dispatch** — all triggered pairs fire simultaneously rather than sequentially.
- **`PSTATUS_TRANSIT`** — new 5th pair state while async orders are in-flight (displayed in gold).
- **Watchdog timer** — if an open stalls beyond `InpAsyncOpenDeadlineMs` (default 2 500 ms), automatic rollback.
- **`OnTradeTransaction`** — real-time fill confirmation from the broker server rather than polling positions.
- **Retry matrix** — per-error-code retry strategy (configurable `InpMaxOpenRetries`, `InpMaxCloseRetries`).
- **Crash recovery** — deal history reconciliation during `OnInit` to detect fills from the previous session.
- **`InpCagSlippageBuffer`** — fires CAG close N points before target to absorb expected sequential-fill drift.
- **Manual buttons remain synchronous** for operational safety (no surprise state changes from button presses).

**Key parameters added:**
| Parameter | Default | Purpose |
|---|---|---|
| `InpCagSlippageBuffer` | 0.0 pts | Pre-fire buffer to absorb fill slippage |
| `InpAsyncOpenDeadlineMs` | 2 500 ms | Watchdog rollback on stuck open |
| `InpAsyncCloseDeadlineMs` | 4 000 ms | Watchdog retry on stuck close |
| `InpMaxOpenRetries` | 3 | Max open leg retries |
| `InpMaxCloseRetries` | 5 | Max close leg retries |

**Status:** Most robust of the v2.x line. Use for high-frequency or multi-pair concurrent strategies. Superseded by v3.26 for full production.

---

### v3.26 — Production Engine (CANONICAL) ⭐
**Files:**
- `best_code.cpp` ← **canonical production source**
- `mmt/final trading bot/best_code.cpp` ← duplicate (identical)

**What it adds over v2.84:**
- **Spread filter** (`InpMaxSpreadS1`, `InpMaxSpreadS2`): blocks OAG/CAG triggers when bid-ask spread is abnormally wide (news events, thin liquidity). Per-symbol configurable. Set 0 to disable.
- **OAG tolerance / drift detection** (`InpOagTolerance`, `InpOagMaxDrift`): gap can be slightly below OAG and still count as "hit"; if gap surges too far above OAG during the confirm window, pair is blocked until gap resets.
- **OAG exit grace** (`InpOagExitToleranceMs`): gap can dip briefly below OAG without resetting the confirm timer.
- **CAG overrun tolerance** (`InpCagOverrunTol`): if gap compresses past target by more than this amount, skip close to avoid chasing a reversal.
- **Concurrency caps** (`InpMaxConcurrentOpening`, `InpMaxConcurrentClosing`): limits how many pairs can be in the opening/closing phase simultaneously to manage broker bandwidth.
- **File-based logging** (`InpEnableLogs`): writes structured event logs to disk for post-session analysis.
- **Close watchdog** (`InpCloseWatchdogMs`, default 60 000 ms): if a closing pair is stuck for this duration, force-cancels and raises an alert.
- **Execution grace period** (`InpExecGraceMs`, default 200 ms): extra time after order dispatch before declaring a timeout.
- **Faster default timer** (100 ms vs 200 ms in v2.x).
- **Grouped input sections** — inputs organised into 7 clearly labelled groups with inline documentation comments.

**Key parameters added over v2.84:**
| Parameter | Default | Purpose |
|---|---|---|
| `InpMaxConcurrentOpening` | 3 | Cap simultaneous opens |
| `InpMaxConcurrentClosing` | 10 | Cap simultaneous closes |
| `InpExecGraceMs` | 200 ms | Grace after dispatch before timeout |
| `InpCloseWatchdogMs` | 60 000 ms | Force-cancel stuck closes |
| `InpMaxSpreadS1` | 1.20 pts | Block on wide S1 spread |
| `InpMaxSpreadS2` | 0.90 pts | Block on wide S2 spread |
| `InpOagTolerance` | 0.25 pts | Gap can be this far below OAG and still hit |
| `InpOagMaxDrift` | 1.00 pts | Cancel if gap surges this far above OAG |
| `InpOagExitToleranceMs` | 0 ms | OAG hit grace on brief dip |
| `InpCagOverrunTol` | 1.00 pts | Skip if gap over-compresses by this much |

**Status:** ✅ **PRODUCTION — use this version.**

---

## Family 2 — Gap Radar / Monitor

These files observe the live gap between two symbols, store a rolling history, compute statistical features (mean, std, Z-score, quantiles, correlation, regression slope), and optionally send Telegram alerts.

### Version Map

```
v1_stat  ──► v2.01/v2.03  ──► v2.20  ──► v3.10  ──► v3.20
(indicator)   (indicator +    (table     (EA      (perf rework
 stats only)   Telegram)      EA UI)     ARGB)    + multi-TG)
```

---

### v1 — Statistical Plan Builder (Indicator)
**Files (duplicates of same content):**
- `mmt/spot_future_arb_code/MMT_GapRadar_v1.mq5` ← original
- `mmt/spot_future_arb_code/MMT_GapRadar_Pro.mq5` ← duplicate
- `mmt/spot_future_arb_code/MMT_GapRadar_Pro (2).mq5` ← duplicate
- `mmt/spot_future_arb_code/MMT_GapRadar_Pro (3).mq5` ← duplicate
- `mmt/MMT_GAP_RADAR_PRO.mq5` (actually v2.20 — see below, different content)

**Internal name:** `GapRadar_PlanBuilder_Pro.mq5`
**Type:** MQL5 Indicator (chart window)

**What it does:**
- Samples gap every `InpTimerMs` ms into a ring buffer.
- Computes:
  - **Pearson Correlation** between S1 and S2 prices
  - **Z-Score** of current gap vs rolling mean/std
  - **Linear Regression Slope** of gap over time
- Tabbed UI: Windows | Stats | Quants | Plan
- Configurable samples count (`InpMaxSamples=2000`) and minimum to show output (`InpMinSamplesToShow=200`).
- No Telegram integration. No trade execution.

**Status:** Useful for pre-session analysis and OAG/CAG level planning.

---

### v2.01 / v2.03 — Indicator + Tabular Stats + Telegram
**Files:**
- `mmt/spot_future_arb_code/latest code/GapMonitorAlert.mq5` — v2.03 (with Telegram)

**Internal name:** `GapRadar_Pro.mq5 (Indicator)`
**Type:** MQL5 Indicator (chart window)

**v2.01 additions over v1:**
- Per-window statistics table (configurable 10 time windows: 1m, 5m, 15m, 30m, 1h, 2h, 4h, 8h, 12h)
- ENUM_WIN_UNIT (MINUTES / HOURS) for window specification
- Tab system: WINDOWS | STATS | QUANTS | PLAN
- Quantile reporting per window
- Active window index (`InpActiveWindowIx`) for headline display

**v2.03 additions over v2.01:**
- Telegram alert integration (single chat ID, `InpTeleChatID`)
- Z-score alert threshold (`InpZThreshold=2.0`)
- Alert cooldown to prevent spam
- `InpTeleAlerts` toggle

**Status:** Good for signal monitoring. Superseded by v3.20 for multi-user Telegram.

---

### v2.20 — Table EA (Quantile-Driven)
**Files (duplicates):**
- `mmt/MMT_GAP_RADAR_PRO.mq5` ← original
- `mmt/spot_future_arb_code/MMT_GAP_RADAR_PRO.mq5` ← duplicate
- `mmt/spot_future_arb_code/MMT_GAP_RADAR_PRO (2).mq5` ← duplicate

**Internal name:** `GapRadarTableEA.mq5`
**Type:** MQL5 Expert Advisor (not indicator — runs on chart as EA)

**What it adds:**
- EA instead of indicator — runs without chart indicators overhead.
- Configurable windows via comma-separated string: `InpWindowsMinutes = "60,240,720"`.
- Quantile-based OAG/CAG suggestion: `InpOAG_Quantile=0.90` and `InpCAG_Quantile=0.50`.
- Real-time tabular UI with per-window stats.
- Scaled UI (`UI_Scale=1.25`).
- Column width inputs for layout control.

**Status:** Useful when you want OAG/CAG levels computed automatically from quantiles. Superseded by v3.10.

---

### v3.10 — Gap Monitor Table (Production Monitor) ⭐
**Files (same content — duplicates):**
- `GapMonitor/GapMonitorV1.mq5` ← **canonical copy**
- `mmt/spot_future_arb_code/latest code/FINAL_GAP_MONITOR.mq5` ← duplicate
- `mmt/spot_future_arb_code/unq_code/FINAL_GAP_MONITOR.mq5` ← duplicate

**Internal name:** `GapMonitorEA_TableUI.mq5`
**Type:** MQL5 Expert Advisor

**What it adds over v2.20:**
- True bordered table with cell backgrounds (uses `ColorToARGB`).
- Zebra row shading, grid lines.
- 10 configurable windows via individual inputs (W1..W10 each with Enable/Unit/Value).
- Execution-aware gap calculation (Bid1−Ask2 / Ask1−Bid2) in all display cells.
- `InpRefreshSec` (seconds, not ms) — slower refresh for stat windows vs trade panel.
- Compact panel with configurable `UI_Width` (default 520 px).

**Status:** ✅ Use as the live gap monitoring dashboard alongside the Trade Panel EA.

---

### v3.20 — High-Performance Monitor + Multi-User Telegram ⭐
**File:** `mmt/spot_future_arb_code/latest code/MMT_Gap_Alerts_TG.mq5`
**Internal name:** `GapRadar_Pro_EA.mq5`
**Type:** MQL5 Expert Advisor

**What it adds over v2.03:**
- **Decoupled sampling vs stats computation**: samples run every `InpSampleMs` (250 ms); stats recompute at most every `InpStatsMinMs` (900 ms). Eliminates per-tick quantile sort.
- **No per-window array allocations** — WinAgg scan pattern with a single scratch array for quantiles.
- **Per-window cache** — avoids recomputing stats on every render cycle.
- **UI text caching** — skips `ObjectGetString` in hot loops.
- **Telegram polling throttle** (`InpTeleMinMs=1500 ms`) — JSON parsing skipped unless due.
- **Multi-chat Telegram** (`InpTeleAllowedChatIDs="957548787;7771695878;5865942099"`) — multiple users can receive alerts.
- **Command polling** (`InpTelePollCommands=true`) — users can query bot via Telegram.
- **Alert cooldown** (`InpTeleCooldownSec=300`) — prevents alert spam.
- **Window values as `double`** (not int) — fractional windows (e.g., 1.5 hours).

**Status:** ✅ Use as the Telegram alert engine. Run alongside GapMonitorV1 (v3.10) for full monitoring.

---

## Duplicate / Archive Files

These files contain identical content to a version already catalogued above. No unique logic.

| File | Duplicate of |
|---|---|
| `mmt/mm_v3.mq5` | Trade Panel v2.82 |
| `mmt/spot_future_arb_code/MMT_V3.mq5` | Trade Panel v2.82 |
| `mmt/spot_future_arb_code/MMT_V3 (2).mq5` | Trade Panel v2.82 |
| `mmt/spot_future_arb_code/latest code/MMT_TradePannel_Pro.mq5` | Trade Panel v2.82 |
| `mmt/final trading bot/best_code.cpp` | Trade Panel v3.26 |
| `mmt/spot_future_arb_code/MMT_GapRadar_Pro.mq5` | Gap Radar v1 |
| `mmt/spot_future_arb_code/MMT_GapRadar_Pro (2).mq5` | Gap Radar v1 |
| `mmt/spot_future_arb_code/MMT_GapRadar_Pro (3).mq5` | Gap Radar v1 |
| `mmt/spot_future_arb_code/MMT_GAP_RADAR_PRO.mq5` | Gap Radar v2.20 |
| `mmt/spot_future_arb_code/MMT_GAP_RADAR_PRO (2).mq5` | Gap Radar v2.20 |
| `mmt/spot_future_arb_code/latest code/FINAL_GAP_MONITOR.mq5` | Gap Monitor v3.10 |
| `mmt/spot_future_arb_code/unq_code/FINAL_GAP_MONITOR.mq5` | Gap Monitor v3.10 |
| `mmt/spot_future_arb_code/unq_code/MMT_TradePannel_Pro.mq5` | Trade Panel v2.83 |

---

## Feature Comparison Matrix

### Trade Panel Family

| Feature | v1.20 | v2.81 | v2.82 | v2.83 | v2.84 | v3.26 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Max pairs | 5 | 20 | 20 | 20 | 20 | 20 |
| OAG scheduling | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ |
| CAG auto-close | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ |
| OAG confirm timer | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ |
| CAG confirm timer | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ |
| Min hold time | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ |
| Rollback on fail | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ |
| State reconcile on init | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ |
| Async execution | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ |
| TRANSIT state | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ |
| Watchdog rollback | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ |
| OnTradeTransaction | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ |
| Spread filter | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| OAG tolerance/drift | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| CAG overrun skip | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| Concurrency caps | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| File-based logging | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| Close watchdog | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| CAG slippage buffer | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ |

### Gap Radar Family

| Feature | v1 | v2.01 | v2.03 | v2.20 | v3.10 | v3.20 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Rolling gap history | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Z-score | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Pearson correlation | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ |
| Regression slope | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ |
| Quantile reporting | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ |
| Multi-window stats | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Tabular UI | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Telegram alerts | ✗ | ✗ | ✓ | ✗ | ✗ | ✓ |
| Multi-user Telegram | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| Telegram command polling | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| Quantile OAG/CAG suggestion | ✗ | ✗ | ✗ | ✓ | ✗ | ✓ |
| ARGB cell backgrounds | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ |
| Decoupled sample/stats | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| Indicator type | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ |
| EA type | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ |

---

## Recommended Setup (Production)

Run all three simultaneously on MT5:

```
Chart 1 (XAUUSD or GCxx):
  ├── EA:        best_code.cpp  (v3.26)         ← Trade execution
  └── (optional) MMT_Gap_Alerts_TG.mq5 (v3.20) ← Telegram alerts

Chart 2 (any chart, monitoring):
  └── EA:        GapMonitorV1.mq5 (v3.10)       ← Gap stat dashboard
```

---

## Key Concepts Glossary

| Term | Meaning |
|---|---|
| **Gap** | `Bid(S1) - Ask(S2)` for SELL_ONLY; `Ask(S1) - Bid(S2)` for BUY_ONLY |
| **OAG** | Open At Gap — the gap level that triggers a scheduled entry |
| **CAG** | Close At Gap — the gap level that triggers auto-close (profit target) |
| **OAG Confirm** | Gap must stay at OAG level for X ms before order fires (anti-spike) |
| **CAG Confirm** | Gap must stay at CAG level for Y ms before close fires (anti-spike) |
| **PSTATUS_IDLE** | No position, no schedule |
| **PSTATUS_SCHED** | Entry scheduled, waiting for OAG hit |
| **PSTATUS_LIVE** | Both legs open, monitoring for CAG |
| **PSTATUS_BROKEN** | Only one leg is open (error state) |
| **PSTATUS_TRANSIT** | v2.84+ async orders in-flight |
| **S1** | Symbol 1 — typically the futures contract (e.g. GCM26) |
| **S2** | Symbol 2 — typically spot gold (e.g. XAUUSD) |
| **Magic Number** | Unique integer stamped on every order to identify this EA's positions |
