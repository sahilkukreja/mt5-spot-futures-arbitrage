# Risk Register

Tracks identified risks to capital, execution, or the project itself. Reviewed by `/arb-risk-review` and
`/arb-hostile-review` before any live-stage graduation.

## Format

### R-000: <risk title>
- **Cause:** ...
- **Consequence:** ...
- **Severity:** low | medium | high | critical
- **Mitigation:** ...
- **Trigger / metric:** what signals this risk is materializing
- **Owner:** ...
- **Status:** open | mitigated | accepted | closed

---

## Standing constraints (from the project mandate)

- Experimental capital ceiling: USD 1,000. This is a hard ceiling, not proof of adequate margin.
- No martingale, grid averaging, loss-recovery sizing, or hidden directional exposure, ever.
- No new entries after kill-switch activation.
- 0.01 lot on both legs is a starting target, not an assumption of equal exposure — hedge ratio must be calculated.

### R-001: VPFX `XAUUSD.vx` margin model may make 0.01 lot infeasible on $1,000
- **Cause:** Specification window shows `XAUUSD.vx` with margin currency = XAU and calculation mode =
  "Forex No Leverage." Read literally, required margin = volume × contract size in XAU, i.e. full notional,
  not leveraged. At 0.01 lot × 100 contract size = 1 XAU ≈ $4,347 at current price — over 4x the $1,000 ceiling.
- **Consequence:** If confirmed, the spot leg alone cannot be opened at any capital-preserving size on this
  account/broker/symbol combination; the VPFX single-broker `XAUUSD.vx` vs `GC-Z26` configuration would be
  unsuitable for the $1,000 test as currently specified.
- **Severity:** critical while open; downgraded to low now (see Status)
- **Mitigation:** Broker's actual margin-rate schedule (captured from the Specification window's "Margin
  rates" table) shows 1% initial margin for `XAUUSD.vx` and 2% for `GC-Z26` at the 0–10 lot tier — i.e.
  ≈$43.48 + ≈$87.80 ≈ $131 combined margin at 0.01/0.01, not the ~$4,347 the calculation-mode label implied.
  See `01_research/07_BROKER_RESEARCH.md` → "Margin findings — resolved."
- **Trigger / metric:** MT5 New Order ticket "Margin required" for `XAUUSD.vx` at 0.01 lot (still not
  cross-checked live — see residual note below).
- **Owner:** user (has live MT5 access)
- **Status:** mitigated — margin-rate schedule resolves the capital-feasibility concern; residual: live order
  ticket "Margin required" has not yet been read to cross-check the schedule-derived figures. Re-open to
  critical if that check disagrees materially.

### R-002: Thin edge consumed by unmodelled costs
- **Cause:** expected convergence is small relative to spread, commission, slippage, swap, rollover, and estimation error
- **Consequence:** apparently profitable signals become negative after costs
- **Severity:** critical
- **Mitigation:** executable bid/ask basis, all-in round-trip cost model, conservative uncertainty buffer, and minimum-EV gate
- **Trigger / metric:** realized pair P&L or cost residual persistently below model; expected payoff close to cost uncertainty
- **Owner:** Quant research
- **Status:** open

### R-003: Unmatched or partially filled hedge leg
- **Cause:** asynchronous acceptance, rejection, partial fill, latency, disconnection, or unsupported filling mode
- **Consequence:** unintended directional gold exposure and rapid loss
- **Severity:** critical
- **Mitigation:** preflight both symbols, explicit transaction-driven pair state, bounded orphan timeout, emergency flatten, reconciliation after restart, and kill switch
- **Trigger / metric:** any pair with non-zero delta mismatch beyond the configured time/exposure limit
- **Owner:** Execution design
- **Status:** open

### R-004: Stale or asynchronous quotes create false basis signal
- **Cause:** spot and futures prices were updated at materially different times or one feed stopped updating
- **Consequence:** the measured opportunity disappears before execution or never existed at executable prices
- **Severity:** high
- **Mitigation:** use timestamped `MqlTick` snapshots, enforce maximum quote age and cross-leg skew, and record signal-to-fill latency
- **Trigger / metric:** quote age or `quote_skew_ms` exceeds an empirically validated limit
- **Owner:** Data and execution research
- **Status:** open

### R-005: Incorrect futures contract or expiry transition
- **Cause:** stale symbol configuration, inaccurate broker metadata, silent symbol substitution, or trading inside the roll/expiry risk window
- **Consequence:** invalid fair basis, poor liquidity, forced close, or hedge against the wrong contract
- **Severity:** critical
- **Mitigation:** bind every pair to a contract identifier and expiry, prohibit silent substitution, validate session/liquidity, and enforce a no-entry roll window
- **Trigger / metric:** missing/changed expiry metadata, spread/liquidity deterioration, or days-to-expiry below the approved boundary
- **Owner:** Instrument research and operations
- **Status:** open

---

No further risks recorded yet.
