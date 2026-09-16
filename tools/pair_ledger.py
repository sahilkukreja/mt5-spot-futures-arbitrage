#!/usr/bin/env python3
"""Maintain a persistent, cross-run ledger of reconciled spot/futures pairs for Q-004.

Read-only/offline, like the other tools in this directory: it never connects to MT5 and never
places an order. It consumes `reconciled_pairs.csv` (and optionally `open_positions_censored.csv`)
already produced by `mt5_data_collector.py --pairs`, and merges them into a durable ledger keyed by
a stable PairID -- so the realized-pair time-to-convergence sample (Q-004) keeps growing across
repeated runs over the coming weeks instead of resetting to whatever a single run's account-history
window happens to cover.

PairID = f"{spot_position_id}_{fut_position_id}". MT5 position IDs (tickets) are unique and
immutable once assigned, so this ID is stable across runs without inventing a new identifier
scheme -- it is the same pairing `reconciled_pairs.csv` already establishes, just persisted.

A pair already in the ledger as OPEN is upserted to CLOSED once a later run's `reconciled_pairs.csv`
reports it closed -- this preserves the original open-time observation instead of silently dropping
it, consistent with `q3_q4_research.py`'s existing censored-observation handling (a closed pair must
never retroactively look like it was always closed; the ledger keeps `first_seen_open_utc`).

Example:
    python tools/pair_ledger.py \
        --reconciled-csv research/2026-09-15T190918Z/reconciled_pairs.csv \
        --censored-csv research/2026-09-15T190918Z/open_positions_censored.csv \
        --ledger research/pair_ledger.csv

Re-run this against each new `--pairs` collection run's output; the ledger accumulates in place.
`research/` is gitignored like all other raw research output -- periodically promote the ledger's
summary stats into `docs/02_quant/13_BASIS_MODEL.md` by hand, the same way every other research
artifact in this project is promoted, rather than treating the ledger file itself as source of truth.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

LEDGER_COLUMNS = [
    "pair_id",
    "spot_position_id",
    "fut_position_id",
    "direction",
    "volume",
    "status",
    "entry_basis",
    "exit_basis",
    "basis_change",
    "duration_hours",
    "net_pnl",
    "first_seen_open_utc",
    "last_updated_utc",
]


def load_reconciled(path: Path) -> pd.DataFrame:
    required = {"spot_position_id", "fut_position_id", "direction", "volume", "entry_basis",
                "exit_basis", "basis_change", "duration_hours", "net_pnl"}
    frame = pd.read_csv(path)
    missing = required - set(frame.columns)
    if missing:
        raise ValueError(f"{path} is missing required columns: {sorted(missing)}")
    frame = frame.copy()
    frame["pair_id"] = frame["spot_position_id"].astype(str) + "_" + frame["fut_position_id"].astype(str)
    frame["status"] = "CLOSED"
    return frame[["pair_id", "spot_position_id", "fut_position_id", "direction", "volume", "status",
                  "entry_basis", "exit_basis", "basis_change", "duration_hours", "net_pnl"]]


def load_censored_pairs(path: Path | None) -> pd.DataFrame:
    """Best-effort: only produces rows if the censored CSV contains both legs of an open pair.

    `open_positions_censored.csv` is per-leg (one row per open position), not per-pair, so this
    pairs same-timestamp opposite-direction rows across the two known symbols. If the schema or
    contents don't support that (e.g. only one leg present, or the file is empty), it returns an
    empty frame rather than guessing -- an incompletely-paired open position must not silently
    enter the ledger as a fabricated pair.
    """
    empty = pd.DataFrame(columns=["pair_id", "spot_position_id", "fut_position_id", "direction",
                                   "volume", "status", "entry_basis", "exit_basis", "basis_change",
                                   "duration_hours", "net_pnl"])
    if path is None or not path.exists() or not path.read_text(encoding="utf-8").strip():
        return empty
    frame = pd.read_csv(path)
    if frame.empty or "symbol" not in frame.columns:
        return empty

    symbols = frame["symbol"].unique().tolist()
    spot_rows = frame[frame["symbol"].str.contains("XAU", case=False, na=False)]
    fut_rows = frame[~frame["symbol"].str.contains("XAU", case=False, na=False)]
    if spot_rows.empty or fut_rows.empty:
        return empty

    rows = []
    for _, spot in spot_rows.iterrows():
        for _, fut in fut_rows.iterrows():
            rows.append({
                "pair_id": f"{spot['position_id']}_{fut['position_id']}",
                "spot_position_id": spot["position_id"],
                "fut_position_id": fut["position_id"],
                "direction": "CONVERGENCE (buy spot/sell fut) — open, unconfirmed pairing by symbol only",
                "volume": spot.get("volume"),
                "status": "OPEN",
                "entry_basis": None,
                "exit_basis": None,
                "basis_change": None,
                "duration_hours": spot.get("duration_hours"),
                "net_pnl": None,
            })
    return pd.DataFrame(rows, columns=list(empty.columns)) if rows else empty


def merge_ledger(existing: pd.DataFrame, new_closed: pd.DataFrame, new_open: pd.DataFrame, now_iso: str) -> pd.DataFrame:
    combined_new = pd.concat([new_closed, new_open], ignore_index=True) if not new_open.empty else new_closed
    if existing.empty:
        combined_new["first_seen_open_utc"] = now_iso
        combined_new["last_updated_utc"] = now_iso
        return combined_new[LEDGER_COLUMNS]

    existing = existing.set_index("pair_id")
    combined_new = combined_new.set_index("pair_id")

    for pair_id, row in combined_new.iterrows():
        if pair_id in existing.index:
            first_seen = existing.loc[pair_id, "first_seen_open_utc"]
            for col in ["direction", "volume", "status", "entry_basis", "exit_basis", "basis_change",
                        "duration_hours", "net_pnl", "spot_position_id", "fut_position_id"]:
                existing.loc[pair_id, col] = row[col]
            existing.loc[pair_id, "first_seen_open_utc"] = first_seen
            existing.loc[pair_id, "last_updated_utc"] = now_iso
        else:
            new_row = row.copy()
            new_row["first_seen_open_utc"] = now_iso
            new_row["last_updated_utc"] = now_iso
            existing.loc[pair_id] = new_row

    return existing.reset_index()[LEDGER_COLUMNS]


def summarize(ledger: pd.DataFrame) -> dict:
    closed = ledger[ledger["status"] == "CLOSED"].copy()
    closed["duration_hours"] = pd.to_numeric(closed["duration_hours"], errors="coerce")
    closed = closed[closed["duration_hours"].notna()]
    open_count = int((ledger["status"] == "OPEN").sum())
    if closed.empty:
        return {"closed_pairs": 0, "open_pairs": open_count, "duration_hours": None}
    return {
        "closed_pairs": int(len(closed)),
        "open_pairs": open_count,
        "duration_hours": {
            "min": round(float(closed["duration_hours"].min()), 2),
            "median": round(float(closed["duration_hours"].median()), 2),
            "mean": round(float(closed["duration_hours"].mean()), 2),
            "max": round(float(closed["duration_hours"].max()), 2),
        },
        "profitable_pairs": int((pd.to_numeric(closed["net_pnl"], errors="coerce") > 0).sum()),
        "loss_making_pairs": int((pd.to_numeric(closed["net_pnl"], errors="coerce") < 0).sum()),
        "date_span": [ledger["first_seen_open_utc"].min(), ledger["last_updated_utc"].max()],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Persistent cross-run ledger of reconciled pairs (Q-004).")
    parser.add_argument("--reconciled-csv", type=Path, required=True, help="reconciled_pairs.csv from this run")
    parser.add_argument("--censored-csv", type=Path, help="open_positions_censored.csv from this run, if any")
    parser.add_argument("--ledger", type=Path, default=Path("research/pair_ledger.csv"),
                         help="Persistent ledger path (default: research/pair_ledger.csv)")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    existing = pd.read_csv(args.ledger) if args.ledger.exists() else pd.DataFrame(columns=LEDGER_COLUMNS)
    new_closed = load_reconciled(args.reconciled_csv)
    new_open = load_censored_pairs(args.censored_csv)

    now_iso = datetime.now(timezone.utc).isoformat()
    ledger = merge_ledger(existing, new_closed, new_open, now_iso)

    args.ledger.parent.mkdir(parents=True, exist_ok=True)
    ledger.to_csv(args.ledger, index=False)

    summary = summarize(ledger)
    print(f"Ledger written: {args.ledger} ({len(ledger)} total pairs)")
    print(summary)


if __name__ == "__main__":
    main()
