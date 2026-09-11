# Hedge Ratio

Status: IN PROGRESS — initial calculation done for VPFX `XAUUSD.vx` / `GC-Z26`; margin cross-check and
transaction-cost integration still pending

## Purpose
Calculate actual economic exposure per leg and the resulting hedge ratio. Per the mandate: **never assume**
`0.01 lot Spot = 0.01 lot Futures` implies equal or neutral exposure — it must be calculated from contract
size, tick value, price, and currency for the specific instruments in play.

## Inputs (from `01_research/07_BROKER_RESEARCH.md`)

| | `XAUUSD.vx` (spot) | `GC-Z26` (futures) |
|---|---|---|
| Contract size | 100 XAU | 100 |
| Tick size | 0.01 | 0.01 |
| Tick value (per 1.0 lot) | $1 (derived: tick size × contract size = 0.01 × 100, profit currency USD) | $1 (confirmed in spec window) |
| Observed price (2026-09-11/12) | ~4347.6–4347.9 | ~4389.7–4390.0 |
| Volume step | 0.01 | 0.01 |

## Result: at equal lot size, this pair is already delta-neutral in physical terms

Both instruments have **identical contract size (100 XAU per lot)**. This is not typical of a Spot/Futures
hedge and should not be assumed to generalize to any other pair without re-deriving it. Because contract sizes
match exactly:

- 0.01 lot × 100 = **1 XAU** of exposure per leg, on both sides, regardless of price.
- Taking one leg long and the other short at equal lot size (0.01/0.01) therefore nets to **exactly 0 XAU net
  physical delta** — true ounce-for-ounce neutrality, not an approximation.
- Tick value is also identical ($1/tick per 1.0 lot on both legs), so P/L sensitivity per point of adverse
  move is symmetric between legs too.

## What the USD notional difference actually is

At 0.01 lot each: Spot notional ≈ 0.01 × 100 × 4347.75 ≈ **$4,347.75**; Futures notional ≈ 0.01 × 100 ×
4389.90 ≈ **$4,389.90**. This ~$42 difference is **not** a hedge-ratio error — it is exactly the basis/gap
being traded (see `11_SPREAD_DEFINITION.md`). Do not "fix" this by unequal lot sizing; doing so would
reintroduce a physical delta mismatch to chase a dollar-notional match that isn't the actual risk being hedged
here. The risk being hedged is gold-price risk (ounces), not dollar-notional symmetry between two contracts on
the same underlying at different prices.

## Net exposure summary (0.01 / 0.01, SELL futures / BUY spot, the convergence trade)

- Spot exposure: **+1 XAU** (long)
- Futures exposure: **−1 XAU** (short)
- Net exposure: **0 XAU** (fully hedged against gold price moves)
- Delta mismatch: **0** — exact, because contract sizes are identical
- Residual risk is **not** directional gold price risk; it is basis risk (the gap itself moving against the
  position before convergence/exit) plus the execution risks below.

## What this does NOT resolve

- **Legging risk**: the two orders are not guaranteed to fill simultaneously. Between the first fill and the
  second, the position is briefly (or, on a rejected leg per `01_research/06_EXISTING_SYSTEM_RESEARCH.md`'s
  observation, possibly for an extended period) net long or short 1 XAU of outright directional exposure.
  This is an execution-design problem (`03_system_design/`), not a hedge-ratio problem — flagged, not solved,
  here.
- **Margin**: confirmed separately in `01_research/07_BROKER_RESEARCH.md` (≈$43.48 + ≈$87.80 ≈ $131 combined
  at 0.01/0.01) — sufficient, but that check and this one are independent; both must hold.
- **Net economic edge**: whether the ~$42 gap (minus costs) is worth trading at all is a separate question for
  `12_FAIR_VALUE_MODEL.md`, `13_BASIS_MODEL.md`, `14_TRANSACTION_COST_MODEL.md`, and `17_EXPECTED_VALUE.md`.
  A perfect hedge ratio on a trade with negative expected value after costs is still a losing trade.

## Scaling beyond 0.01 lot

Because both contract sizes are equal, the neutrality property holds at any equal lot size (0.02/0.02,
0.10/0.10, etc.) as long as `volume_step` (0.01 for both) permits matching the two legs exactly — which it
does here, unlike pairs with mismatched minimum lot/contract-size ratios where equal lots cannot achieve exact
neutrality (the mandate's "if perfect neutralization is impossible" case does not apply to this specific pair,
though it may apply to other pairs the architecture must eventually support).
