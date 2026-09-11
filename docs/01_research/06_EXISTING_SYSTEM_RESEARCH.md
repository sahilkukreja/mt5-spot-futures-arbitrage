# Existing System Research

Status: NOT STARTED

## Purpose
Research publicly available information on existing arbitrage/hedging systems to extract useful patterns — without copying or anchoring on them as baseline.

## Scope
MT5 arbitrage EAs, cross-broker arbitrage, Spot/Futures arbitrage, latency arbitrage, hedging EAs,
statistical arbitrage EAs, commercial MT5 arbitrage products, open-source trading systems,
academic research, professional basis trading architecture.

## Extract only
- Useful architecture patterns
- Execution methods
- Risk controls
- Common failure modes
- Infrastructure patterns

Treat marketing claims skeptically. Do not copy commercial bots.

## Note on internal legacy code
The `/legacy` folder contains a prior in-house EA (SPOT-FUR-ARB-BOT). Per the project mandate, it may be
reviewed here as reference material / lessons learned only — it must not constrain the new architecture.
See `legacy/NOTICE.md`.
