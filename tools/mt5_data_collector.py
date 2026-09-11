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
