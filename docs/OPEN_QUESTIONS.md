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
- **Status:** answered (see `01_research/07_BROKER_RESEARCH.md` → "Margin findings — resolved"). No, the
  "Forex No Leverage" calculation-mode label does not mean full-notional margin; the broker's margin-rate
  schedule (1% spot / 2% futures at the first tier) applies, giving ≈$131 combined margin at 0.01/0.01 lot.
  Residual: not yet cross-checked against a live MT5 order-ticket "Margin required" reading.

### Q-002: What is the spot leg's commission, and what are price source/settlement/rollover for the futures leg?
- **Raised:** 2026-09-12
- **Blocks:** `01_research/07_BROKER_RESEARCH.md` completion, `02_quant/14_TRANSACTION_COST_MODEL.md`
- **Status:** open — needs: `XAUUSD.vx` commission (per lot/side), `XAUUSD.vx` price source, `GC-Z26`
  settlement mechanism (cash-settled CFD vs. delivery-linked), `GC-Z26` rollover process at/before the
  25 Nov 2026 expiry, and confirmation of any broker restriction on holding opposite-direction positions
  across these two specific symbols simultaneously.

## From the project mandate (first milestone)

1. Is Spot/Futures Gold arbitrage realistically exploitable using retail MT5 infrastructure? — **partially
   addressed**: margin and physical hedge-ratio are viable on VPFX `XAUUSD.vx`/`GC-Z26` (see D-001, D-002 in
   `DECISION_LOG.md`); net economic edge after costs is not yet assessed (blocked on Q-002 and a real spread
   distribution, not two snapshots).
2. What exact price relationship should we trade? — working answer: `Bid(GC-Z26) − Ask(XAUUSD.vx)` for the
   convergence (sell futures/buy spot) trade — see `02_quant/11_SPREAD_DEFINITION.md`. Not yet validated
   against a real distribution.
3. What expected edge remains after all costs? — open, blocked on Q-002 and `14_TRANSACTION_COST_MODEL.md`.
4. Which broker/instrument structure is suitable? — VPFX `XAUUSD.vx`/`GC-Z26` shown viable on margin and hedge
   ratio (D-001); not yet compared against alternatives, and commission/settlement/rollover unconfirmed (Q-002).
5. Can a $1,000 account safely support 0.01-lot hedged testing? — **yes on margin** (≈$131 combined at
   0.01/0.01, R-001 mitigated); full answer also needs the transaction-cost and stress analysis still pending.
6. What data must be collected before choosing entry and exit thresholds? — see `02_quant/10_DATA_REQUIREMENTS.md`;
   only two point-in-time gap snapshots exist so far (`11_SPREAD_DEFINITION.md`), not a distribution.
7. What execution latency is acceptable? — open, not yet studied.
8. What conditions make the strategy economically unviable? — open, blocked on the cost/EV model.
