# Broker Research

Status: IN PROGRESS

## Purpose
Capture exact, broker-verified specifications for the candidate Spot and Futures/futures-linked symbols
before any hedge ratio, margin, or cost-model work proceeds. No hedge ratio or exposure figure in
`02_quant/` may be trusted until every field below is filled from an actual MT5 Specification window
(or equivalent broker documentation) — not assumed or copied from another broker.

## Test configuration under evaluation

- Strategy classification (working hypothesis, not yet proven): basis / relative-value — see `02_ARBITRAGE_TYPES.md`
- Broker: **VPFX (Ventura Prime FX Limited)**, live account, VPFX-Live server
- Spot leg: `XAUUSD.vx`
- Futures leg: `GC-Z26` (Gold December 2026 Futures, CME, expiry 25 Nov 2026)
- Capital ceiling: USD 1,000 (hard constraint, per `docs/PROJECT_MANDATE.md`)
- Target size: 0.01 lot per leg — starting point only; margin viability confirmed below (see Margin Findings),
  but this is not yet an equal-exposure hedge ratio (see `02_quant/16_HEDGE_RATIO.md`)
- Single-broker configuration for this first pass (both legs confirmed in one MT5 account)

Note: this is a **live** account, not demo. No orders should be placed from this research pass — spec/margin
data only.

## Required per-symbol specification

| Field | Spot (`XAUUSD.vx`) | Futures (`GC-Z26`) |
|---|---|---|
| Broker | VPFX (Ventura Prime FX Limited) | VPFX (Ventura Prime FX Limited) |
| Account type | Live, Hedge mode | Live, Hedge mode |
| Exact symbol name | XAUUSD.vx | GC-Z26 |
| Underlying / asset type | Gold vs US Dollar (Commodities → Precious Metals) | Gold December 2026 Futures |
| Exchange | CME (as labeled by broker) | CME |
| Digits | 2 | 2 |
| Contract size | 100 XAU | 100 |
| Minimum volume | 0.01 | 0.01 |
| Maximum volume | 10 | 10 |
| Volume step | 0.01 | 0.01 |
| Volume limit | 50 | (not captured) |
| Tick size | (not captured directly; digits=2 → 0.01) | 0.01 |
| Tick value | (not captured directly) | 1 (USD, per spec window) |
| Margin currency | XAU (label only — see Margin Findings; actual required margin is USD-denominated per the broker's margin-rate schedule) | USD |
| Margin calculation mode | "Forex No Leverage" (label only — superseded by margin-rate schedule, see Margin Findings) | CFD |
| Initial margin rate (0–10 lots) | 1% → ~$4,348.01 required margin per 1.0 lot | 2% → ~$8,779.70 required margin per 1.0 lot |
| Initial margin rate (higher tiers) | ≥10 lots: 2% → ~$8,696.02/lot | 10–20 lots: 3% → ~$13,169.55/lot; ≥20 lots: 5% → ~$21,949.25/lot |
| Maintenance margin rate | Same as initial at each tier | Same as initial at each tier |
| Commission | (not captured for spot leg) | 7.5 USD per lot (tier 0–1000 lots), instant by deal volume, in/out |
| Observed bid/ask (2026-09-11 ~21:35 server time) | 4347.58 / 4347.93 (spread ~35 points) | 4389.75 / 4390.05 (spread ~30 points) |
| Swap type | In points | (not captured) |
| Swap long / swap short | -60 / +40 | (not captured) |
| Swap day multipliers | Mon 1x, Tue 1x, Wed 3x, Thu 1x, Fri (not captured) | (not captured) |
| Trading hours (server time) | (not captured) | Sun 23:02–24:00 (quotes); Mon–Thu 00:00–21:58 & 23:01–24:00 (quotes and trade identical) |
| Exchange or OTC | Labeled CME, calc mode is Forex-style — likely a CFD-on-spot-gold synthetic, not literal exchange execution | CME-referenced futures CFD |
| Price source | (not captured) | By bid price |
| Settlement mechanism | (not captured) | (not captured — need to confirm cash-settled CFD vs. physical-delivery-linked) |
| Contract expiry (futures only) | n/a | 25 Nov 2026 |
| Rollover process (futures only) | n/a | (not captured — ask broker/support directly) |
| Quote/account currency | USD (profit currency) | USD (profit currency) |
| Stops level | 0 | 10 |

## Margin findings — resolved (initial "no-leverage" reading was wrong)

An initial pass over this document flagged `XAUUSD.vx`'s "Margin currency: XAU" / "Calculation: Forex No
Leverage" labels as implying full-notional margin (≈$4,347 for 0.01 lot — infeasible on $1,000). That reading
was based on the calculation-mode label alone and **has been superseded** by the broker's actual margin-rate
schedule, captured directly from the Specification window's "Margin rates" table (screenshots, 2026-09-11):

| | Margin rate (0–10 lots) | Required margin at 0.01 lot |
|---|---|---|
| `XAUUSD.vx` | 1% (≈$4,348.01 per 1.0 lot) | **≈ $43.48** |
| `GC-Z26` | 2% (≈$8,779.70 per 1.0 lot) | **≈ $87.80** |

**Combined margin for one 0.01/0.01 hedge ≈ $131.28** — well within the $1,000 ceiling, leaving roughly $869
free margin before any stress scenario. This resolves R-001 / Q-001: the calculation-mode label describes an
internal margin methodology, not literal full-notional collateral; the margin-rate table is the authoritative
figure and behaves like ordinary leveraged margin (~100x effective at this tier for the spot leg, ~50x for the
futures leg).

**Still not yet verified:** the *live* MT5 New Order ticket "Margin required" field, which accounts for the
exact live price and any per-account adjustments, has not been read directly — the numbers above are computed
from the margin-rate schedule, which should match but has not been cross-checked against an order ticket. Do
this opportunistically, without placing an order, before this figure is used for a final Phase 0 decision.

Margin sufficiency does not by itself validate the strategy — it only clears one blocking risk. The hedge
ratio (0.01/0.01 does not imply equal *exposure* — contract sizes are equal but prices differ, so notional
differs) and the full transaction-cost model are still required before any EV conclusion. See
`docs/02_quant/16_HEDGE_RATIO.md` and `14_TRANSACTION_COST_MODEL.md`.

## Account-level checks

- [x] Does the MT5 account support hedging mode (not netting-only)? — **Yes**, confirmed by terminal title bar
      ("VPFX-Live - **Hedge**")
- [x] Do both instruments exist and trade in the same account? — **Yes**, both visible in Market Watch and
      tradable from the same panel
- [ ] Any broker-specific restrictions on simultaneous opposite-direction positions across these symbols?
- [ ] Any minimum stop distance / freeze level that could interfere with legging? (Stops level 0 for spot,
      10 for futures — futures leg has a nonzero freeze/stop distance to account for)

## Evidence

- MT5 Specification window screenshots for `GC-Z26` and `XAUUSD.vx`, captured 2026-09-11, provided in chat by
  the user. Not stored in this repo (see legacy/account-data handling policy below).
- Terminal title bar: account `VPFX-Live - Hedge - Ventura Prime FX Limited`.

**Do not commit account numbers, screenshots containing account IDs, or terminal exports into this repo.**
If screenshot evidence needs to be preserved, redact the account number first and store under
`reference/legacy/SPOT-FUR-ARB-BOT/samples/` per that folder's review policy — not directly in `docs/`.

## Open items feeding this document

See `docs/OPEN_QUESTIONS.md` for the standing Phase 0 questions this document is meant to help answer,
particularly: whether $1,000 can support 0.01-lot hedged testing, and which broker/instrument structure
is suitable.

## Next step

Once both rows of the table are complete, hand this to:
- `docs/02_quant/16_HEDGE_RATIO.md` (contract-size-adjusted hedge ratio, residual exposure)
- `docs/02_quant/14_TRANSACTION_COST_MODEL.md` (commission, spread, swap inputs)
- `/arb-risk-review` (required margin vs. USD 1,000, stressed free margin)
