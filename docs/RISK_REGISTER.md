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

---

No further risks recorded yet.
