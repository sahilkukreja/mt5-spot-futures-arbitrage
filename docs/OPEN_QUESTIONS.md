# Open Questions

Unresolved questions blocking a decision. Remove an entry only when the answer is documented and linked from here;
otherwise refine it as understanding improves.

## Format

### Q-000: <question>
- **Raised:** YYYY-MM-DD
- **Blocks:** which decision/doc this blocks
- **Status:** open | answered (link)

---

## Active

### Q-001: Does `XAUUSD.vx` on VPFX actually require full-notional (no-leverage) margin?
- **Raised:** 2026-09-12
- **Blocks:** `01_research/07_BROKER_RESEARCH.md` conclusion, all `02_quant/` hedge-ratio and margin work,
  and the Phase 0 broker/instrument decision — see `docs/RISK_REGISTER.md` R-001.
- **Status:** answered (see `01_research/07_BROKER_RESEARCH.md` → "Margin findings — resolved"). Live
  `order_calc_margin()` at 0.01 lot gives `XAUUSD.vx` BUY $42.96 / SELL $42.95 and `GC-Z26` BUY $86.72 /
  SELL $86.71, combined ≈ $129.67. This confirms that VPFX is applying a normal leveraged margin-rate
  schedule despite the "Forex No Leverage" calculation-mode label. This resolves the question for this pair
  at 0.01/0.01 lot; revalidate after a contract roll, broker specification change, or margin-tier change.

### Q-002: What is the spot leg's commission, and what are price source/settlement/rollover for the futures leg?
- **Raised:** 2026-09-12
- **Blocks:** `01_research/07_BROKER_RESEARCH.md` completion, `02_quant/14_TRANSACTION_COST_MODEL.md`
- **Status:** partially answered 2026-09-15, further advanced 2026-09-16. Confirmed: `XAUUSD.vx` commission is
  **$0.00** in live deal history; `GC-Z26` commission is **$10 per lot round trip**; at 0.01 lot the futures
  commission is **$0.10 per completed pair**. Approximate full spread crossing from captured quotes is about
  **$0.60** per 0.01/0.01 pair (spot spread ≈ $0.30 + futures spread ≈ $0.30 + futures commission ≈ $0.10), not
  counting swap and slippage. **New 2026-09-16:** `GC-Z26` settlement mechanism is now resolved —
  `symbol_info()`'s own `trade_calc_mode` field reads `SYMBOL_CALC_MODE_CFD` (sourced, not the marketing name),
  confirming a cash-settled CFD, not a delivery-linked contract. Still open: `GC-Z26` rollover *timing/mechanics*
  (the contract's `expiration_time` field reads 0 despite the description stating "Exp 25 Nov 2026" — no
  machine-readable expiry exists, only free text). **Opposite-direction-position restriction: now answered
  2026-09-16, empirically.** `research/2026-09-15T190918Z/reconciled_pairs.csv` and `closed_trades_*.csv` show
  8 real instances (7 closed + 1 open, position IDs 34226815/34226816 through 34231072/34231073) of
  simultaneous BUY `XAUUSD.vx` / SELL `GC-Z26`, all filled, none rejected, across 2026-09-11 through
  2026-09-15 — direct, repeated, real evidence the broker permits this, not just an absence of a documented
  restriction. **`XAUUSD.vx` true price source: still open**, and now confirmed not answerable from public
  sources — one `WebSearch` and two `WebFetch` attempts against VPFX's public site (vpfx.net) and a search for
  broker reviews found only that VPFX is regulated by Malaysia's Labuan FSA (license MB/20/0046) and offers
  MT5-based multi-asset CFDs; no page discloses gold price-feed/liquidity-provider methodology. The `exchange:
  "CME"` field remains flagged as unreliable (see above). This is a genuine broker-support/Client-Agreement
  action item, not something derivable from data already available. See `02_quant/14_TRANSACTION_COST_MODEL.md`
  → "Q-002 update (2026-09-16)".

### Q-003: What are the calibrated values for quote-staleness threshold, orphan-leg timeout, and margin
stress multiplier?
- **Raised:** 2026-09-15
- **Blocks:** `03_system_design/22_STATE_MACHINE.md` and `24_RISK_ENGINE.md` (not yet written) — the Risk
  Engine and Execution Engine state machine sketched in `20_SYSTEM_ARCHITECTURE.md` name these decision
  points but leave every number UNCALIBRATED.
- **Status:** open — partially measured, still uncalibrated, now with candidates proposed for two of the
  three sub-items (2026-09-16). Quote-skew p95 = 384 ms and p99 = 452 ms across 707,467 post-hoc synchronized
  rows; **proposed research candidate 400ms**, explicitly not approved. **New finding: skew alone has a
  confirmed blind spot** — the R-004 anomaly's own skew (238ms) was inside this candidate, so a skew-only gate
  would not have caught it; a per-leg price-velocity check looks like a better-targeted complementary signal
  (the single highest-velocity tick in the entire 7-day dataset, 161.6 pts/sec vs. a p99.9 of 8.08, occurs one
  tick before that exact anomaly) but no numeric velocity threshold is proposed yet — one extreme event isn't
  enough to derive a defensible number. **Margin-stress multiplier: now computed, and the finding is that it's
  not the binding risk at 0.01 lot** — even a 20% adverse price move only adds ≈$26 to the ≈$130 baseline
  margin (margin level stays >600%); the real stress risk at this size is notional directional exposure during
  a leg mismatch (R-003), not margin recalculation. See `01_research/07_BROKER_RESEARCH.md` → "Margin-stress
  multiplier candidate". **Orphan-leg timeout: confirmed still blocked**, no change — no signal-to-fill latency
  data exists without a live/demo execution trial, and nothing in the collected data proxies for it. See
  `02_quant/13_BASIS_MODEL.md` for the quote-staleness/velocity and orphan-leg-timeout write-ups, and
  `tools/research_questions.py` / `research/2026-09-15T190918Z/research_questions_summary.json` for the
  underlying Q-003 measurement.

### Q-004: What is the empirical time-to-convergence / expected holding period for the `GC-Z26`/`XAUUSD.vx` gap?
- **Raised:** 2026-09-15
- **Blocks:** `02_quant/14_TRANSACTION_COST_MODEL.md` (cannot convert its swap-cost sensitivity table into a
  real expected cost without this), `13_BASIS_MODEL.md`, `17_EXPECTED_VALUE.md`, and any signal design bounding
  maximum holding time.
- **Status:** open with provisional evidence only, now from two distinct sources. (1) Realized-pair evidence,
  unchanged: 7 completed pairs, holding times roughly 3–13 hours (mean 9.91 hours), 4 profitable and 3
  loss-making, net +$1.57 after commission. (2) **New 2026-09-16:** a tick-level mean-reversion ("decay") proxy
  — AR(1) half-life of the `convergence_basis` series is ≈112 minutes at a 1-minute resampling grid, growing to
  ≈25 hours at a 4-hour grid, with 1-minute-series autocorrelation still at 0.60 after 24 hours. This is
  additional, distinct evidence (statistical persistence of the raw series, not realized trade durations) and
  does not resolve Q-004 on its own — see `13_BASIS_MODEL.md` for the full analysis and its limitations
  (contaminated by a slow within-week drift at coarser grids). Both sources point the same direction
  (intraday-to-single-day resolution is plausible) but neither individually, nor together, is sufficient for a
  multi-week conclusion. **New 2026-09-16: `tools/pair_ledger.py`** now maintains a persistent, PairID-keyed
  ledger (`research/pair_ledger.csv`) that merges each future `--pairs` collection run rather than resetting —
  this doesn't add evidence by itself (seeded from the same n=7), but it means the realized-pair sample can
  now accumulate across weeks of repeated runs instead of requiring one large one-off collection to move past
  n=7. The latest closed-trade snapshot found 0 open positions, so it supplied 0 censored
  observations. Contradiction to preserve: an earlier account reconciliation separately identified one
  currently-open 8th pair; the latest snapshot may reflect that position having closed, or a different
  observation state, but it does not resolve the historical censoring discrepancy. The evidence remains too
  small and too short (max ~7 days of ticks, max ~13 hours of realized trades) to support a durable conclusion
  about multi-week behavior.

## From the project mandate (first milestone)

1. Is Spot/Futures Gold arbitrage realistically exploitable using retail MT5 infrastructure? — **partially
   addressed**: margin and physical hedge-ratio are viable on VPFX `XAUUSD.vx`/`GC-Z26` (see D-001, D-002 in
   `DECISION_LOG.md`); net economic edge after costs is not yet assessed (blocked on Q-002 and a real spread
   distribution, not two snapshots).
2. What exact price relationship should we trade? — working answer: `Bid(GC-Z26) − Ask(XAUUSD.vx)` for the
   convergence (sell futures/buy spot) trade — see `02_quant/11_SPREAD_DEFINITION.md`. Not yet validated
   against a real distribution.
3. What expected edge remains after all costs? — still open. `17_EXPECTED_VALUE.md` (new, 2026-09-16) assembles
   the mandate's full `TRUE NET EDGE` component list: known costs (spread, commission, swap) are now fully
   sourced and small relative to the raw spread for near-term holding periods, but entry/exit slippage, latency
   uncertainty, and the execution-risk buffer remain **unmeasured** (no live execution trial exists yet), and
   the mandate's own Required Safety Margin is **undefined**. Neither gap can be closed without a bounded
   Phase 1 demo-execution trial. The dominant *known* cost is still the asymmetric swap (spot pays, futures
   doesn't), which alone can exceed the entire gap over a multi-week holding period — see
   `14_TRANSACTION_COST_MODEL.md` and Q-004.
4. Which broker/instrument structure is suitable? — VPFX `XAUUSD.vx`/`GC-Z26` shown viable on margin and hedge
   ratio (D-001); not yet compared against alternatives, and commission/settlement/rollover unconfirmed (Q-002).
5. Can a $1,000 account safely support 0.01-lot hedged testing? — **yes on margin** (≈$131 combined at
   0.01/0.01, R-001 mitigated); full answer also needs the transaction-cost and stress analysis still pending.
6. What data must be collected before choosing entry and exit thresholds? — **largely answered 2026-09-15**:
   the real tick-level executable-basis distribution now exists (707,580 synchronized rows, 7 days; mean
   41.45, median 41.24, std 1.60, p05/p95 39.54/44.27 — see `11_SPREAD_DEFINITION.md`), superseding both the
   two-snapshot table and the M1-bar approximation. Also surfaced a real stale-quote anomaly (basis briefly
   collapsed to 5.07) feeding R-004. Still missing before thresholds can actually be chosen: fair-value
   decomposition (`12_FAIR_VALUE_MODEL.md`) and time-to-convergence data (Q-004, `13_BASIS_MODEL.md`).
7. What execution latency is acceptable? — open, not yet studied.
8. What conditions make the strategy economically unviable? — open, blocked on the cost/EV model. Partial,
   sourced answer: a holding period longer than roughly 3–4 weeks under the current swap regime, on its own,
   is enough to erase the observed gap (see `14_TRANSACTION_COST_MODEL.md`) — so "convergence takes too long"
   is now a concretely quantified failure mode, not just a generic concern.
