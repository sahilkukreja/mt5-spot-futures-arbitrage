# Expected Value

Status: IN PROGRESS — **substantially rewritten 2026-09-16.** The first draft's sensitivity table contained a
structural modelling error (it treated the entire observed basis as capturable profit); that error is now
identified, corrected, and the corrected result is decisive for one of the two trade directions. See
"Correction 2026-09-16" below, which supersedes the superseded table further down.

**Does not clear the mandate's trading gate** (`Net Executable Edge > Required Safety Margin`) — slippage,
latency and the Required Safety Margin remain unmeasured/undefined. But it now does something the first draft
could not: it **rules out** the hold-to-convergence trade on measured evidence, with a confidence interval,
rather than leaving it open.

## Correction 2026-09-16 — the first draft measured the wrong quantity

**The error.** The "Provisional sensitivity table" below computes `raw spread − known costs` and reports, for
example, a `$33.60` residual for a 10-day hold. That silently assumes the trade captures the **entire** basis
(~$41) as profit. It does not. A convergence pair (SELL futures / BUY spot) opened at basis `B₀` and closed at
`B₁` earns `B₀ − B₁`, not `B₀`. The full basis is only captured by holding all the way to convergence at
expiry — which the table's own last row shows costs more in swap than it returns.

**What was missing:** the *rate at which the basis actually decays*. That is now measured.

**Measurement.** Source: `research/export-full/basis_summary.json`, built by `tools/tick_export_loader.py` from
the full MT5 terminal tick exports — 6,520,722 futures ticks and 8,798,113 spot ticks, 2026-07-27 → 2026-09-16,
5,843,313 synchronized rows at a 500 ms merge tolerance. OLS of daily mean `convergence_basis` on calendar day,
over the 38 full sessions (thin Sunday sessions with <20,000 ticks excluded):

| Quantity | Value |
|---|---|
| Basis decay | **−$0.3905/day** (1 s.e. $0.0293; 95% CI −$0.4480 … −$0.3330) |
| R² | 0.8312 |
| Residual std about the trend | $2.77 |
| Fitted basis, window start → end | $62.43 → $42.52 over 51 days |

The cost-of-carry model independently predicts −$0.4832/day over the same window (`12_FAIR_VALUE_MODEL.md`'s
4.71% implied rate, `T` falling 0.3313 → 0.1916 years). Observed −$0.3905/day is the same magnitude and sign —
**the decay is the carry unwinding, exactly as the fair-value model says it should.** This is the strongest
confirmation of that model so far, and it is also what kills the trade.

### Net carry of the convergence trade (SELL `GC-Z26` / BUY `XAUUSD.vx`, 0.01/0.01)

| Component | $/day | Source |
|---|---|---|
| Basis decay captured | **+0.3905** | measured above |
| Spot leg swap paid (long) | **−0.7714** | −60 pts/day = −$0.60/day, ×3 on Wednesdays → ×9/7 average (`14_TRANSACTION_COST_MODEL.md`) |
| Futures leg swap | 0.0000 | `swap_mode=SYMBOL_SWAP_MODE_DISABLED` |
| **Net carry** | **−0.3809** | 95% CI −$0.4384 … −$0.3234 — **entirely negative** |

Plus a one-off round trip of **−$0.4975** (measured spread $0.3975 + futures commission $0.10, see
`14_TRANSACTION_COST_MODEL.md`). Expected P&L of a randomly-timed convergence pair held `H` days:

`E[P&L] = −0.3809·H − 0.4975`

| Hold | Expected P&L |
|---|---|
| 1 day | −$0.88 |
| 5 days | −$2.40 |
| 10 days | −$4.31 |
| 30 days | −$11.92 |

**Negative for every holding period, including zero.** The first draft's table reported +$33.60 at 10 days;
the corrected figure is −$4.31. The sign is wrong in the original, not just the magnitude.

### What this rules out, and what it does not

**Ruled out — the hold-to-convergence thesis.** Holding a convergence pair to capture the basis is not
marginal or uncertain; it is negative-carry by a margin whose 95% confidence interval does not touch zero. The
broker charges $0.77/day to hold the position and the position earns $0.39/day. This answers the mandate's
question 8 ("what conditions make the strategy economically unviable") concretely: *any* overnight hold does,
under the current swap regime.

**Not ruled out — intraday relative-value trading.** Swap is only charged on positions held overnight, so an
intraday pair pays the $0.4975 round trip and nothing else. Against that, the daily high–low range of
`convergence_basis` over the 38 full sessions is **median $7.91** (p25 $6.57, p75 $10.91, min $4.20), and
**all 38 of 38 sessions had a range exceeding 4× the round-trip cost.** This is consistent with the existing
realized-pair evidence, which is entirely intraday — durations 2.16–12.74h, median 11.13h, 5 of 8 profitable,
net positive (`OPEN_QUESTIONS.md` Q-004). Those pairs were profitable *because* they never held overnight.

This is not a claim of edge. A wide range is opportunity, not profit: capturing it requires entering high and
exiting low within the session, which requires a signal that does not yet exist
(`15_SIGNAL_RESEARCH.md` is unwritten) and a slippage measurement that does not yet exist (B1). The residual
std about the trend is $2.77 and intraday swings are several dollars, so a single trade's outcome is dominated
by entry/exit timing, not by the drift. The drift only tells us the *average* trade loses.

### The reverse direction — flagged, explicitly not recommended

The mirror trade (BUY futures / SELL spot) receives spot swap of +40 pts/day (+$0.5143/day averaged for
Wednesdays) and pays the basis decay of −$0.3905/day, netting **+$0.1238/day**. It is recorded here for
completeness and because it would be dishonest to report only the direction that fails.

It should not be pursued on this evidence:

- It is **swap harvesting with basis risk**, not arbitrage. Its entire return is a broker-set swap credit the
  broker can change without notice, against real price risk it cannot control.
- +$0.1238/day is small against a residual std of $2.77 and daily ranges near $8 — precisely the
  "edge small relative to uncertainty" the mandate and `/arb-research` require be rejected.
- The +40/−60 point swap asymmetry is the broker's spread. Nothing here establishes the credit side is durable.
- It inverts the project's stated premise and would need its own hedge-ratio, margin, short-availability and
  rollover analysis from scratch.



## Purpose

Assemble `docs/PROJECT_MANDATE.md` → "TRUE NET EDGE"'s full list of components — Raw Spread minus spot/futures
spread cost, spot/futures commission, entry/exit slippage, financing, swap, carry, rollover, currency
conversion, latency uncertainty, and an execution-risk buffer — using the real evidence now collected in
`11_SPREAD_DEFINITION.md`, `12_FAIR_VALUE_MODEL.md`, `13_BASIS_MODEL.md`, and `14_TRANSACTION_COST_MODEL.md`,
and report the status of each component honestly rather than filling gaps with assumed values.

## Component inventory

| Mandate component | Status | Value / evidence |
|---|---|---|
| Raw Spread | **Measured — but it is not revenue** | `convergence_basis`, n=5,843,313 (45-day export): mean 52.78, median 55.60, p05 40.25, p95 59.69. The capturable quantity is the *change* in this, not its level — see "Correction 2026-09-16" |
| Basis decay (the actual revenue term) | **Measured 2026-09-16** | **−$0.3905/day** (95% CI −0.4480 … −0.3330, R²=0.83). Was entirely absent from the first draft |
| Spot spread cost | **Measured as a distribution 2026-09-16** | mean **$0.1545**, median $0.15, p99 $0.15, p99.9 $2.13, max $12.15 (n=8,798,113 ticks). Supersedes the earlier $0.30 assumption |
| Futures spread cost | **Measured as a distribution 2026-09-16** | mean **$0.2430**, median $0.24, p99 $0.25, p99.9 $0.44, max $5.04 (n=6,520,722 ticks). Supersedes the earlier $0.30 assumption |
| Spot commission | **Measured** | $0.00 (live deal history, `14_TRANSACTION_COST_MODEL.md`) |
| Futures commission | **Measured** | $0.10 round trip at 0.01 lot ($10/lot, confirmed 2026-09-15) |
| Financing / Carry | **Partially measured** | `12_FAIR_VALUE_MODEL.md`: ~77% of the mean gap is consistent with SOFR-based carry (median implied rate 4.74% vs SOFR 3.64%); ~23% (~$9.67) is an unexplained residual, not yet attributable to a specific cause |
| Swap | **Measured, holding-period-sensitive** | Spot leg: −$0.60/day (−$1.80 on the weekly triple-swap day); futures leg: $0.00/day (`swap_mode=0`). One-sided, cumulative — see `14_TRANSACTION_COST_MODEL.md`'s cost-vs-holding-period table |
| Rollover mechanism/cost | **Partially measured** | Settlement type now known (cash-settled CFD, `trade_calc_mode=SYMBOL_CALC_MODE_CFD` — `14_TRANSACTION_COST_MODEL.md` Q-002 update); rollover timing/mechanics near the 25 Nov 2026 expiry still undocumented — no machine-readable expiry field exists in `symbol_info()` |
| Currency conversion | **Resolved — $0.00** | Both legs quote and settle in USD |
| Expected entry slippage | **Unmeasured** | No live execution has occurred under this project; blocked on a Phase 1 demo/live execution trial |
| Expected exit slippage | **Unmeasured** | Same as above |
| Latency uncertainty | **Unmeasured** | Same as above; `quote_skew_ms` (mean 130.6ms, p95 384ms) measures cross-leg *quote* skew, not order-to-fill latency, and is not a substitute |
| Execution-risk buffer | **Unmeasured / undefined** | Mandate requires this be tied to measured execution data, not chosen arbitrarily — cannot be set until slippage/latency trials exist |
| Required Safety Margin | **Undefined — methodology proposed 2026-09-16** | No value set; a proposed derivation method now exists (see "Required Safety Margin" section below) tying it to the future Phase 1 slippage/latency distribution, but it still requires that trial's data before a number can be computed |

## Provisional sensitivity table — SUPERSEDED 2026-09-16, RETAINED AS A RECORD OF THE ERROR

> **Do not use this table.** It computes `raw spread − costs` and so assumes the full basis is captured as
> profit, which is only true at convergence. See "Correction 2026-09-16" at the top of this document for the
> corrected model and result. It is kept rather than deleted because the error is instructive: every cost line
> in it was correctly sourced, and it still reached the wrong sign, because the *revenue* side was never
> modelled at all.

This table uses **only** the components marked Measured or Partially measured above. Unmeasured components
(entry/exit slippage, latency uncertainty, execution-risk buffer) are **omitted, not assumed zero** — this
table cannot be read as a completed Net Executable Edge, only as a lower bound on total cost and therefore an
upper bound on what the true (unknown) Net Executable Edge could be.

Raw spread at three points of its measured distribution (p05, median, p95), against the fixed-cost floor
($0.30 spot spread + $0.30 futures spread + $0.10 futures commission + $0.00 spot commission = $0.70) plus
cumulative one-sided spot swap by holding period (`14_TRANSACTION_COST_MODEL.md`'s table):

| Holding period | Cumulative swap | Known cost total | Residual at raw-spread p05 (39.54) | Residual at median (41.20) | Residual at p95 (44.25) |
|---|---|---|---|---|---|
| Same day | $0.00 | $0.70 | $38.84 | $40.50 | $43.55 |
| 1 day | $0.60 | $1.30 | $38.24 | $39.90 | $42.95 |
| 5 days (1 Wed) | $4.20 | $4.90 | $34.64 | $36.30 | $39.35 |
| 10 days | ≈$6.90 | ≈$7.60 | $31.94 | $33.60 | $36.65 |
| 20 days | ≈$15.60 | ≈$16.30 | $23.24 | $24.90 | $27.95 |
| 30 days | ≈$22.80 | ≈$23.50 | $16.04 | $17.70 | $20.75 |
| 71 days (to expiry) | ≈$53.85 | ≈$54.55 | **−$15.01** | **−$13.35** | **−$10.30** |

Every column stays positive well past a month of holding and only turns negative near the full remaining
contract life — same conclusion as `14_TRANSACTION_COST_MODEL.md`, now shown across the raw-spread
distribution rather than a single snapshot value. **This is not a Net Executable Edge**: it excludes slippage,
latency uncertainty, and the execution-risk buffer, all of which the mandate requires and none of which are
measured. Historical mid-to-executable spread evidence (used to build `11_SPREAD_DEFINITION.md`'s distribution)
is not the same as what this project could actually capture executing against its own orders in real time —
slippage and latency could erase a meaningful part of the same-day/short-holding-period residual shown above,
and there is currently no data to bound by how much.

## What this does and does not establish

**Superseded bullet (kept for the record):** the first draft concluded "the measured cost floor is small
relative to the raw spread's own p05". That statement is true and irrelevant — the cost floor should be
compared against the *decay captured over the holding period*, not against the basis level. Compared correctly,
costs exceed revenue at every holding period.

- **Does establish (2026-09-16):** the hold-to-convergence convergence trade has negative expected value at
  every holding period, with a 95% confidence interval that does not include zero. This is a real go/no-go
  result on measured evidence, and it is a **no-go** for that specific structure.
- **Does establish:** the intraday structure is not excluded by the same argument — swap does not apply, and
  measured daily ranges are 8–20× the measured round-trip cost.
- **Does not establish:** that any intraday trade has positive expected value. The mandate's gate compares Net
  Executable Edge — which must include slippage, latency uncertainty, and an execution-risk buffer — against a
  Required Safety Margin that is not yet defined. Both of those pieces are currently missing, not small.
  R-003 (unmatched/partially-filled hedge leg) is also not priced into this document in dollar terms at all;
  it is a separate, unbounded tail risk handled architecturally, not a cost line item here.

## Decisions proposed

**D-006 (proposed 2026-09-16): reject the hold-to-convergence structure.** Any structure whose return depends
on holding a long-spot/short-futures pair overnight to capture basis convergence should be rejected on measured
evidence: net carry −$0.3809/day, 95% CI −$0.4384 … −$0.3234. This is a rejection of a *structure*, not of the
project — it does not reject intraday relative-value work, and it does not authorize anything. Routes through
`/arb-risk-review` and `/arb-hostile-review`, then `DECISION_LOG.md`.

Beyond that: no Net Executable Edge figure and no entry/exit threshold. Per the mandate's `NO MAGIC OAG/CAG
VALUES` and `TRUE NET EDGE` sections, proposing those now — with slippage, latency uncertainty, and the execution-risk buffer
still unmeasured, and the Required Safety Margin still undefined — would be fabricating the missing inputs.

## Smallest next empirical test

A small, explicitly bounded **Phase 1 demo-account execution trial** (not this document's decision to
authorize — routes through `/arb-risk-review` and `/arb-hostile-review` first) is the last missing input class:
it is the only way to measure entry/exit slippage and order-to-fill latency, which are the two components nothing
else collected so far can substitute for. Everything else in the component inventory above now has either a
real sourced measurement or a named, specific reason it remains open.

## Required Safety Margin — proposed methodology, not a value (2026-09-16)

The mandate's gate (`Net Executable Edge > Required Safety Margin`) needs a Required Safety Margin, and none
exists anywhere in this project. Per the mandate's own `NO MAGIC OAG/CAG VALUES` rule ("derive thresholds from
data"), this section proposes *how* to derive it once the inputs exist — not a number now, since picking one
today would be exactly the fabrication the mandate prohibits.

**Proposed methodology:** tie the Required Safety Margin to the measured uncertainty of the components that
are currently unmeasured — entry/exit slippage and latency, both blocked on a Phase 1 demo-execution trial
(see "Smallest next empirical test" above). Once that trial produces a real slippage distribution:

`Required Safety Margin = k × p95(round-trip slippage + latency-driven adverse movement)`

for some conservative multiplier `k ≥ 1` (candidate `k=2`, itself to be justified against the trial's own
sample size and variance once real numbers exist — a small trial with high variance in its own p95 estimate
would need a larger `k` to stay conservative, not a fixed one chosen in advance). This ties the margin to the
project's own measured execution reality rather than an externally borrowed rule of thumb, consistent with how
every other threshold in this project (quote-staleness candidates, margin-stress candidate) has been derived
from this project's own collected data rather than assumed.

**Why not propose a number now:** every other candidate threshold in this project so far (quote-staleness
400ms, margin-stress multiplier) was derived from a real, sourced distribution already collected. No
slippage/latency distribution exists yet — proposing a Required Safety Margin number today would break that
pattern and violate the mandate's own rule.

## Unresolved questions this document depends on

- **Q-002** (open) — price source remains fully open; opposite-direction-position restriction is now answered
  empirically (8 real instances, all filled, see `OPEN_QUESTIONS.md`), but rollover timing/mechanics is still
  open.
- **Q-004** (open) — time-to-convergence; this document's sensitivity table sidesteps it by presenting cost
  across a holding-period range rather than picking one, but a real expected-value number still needs a real
  holding-period distribution, not a range.
- **New: Required Safety Margin is undefined.** No document in this project has yet proposed how conservative
  it should be for a $1,000 capital base; this blocks evaluating the mandate's gate even once every cost
  component above is measured.
