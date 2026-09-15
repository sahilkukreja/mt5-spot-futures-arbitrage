# Fair Value Model

Status: DRAFT — research placeholder, not approved.

## Purpose
Model the theoretical fair-value relationship between gold spot and the futures contract so that the
observed spread can be decomposed into expected carry vs abnormal basis.

## Candidate relationship
For a spot/futures hedge with the same underlying commodity, the carry relation is approximately:

F_t = S_t * e^{(r + c - y) * T}

where:
- F_t is the theoretical futures fair value
- S_t is the spot price
- r is the financing / risk-free carry rate
- c is the storage / carrying cost (expected to be near zero for silver or gold in a CFD context)
- y is the convenience yield or commodity preference premium
- T is the time to expiry in years

For the retail VPFX pair, the first practical approximation is:

basis_fair = futures_price - spot_price ≈ spot_price * r * T + financing + other carry terms

This is a rough model, not a final one, because the broker-labeled `GC-Z26` is a futures CFD and may not
follow an exchange delivery / physical-storage carry model exactly.

## Required inputs
- Spot price `XAUUSD.vx`
- Futures price `GC-Z26`
- Time to expiry of the selected futures contract
- Actual financing rate or implied carry used by the broker
- Any funding / premium / storage assumptions specific to the broker product
- Rollover or settlement assumptions at expiry

## Validation plan
- Compare `fair_value_basis` to the empirically observed `basis` distribution.
- Flag cases where observed basis materially exceeds the range implied by carry + costs.
- Sanity-check that any apparent arbitrage signal is not just a normal carry effect.

## Current evidence status
- Margin feasibility is already verified from live account data.
- The real executable spread distribution remains the stronger input for the model.
- The final fair-value decomposition should be updated only after the broker settlement/rollover facts are confirmed.
