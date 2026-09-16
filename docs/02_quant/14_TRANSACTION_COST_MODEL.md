# Transaction Cost Model

Status: IN PROGRESS — partial. Spread cost and futures commission are sourced; spot commission, slippage,
and rollover mechanics remain unresolved (Q-002). One material, previously-undocumented finding: **swap cost
is asymmetric between the two legs and is large relative to the raw gap over any holding period longer than
a few days.** No Net Executable Edge can be signed yet — this document establishes a cost floor and the
single biggest open uncertainty, not a go/no-go conclusion.

## Objective

Compute the true net executable edge by subtracting all real costs from the raw spread (`11_SPREAD_DEFINITION.md`),
per `docs/PROJECT_MANDATE.md` → "TRUE NET EDGE". Reject the trade if edge is small relative to cost
uncertainty (this skill's own instruction) — which, per the finding below, cannot yet be ruled out.

## Scope / definitions

Uses `02_quant/11_SPREAD_DEFINITION.md`'s convergence trade: **BUY `XAUUSD.vx` (spot) / SELL `GC-Z26` (futures)**,
entering at `convergence_basis = Bid(GC-Z26) − Ask(XAUUSD.vx)`. At 0.01 lot with contract size 100 (both
symbols), 1.00 of price movement = $1.00 P/L (established in `16_HEDGE_RATIO.md`) — so all costs below are
computed directly in USD at 0.01 lot by treating price-point costs as dollar-equivalent 1:1.

## Evidence (sourced, 2026-09-15)

Two sources, both from `tools/mt5_data_collector.py` default-mode runs (read-only, no order placed):
`research/2026-09-15T170138Z/` (margin/gap-history run) and `research/2026-09-15T172247Z/symbol_specs.json`
(full `symbol_info()` dump — not previously mined beyond the fields already in `07_BROKER_RESEARCH.md`).

| Field | `XAUUSD.vx` | `GC-Z26` | Source |
|---|---|---|---|
| Spread (live, 2026-09-15) | 30 points (0.30) | 30 points (0.30) | `symbol_specs.json` `spread` field |
| `swap_mode` | 1 (`SYMBOL_SWAP_MODE_POINTS`) | 0 (`SYMBOL_SWAP_MODE_DISABLED`) | `symbol_specs.json` |
| `swap_long` / `swap_short` | −60.0 / +40.0 points/day | 0.0 / 0.0 | `symbol_specs.json` |
| `swap_rollover3days` | 3 (Wednesday) | 3 (irrelevant — swap disabled) | `symbol_specs.json` |
| Commission | not captured for spot (Q-002) | **$10/lot, round-trip total** (updated 2026-09-15 from live account trade history — supersedes the earlier $7.50/lot "in/out" spec-window reading) | `07_BROKER_RESEARCH.md` |
| Quote/profit currency | USD/USD | USD/USD | `07_BROKER_RESEARCH.md` — no FX conversion needed |
| Live bid/ask (2026-09-15, this run) | 4292.93 / 4293.23 | 4333.30 / 4333.60 | `symbol_specs.json` |
| Resulting convergence_basis | 4333.30 − 4293.23 = **40.07** | | calculation |
| Days to `GC-Z26` expiry (25 Nov 2026) from today (2026-09-15) | **71 days** | | calculation |

**Note on gold price movement:** the underlying price has moved materially since the 2026-09-11/12 snapshots
in `07_BROKER_RESEARCH.md` (~4347 → ~4293), yet the convergence gap is still ~40, close to the earlier ~41.8
mean from the M1-bar study in `11_SPREAD_DEFINITION.md`. This is a data point (not yet a validated pattern)
consistent with the gap behaving like a carry-driven quantity that doesn't move 1:1 with the underlying price —
relevant to `12_FAIR_VALUE_MODEL.md`, still NOT STARTED.

## Cost components

| Component | Value | Status |
|---|---|---|
| Spot spread cost (round trip) | ~~$0.30~~ → **$0.1545** mean at 0.01 lot | **Sourced as a full distribution 2026-09-16** — see "Spread, measured properly" below |
| Futures spread cost (round trip) | ~~$0.30~~ → **$0.2430** mean at 0.01 lot | **Sourced as a full distribution 2026-09-16** — same |
| Futures commission (round trip, total) | $10 × 0.01 = **$0.10** | Sourced, confirmed fixed 2026-09-15 (see below) |
| Spot commission | **$0.00** | Sourced 2026-09-15 — **Q-002 partially resolved** |
| Swap — spot leg (long, held) | −60 pts/day = **−$0.60/day**; ×3 on the Wednesday rollover = **−$1.80** that day | Sourced |
| Swap — futures leg (short, held) | **$0.00/day** — `swap_mode=0`, confirmed disabled | Sourced (new finding this run) |
| Financing/carry (embedded, not daily swap) | Not separable from the basis itself yet — `12_FAIR_VALUE_MODEL.md` NOT STARTED | Blocked |
| Rollover mechanism/cost near expiry | Settlement type now known (cash-settled CFD, `trade_calc_mode=SYMBOL_CALC_MODE_CFD`); rollover *timing/mechanics* still undocumented — no machine-readable expiry field exists | **Partially resolved, still blocked on Q-002 for timing/mechanics** |
| Slippage (entry/exit) | Not measured — no live execution has occurred | Blocked — needs Phase 1 (demo/live) data |
| Latency uncertainty | Not measured | Blocked — needs Phase 1 data |
| FX conversion | **$0.00** — both legs quote/settle in USD | Resolved |
| Execution-risk buffer | Not set — mandate requires this be tied to measured execution data, not chosen arbitrarily | Blocked |

## Spread, measured properly (2026-09-16) — supersedes the two snapshot values

The $0.30/leg figures above came from single live readings of the `spread` field. The full terminal tick
exports now give the actual distribution, per leg, across every quoted tick in a 45-day window. Source:
`research/export-full/basis_summary.json` via `tools/tick_export_loader.py`.

| Leg | n ticks | mean | median | p95 | p99 | p99.9 | max |
|---|---:|---:|---:|---:|---:|---:|---:|
| `XAUUSD.vx` (spot) | 8,798,113 | **0.1545** | 0.15 | 0.15 | 0.15 | 2.13 | **12.15** |
| `GC-Z26` (futures) | 6,520,722 | **0.2430** | 0.24 | 0.25 | 0.25 | 0.44 | **5.04** |

Two findings, pulling in opposite directions:

1. **Typical spread is roughly half what was assumed.** Combined round-trip spread is **$0.3975**, not $0.60.
   Both legs quote at a near-constant floor — spot's p99 equals its median exactly, and the futures p99 is one
   cent above its median. For ordinary conditions this is close to a *fixed* cost, not a variable one.
2. **The tail is far worse than assumed, and was completely invisible in the snapshots.** Spot spread reaches
   $12.15 — 81× its median, and 40× the $0.30 that was being used as a worst case. Futures reaches $5.04.

Because the distribution is near-degenerate until it isn't, a spread gate is unusually cheap and unusually
effective here: rejecting entry when either leg's spread exceeds, say, 2× its median would reject well under
1% of ticks while eliminating the entire tail. **No such threshold is proposed as a value** — it belongs in
`15_SIGNAL_RESEARCH.md` / `24_RISK_ENGINE.md` and needs its own derivation. The point for this document is
that the cost is now a measured distribution rather than a point estimate, and its shape matters.

## Calculation: cost floor vs. holding period

**Same-day round trip, known costs only** (spread + futures commission + spot commission, now fully sourced
at $0; still excludes slippage, rollover, and execution-risk buffer), using the **measured** spreads:

```
$0.1545 (spot spread) + $0.2430 (futures spread) + $0.10 (futures commission) = $0.4975
```

(The superseded figure was $0.70, using $0.30/leg. The tables immediately below still use the old $0.70 floor;
they are left as-is because the swap term dominates them entirely and the $0.20 difference does not change
any conclusion they draw. The corrected floor is used in `17_EXPECTED_VALUE.md`.)

This alone looks favorable. It is not the real picture, because of the swap asymmetry above: **only the spot
leg pays daily swap; the futures leg pays none.** Every day the position is held costs the trade ~$0.60
(≈$1.80 on the weekly Wednesday triple-swap) with nothing recovered from the short futures leg. Cumulative
effect (7 calendar days per week, 1 Wednesday per week, $0.70 fixed cost included once):

| Holding period | Cumulative spot swap | Total known cost | % of 40.07 gap |
|---|---|---|---|
| 1 day | $0.60 | $1.30 | 3.2% |
| 5 days (1 Wed) | $4.20 | $4.90 | 12.2% |
| 10 days (1–2 Wed) | ≈$6.60–7.20 | ≈$7.30–7.90 | 18–20% |
| 20 days (≈3 Wed) | ≈$15.60 | ≈$16.30 | 41% |
| 30 days (≈4 Wed) | ≈$22.80 | ≈$23.50 | **59%** |
| 71 days (to `GC-Z26` expiry, ≈10 Wed) | ≈$53.85 | ≈$54.55 | **> 100% of the current gap** |

**Headline finding:** at the current swap rate, holding this specific convergence position for the full
remaining life of the `GC-Z26` contract would cost more in one-sided spot swap alone than the entire
observed gap — before spot commission, slippage, or any execution-risk buffer are even added. This does not
mean the trade is unviable; it means **time to convergence is the dominant unresolved variable**, not spread
or commission (which are individually small). A trade held only a few days faces a very different cost
picture than one held for weeks.

> **Update 2026-09-16 — the caveat in that paragraph is now resolved, against the trade.** "This does not mean
> the trade is unviable" was the right call on the evidence available then, because the *revenue* side had
> never been measured: the tables above compare cost against the basis **level**, but the trade only earns the
> basis **change**. That change is now measured at **−$0.3905/day** (95% CI −$0.4480 … −$0.3330, R²=0.83) from
> 5.8M synchronized rows over 45 days. Against −$0.7714/day of one-sided spot swap, net carry is
> **−$0.3809/day** and the confidence interval does not touch zero. Time to convergence is therefore no longer
> "the dominant unresolved variable" for this structure — it is resolved, and the answer is that no overnight
> holding period works. Full derivation in `17_EXPECTED_VALUE.md` → "Correction 2026-09-16". Intraday holds,
> which pay no swap at all, are not covered by this finding and remain open.

## Real paired-trade evidence (2026-09-15) — automated reconciliation, n=7

The manual screenshot review (below, superseded) found 6 pairs and mislabeled a 7th trade (`34226815`) as
unrelated. `tools/mt5_data_collector.py --pairs` (new, this session) pulls the **full** account deal history
via `mt5.history_deals_get()` (read-only) and reconstructs every closed spot/futures pair automatically —
removing the sample-size cap imposed by "whatever happened to be visible in a screenshot." It found the same
6 pairs, **plus a 7th**: `34226815`/`34226816` — the very first `GC-Z26` trade *does* have a matching spot
leg, opened at the identical timestamp, that wasn't visible in the second screenshot's cropped range.

All 8 closed positions per symbol resolved cleanly except 1 per symbol (see "Currently open pair" below —
not a data-quality problem, an actually-open position). Full reconciliation
(`research/2026-09-15T181429Z/reconciled_pairs.csv`):

| Pair (spot / futures ticket) | Entry basis | Exit basis | Basis moved | Duration | Net P&L |
|---|---|---|---|---|---|
| 34226816 / 34226815 | 42.05 | 41.47 | narrowed −0.58 | ~3h05m | **+$0.42** |
| 34227092 / 34227091 | 40.16 | 40.31 | widened +0.15 | ~12h44m | **−$0.31** |
| 34227214 / 34227213 | 41.01 | 40.31 | narrowed −0.70 | ~11h08m | **+$0.54** |
| 34229071 / 34229070 | 39.79 | 39.86 | widened +0.07 | ~11h18m | **−$0.17** |
| 34229105 / 34229104 | 41.32 | 39.93 | narrowed −1.39 | ~11h08m | **+$1.29** |
| 34229107 / 34229106 | 39.77 | 39.96 | widened +0.19 | ~11h08m | **−$0.29** |
| 34229430 / 34229429 | 40.15 | 39.96 | narrowed −0.19 | ~8h53m | **+$0.09** |

Every row reconciles exactly to (basis change) + (commission), confirming `11_SPREAD_DEFINITION.md`'s formula
against real fills. **Net across all 7 pairs: +$1.57 after commission**, over 2026-09-11 through 2026-09-15
(~4 days), mean duration ~9.9 hours, entry basis range 39.77–42.05 (mean ≈40.6). 4 of 7 pairs profitable, 3
lost money.

**What this does and doesn't establish** (same conclusion as before, now on a slightly larger and complete
sample): this is real executable-price evidence of the exact strategy, not a snapshot or approximation — but
**n=7 over ~4 days is still nowhere near enough** to conclude positive expected value. Basis moves (0.07–1.39)
are comparable in size to round-trip cost, so realized P&L is dominated by small-sample noise, not a
validated edge. Does not resolve Q-004 — says nothing about multi-week holding behavior.

## Currently open positions (live, re-checked 2026-09-16 — materially more than previously documented)

`positions_get()` (read-only) on 2026-09-15 showed one open pair. **Re-checked live 2026-09-16: four pairs
are now open concurrently** (8 positions total), all the standard convergence trade (BUY `XAUUSD.vx` / SELL
`GC-Z26`, 0.01 lot each):

| Pair (fut ticket / spot ticket) | Entry basis | Opened (epoch) |
|---|---|---|
| 34232433 / 34232434 | 40.78 | 1789565387 |
| 34232481 / 34232482 | 40.97 | 1789567978 |
| 34232580 / 34232581 | 42.26 | 1789569912 |
| 34232582 / 34232583 | 43.06 | 1789569923 |

Current live basis at check time: `convergence_basis` (Bid `GC-Z26` − Ask `XAUUSD.vx`) = **40.82**, consistent
with the tick-level distribution already documented (mean 41.43). Account snapshot: balance $999.02, equity
$1,000.61, **margin $524.56 (4 pairs × ≈$131 each), margin free $476.05, margin level ≈191%** — a material
drop from the ≈700–770% margin level calculated for a single 0.01/0.01 pair earlier in this document, because
margin utilization scales with the number of concurrent pairs. Still nowhere near the broker's stop-out level
(`margin_so_call=100%`, `margin_so_so=50%`, per `account_info()`), but this is a real, live reduction in the
account's stress buffer that the earlier single-pair margin analysis (`01_research/07_BROKER_RESEARCH.md`,
`RISK_REGISTER.md` R-001/margin-stress-multiplier candidate) did not model. As before: no automated system
exists under this project (no MQL5 has been written), so this is not this project's output — origin/rationale
for the 3 additional concurrent pairs opened since 2026-09-15 is unknown. The mandate's `INITIAL CAPITAL
PROTECTION` section specifies "one hedge pair at a time initially" for this project's own future live testing;
that this account already runs 4 concurrently, outside this project's control, is noted factually, not as
something this project has done or endorses.

## Discrepancy — resolved

The earlier flagged mismatch (-$0.10 vs -$0.16 per futures leg) is a real historical rate change, not
measurement noise: **$16/lot round trip on trades opened before 2026-09-14, corrected to $10/lot since.**
The 3 trades showing -$0.16 (`34227091`, `34227213`, plus standalone `34226815`) were all opened 2026-09-11
through 2026-09-14 01:11; every trade opened from 2026-09-14 15:22 onward shows -$0.10. Confirmed via a
second account-history view with an explicit `Commission` column. Treat $10/lot round trip as the current,
stable rate going forward; the table above already uses it.

## Assumptions (flagged as assumptions, not sourced facts)

- `point = 0.01` for both symbols (from `digits=2` and `trade_tick_size=0.01`, both directly sourced) — used
  to convert quoted swap "points" into the same price units as the basis. Not independently double-checked
  against a documented "1 point = X price units" statement from the broker beyond the `symbol_info()` fields.
- Swap accrues once per calendar day the position is held overnight, with the standard MT5 triple-charge on
  the day indicated by `swap_rollover3days=3` (Wednesday) to cover the weekend. Not confirmed against an
  actual multi-day held position (no position has ever been opened by this project).
- ~~The `$7.50` futures commission is charged on both entry and exit ("in/out" per `07_BROKER_RESEARCH.md`) —
  read literally from the spec window's wording, not independently confirmed by an actual filled trade.~~
  **Superseded — no longer an assumption.** See "Discrepancy — resolved" above: real deal history with an
  explicit `Commission` column confirms **$10/lot round trip total** (not $7.50 in/out) for trades opened from
  2026-09-14 onward. This bullet is kept struck through rather than deleted so the correction is visible; do
  not cite the $7.50 figure going forward.

## Hypotheses (unproven, need `12_FAIR_VALUE_MODEL.md`/`13_BASIS_MODEL.md` to test)

- The ~40 gap may be substantially explained by the market's own pricing of the asymmetric carry (futures
  priced to reflect that a synthetic long-spot-financed-to-expiry position would cost something like the
  observed swap), i.e. much of it could be **expected**, not abnormal/exploitable — directly the mandate's
  "EXPECTED vs ABNORMAL" question, still open.
- The gap may not decay smoothly toward zero as expiry approaches; it might jump, stay wide until late, or
  overshoot. No time-to-convergence data exists yet to test this.

## Q-002 update (2026-09-16) — settlement/rollover partially resolved, price source and position-restriction still open

Source: `research/2026-09-15T190918Z/symbol_specs.json` (`symbol_info()` dump, already partially mined for
swap fields above; these fields were not previously read for Q-002).

- **`GC-Z26` settlement mechanism — resolved as far as the API can answer.** `trade_calc_mode = 2`, and the
  collector's own human-readable annotation confirms `_trade_calc_mode_name = "SYMBOL_CALC_MODE_CFD"` — this
  is a **cash-settled CFD tracking a futures reference price**, not a delivery-linked or exchange-cleared
  futures contract, directly from the broker's own calculation-mode field (not the marketing name/description,
  which was the only prior evidence). This matters beyond bookkeeping: standard cost-of-carry / convenience-
  yield theory assumes a real deliverable contract; a CFD's basis can instead reflect the broker's own
  synthetic-quote construction — see the caveat added to `12_FAIR_VALUE_MODEL.md`'s implied-carry finding.
- **`GC-Z26` rollover mechanics — still open, and now with a specific, concrete gap.** `expiration_time = 0` in
  the live `symbol_info()` dump, despite the symbol's own `description` field stating "Gold December 2026
  Futures - Exp 25 Nov 2026". (Do not confuse this with `expiration_mode = 15`, which is a bitmask of which
  *order*-expiration types — GTC/day/specified — the symbol supports; it says nothing about the *contract's*
  own expiry.) **Finding: the contract's expiry date is not mechanically readable from the API's dedicated
  expiry field** — it currently only exists as free text in `description`/`name`. This means no code can
  currently detect an approaching rollover or a symbol substitution purely from `symbol_info()`; monitoring
  must rely on parsing the name/description string or on manual/broker-support confirmation. This is a
  concrete instance of the exact risk `docs/RISK_REGISTER.md` R-005 already describes generically — flagged
  there now with this specific evidence.
- **`XAUUSD.vx` price source — still open, evidence is weak and flagged as unreliable.** `symbol_specs.json`
  lists `exchange: "CME"` for `XAUUSD.vx`, but spot gold (`XAUUSD`) is not a CME-listed instrument (CME lists
  gold *futures*, not spot) — this field is almost certainly a broker template/default value carried over from
  the futures symbol's categorization, not a genuine liquidity-provider disclosure. **Do not treat this field
  as resolving the price-source question.** The true price source (which liquidity providers feed
  `XAUUSD.vx`'s quotes) still requires broker documentation or direct support confirmation; nothing in the
  collected data answers it.
- **Opposite-direction position restriction — still fully open.** No field in `symbol_info()` or any other
  collected source speaks to whether VPFX restricts holding simultaneous opposite-direction positions across
  `XAUUSD.vx` and `GC-Z26`. Not answerable without a broker documentation lookup or a support inquiry; not
  fabricated here.

**Net effect on Q-002:** settlement mechanism is now resolved (CFD, sourced from the calc-mode field);
rollover mechanics remain open with a sharper, concrete problem statement (no machine-readable expiry field);
price source and opposite-direction restriction remain open, one of them (price source) with a piece of
evidence now explicitly flagged as unreliable rather than silently missing.

## Unresolved questions this document depends on

- **Q-002** (open, partially advanced — see update above) — spot price source and the broker's opposite-
  direction-position policy remain the two fully open items; rollover mechanics are now a concrete, named gap
  (no machine-readable expiry field) rather than a vague unknown.
- **New: time-to-convergence / expected holding period.** Without this, the swap-cost table above cannot be
  converted into an actual expected cost — only a sensitivity table. `13_BASIS_MODEL.md` now has a
  supplementary tick-level decay proxy alongside the n=7 realized-pair sample, but neither closes this gap on
  its own. See "Decisions proposed" below.

## Risks

- Directly deepens `docs/RISK_REGISTER.md` R-002 ("thin edge consumed by unmodelled costs") — this document
  gives R-002 a specific, sourced mechanism (asymmetric swap) rather than a generic concern. See registry
  update.
- If the strategy's realistic holding period (once `13_BASIS_MODEL.md`/`15_SIGNAL_RESEARCH.md` exist) turns
  out to be on the order of weeks rather than days, this cost alone could dominate the trade's economics
  regardless of how the entry/exit signal is designed.

## Validation data

- `research/2026-09-15T170138Z/margin_required.json`, `gap_summary.json` (M1-bar gap distribution, already
  promoted into `11_SPREAD_DEFINITION.md`)
- `research/2026-09-15T172247Z/symbol_specs.json` (full `symbol_info()` dump; swap fields used above)
- Do not commit these — gitignored working data, cited here as the promoted source of truth.

## Decisions proposed

None. Evidence is insufficient to propose a cost-model decision — the spot commission and rollover/settlement
gaps (Q-002) and the complete absence of time-to-convergence data mean any Net Executable Edge number
computed now would be fabricated. Proposing "trade at gap > $X" thresholds before this data exists would
violate the mandate's "NO MAGIC OAG/CAG VALUES" rule.

## Smallest next empirical test

Two candidates, in order of cost/effort:

1. **Cheapest, do first:** re-read `GC-Z26`'s and `XAUUSD.vx`'s `symbol_info()` for the commission field
   directly (`MqlTradeRequest`/spec window may expose spot commission even though the earlier manual capture
   missed it) — if the MT5 API exposes it the same way it exposed swap here, this could close half of Q-002
   with zero new infrastructure, the same way this document's swap finding was "free" from data already
   collected.
2. **Requires the pending `--ticks` run** (`08_TICK_DATA_COLLECTION.md`, not yet executed): even one week of
   tick data won't give a real time-to-convergence distribution, but it will show whether the gap is stable,
   trending, or noisy intraday — a prerequisite before designing the multi-week observation needed to
   actually measure convergence time.
