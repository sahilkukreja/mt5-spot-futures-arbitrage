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
  multiplier candidate". **Orphan-leg timeout: still uncalibrated, but a measurement path now exists
  (2026-09-16).** The blocking condition was correct and unchanged — no signal-to-fill latency data exists
  without a live/demo execution trial, and nothing in the collected data proxies for it. What is new is that
  `04_testing/34_DEMO_TEST_PLAN.md` (D-007, proposed) now specifies that trial: its `legging_window` output —
  elapsed ms between leg 1 fill and leg 2 fill, across n≥300 stratified pairs, with leg order randomised —
  would be the first empirical basis this project has for the orphan-leg timeout. Until that trial runs *and*
  clears its validity check (R-007), the parameter stays uncalibrated and no number may be adopted. See
  `02_quant/13_BASIS_MODEL.md` for the quote-staleness/velocity and orphan-leg-timeout write-ups, and
  `tools/research_questions.py` / `research/2026-09-15T190918Z/research_questions_summary.json` for the
  underlying Q-003 measurement.

### Q-004: What is the empirical time-to-convergence / expected holding period for the `GC-Z26`/`XAUUSD.vx` gap?
- **ANSWERED 2026-09-16 for the overnight structure — the question was partly mis-framed.** The basis does not
  mean-revert toward a level; it **decays deterministically** at **−$0.3905/day** (95% CI −$0.4480 … −$0.3330,
  R²=0.83, 5,843,313 synchronized rows from the full terminal tick exports) as the contract approaches expiry,
  matching `12_FAIR_VALUE_MODEL.md`'s carry prediction of −$0.4832/day. Against one-sided spot swap of
  −$0.7714/day, net carry is **−$0.3809/day with a 95% CI entirely below zero**: there is no overnight holding
  period at which the convergence trade is profitable. This also explains why the AR(1) half-life estimates
  kept inflating — they were fitting the drift, since there is no fixed mean to revert to. See
  `17_EXPECTED_VALUE.md` → "Correction 2026-09-16" and `13_BASIS_MODEL.md` → "Resolved 2026-09-16".
  **Still open, and now the only live form of this question:** the holding-period distribution for *intraday*
  trades, which pay no swap. That is a signal-design question for the unwritten `15_SIGNAL_RESEARCH.md`, not a
  basis-statistics question. The original status text is retained below as a record.


- **Raised:** 2026-09-15
- **Blocks:** `02_quant/14_TRANSACTION_COST_MODEL.md` (cannot convert its swap-cost sensitivity table into a
  real expected cost without this), `13_BASIS_MODEL.md`, `17_EXPECTED_VALUE.md`, and any signal design bounding
  maximum holding time.
- **Status:** open with provisional evidence only, updated 2026-09-16 with a materially larger dataset and one
  method correction. (1) **Realized-pair evidence, now n=8** (was 7): the previously-open 8th pair closed
  (entry basis 40.37, exit 40.22, duration 2.16h, net +$0.05 — the shortest-held pair so far), and 4 new pairs
  opened since and remain open (not this project's output). Updated closed-pair stats: durations 2.16–12.74h,
  median 11.13h, mean 8.95h, 5 of 8 profitable, still net positive. Still far too small for a multi-week
  conclusion. `tools/pair_ledger.py`'s persistent ledger (`research/pair_ledger.csv`) is now confirmed working
  end-to-end — correctly transitioned the 8th pair from open to closed rather than duplicating it, grown to 12
  total tracked pairs (8 closed, 4 open). (2) **Tick-level mean-reversion ("decay") proxy — re-tested on a
  45-day/5,111,120-row dataset (was 7-day/707k) and found unreliable, correcting the 2026-09-15 write-up.**
  Every half-life estimate grew substantially when the window widened (e.g. the 1-minute-grid half-life went
  from ≈112 minutes to ≈1,437 minutes just from widening the observation window, no method change) — the AR(1)
  fit's own implied local mean swings by 35 points across resampling grids on the same series, showing the raw
  dollar `convergence_basis` series is contaminated by the underlying ~8% spot price drift over 45 days and is
  not stationary enough for this method to measure genuine mean-reversion speed. **Withdrawn as usable Q-004
  evidence** pending a de-trended re-implementation (proposed: run the same method on the *implied annualized
  carry rate* series instead, which independently proved far more stationary — see `12_FAIR_VALUE_MODEL.md`).
  This is a real methodological finding, not just more data: a short-window decay-proxy estimate should not be
  trusted without testing it at a longer window first. The evidence remains too small and too method-limited
  to support a durable conclusion about multi-week holding-period behavior.
  - **Partial de-trended follow-up, 2026-09-18** (a related but distinct measurement from the proposed one
    above): `12_FAIR_VALUE_MODEL.md` "Residual dispersion and reversion" measures the AR(1) half-life of the
    carry-*baseline-adjusted residual* `x_t` (not the raw basis, and not literally the rate series itself as
    proposed above). Same instability signature recurs: half-life estimate grows from ≈68 min at a 1-min grid
    to ≈1,232 min at a 240-min grid. This is consistent with, not a resolution of, the withdrawal above — it
    extends the same caution to the residual too, and uses a fixed (not lagged/rolling) `r_hat`. The
    originally proposed rate-series AR(1) re-implementation is still not done.

## From the project mandate (first milestone)

1. Is Spot/Futures Gold arbitrage realistically exploitable using retail MT5 infrastructure? — **partially
   addressed**: margin and physical hedge-ratio are viable on VPFX `XAUUSD.vx`/`GC-Z26` (see D-001, D-002 in
   `DECISION_LOG.md`); net economic edge after costs is not yet assessed (blocked on Q-002 and a real spread
   distribution, not two snapshots).
2. What exact price relationship should we trade? — working answer: `Bid(GC-Z26) − Ask(XAUUSD.vx)` for the
   convergence (sell futures/buy spot) trade — see `02_quant/11_SPREAD_DEFINITION.md`. Not yet validated
   against a real distribution.
3. What expected edge remains after all costs? — **answered for the hold-to-convergence structure, 2026-09-16:
   negative.** Net carry −$0.3809/day (95% CI −$0.4384 … −$0.3234) once the basis decay rate (−$0.3905/day) is
   measured against one-sided spot swap (−$0.7714/day). Expected P&L is negative at every holding period
   including same-day, once the $0.4975 round trip is added. Still open for an *intraday* structure, which
   pays no swap: measured daily range of `convergence_basis` is median $7.91 against that $0.4975 round trip,
   but no signal exists to capture it and slippage is still unmeasured. See `17_EXPECTED_VALUE.md` →
   "Correction 2026-09-16". Earlier text retained below for the record. `17_EXPECTED_VALUE.md` assembles
   the mandate's full `TRUE NET EDGE` component list: known costs (spread, commission, swap) are now fully
   sourced and small relative to the raw spread for near-term holding periods, but entry/exit slippage, latency
   uncertainty, and the execution-risk buffer remain **unmeasured** (no live execution trial exists yet), and
   the mandate's own Required Safety Margin is **undefined**. Neither gap can be closed without a bounded
   Phase 1 demo-execution trial. The dominant *known* cost is still the asymmetric swap (spot pays, futures
   doesn't), which alone can exceed the entire gap over a multi-week holding period — see
   `14_TRANSACTION_COST_MODEL.md` and Q-004.
4. Which broker/instrument structure is suitable? — VPFX `XAUUSD.vx`/`GC-Z26` shown viable on margin and hedge
   ratio (D-001); not yet compared against alternatives, and commission/settlement/rollover unconfirmed (Q-002).
5. Can a $1,000 account safely support 0.01-lot hedged testing? — **yes on margin for a single pair**
   (≈$131 combined at 0.01/0.01, R-001 mitigated); **update 2026-09-16**: the live account currently runs 4
   concurrent pairs (not this project's output), pushing margin usage to ≈$525 and margin level down to ≈191%
   (from ≈700–770% for one pair) — still well clear of the broker's stop-out levels, but a real, measured
   reduction in stress buffer at higher concurrency, see `RISK_REGISTER.md` R-002. Full answer also needs the
   transaction-cost and stress analysis still pending.
6. What data must be collected before choosing entry and exit thresholds? — **substantially advanced
   2026-09-16**: the tick-level executable-basis distribution now spans 45 days / 5,111,120 synchronized rows
   (was 7 days / 707,580), superseding both the two-snapshot table and the M1-bar approximation. The
   fair-value carry decomposition (`12_FAIR_VALUE_MODEL.md`) is now validated — the implied annualized rate
   held stable (4.74%→4.71%) across a 60%-wider time-to-expiry range, passing the model's own central
   prediction test. The R-004 stale-quote anomaly went from 1 to 3 occurrences, now showing a real weekly
   clustering pattern (Fridays, ~13:30 UTC). Still missing: time-to-convergence data (Q-004 — the decay-proxy
   method was tested at this wider scale and found unreliable, a real setback, not just more evidence needed)
   and Q-002 (rollover/price-source/position-restriction).
7. What execution latency is acceptable? — open, not yet studied.
8. What conditions make the strategy economically unviable? — **substantially answered 2026-09-16.** The
   condition is far more aggressive than previously thought: **any overnight hold at all**, not "longer than
   3–4 weeks". The spot leg's one-sided swap (−$0.7714/day averaged for the Wednesday triple charge) exceeds
   the basis decay the position earns (−$0.3905/day), so the trade bleeds −$0.3809/day from the first night.
   The earlier "3–4 weeks" figure came from comparing swap against the basis *level* rather than against the
   basis *change*, which overstated the revenue side — see `17_EXPECTED_VALUE.md` → "Correction 2026-09-16".
   Second unviability condition, unchanged and still open: entry/exit slippage large enough to consume the
   intraday move, which cannot be assessed without a demo execution trial.
