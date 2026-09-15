# Tick Data Collection — Phase 0 Design

Status: PROPOSED (not yet validated or approved) — 2026-09-14

## Purpose

Define and justify the bounded Phase 0 step for collecting synchronized executable bid/ask tick data for
`XAUUSD.vx` (spot) and `GC-Z26` (futures) on VPFX. Tick-level bid/ask data is required before
`docs/02_quant/14_TRANSACTION_COST_MODEL.md` or `docs/02_quant/17_EXPECTED_VALUE.md` can be completed,
per the mandate's `REAL EXECUTABLE PRICES` section and `docs/02_quant/10_DATA_REQUIREMENTS.md`.

No orders are placed by any step in this document. This is a read-only research activity.

---

## Constraint that forces this decision

The `MetaTrader5` Python package — already used in `tools/mt5_data_collector.py` — communicates with the
running MT5 terminal via a Windows-only IPC channel. It is not installable on native macOS Python.
The project's existing data-collection tooling therefore cannot run on the Mac as-is.

Two options exist within Phase 0 constraints.

---

## Option A — Windows VMware, extend the existing Python collector (RECOMMENDED)

Install MT5 and Python inside a Windows VM running in VMware Fusion on the user's Mac. Run and extend
`tools/mt5_data_collector.py` there with `mt5.copy_ticks_range()` to pull true bid/ask tick history for
both symbols, then merge the two series by timestamp and save the synchronized executable-basis series to
`research/<timestamp>/`.

### Why Option A is recommended

1. **Exact granularity.** `mt5.copy_ticks_range(symbol, from_dt, to_dt, mt5.COPY_TICKS_ALL)` returns a
   structured array with `time_msc` (millisecond timestamp), `bid`, `ask`, `flags`, and `volume` for every
   tick stored in the terminal's history. This is the same resolution that `10_DATA_REQUIREMENTS.md`
   requires for a final cost/EV model. The alternative (Option B's `CopyTicksRange()`) has the same
   underlying tick store but imposes MQL5 sandbox constraints on what can be exported.

2. **The script already exists.** `tools/mt5_data_collector.py` has the connection, specification, and
   margin-calculation logic. Adding a tick-collection function is a single well-defined extension — no new
   language artifacts, no new review surface.

3. **Python is better suited to data analysis.** The project's downstream pipeline is
   `research/<timestamp>/` → hand-review → promote into `docs/`. `pandas.merge_asof()` can merge two
   asynchronous tick streams by timestamp with a configurable tolerance in a few lines — this step would
   require a custom sorted-merge loop in MQL5.

4. **Stays within the existing project discipline.** The project already accepts that the Windows terminal
   is required for MT5 Python access (noted in `tools/README.md`). VMware is a documented, reversible
   way to satisfy that requirement on a Mac.

5. **No new MQL5 artifacts at Phase 0.** The mandate prohibits implementing the production EA and
   establishes phase gates before any MQL5 code is written. A read-only MQL5 Script is not the production
   EA, but it still introduces a new artifact type that must be designed, compiled, tested, and maintained.
   Extending a Python script stays in the same language and review surface the project already uses.

---

## Option B — MQL5 read-only export script in Mac/Wine MT5 (NOT recommended for this step)

Write a new MQL5 Script (not an EA; a `void OnStart()` script) that calls `CopyTicksRange()` for both
symbols and writes synchronized tick rows to a CSV file in the MT5 sandbox (`MQL5/Files/`).

### Why Option B is not recommended for this step

1. **New language artifact.** A compiled MQL5 `.ex5` requires design, review, and testing under the same
   phase-gate discipline as any MQL5 code. Extending an existing Python script does not.

2. **Sandbox file extraction friction.** MT5 under Wine writes to the Wine `MQL5/Files/` sandbox, not to
   the project directory. Extracting the CSV requires a manual copy step from the Wine prefix path on
   every run — more friction than `tools/mt5_data_collector.py` which writes directly to `research/`.

3. **Same underlying tick-history limitation.** `CopyTicksRange()` in MQL5 and `copy_ticks_range()` in
   Python both access the terminal's stored tick history. The depth of that history is broker/terminal
   configured — neither option gets more history than the terminal has stored.

4. **Live-capture would require an EA, not a Script.** For real-time synchronized tick capture, a Script's
   `OnStart()` function blocks until it finishes — live capture would require `OnTick()` in an EA, which
   is a larger and more permanent artifact than a one-off data-collection tool.

Option B remains a valid fallback if the VMware approach proves impractical (e.g., VMware not available,
Windows license not available, VM performance unacceptable for live tick rates). If Option B is later
chosen, a separate MQL5 script spec should be written and reviewed before implementation.

---

## Recommended implementation: Option A

### Files affected

| File | Change |
|---|---|
| `tools/mt5_data_collector.py` | Add `collect_tick_data()` and `compute_synchronized_basis()` functions; extend `main()` to call them and write per-symbol tick CSVs and the merged basis CSV |
| `tools/README.md` | Add: Windows VMware setup note; describe the new tick output files |
| `docs/02_quant/10_DATA_REQUIREMENTS.md` | Update status: collection method now specified; record tick output schema |
| `docs/DECISION_LOG.md` | Add D-004: tick-data collection approach |

No changes to `docs/01_research/07_BROKER_RESEARCH.md`, `docs/02_quant/11_SPREAD_DEFINITION.md`, or any
quant model document — those are updated only after the collected data is reviewed and promoted by hand.

### New functions in `tools/mt5_data_collector.py`

```python
def collect_tick_data(spot: str, futures: str,
                      from_dt: datetime, to_dt: datetime
                      ) -> tuple[pd.DataFrame, pd.DataFrame]:
    """
    Pull raw tick history for both symbols via copy_ticks_range.
    Read-only: no order is placed or checked.

    Returns (spot_df, futures_df) each with columns:
        time_msc  int64   — milliseconds since epoch (UTC)
        time_utc  datetime[UTC]
        bid       float64
        ask       float64
        flags     uint32  — MT5 tick flags (bid/ask/last update)
    """
    for sym in (spot, futures):
        if not mt5.symbol_select(sym, True):
            raise RuntimeError(f"symbol_select({sym!r}) failed: {mt5.last_error()}")

    raw_spot = mt5.copy_ticks_range(spot, from_dt, to_dt, mt5.COPY_TICKS_ALL)
    raw_fut  = mt5.copy_ticks_range(futures, from_dt, to_dt, mt5.COPY_TICKS_ALL)

    if raw_spot is None or len(raw_spot) == 0:
        raise RuntimeError(f"copy_ticks_range returned nothing for {spot}: {mt5.last_error()}")
    if raw_fut is None or len(raw_fut) == 0:
        raise RuntimeError(f"copy_ticks_range returned nothing for {futures}: {mt5.last_error()}")

    def _to_df(arr, label: str) -> pd.DataFrame:
        df = pd.DataFrame(arr)[["time_msc", "bid", "ask", "flags"]].copy()
        df["time_utc"] = pd.to_datetime(df["time_msc"], unit="ms", utc=True)
        # Keep only bid/ask update ticks (flags bit 1 = bid, bit 2 = ask).
        # Volume-only ticks are irrelevant for spread research.
        df = df[df["flags"].apply(lambda f: bool(f & 0x06))].reset_index(drop=True)
        print(f"  {label}: {len(df):,} bid/ask ticks "
              f"({df['time_utc'].iloc[0]} → {df['time_utc'].iloc[-1]})")
        return df

    return _to_df(raw_spot, spot), _to_df(raw_fut, futures)


def compute_synchronized_basis(spot_df: pd.DataFrame,
                                futures_df: pd.DataFrame,
                                tolerance_ms: int = 500) -> pd.DataFrame:
    """
    For each futures bid/ask tick, look back to find the most recent spot tick
    within tolerance_ms and compute the two executable basis values:

        convergence_basis = Bid(futures) - Ask(spot)   # SELL futures / BUY spot
        reverse_basis     = Ask(futures) - Bid(spot)   # BUY  futures / SELL spot

    quote_skew_ms is the time difference between the two ticks; values near
    tolerance_ms indicate the spot quote may be stale relative to the futures
    quote at that moment.

    This is a post-hoc synchronization approximation. True synchronization
    requires live simultaneous sampling — this is adequate for Phase 0
    distributional study but must be labeled as such in any doc it feeds.
    """
    fut_sorted  = futures_df.sort_values("time_msc").reset_index(drop=True)
    spot_sorted = spot_df.sort_values("time_msc").reset_index(drop=True)

    merged = pd.merge_asof(
        fut_sorted.rename(columns={"bid": "fut_bid", "ask": "fut_ask",
                                   "time_msc": "fut_time_msc", "time_utc": "fut_time_utc"}),
        spot_sorted.rename(columns={"bid": "spot_bid", "ask": "spot_ask",
                                    "time_msc": "spot_time_msc", "time_utc": "spot_time_utc"}),
        left_on="fut_time_msc",
        right_on="spot_time_msc",
        direction="backward",
        tolerance=tolerance_ms,
    )

    merged = merged.dropna(subset=["spot_bid", "spot_ask"]).reset_index(drop=True)
    merged["convergence_basis"] = merged["fut_bid"]  - merged["spot_ask"]
    merged["reverse_basis"]     = merged["fut_ask"]  - merged["spot_bid"]
    merged["mid_basis"]         = (merged["fut_bid"] + merged["fut_ask"]) / 2 \
                                - (merged["spot_bid"] + merged["spot_ask"]) / 2
    merged["quote_skew_ms"]     = merged["fut_time_msc"] - merged["spot_time_msc"]

    print(f"  Synchronized rows: {len(merged):,} "
          f"(dropped {len(fut_sorted) - len(merged):,} futures ticks with no spot within "
          f"{tolerance_ms} ms)")
    return merged


def summarize_basis(df: pd.DataFrame) -> dict:
    """Summary statistics for the synchronized executable basis."""
    def _stats(col: str) -> dict:
        s = df[col]
        return {
            "n": int(len(s)),
            "mean": round(float(s.mean()), 4),
            "median": round(float(s.median()), 4),
            "std": round(float(s.std()), 4),
            "min": round(float(s.min()), 4),
            "max": round(float(s.max()), 4),
            "p05": round(float(s.quantile(0.05)), 4),
            "p25": round(float(s.quantile(0.25)), 4),
            "p75": round(float(s.quantile(0.75)), 4),
            "p95": round(float(s.quantile(0.95)), 4),
        }

    return {
        "convergence_basis": _stats("convergence_basis"),
        "reverse_basis":     _stats("reverse_basis"),
        "mid_basis":         _stats("mid_basis"),
        "quote_skew_ms":     _stats("quote_skew_ms"),
        "note": (
            "Basis computed via pd.merge_asof (backward, tolerance set at collection time). "
            "convergence_basis = Bid(GC-Z26) - Ask(XAUUSD.vx) for SELL futures / BUY spot. "
            "reverse_basis = Ask(GC-Z26) - Bid(XAUUSD.vx) for BUY futures / SELL spot. "
            "This is a post-hoc approximation — true live synchronization is a separate "
            "Phase 1 / real-time-capture requirement."
        ),
    }
```

These functions are called in `main()` after the existing margin and bar-history sections. The tick date
range should be set to the previous full week by default (same discipline as `HISTORY_DAYS = 7`) but the
caller can override `from_dt` / `to_dt`.

### Output files added to `research/<timestamp>/`

| File | Contents |
|---|---|
| `ticks_XAUUSD.vx.csv` | Columns: `time_msc, bid, ask, flags, time_utc` — per spot tick |
| `ticks_GC-Z26.csv` | Columns: `time_msc, bid, ask, flags, time_utc` — per futures tick |
| `basis_synchronized.csv` | Merged columns: `fut_time_msc, fut_bid, fut_ask, spot_time_msc, spot_bid, spot_ask, convergence_basis, reverse_basis, mid_basis, quote_skew_ms` |
| `basis_summary.json` | Descriptive statistics for all basis columns (see `summarize_basis()`) |

---

## VMware setup (Windows guest on macOS host)

The VMware guest is a disposable data-collection environment, not a production or trading system.

### Required software in the Windows VM

1. MetaTrader 5 terminal — download from the VPFX account portal or mt5.com; install and log into the
   VPFX-Live server (same account, different machine connection). **Only one MT5 session per account is
   typically allowed simultaneously** — shut down the Mac Wine MT5 terminal before connecting from the VM,
   or create a free VPFX demo account for the VM and use the live account only for order-ticket margin
   cross-check (which `order_calc_margin()` does not require a live account for, only a logged-in terminal).
2. Python 3.10 or 3.11 (64-bit); confirm `python --version` returns a 64-bit build.
3. `pip install MetaTrader5 pandas` (approx. 100 MB including numpy).
4. Git (to clone/pull the project repo) or a shared folder from macOS host → Windows guest.

### Network and time sync

- The VM's clock must be NTP-synchronized (Windows default: `W32tm` service enabled). Tick timestamps
  come from the broker's server; they do not depend on the VM clock, but the VM clock determines which
  date range is requested in `copy_ticks_range()`.
- No special firewall rule is needed — the MetaTrader5 package uses local IPC to the terminal process,
  not a network connection to the broker.

---

## Acceptance criteria

The step is complete when all of the following are true after a single run of the extended script in the
Windows VM:

| # | Criterion |
|---|---|
| AC-1 | `mt5.initialize()` returns `True`; `mt5.account_info()` returns a non-None result with the expected VPFX server name |
| AC-2 | `collect_tick_data()` returns non-empty DataFrames for both `XAUUSD.vx` and `GC-Z26` covering at least 1 full trading session (≥ 2,000 ticks per symbol) |
| AC-3 | Both DataFrames contain `time_msc`, `bid`, `ask` columns with no NaN values |
| AC-4 | `time_msc` values are monotonically non-decreasing in both DataFrames |
| AC-5 | `compute_synchronized_basis()` produces a merged DataFrame with ≥ 80% of futures ticks matched to a spot tick within the 500 ms tolerance |
| AC-6 | All `convergence_basis` values in the merged DataFrame are positive (futures trading above spot — consistent with observed contango) |
| AC-7 | `basis_summary.json` mean convergence_basis is in the range 35–55 (plausible for GC Dec 2026 vs spot at current levels; flag for review if outside this range) |
| AC-8 | `order_calc_margin()` call for `XAUUSD.vx` at 0.01 lot BUY returns a value between $30 and $80 (cross-checks R-001 residual without placing an order) |
| AC-9 | No deals or positions appear in MT5 account history that did not exist before the run (verified by comparing `mt5.history_deals_total()` before and after) |
| AC-10 | All output files land in `research/<timestamp>/`; no file is written to `docs/`, `src/`, or `tools/` |

---

## Risks

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R-A1 | VPFX does not allow simultaneous login from a second MT5 instance on the same live account | Medium | Use a VPFX demo account in the VM; the MetaTrader5 package's read-only calls work on demo; OR shut down the Mac Wine terminal before connecting from the VM |
| R-A2 | MT5 terminal stores limited tick history (e.g., only hours, not days) | Medium | Run the script live during a trading session and keep it running for several hours to accumulate ticks — `copy_ticks_range()` returns what the terminal has cached; check `HISTORY_DAYS` output count |
| R-A3 | VMware Fusion not installed or no Windows license available | Low | Use Parallels Desktop or a cloud Windows VM (e.g., AWS EC2 Windows Server with a temporary license); the Python package and MT5 installer work the same way on any Windows Server 2019+ VM |
| R-A4 | 64-bit Python required; 32-bit install silently fails to find the MetaTrader5 package | Low | Verify `python -c "import struct; print(struct.calcsize('P')*8)"` returns `64` before installing the package |
| R-A5 | Large tick history (e.g., 7 days × high-frequency gold quotes) may be slow to pull | Low | Reduce `HISTORY_DAYS` to 1–2 for an initial test; check row count; then extend if the terminal has more history available |
| R-A6 | The Mac Wine MT5 terminal and the VM terminal both pull ticks at the same time, saturating the broker feed | Low | Only one terminal should be connected at a time for data-collection runs; shut down the Mac terminal first |
| R-A7 | Stale or non-updating quotes in the VM terminal (e.g., Market Watch not subscribed) | Low | Confirmed by `symbol_select(symbol, True)` in the script; if tick count is zero, open the Market Watch in the terminal manually and re-run |

---

## Exact validation steps

Run these steps in order. They can be completed in one session.

### Step 1 — Environment verification (≈ 15 min)

```cmd
python --version
REM Must print Python 3.x.y (64 bit) or a 64-bit build

python -c "import struct; print(struct.calcsize('P')*8)"
REM Must print 64

pip install MetaTrader5 pandas
python -c "import MetaTrader5 as mt5; print(mt5.__version__)"
REM Must print a version string without error
```

### Step 2 — Terminal connectivity check (≈ 5 min)

1. Ensure the MT5 terminal is running and logged into the VPFX (live or demo) account in the VM.
2. In the Market Watch panel, confirm both `XAUUSD.vx` and `GC-Z26` are visible and showing live
   bid/ask prices (not greyed out).
3. Run:
```cmd
python -c "
import MetaTrader5 as mt5
mt5.initialize()
print('Account server:', mt5.account_info().server)
tick = mt5.symbol_info_tick('XAUUSD.vx')
print('XAUUSD.vx bid/ask:', tick.bid, '/', tick.ask)
tick = mt5.symbol_info_tick('GC-Z26')
print('GC-Z26 bid/ask:', tick.bid, '/', tick.ask)
mt5.shutdown()
"
REM Both bid/ask values must be non-zero and plausible (gold ~4200-4500 range)
```

### Step 3 — Margin cross-check (residual from R-001) (≈ 5 min)

```cmd
python -c "
import MetaTrader5 as mt5
mt5.initialize()
tick = mt5.symbol_info_tick('XAUUSD.vx')
m = mt5.order_calc_margin(mt5.ORDER_TYPE_BUY, 'XAUUSD.vx', 0.01, tick.ask)
print('XAUUSD.vx BUY 0.01 margin:', m)
tick = mt5.symbol_info_tick('GC-Z26')
m = mt5.order_calc_margin(mt5.ORDER_TYPE_SELL, 'GC-Z26', 0.01, tick.bid)
print('GC-Z26 SELL 0.01 margin:', m)
mt5.shutdown()
"
REM Expected: XAUUSD.vx ~$40-55, GC-Z26 ~$80-100. Record both numbers.
REM If either is > $200, re-open docs/RISK_REGISTER.md R-001.
```

### Step 4 — Tick history probe (≈ 10 min)

Before running the full script, verify that tick history is available for both symbols:

```cmd
python -c "
import MetaTrader5 as mt5
from datetime import datetime, timedelta, timezone
mt5.initialize()
for sym in ('XAUUSD.vx', 'GC-Z26'):
    mt5.symbol_select(sym, True)
    to = datetime.now(tz=timezone.utc)
    fr = to - timedelta(hours=4)
    ticks = mt5.copy_ticks_range(sym, fr, to, mt5.COPY_TICKS_ALL)
    print(sym, '— ticks in last 4h:', 0 if ticks is None else len(ticks))
mt5.shutdown()
"
REM If either count is 0, the terminal does not have tick history stored.
REM Workaround: leave the terminal running with Market Watch open for the session,
REM then re-run after a few hours to let history accumulate.
```

### Step 5 — Full collector run (≈ 10–30 min depending on history depth)

```cmd
cd path\to\mt5-spot-futures-arbitrage
python tools\mt5_data_collector.py
```

Expected console output:

```
Connected: server='VPFX-Live', trade_mode=0, currency='USD'
(Account number intentionally not printed ...)

--- Symbol specifications ---
XAUUSD.vx: calc_mode=..., contract_size=100.0, tick_value=1.0
GC-Z26: calc_mode=..., contract_size=100.0, tick_value=1.0

--- Margin required at 0.01 lot ---
XAUUSD.vx: BUY margin=<X>, SELL margin=<X>
GC-Z26: BUY margin=<X>, SELL margin=<X>

--- Gap history, last 7 days, M1 bars ---
{ ... summary ... }

--- Tick data collection ---
XAUUSD.vx: <N> bid/ask ticks (YYYY-MM-DD ... → YYYY-MM-DD ...)
GC-Z26: <N> bid/ask ticks (YYYY-MM-DD ... → YYYY-MM-DD ...)

--- Synchronized executable basis ---
Synchronized rows: <M> (dropped <K> futures ticks with no spot within 500 ms)
{ ... basis_summary.json preview ... }

All outputs written to: research/<timestamp>/
```

### Step 6 — Output verification (≈ 10 min)

Open `research/<timestamp>/` and check:

```
basis_summary.json:
  convergence_basis.mean  → between 35 and 55
  convergence_basis.min   → must be positive (futures premium over spot)
  convergence_basis.p05   → must be positive
  quote_skew_ms.p95       → ideally < 200 ms; flag for discussion if > 500 ms

ticks_XAUUSD.vx.csv: open first 10 rows, confirm bid < ask on every row
ticks_GC-Z26.csv: same check

basis_synchronized.csv:
  convergence_basis column → no negative values (flag if any found, investigate)
  quote_skew_ms column → spot-check a few rows, values should be small positive integers
```

### Step 7 — Verify no orders placed

```cmd
python -c "
import MetaTrader5 as mt5
mt5.initialize()
before = mt5.history_deals_total(
    __import__('datetime').datetime(2026,9,1),
    __import__('datetime').datetime.now()
)
print('Total deals in history:', before)
mt5.shutdown()
"
REM Compare this number to what it was before Step 5.
REM It must not have increased. If it did, investigate before continuing.
```

### Step 8 — Promote findings to docs (manual, by the user)

Review the `basis_summary.json` and `basis_synchronized.csv` in the `research/<timestamp>/` folder.
Hand-transcribe any decision-relevant numbers into:

- `docs/02_quant/11_SPREAD_DEFINITION.md` — replace the two point-in-time snapshots with distributional
  statistics (mean, percentiles, note the sample period and tick count)
- `docs/02_quant/10_DATA_REQUIREMENTS.md` — update Status from IN PROGRESS to first-milestone complete
  once a full trading session of tick data is collected, reviewed, and promoted
- `docs/01_research/07_BROKER_RESEARCH.md` — record the live `order_calc_margin()` result for R-001
  residual cross-check (Step 3 above)

Do not commit the `research/` folder's contents to the repository.

---

## What this step does NOT do

- Does not place, check, or simulate any order.
- Does not validate the strategy's economic edge — that is `docs/02_quant/14_TRANSACTION_COST_MODEL.md`
  and `docs/02_quant/17_EXPECTED_VALUE.md`, which cannot start until the distributional study from this
  step is reviewed.
- Does not validate live execution latency, fill behavior, or broker quote behavior under stress — those
  are Phase 1 / demo-trading concerns.
- Does not replace the broker-level questions still open in `docs/OPEN_QUESTIONS.md` Q-002 (commission,
  settlement, rollover).

---

## Evidence produced by this step

If all acceptance criteria pass:

- A factual tick-distribution replaces the two point-in-time snapshots in `11_SPREAD_DEFINITION.md`.
- The R-001 residual (live margin cross-check) is cleared in `07_BROKER_RESEARCH.md`.
- `14_TRANSACTION_COST_MODEL.md` can be started using the real spread observations as one cost input.
- The answer to mandate question 6 ("What data must be collected before choosing entry/exit thresholds?")
  moves from "not yet started" to "first distributional study complete" — a meaningful Phase 0 milestone.
