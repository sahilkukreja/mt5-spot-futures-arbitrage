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
- **Status:** partially answered 2026-09-15. Confirmed: `XAUUSD.vx` commission is **$0.00** in live deal
  history; `GC-Z26` commission is **$10 per lot round trip**; at 0.01 lot the futures commission is
  **$0.10 per completed pair**. Approximate full spread crossing from captured quotes is about **$0.60**
  per 0.01/0.01 pair (spot spread ≈ $0.30 + futures spread ≈ $0.30 + futures commission ≈ $0.10), not
  counting swap and slippage. Still open: `XAUUSD.vx` price source, `GC-Z26` settlement mechanism
  (cash-settled CFD vs. delivery-linked), `GC-Z26` rollover process at/before the 25 Nov 2026 expiry,
  and confirmation of any broker restriction on holding opposite-direction positions across these two
  symbols simultaneously.

### Q-003: What are the calibrated values for quote-staleness threshold, orphan-leg timeout, and margin
stress multiplier?
- **Raised:** 2026-09-15
- **Blocks:** `03_system_design/22_STATE_MACHINE.md` and `24_RISK_ENGINE.md` (not yet written) — the Risk
  Engine and Execution Engine state machine sketched in `20_SYSTEM_ARCHITECTURE.md` name these decision
  points but leave every number UNCALIBRATED.
- **Status:** open — partially measured, still uncalibrated. The latest full Q-003/Q-004 run reports quote-skew
  p95 = 384 ms and p99 = 452 ms across 707,467 post-hoc synchronized rows; these are research candidates
  only, not approved limits. Signal-to-fill/orphan-leg latency data and margin/adverse-price stress scenarios
  are still missing, so no final threshold, timeout, or stress multiplier is ready to lock in. See
  `tools/research_questions.py` and `research/2026-09-15T190918Z/research_questions_summary.json`.

### Q-004: What is the empirical time-to-convergence / expected holding period for the `GC-Z26`/`XAUUSD.vx` gap?
- **Raised:** 2026-09-15
- **Blocks:** `02_quant/14_TRANSACTION_COST_MODEL.md` (cannot convert its swap-cost sensitivity table into a
  real expected cost without this), `13_BASIS_MODEL.md`, and any signal design bounding maximum holding time.
- **Status:** open with provisional evidence only. The latest run confirms 7 completed pairs, with holding times
  of roughly 3–13 hours (mean 9.91 hours), 4 profitable and 3 loss-making, and net +$1.57 after commission.
  This does not answer the empirical time-to-convergence distribution or expected holding period. The latest
  snapshot found 0 open positions, so it supplied 0 censored observations. Contradiction to preserve: an
  earlier account reconciliation separately identified one currently-open 8th pair; the latest snapshot may
  reflect that position having closed, or a different observation state, but it does not resolve the historical
  censoring discrepancy. The evidence remains too small and too short to support a durable conclusion about
  multi-week behavior.

## From the project mandate (first milestone)

1. Is Spot/Futures Gold arbitrage realistically exploitable using retail MT5 infrastructure? — **partially
   addressed**: margin and physical hedge-ratio are viable on VPFX `XAUUSD.vx`/`GC-Z26` (see D-001, D-002 in
   `DECISION_LOG.md`); net economic edge after costs is not yet assessed (blocked on Q-002 and a real spread
   distribution, not two snapshots).
2. What exact price relationship should we trade? — working answer: `Bid(GC-Z26) − Ask(XAUUSD.vx)` for the
   convergence (sell futures/buy spot) trade — see `02_quant/11_SPREAD_DEFINITION.md`. Not yet validated
   against a real distribution.
3. What expected edge remains after all costs? — still open, blocked on Q-002. Partial progress: spread +
   futures commission cost is small (~$0.75, ~2% of the ~$40 gap); the dominant, previously-unmodelled cost is
   asymmetric swap (spot pays, futures doesn't), which alone can exceed the entire gap over a multi-week
   holding period — see `14_TRANSACTION_COST_MODEL.md` and Q-004.
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
