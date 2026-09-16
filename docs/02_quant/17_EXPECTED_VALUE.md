# Expected Value

Status: DRAFT — first assembly of the mandate's `TRUE NET EDGE` components from existing evidence. **Does not
clear the mandate's trading gate** (`Net Executable Edge > Required Safety Margin`): several required
components are still unmeasured, and the Required Safety Margin itself is not yet defined. This document
states what is known, what is missing, and why no go/no-go conclusion is possible yet — it is not a signal
design or a threshold proposal.

## Purpose

Assemble `docs/PROJECT_MANDATE.md` → "TRUE NET EDGE"'s full list of components — Raw Spread minus spot/futures
spread cost, spot/futures commission, entry/exit slippage, financing, swap, carry, rollover, currency
conversion, latency uncertainty, and an execution-risk buffer — using the real evidence now collected in
`11_SPREAD_DEFINITION.md`, `12_FAIR_VALUE_MODEL.md`, `13_BASIS_MODEL.md`, and `14_TRANSACTION_COST_MODEL.md`,
and report the status of each component honestly rather than filling gaps with assumed values.

## Component inventory

| Mandate component | Status | Value / evidence |
|---|---|---|
| Raw Spread | **Measured** | `convergence_basis` distribution, n=707,467: mean 41.43, median 41.20, p05 39.54, p95 44.25 (`11_SPREAD_DEFINITION.md`) |
| Spot spread cost | **Measured** | $0.30 round trip at 0.01 lot (live spread field; not yet a distribution) |
| Futures spread cost | **Measured** | $0.30 round trip at 0.01 lot (same caveat) |
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

## Provisional sensitivity table — measured components only

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

- **Does establish:** for realistic near-term holding periods (same day through ~2–3 weeks), the known,
  measured cost floor is small relative to the raw spread's own p05 — the same-day cost floor ($0.70) is under
  2% of even the 5th-percentile raw spread (39.54). This is consistent with the n=7 realized-pair evidence in
  `14_TRANSACTION_COST_MODEL.md` (net +$1.57 after commission over ~4 days).
- **Does not establish:** that this is a positive expected value trade. The mandate's gate compares Net
  Executable Edge — which must include slippage, latency uncertainty, and an execution-risk buffer — against a
  Required Safety Margin that is not yet defined. Both of those pieces are currently missing, not small.
  R-003 (unmatched/partially-filled hedge leg) is also not priced into this document in dollar terms at all;
  it is a separate, unbounded tail risk handled architecturally, not a cost line item here.

## Decisions proposed

None. Per the mandate's `NO MAGIC OAG/CAG VALUES` and `TRUE NET EDGE` sections, proposing a Net Executable
Edge figure or an entry/exit threshold now — with slippage, latency uncertainty, and the execution-risk buffer
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
