---
name: arb-research
description: Research and document gold spot–futures economics for the MT5 arbitrage project, including instruments, executable spread, fair value, basis, costs, data, hedge ratio, and expected value. Do not use for MQL5 implementation.
---

# Arbitrage Research

Produce evidence-backed research, not trading claims.

## Context budget

Read `docs/PROJECT_MANDATE.md`, then only the target document and its direct dependencies:

- Instrument mechanics → `docs/01_research/`
- Data/spread/fair value/basis/costs/signals/hedge ratio/EV → `docs/02_quant/`
- Existing accepted decisions → search `docs/DECISION_LOG.md` for the relevant term before loading more.

Do not read source code or prior-bot material unless the user explicitly requests comparison or empirical extraction.

## Required reasoning

- Distinguish true arbitrage, basis, relative value, statistical arbitrage, latency arbitrage, broker dislocation, and mean reversion.
- Use executable bid/ask prices for trade eligibility; label mid-price analysis separately.
- Explain expected basis through carry, time to expiry, funding, settlement, hours, and contract structure.
- Calculate notional and tick-value exposure independently. Never assume equal lot numbers imply a hedge.
- Include spreads, commissions, entry/exit slippage, swap/funding, rollover, FX, latency uncertainty, and an execution-risk buffer.
- Separate sourced facts, calculations, assumptions, and hypotheses.
- Reject a proposal whose edge is small relative to uncertainty.

## Deliverable

Update one primary research document. Include objective, evidence, formulas with units, assumptions, unresolved questions, risks, validation data, and decisions proposed. Update `docs/OPEN_QUESTIONS.md` and `docs/DECISION_LOG.md` only for material changes; do not duplicate the full analysis there.

Do not invent broker specifications or magic thresholds. End with the smallest next empirical test.
