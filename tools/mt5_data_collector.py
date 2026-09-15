"""
Read-only MT5 research data collector for Phase 0 (docs/01_research, docs/02_quant).

Answers, from live broker data instead of guesswork:
  - Full symbol specification for both legs (contract size, tick value, margin mode,
    swap, expiry, session hours, etc.) via symbol_info().
  - Actual required margin at a given volume, for both BUY and SELL, via
    order_calc_margin() -- this is the same number the New Order ticket shows, without
    placing an order. Resolves the residual note in docs/RISK_REGISTER.md R-001.
  - A real distribution of the executable spread/gap between the two legs (mean,
    median, std, percentiles) from historical bars, instead of the two point-in-time
    snapshots currently in docs/02_quant/11_SPREAD_DEFINITION.md.

Safety:
  - Every MT5 call here is read-only or a calculation. Nothing in this script can open,
    close, or modify a position: order_send / order_check are never called.
  - No credentials are read, stored, or logged. mt5.initialize() attaches to the MT5
    terminal that is already running and logged in on this machine -- it does not take
    a login/password. If you need a fresh login, do it in the terminal itself first.
  - Requires Windows with a running MetaTrader5 terminal (the MetaTrader5 pip package
    talks to the local terminal process; it does not work headless or on macOS/Linux).

Usage:
    pip install MetaTrader5 pandas
    python tools/mt5_data_collector.py

Output:
    Writes CSV/JSON summaries under research/<UTC timestamp>/ (gitignored -- these are
    working data, not source of truth; promote any conclusion into the relevant
    docs/01_research or docs/02_quant document by hand after reviewing the numbers).
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    import MetaTrader5 as mt5
except ImportError:
    sys.exit(
        "MetaTrader5 package not found. This script must run on Windows, with pip "
        "install MetaTrader5 pandas, and the MT5 terminal already running and logged "
        "into the VPFX account."
    )

try:
    import pandas as pd
except ImportError:
    sys.exit("pandas not found. pip install pandas")


# ---- Configuration: adjust if the symbol pair under study changes ---------------

SPOT_SYMBOL = "XAUUSD.vx"
FUTURES_SYMBOL = "GC-Z26"
STUDY_VOLUME = 0.01
HISTORY_TIMEFRAME = mt5.TIMEFRAME_M1
HISTORY_DAYS = 7  # how far back to pull bars for the gap distribution

OUTPUT_ROOT = Path(__file__).resolve().parent.parent / "research"


# ---- Connection -------------------------------------------------------------------


def connect() -> None:
    if not mt5.initialize():
        code, desc = mt5.last_error()
        sys.exit(f"mt5.initialize() failed: [{code}] {desc}. Is the MT5 terminal running and logged in?")
    info = mt5.account_info()
    if info is None:
        sys.exit("Connected to terminal, but account_info() returned None -- is an account logged in?")
    print(f"Connected: server={info.server!r}, trade_mode={info.trade_mode}, currency={info.currency}")
    print("(Account number intentionally not printed -- do not paste it back into any committed file.)")


def disconnect() -> None:
    mt5.shutdown()


# ---- Symbol specification -----------------------------------------------------


def dump_symbol_spec(symbol: str) -> dict:
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"symbol_select({symbol!r}) failed: {mt5.last_error()}")
    info = mt5.symbol_info(symbol)
    if info is None:
        raise RuntimeError(f"symbol_info({symbol!r}) returned None: {mt5.last_error()}")
    spec = info._asdict()

    # Human-readable expansions for the fields that matter most to this project's
    # open questions (margin mode, settlement/calc mode, expiry).
    spec["_trade_calc_mode_name"] = _CALC_MODE_NAMES.get(spec.get("trade_calc_mode"), "UNKNOWN")
    spec["_trade_mode_name"] = _TRADE_MODE_NAMES.get(spec.get("trade_mode"), "UNKNOWN")
    exp = spec.get("expiration_time")
    if exp:
        spec["_expiration_time_utc"] = datetime.fromtimestamp(exp, tz=timezone.utc).isoformat()
    return spec


_CALC_MODE_NAMES = {
    getattr(mt5, name): name
    for name in dir(mt5)
    if name.startswith("SYMBOL_CALC_MODE_")
}
_TRADE_MODE_NAMES = {
    getattr(mt5, name): name
    for name in dir(mt5)
    if name.startswith("SYMBOL_TRADE_MODE_")
}


# ---- Margin, without placing an order ------------------------------------------


def margin_required(symbol: str, volume: float) -> dict:
    """order_calc_margin is a pure calculation -- it never touches the order book."""
    tick = mt5.symbol_info_tick(symbol)
    if tick is None:
        raise RuntimeError(f"symbol_info_tick({symbol!r}) returned None: {mt5.last_error()}")

    buy_margin = mt5.order_calc_margin(mt5.ORDER_TYPE_BUY, symbol, volume, tick.ask)
    sell_margin = mt5.order_calc_margin(mt5.ORDER_TYPE_SELL, symbol, volume, tick.bid)
    return {
        "symbol": symbol,
        "volume": volume,
        "ask": tick.ask,
        "bid": tick.bid,
        "margin_required_buy": buy_margin,
        "margin_required_sell": sell_margin,
    }


# ---- Historical gap distribution ------------------------------------------------


def collect_gap_history(spot: str, futures: str, timeframe, days: int) -> pd.DataFrame:
    utc_to = datetime.now(tz=timezone.utc)
    utc_from = utc_to - timedelta(days=days)

    spot_rates = mt5.copy_rates_range(spot, timeframe, utc_from, utc_to)
    fut_rates = mt5.copy_rates_range(futures, timeframe, utc_from, utc_to)
    if spot_rates is None or len(spot_rates) == 0:
        raise RuntimeError(f"No historical rates returned for {spot!r}: {mt5.last_error()}")
    if fut_rates is None or len(fut_rates) == 0:
        raise RuntimeError(f"No historical rates returned for {futures!r}: {mt5.last_error()}")

    spot_df = pd.DataFrame(spot_rates)
    fut_df = pd.DataFrame(fut_rates)

    # copy_rates_range gives OHLC bars, not raw bid/ask -- 'close' is the best
    # available proxy for each bar's end-of-bar price from this call. This is NOT
    # the same as true executable bid/ask at every tick; treat it as an approximation
    # suitable for a first-pass distribution, not a final cost/edge calculation.
    # For a rigorous executable-price study, switch to copy_ticks_range and rebuild
    # bid/ask series directly -- left as a follow-up, since tick data volume is much
    # larger and the M1-close approximation is enough to decide if this is worth that
    # extra work.
    spot_df = spot_df[["time", "close"]].rename(columns={"close": "spot_close"})
    fut_df = fut_df[["time", "close"]].rename(columns={"close": "fut_close"})

    merged = pd.merge(spot_df, fut_df, on="time", how="inner")
    merged["time"] = pd.to_datetime(merged["time"], unit="s", utc=True)
    merged["gap_close_to_close"] = merged["fut_close"] - merged["spot_close"]
    return merged


def summarize_gap(df: pd.DataFrame) -> dict:
    s = df["gap_close_to_close"]
    return {
        "n_bars": int(len(s)),
        "mean": float(s.mean()),
        "median": float(s.median()),
        "std": float(s.std()),
        "min": float(s.min()),
        "max": float(s.max()),
        "p05": float(s.quantile(0.05)),
        "p25": float(s.quantile(0.25)),
        "p50": float(s.quantile(0.50)),
        "p75": float(s.quantile(0.75)),
        "p95": float(s.quantile(0.95)),
        "note": (
            "Computed from M1 bar CLOSE prices (approximation), not true tick-level "
            "executable bid/ask. Sufficient for a first look; re-derive from "
            "copy_ticks_range before this feeds a final cost/EV conclusion."
        ),
    }


# ---- Main ---------------------------------------------------------------------


def main() -> None:
    connect()
    try:
        run_dir = OUTPUT_ROOT / datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
        run_dir.mkdir(parents=True, exist_ok=True)

        print(f"\n--- Symbol specifications ---")
        specs = {}
        for sym in (SPOT_SYMBOL, FUTURES_SYMBOL):
            spec = dump_symbol_spec(sym)
            specs[sym] = spec
            print(f"{sym}: calc_mode={spec['_trade_calc_mode_name']}, "
                  f"trade_mode={spec['_trade_mode_name']}, "
                  f"contract_size={spec.get('trade_contract_size')}, "
                  f"tick_value={spec.get('trade_tick_value')}")
        (run_dir / "symbol_specs.json").write_text(json.dumps(specs, indent=2, default=str))

        print(f"\n--- Margin required at {STUDY_VOLUME} lot (no order placed) ---")
        margins = {}
        for sym in (SPOT_SYMBOL, FUTURES_SYMBOL):
            m = margin_required(sym, STUDY_VOLUME)
            margins[sym] = m
            print(f"{sym}: BUY margin={m['margin_required_buy']}, SELL margin={m['margin_required_sell']}")
        (run_dir / "margin_required.json").write_text(json.dumps(margins, indent=2, default=str))

        print(f"\n--- Gap history, last {HISTORY_DAYS} days, M1 bars ---")
        gap_df = collect_gap_history(SPOT_SYMBOL, FUTURES_SYMBOL, HISTORY_TIMEFRAME, HISTORY_DAYS)
        gap_df.to_csv(run_dir / "gap_history.csv", index=False)
        summary = summarize_gap(gap_df)
        (run_dir / "gap_summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2))

        print(f"\nAll outputs written to: {run_dir}")
        print("These are working data (gitignored) -- review them, then hand-transcribe")
        print("any conclusion into docs/01_research/07_BROKER_RESEARCH.md and")
        print("docs/02_quant/11_SPREAD_DEFINITION.md yourself. Do not commit this folder's contents.")
    finally:
        disconnect()


if __name__ == "__main__":
    main()


# ---- Tick data collection (executable bid/ask per tick) --------------------------
#
# This section extends the script's first-pass M1-bar gap statistics with true
# tick-level bid/ask data, as required before any conclusion can feed
# docs/02_quant/14_TRANSACTION_COST_MODEL.md or 17_EXPECTED_VALUE.md.
# See docs/01_research/08_TICK_DATA_COLLECTION.md for the full design rationale
# and acceptance criteria.
#
# mt5.copy_ticks_range() is a read-only call -- it never touches the order book.


TICK_HISTORY_DAYS = 7      # how far back to request; broker may have less stored
TICK_SYNC_TOLERANCE_MS = 500  # max age (ms) of the spot quote when merging with a futures tick


def collect_tick_data(
    spot: str,
    futures: str,
    from_dt: datetime,
    to_dt: datetime,
) -> "tuple[pd.DataFrame, pd.DataFrame]":
    """
    Pull raw bid/ask tick history for both symbols.
    Read-only: no order is placed, checked, or modified.

    Returns (spot_df, futures_df) each with columns:
        time_msc  int64        — milliseconds since epoch (UTC)
        time_utc  datetime[tz] — human-readable UTC timestamp
        bid       float64
        ask       float64
        flags     uint32       — MT5 tick flags (bit 1=bid update, bit 2=ask update)

    Filters out volume-only ticks (flags & 0x06 == 0) which carry no bid/ask.
    """
    for sym in (spot, futures):
        if not mt5.symbol_select(sym, True):
            raise RuntimeError(f"symbol_select({sym!r}) failed: {mt5.last_error()}")

    raw_spot = mt5.copy_ticks_range(spot, from_dt, to_dt, mt5.COPY_TICKS_ALL)
    raw_fut  = mt5.copy_ticks_range(futures, from_dt, to_dt, mt5.COPY_TICKS_ALL)

    if raw_spot is None or len(raw_spot) == 0:
        raise RuntimeError(
            f"copy_ticks_range returned nothing for {spot}: {mt5.last_error()}. "
            "Is the Market Watch subscribed and does the terminal have tick history for this symbol?"
        )
    if raw_fut is None or len(raw_fut) == 0:
        raise RuntimeError(
            f"copy_ticks_range returned nothing for {futures}: {mt5.last_error()}. "
            "Is the Market Watch subscribed and does the terminal have tick history for this symbol?"
        )

    def _to_df(arr, label: str) -> "pd.DataFrame":
        df = pd.DataFrame(arr)[["time_msc", "bid", "ask", "flags"]].copy()
        df["time_utc"] = pd.to_datetime(df["time_msc"], unit="ms", utc=True)
        # Keep only ticks that carry a bid or ask update.
        # Bit 1 (0x02) = bid updated, bit 2 (0x04) = ask updated.
        df = df[df["flags"].apply(lambda f: bool(int(f) & 0x06))].reset_index(drop=True)
        if len(df) == 0:
            raise RuntimeError(
                f"{label}: all ticks had flags=0 (volume-only) — no bid/ask updates in history. "
                "Try a different date range or check that the symbol's Market Watch is active."
            )
        print(
            f"  {label}: {len(df):,} bid/ask ticks "
            f"({df['time_utc'].iloc[0]} → {df['time_utc'].iloc[-1]})"
        )
        return df

    return _to_df(raw_spot, spot), _to_df(raw_fut, futures)


def compute_synchronized_basis(
    spot_df: "pd.DataFrame",
    futures_df: "pd.DataFrame",
    tolerance_ms: int = TICK_SYNC_TOLERANCE_MS,
) -> "pd.DataFrame":
    """
    Merge the two asynchronous tick streams by timestamp.

    For each futures tick, look back to find the most recent spot tick within
    tolerance_ms and compute the two executable basis values defined in
    docs/02_quant/11_SPREAD_DEFINITION.md:

        convergence_basis = Bid(futures) - Ask(spot)   # SELL futures / BUY  spot
        reverse_basis     = Ask(futures) - Bid(spot)   # BUY  futures / SELL spot
        mid_basis         = Mid(futures) - Mid(spot)   # for statistics only, not executable

    quote_skew_ms: time between the futures tick and the matched spot tick.
    A value near tolerance_ms means the spot quote was approaching stale at
    the moment of the futures tick — flag rows where this exceeds 200 ms.

    This is a POST-HOC approximation of synchronization. True live
    synchronization (simultaneous SymbolInfoTick() reads in MQL5 OnTick, or
    copy_ticks_range with near-zero latency) is a Phase 1 / real-time concern.
    Label any statistic derived here as "post-hoc tick merge, tolerance <N> ms".
    """
    fut  = futures_df.sort_values("time_msc").reset_index(drop=True)
    spot = spot_df.sort_values("time_msc").reset_index(drop=True)

    merged = pd.merge_asof(
        fut.rename(columns={
            "bid": "fut_bid", "ask": "fut_ask",
            "time_msc": "fut_time_msc", "time_utc": "fut_time_utc",
        }),
        spot.rename(columns={
            "bid": "spot_bid", "ask": "spot_ask",
            "time_msc": "spot_time_msc", "time_utc": "spot_time_utc",
        }),
        left_on="fut_time_msc",
        right_on="spot_time_msc",
        direction="backward",
        tolerance=tolerance_ms,
    )

    n_before = len(merged)
    merged = merged.dropna(subset=["spot_bid", "spot_ask"]).reset_index(drop=True)
    n_dropped = n_before - len(merged)

    merged["convergence_basis"] = merged["fut_bid"] - merged["spot_ask"]
    merged["reverse_basis"]     = merged["fut_ask"] - merged["spot_bid"]
    merged["mid_basis"]         = (
        (merged["fut_bid"] + merged["fut_ask"]) / 2.0
        - (merged["spot_bid"] + merged["spot_ask"]) / 2.0
    )
    merged["quote_skew_ms"] = (merged["fut_time_msc"] - merged["spot_time_msc"]).astype(int)

    print(
        f"  Synchronized rows: {len(merged):,} "
        f"(dropped {n_dropped:,} futures ticks with no spot within {tolerance_ms} ms)"
    )
    stale = (merged["quote_skew_ms"] > 200).sum()
    if stale:
        print(f"  WARNING: {stale:,} rows ({100*stale/len(merged):.1f}%) "
              f"have quote_skew_ms > 200 — spot quote was aging at time of futures tick")

    return merged


def summarize_basis(df: "pd.DataFrame", tolerance_ms: int = TICK_SYNC_TOLERANCE_MS) -> dict:
    """Descriptive statistics for the synchronized executable-basis DataFrame."""

    def _stats(col: str) -> dict:
        s = df[col]
        return {
            "n": int(len(s)),
            "mean":   round(float(s.mean()), 4),
            "median": round(float(s.median()), 4),
            "std":    round(float(s.std()), 4),
            "min":    round(float(s.min()), 4),
            "max":    round(float(s.max()), 4),
            "p05":    round(float(s.quantile(0.05)), 4),
            "p25":    round(float(s.quantile(0.25)), 4),
            "p75":    round(float(s.quantile(0.75)), 4),
            "p95":    round(float(s.quantile(0.95)), 4),
        }

    negatives = int((df["convergence_basis"] < 0).sum())
    return {
        "convergence_basis": _stats("convergence_basis"),
        "reverse_basis":     _stats("reverse_basis"),
        "mid_basis":         _stats("mid_basis"),
        "quote_skew_ms":     _stats("quote_skew_ms"),
        "convergence_basis_negative_rows": negatives,
        "merge_tolerance_ms": tolerance_ms,
        "note": (
            f"Post-hoc tick merge via pd.merge_asof (backward, tolerance={tolerance_ms} ms). "
            "convergence_basis = Bid(GC-Z26) - Ask(XAUUSD.vx): executable for SELL futures / BUY spot. "
            "reverse_basis = Ask(GC-Z26) - Bid(XAUUSD.vx): executable for BUY futures / SELL spot. "
            "mid_basis is for distributional research only — not an executable price. "
            "These figures are a Phase 0 approximation; true live synchronization is a separate "
            "Phase 1 requirement before any execution conclusion is drawn."
        ),
    }


# ---- Updated main: adds tick collection after the existing M1-bar section --------


def _main_with_ticks() -> None:
    """
    Extended main() that runs the original spec/margin/bar sections and then
    adds tick-level bid/ask collection and synchronized basis computation.

    Call this instead of main() once the VMware Windows environment is confirmed
    (see docs/01_research/08_TICK_DATA_COLLECTION.md, Step 2).
    """
    connect()
    try:
        run_dir = OUTPUT_ROOT / datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
        run_dir.mkdir(parents=True, exist_ok=True)

        # --- Original sections (unchanged) ---
        print(f"\n--- Symbol specifications ---")
        specs = {}
        for sym in (SPOT_SYMBOL, FUTURES_SYMBOL):
            spec = dump_symbol_spec(sym)
            specs[sym] = spec
            print(
                f"{sym}: calc_mode={spec['_trade_calc_mode_name']}, "
                f"trade_mode={spec['_trade_mode_name']}, "
                f"contract_size={spec.get('trade_contract_size')}, "
                f"tick_value={spec.get('trade_tick_value')}"
            )
        (run_dir / "symbol_specs.json").write_text(json.dumps(specs, indent=2, default=str))

        print(f"\n--- Margin required at {STUDY_VOLUME} lot (no order placed) ---")
        margins = {}
        for sym in (SPOT_SYMBOL, FUTURES_SYMBOL):
            m = margin_required(sym, STUDY_VOLUME)
            margins[sym] = m
            print(f"{sym}: BUY margin={m['margin_required_buy']}, SELL margin={m['margin_required_sell']}")
        (run_dir / "margin_required.json").write_text(json.dumps(margins, indent=2, default=str))

        print(f"\n--- Gap history, last {HISTORY_DAYS} days, M1 bars ---")
        gap_df = collect_gap_history(SPOT_SYMBOL, FUTURES_SYMBOL, HISTORY_TIMEFRAME, HISTORY_DAYS)
        gap_df.to_csv(run_dir / "gap_history.csv", index=False)
        summary = summarize_gap(gap_df)
        (run_dir / "gap_summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2))

        # --- New: tick-level bid/ask collection ---
        print(f"\n--- Tick data collection, last {TICK_HISTORY_DAYS} days ---")
        utc_to   = datetime.now(tz=timezone.utc)
        utc_from = utc_to - timedelta(days=TICK_HISTORY_DAYS)
        spot_ticks, fut_ticks = collect_tick_data(
            SPOT_SYMBOL, FUTURES_SYMBOL, utc_from, utc_to
        )
        spot_ticks.to_csv(run_dir / f"ticks_{SPOT_SYMBOL}.csv", index=False)
        fut_ticks.to_csv(run_dir / f"ticks_{FUTURES_SYMBOL}.csv", index=False)
        print(f"  Tick CSVs written.")

        print(f"\n--- Synchronized executable basis (tolerance={TICK_SYNC_TOLERANCE_MS} ms) ---")
        basis_df = compute_synchronized_basis(spot_ticks, fut_ticks, TICK_SYNC_TOLERANCE_MS)
        basis_df.to_csv(run_dir / "basis_synchronized.csv", index=False)
        basis_summary = summarize_basis(basis_df, TICK_SYNC_TOLERANCE_MS)
        (run_dir / "basis_summary.json").write_text(json.dumps(basis_summary, indent=2))
        print(json.dumps(basis_summary, indent=2))

        print(f"\nAll outputs written to: {run_dir}")
        print(
            "NEXT STEP: review basis_summary.json and basis_synchronized.csv, then\n"
            "hand-transcribe decision-relevant findings into:\n"
            "  docs/02_quant/11_SPREAD_DEFINITION.md  (distributional statistics)\n"
            "  docs/01_research/07_BROKER_RESEARCH.md (margin_required BUY value for R-001)\n"
            "Do NOT commit the research/ folder contents."
        )
    finally:
        disconnect()


if __name__ == "__main__":
    # Switch to _main_with_ticks() once the Windows VMware environment is ready
    # (see docs/01_research/08_TICK_DATA_COLLECTION.md for setup steps).
    # Until then, main() (M1-bar only) still works without VMware.
    import sys
    if "--ticks" in sys.argv:
        _main_with_ticks()
    else:
        main()
