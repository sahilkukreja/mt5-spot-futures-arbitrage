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
  - With --pairs: reconciled closed trade pairs AND currently-open (censored) pairs
    (match_open_pairs()), ready to feed into pair_ledger.py's persistent cross-run
    ledger so the Q-004 time-to-convergence sample keeps growing across repeated runs
    instead of resetting to one lookback window each time.

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

import argparse
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
        print("\nNote: this default run provides M1 bar evidence only. For executable bid/ask")
        print("evidence, use: python tools/mt5_data_collector.py --ticks")
    finally:
        disconnect()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Read-only MT5 research collector for VPFX gold spot vs futures. "
            "Use the default mode for a first-pass gap study or --ticks for executable "
            "bid/ask evidence."
        )
    )
    parser.add_argument(
        "--ticks",
        action="store_true",
        help="Collect true bid/ask tick history and compute the synchronized executable basis.",
    )
    parser.add_argument(
        "--evidence",
        action="store_true",
        help="Alias for --ticks; intended for evidence collection before documentation review.",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=None,
        help="Override the lookback window for the tick-history run (default: 7 days).",
    )
    parser.add_argument(
        "--tolerance-ms",
        type=int,
        default=None,
        help="Override the bid/ask merge tolerance in milliseconds for the tick-based basis run.",
    )
    parser.add_argument(
        "--pairs",
        action="store_true",
        help=(
            "Reconstruct closed spot/futures trade pairs from account deal history "
            "(read-only, via history_deals_get) and compute entry/exit basis and P&L "
            "for each -- expands on manual review of the History tab."
        ),
    )
    parser.add_argument(
        "--pair-lookback-days",
        type=int,
        default=180,
        help="How far back to search deal history for --pairs (default: 180 days).",
    )
    parser.add_argument(
        "--pair-tolerance-seconds",
        type=int,
        default=300,
        help="Max time gap (seconds) between a spot and futures open to still count as one pair.",
    )
    return parser.parse_args()


# NOTE: dispatch happens in the single `if __name__ == "__main__":` block at the
# bottom of this file, after every mode function (main, _main_with_ticks,
# _main_with_pairs) is defined. An earlier version of this file had a second,
# duplicate __main__ block here that called `_main_with_ticks()` before that
# function existed in module execution order -- calling `--ticks` would have
# raised NameError. Never triggered in practice (only the default mode has been
# run so far), but real. Removed; see the bottom of the file for the only dispatch.


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
            f"({df['time_utc'].iloc[0]} to {df['time_utc'].iloc[-1]})"
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


# ---- Paired-trade reconciliation (closed spot+futures pairs from deal history) ---
#
# Manual review of the account's History tab (2026-09-15) found that several
# GC-Z26 trades were not standalone -- they were opened at the same instant as a
# matching XAUUSD.vx fill in the opposite direction: real, already-executed
# instances of this project's convergence trade. That review only covered the
# rows visible in two screenshots. This section pulls the FULL deal history via
# mt5.history_deals_get() (read-only -- no order is placed, checked, or modified)
# and reconstructs every matching pair automatically, so the sample isn't capped
# by what happened to be on screen.
#
# Each closed MT5 position produces at least two deal records: an entry deal
# (DEAL_ENTRY_IN) and an exit deal (DEAL_ENTRY_OUT), linked by position_id. This
# groups deals by position_id first to get one row per closed trade, THEN matches
# spot trades to futures trades by opposite direction, equal volume, and open
# time within a tolerance window.


def collect_closed_trades(symbol: str, from_dt: datetime, to_dt: datetime) -> "pd.DataFrame":
    """
    Pull closed-trade history for one symbol via history_deals_get() (read-only).
    Groups raw deals by position_id and keeps only positions with exactly one
    entry (IN) deal and one exit (OUT) deal -- i.e. simple, fully-closed trades.
    Positions with partial closes / multiple in-out legs are returned separately
    as "unhandled" rows rather than silently merged or dropped.

    Returns a DataFrame with columns: position_id, symbol, direction (BUY/SELL),
    volume, open_time, open_price, close_time, close_price, commission (sum of
    both deals'), swap (sum), profit (sum), unhandled (bool).
    """
    raw = mt5.history_deals_get(from_dt, to_dt, group=symbol)
    if raw is None or len(raw) == 0:
        return pd.DataFrame(columns=[
            "position_id", "symbol", "direction", "volume", "open_time", "open_price",
            "close_time", "close_price", "commission", "swap", "profit", "unhandled",
        ])

    df = pd.DataFrame([d._asdict() for d in raw])
    df = df[df["symbol"] == symbol].copy()

    rows = []
    for pid, grp in df.groupby("position_id"):
        in_rows = grp[grp["entry"] == mt5.DEAL_ENTRY_IN]
        out_rows = grp[grp["entry"] == mt5.DEAL_ENTRY_OUT]
        if len(in_rows) == 1 and len(out_rows) == 1:
            in_row, out_row = in_rows.iloc[0], out_rows.iloc[0]
            rows.append({
                "position_id": pid,
                "symbol": symbol,
                "direction": "BUY" if in_row["type"] == mt5.DEAL_TYPE_BUY else "SELL",
                "volume": in_row["volume"],
                "open_time": pd.to_datetime(in_row["time"], unit="s", utc=True),
                "open_price": in_row["price"],
                "close_time": pd.to_datetime(out_row["time"], unit="s", utc=True),
                "close_price": out_row["price"],
                "commission": in_row["commission"] + out_row["commission"],
                "swap": in_row["swap"] + out_row["swap"],
                "profit": in_row["profit"] + out_row["profit"],
                "unhandled": False,
            })
        else:
            # Partial close, multiple legs on one position, or still-open position
            # caught mid-history. Flag rather than guess.
            rows.append({
                "position_id": pid, "symbol": symbol, "direction": None, "volume": None,
                "open_time": None, "open_price": None, "close_time": None, "close_price": None,
                "commission": None, "swap": None, "profit": None, "unhandled": True,
            })
    return pd.DataFrame(rows)


def reconcile_pairs(
    spot_trades: "pd.DataFrame",
    fut_trades: "pd.DataFrame",
    tolerance_seconds: int = 300,
) -> "tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]":
    """
    Greedy nearest-time match: for each spot trade (earliest open_time first),
    find the closest unused futures trade with equal volume, opposite direction,
    and open_time within tolerance_seconds. Returns (pairs, unmatched_spot,
    unmatched_futures) -- unmatched trades are reported, never silently dropped.

    entry_basis / exit_basis follow 02_quant/11_SPREAD_DEFINITION.md exactly:
      CONVERGENCE (spot BUY / futures SELL): basis = futures_price - spot_price
      REVERSE     (spot SELL / futures BUY): basis = spot_price - futures_price
    """
    spot = spot_trades[~spot_trades["unhandled"]].sort_values("open_time").reset_index(drop=True)
    fut = fut_trades[~fut_trades["unhandled"]].sort_values("open_time").reset_index(drop=True)

    used_fut_idx: set = set()
    pairs = []
    unmatched_spot_rows = []

    for _, srow in spot.iterrows():
        best_idx, best_dt = None, None
        for j, frow in fut.iterrows():
            if j in used_fut_idx:
                continue
            if frow["volume"] != srow["volume"] or frow["direction"] == srow["direction"]:
                continue
            dt = abs((srow["open_time"] - frow["open_time"]).total_seconds())
            if dt <= tolerance_seconds and (best_dt is None or dt < best_dt):
                best_idx, best_dt = j, dt

        if best_idx is None:
            unmatched_spot_rows.append(srow.to_dict())
            continue

        frow = fut.iloc[best_idx]
        used_fut_idx.add(best_idx)
        convergence = srow["direction"] == "BUY"  # buy spot / sell futures
        entry_basis = (frow["open_price"] - srow["open_price"]) if convergence else (srow["open_price"] - frow["open_price"])
        exit_basis = (frow["close_price"] - srow["close_price"]) if convergence else (srow["close_price"] - frow["close_price"])
        pairs.append({
            "spot_position_id": srow["position_id"],
            "fut_position_id": frow["position_id"],
            "direction": "CONVERGENCE (buy spot/sell fut)" if convergence else "REVERSE (sell spot/buy fut)",
            "volume": srow["volume"],
            "open_time_skew_seconds": best_dt,
            "entry_basis": round(entry_basis, 4),
            "exit_basis": round(exit_basis, 4),
            "basis_change": round(exit_basis - entry_basis, 4),
            "duration_hours": round((frow["close_time"] - frow["open_time"]).total_seconds() / 3600, 2),
            "spot_profit": srow["profit"], "fut_profit": frow["profit"],
            "spot_commission": srow["commission"], "fut_commission": frow["commission"],
            "net_pnl": round(srow["profit"] + frow["profit"] + srow["commission"] + frow["commission"], 4),
        })

    unmatched_fut_rows = fut.iloc[[j for j in range(len(fut)) if j not in used_fut_idx]]
    return pd.DataFrame(pairs), pd.DataFrame(unmatched_spot_rows), unmatched_fut_rows


# ---- Currently-open positions and the persistent cross-run pair log (Q-004) -------
#
# reconcile_pairs() above only sees CLOSED trades, reset to whatever the lookback
# window covers each run -- the realized-pair sample never grows beyond one run's
# window. This adds a read-only snapshot of currently-open positions via
# positions_get(), paired the same way closed trades are -- these become the
# "censored" (still accruing holding time) observations for Q-004. Persisting them
# across runs into a stable-PairID ledger is tools/pair_ledger.py's job (it merges
# reconciled_pairs.csv and this section's open_pairs_censored.csv output into
# research/pair_ledger.csv); this module only produces the per-run snapshot.
# Still fully read-only: no order_send/order_check.


def collect_open_positions(symbols: set) -> "pd.DataFrame":
    """Read-only positions_get() snapshot for the given symbols. Never modifies anything."""
    positions = mt5.positions_get()
    if positions is None:
        positions = ()
    now = datetime.now(timezone.utc)
    rows = []
    for p in positions:
        row = p._asdict()
        if row.get("symbol") not in symbols:
            continue
        opened = datetime.fromtimestamp(row["time"], tz=timezone.utc)
        rows.append({
            "position_id": row.get("ticket"),
            "symbol": row.get("symbol"),
            "direction": "BUY" if row.get("type") == mt5.POSITION_TYPE_BUY else "SELL",
            "volume": row.get("volume"),
            "open_time": opened,
            "open_price": row.get("price_open"),
            "price_current": row.get("price_current"),
            "profit": row.get("profit"),
            "duration_hours": round((now - opened).total_seconds() / 3600, 4),
        })
    return pd.DataFrame(rows, columns=[
        "position_id", "symbol", "direction", "volume", "open_time",
        "open_price", "price_current", "profit", "duration_hours",
    ])


def match_open_pairs(
    open_positions: "pd.DataFrame",
    spot_symbol: str = SPOT_SYMBOL,
    futures_symbol: str = FUTURES_SYMBOL,
    tolerance_seconds: int = 300,
) -> "tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]":
    """
    Same greedy nearest-time matching as reconcile_pairs(), applied to currently-OPEN
    positions instead of closed ones -- these become "censored" observations for
    Q-004 (still accruing holding time, no exit yet). Returns (matched, unmatched_spot,
    unmatched_futures); an unmatched single-leg open position is a live, real R-003
    candidate (an apparently orphaned leg) and must not be silently dropped.
    """
    empty = pd.DataFrame(columns=[
        "pair_id", "spot_position_id", "fut_position_id", "direction", "volume",
        "open_time_skew_seconds", "entry_basis", "duration_hours_at_snapshot", "status",
    ])
    if open_positions.empty:
        return empty, pd.DataFrame(), pd.DataFrame()

    spot = open_positions[open_positions["symbol"] == spot_symbol].sort_values("open_time").reset_index(drop=True)
    fut = open_positions[open_positions["symbol"] == futures_symbol].reset_index(drop=True)

    used_fut_idx: set = set()
    rows = []
    unmatched_spot_rows = []
    for _, srow in spot.iterrows():
        best_idx, best_dt = None, None
        for j, frow in fut.iterrows():
            if j in used_fut_idx:
                continue
            if frow["volume"] != srow["volume"] or frow["direction"] == srow["direction"]:
                continue
            dt = abs((srow["open_time"] - frow["open_time"]).total_seconds())
            if dt <= tolerance_seconds and (best_dt is None or dt < best_dt):
                best_idx, best_dt = j, dt
        if best_idx is None:
            unmatched_spot_rows.append(srow.to_dict())
            continue
        frow = fut.iloc[best_idx]
        used_fut_idx.add(best_idx)
        convergence = srow["direction"] == "BUY"
        entry_basis = (frow["open_price"] - srow["open_price"]) if convergence else (srow["open_price"] - frow["open_price"])
        rows.append({
            "pair_id": f"{srow['position_id']}_{frow['position_id']}",
            "spot_position_id": srow["position_id"],
            "fut_position_id": frow["position_id"],
            "direction": "CONVERGENCE (buy spot/sell fut)" if convergence else "REVERSE (sell spot/buy fut)",
            "volume": srow["volume"],
            "open_time_skew_seconds": best_dt,
            "entry_basis": round(entry_basis, 4),
            "duration_hours_at_snapshot": max(srow["duration_hours"], frow["duration_hours"]),
            "status": "open",
        })
    unmatched_fut_rows = fut.iloc[[j for j in range(len(fut)) if j not in used_fut_idx]]
    return pd.DataFrame(rows), pd.DataFrame(unmatched_spot_rows), unmatched_fut_rows


def _main_with_pairs(lookback_days: int, tolerance_seconds: int) -> None:
    """
    Read-only: reconstructs every closed spot/futures pair from account deal
    history and writes the reconciliation to research/<timestamp>/. Never calls
    order_send/order_check. Does not place, modify, or close anything.
    """
    connect()
    try:
        run_dir = OUTPUT_ROOT / datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
        run_dir.mkdir(parents=True, exist_ok=True)

        utc_to = datetime.now(tz=timezone.utc)
        utc_from = utc_to - timedelta(days=lookback_days)

        print(f"\n--- Closed-trade history, last {lookback_days} days ---")
        spot_trades = collect_closed_trades(SPOT_SYMBOL, utc_from, utc_to)
        fut_trades = collect_closed_trades(FUTURES_SYMBOL, utc_from, utc_to)
        print(f"  {SPOT_SYMBOL}: {len(spot_trades)} closed positions "
              f"({int(spot_trades['unhandled'].sum())} unhandled)")
        print(f"  {FUTURES_SYMBOL}: {len(fut_trades)} closed positions "
              f"({int(fut_trades['unhandled'].sum())} unhandled)")
        spot_trades.to_csv(run_dir / f"closed_trades_{SPOT_SYMBOL}.csv", index=False)
        fut_trades.to_csv(run_dir / f"closed_trades_{FUTURES_SYMBOL}.csv", index=False)

        print(f"\n--- Pair reconciliation (tolerance={tolerance_seconds}s) ---")
        pairs, unmatched_spot, unmatched_fut = reconcile_pairs(spot_trades, fut_trades, tolerance_seconds)
        pairs.to_csv(run_dir / "reconciled_pairs.csv", index=False)
        unmatched_spot.to_csv(run_dir / "unmatched_spot_trades.csv", index=False)
        unmatched_fut.to_csv(run_dir / "unmatched_futures_trades.csv", index=False)

        print(f"  Matched pairs: {len(pairs)}")
        print(f"  Unmatched spot trades: {len(unmatched_spot)}")
        print(f"  Unmatched futures trades: {len(unmatched_fut)}")
        if len(pairs):
            print(f"  Net P&L across matched pairs: {pairs['net_pnl'].sum():.2f}")
            print(pairs.to_string(index=False))

        print("\n--- Currently-open positions (censored observations) ---")
        open_positions = collect_open_positions({SPOT_SYMBOL, FUTURES_SYMBOL})
        open_pairs, unmatched_open_spot, unmatched_open_fut = match_open_pairs(
            open_positions, SPOT_SYMBOL, FUTURES_SYMBOL, tolerance_seconds
        )
        open_positions.to_csv(run_dir / "open_positions_censored.csv", index=False)
        open_pairs.to_csv(run_dir / "open_pairs_censored.csv", index=False)
        print(f"  Open positions: {len(open_positions)}  Matched open pairs: {len(open_pairs)}")
        if len(unmatched_open_spot) or len(unmatched_open_fut):
            print(
                f"  WARNING: {len(unmatched_open_spot)} unmatched open spot leg(s), "
                f"{len(unmatched_open_fut)} unmatched open futures leg(s) -- a real, live "
                "single-leg position with no matching opposite-direction leg. This looks like "
                "an R-003 orphan-leg candidate; verify directly in the terminal."
            )

        print(f"\nAll outputs written to: {run_dir}")
        print(
            "NEXT STEP: review reconciled_pairs.csv, open_pairs_censored.csv, and the unmatched_*\n"
            "files, then hand-transcribe any material change into\n"
            "docs/02_quant/14_TRANSACTION_COST_MODEL.md and docs/OPEN_QUESTIONS.md Q-004.\n"
            "Run tools/pair_ledger.py against this run's reconciled_pairs.csv and\n"
            "open_pairs_censored.csv to grow the persistent Q-004 sample in research/pair_ledger.csv\n"
            "beyond this one lookback window. Do NOT commit the research/ folder contents."
        )
    finally:
        disconnect()


if __name__ == "__main__":
    args = parse_args()
    if args.days is not None:
        TICK_HISTORY_DAYS = args.days
    if args.tolerance_ms is not None:
        TICK_SYNC_TOLERANCE_MS = args.tolerance_ms

    if args.ticks or args.evidence:
        _main_with_ticks()
    elif args.pairs:
        _main_with_pairs(args.pair_lookback_days, args.pair_tolerance_seconds)
    else:
        main()
