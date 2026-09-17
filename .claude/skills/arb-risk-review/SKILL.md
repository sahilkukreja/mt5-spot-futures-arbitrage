---
name: arb-risk-review
description: Review capital, hedge exposure, margin, failure loss, limits, kill switches, broker constraints, and stage-graduation safety for the MT5 arbitrage project. Use for the USD 1,000 and 0.01-lot test constraint or any risk-sensitive change.
---

# Arbitrage Risk Review

## Load first

Read `.claude/skills/PROJECT_STATE.md` before anything else. It carries the current gate status, the measured
constants, the canonical dataset, and the pitfalls that have already cost this project time. It is a cache —
`docs/` wins on any conflict.

Assume capital preservation outranks return.

## Minimal context

Read `docs/PROJECT_MANDATE.md`, the proposal under review, and relevant entries from `docs/RISK_REGISTER.md`. Read broker/quant documents only when their numbers feed the risk calculation.

## Mandatory checks

- Identify both legs' contract size, tick size/value, currency, lot step, margin method, and leverage.
- Calculate notional, delta/tick-value mismatch, combined margin, free margin, margin level, and residual exposure.
- Stress normal divergence, abnormal divergence, delayed hedge, rejected hedge, worst observed slippage, disconnect, and emergency flatten.
- Evaluate per-trade, daily, weekly, drawdown, concurrency, holding-time, quote-age, latency, slippage, margin, expiry, and position-mismatch limits.
- Reject unexplained numerical limits.
- Confirm no martingale, grid averaging, loss-recovery sizing, or hidden directional exposure.
- Check broker terms and applicable regulatory constraints before live approval.

The target `0.01 lot` is not approval to trade equal lots. USD 1,000 is a hard experimental-capital ceiling, not proof of adequate margin.

## Verdict

Return `APPROVE`, `APPROVE WITH CONDITIONS`, or `REJECT`, followed by decisive evidence, breached invariants, required mitigations, unresolved inputs, and the exact re-test needed. Update the risk register only when the repository change is requested.

## Project-specific risk inputs (2026-09-18) — dated observations, not standing conclusions

Each item below is a dated measurement or a current implementation state, not a permanent fact. Re-check the
date against `.claude/skills/PROJECT_STATE.md` and the cited document before citing any of these as still
current; several already went stale once (margin/exposure figures below are from a 2026-09-16 observation,
guard implementation status is from 2026-09-18).

**Assumptions vs. measurements — separated explicitly:**
- **Measured, sourced:** R-002 has materialized, not just been identified. Net carry on the overnight
  convergence structure is **-USD 0.3809/day with a 95% CI entirely below zero**, from 5.8M synchronized rows
  (D-006). Any proposal relying on overnight basis convergence should be rejected on this basis alone.
- **Measured, sourced:** margin ≈USD 129.67 combined per 0.01/0.01 pair; a real Stage 2 pair observed margin
  level ≈771% (`RISK_REGISTER.md` R-001). Margin-stress is **not** the binding risk at this size — a 20%
  adverse move adds only ≈USD 26. The binding risk is notional directional exposure during a leg mismatch
  (R-003). *(Separately: 4 concurrent pairs were observed open on an unrelated, pre-existing account position
  2026-09-16, margin ≈USD 525/191% — not this project's own output, cited only as a margin-guard sanity check,
  do not conflate with this project's own trial activity.)*
- **Sourced, but flagged for reconciliation, not settled:** spot swap is asymmetric, -60 pts/day long / +40
  short, futures disabled, giving a ×9/7 weekly average (-$0.7714/day) via the standard MT5 triple-Wednesday
  convention. This project's own `14_TRANSACTION_COST_MODEL.md` marks the Wednesday triple-charge as
  *Sourced*, and the ×9/7 convention matches documented MT5 behavior (compensating for two uncharged weekend
  nights, not double-counting them) — but an external proposal has disputed it
  (`docs/Gold-Basis-EA-Strategy-and-System-Design.md` §4.3, 2026-09-18). Check the actual broker charging
  schedule directly (per-weekday swap multipliers, `SYMBOL_SWAP_ROLLOVER3DAYS`) rather than citing either side
  of this dispute as settled.
- Rollover: no successor symbol exists (R-005). Expiry 25 Nov 2026 with no machine-readable expiry field.

**Distinguish a loss trigger from a guaranteed loss cap — this project already found a real gap here, twice:**
A pre-trade budget check (e.g. `InpMaxTradeLossUsd`) only blocks the *next* fire if a projected worst case
exceeds it; it does not cap what an *already-open* trade can lose in real time, and inputs like
`InpAckTimeoutMs`/`InpFillTimeoutMs`/`InpOrphanTimeoutMs` in `HarnessStage2_LivePilot.mq5` are currently
**declared but never referenced in any logic** (confirmed by grep, 2026-09-17) — the ~$4.85 orphan-exposure
figure `InpMaxTradeLossUsd`'s own justification depends on describes a wait-then-flatten mechanism that does
not exist in code; the actual behavior is an immediate flatten with no timeout window at all. Verify a cited
timeout/limit is actually wired into logic, not just declared as an input, before trusting its derived dollar
figure.

**R-004 (stale-quote/fast-repricing) status, 2026-09-18 — check before re-flagging as unaddressed:** a
velocity/quote-age/cross-leg-skew guard now exists (`GuardFastMarketLogic()` in `HarnessStage2_Guards.mqh`,
wrapper `GuardFastMarket()` in `HarnessStage2_LivePilot.mq5`), replay-tested against the real 2026-09-11
anomaly, compiled clean, **not yet exercised against a real broker connection.** A review encountering R-004
should check this implementation first rather than re-deriving "no guard exists" from scratch — but should
still verify it actually ran for real before treating it as closed.

A useful risk-control taxonomy extracted from the legacy project (as reference only): daily-loss-percent
*plus* a separate consecutive-loss count, weekly drawdown percent, and an equity-drawdown pause that requires
manual restart rather than auto-clearing. **Note (2026-09-17): a weekly drawdown limit specifically has been
flagged as missing from every stage of this project's own harness so far** — check for one before assuming
the taxonomy above is fully implemented.
