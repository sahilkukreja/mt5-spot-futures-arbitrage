# Basis Model

Status: DRAFT — research placeholder, not approved.

## Purpose
Model the observed spot/futures basis statistically: distribution, mean reversion, and time-to-convergence.

## Basis definitions
For the project, the working basis definitions are:

- `convergence_basis = Bid(GC-Z26) - Ask(XAUUSD.vx)`
- `reverse_basis = Ask(GC-Z26) - Bid(XAUUSD.vx)`
- `mid_basis = Mid(GC-Z26) - Mid(XAUUSD.vx)`

The executable trade is the convergence case when the futures bid is sufficiently above the spot ask to
cover costs and execution friction.

## Distribution metrics to compute
- mean / median / std
- p05 / p25 / p75 / p95
- skewness / kurtosis if enough data exists
- stale-quote anomaly count (`quote_skew_ms > 200`)

## Time-to-convergence requirements
- Compute holding time distribution for each qualifying pair
- Measure time from basis entry to exit or unwind
- Separate fast-reversion behavior from slow drift or normal carry effects
- Identify whether a typical basis trade resolves within hours, days, or weeks

## Main risk
The measured basis is only valuable if we know whether it is an actual economic edge or merely a normal
carry pattern. The key missing evidence is the broker settlement/rollover story and the real holding-period
statistics beyond the early sample size.

## Current evidence status
- Margin and first-pass gap stats are collected.
- Real tick-level executable basis is the required next evidence step.
- Q-004 remains open until a materially larger sample of holding periods is observed.
