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
- **Trigger / metric:** live `order_calc_margin()` reading for `XAUUSD.vx` at 0.01 lot (the read-only
  API equivalent of the New Order ticket "Margin required" figure — see `08_TICK_DATA_COLLECTION.md` AC-8).
- **Owner:** user (has live MT5 access)
- **Status:** mitigated, residual resolved 2026-09-15 — margin-rate schedule resolves the
  capital-feasibility concern, and the live `order_calc_margin()` cross-check (XAUUSD.vx BUY $42.96/SELL
  $42.95, GC-Z26 BUY $86.72/SELL $86.71 — combined ≈$129.68) agrees with the ≈$131 schedule estimate and
  satisfies AC-8's $30–$80 expected range for the spot leg. Promoted into `01_research/07_BROKER_RESEARCH.md`
  → "Margin findings". Re-open to critical only if a later reading (e.g. after a price move or account
  change) disagrees materially.

### R-002: Thin edge consumed by unmodelled costs
- **Cause:** expected convergence is small relative to spread, commission, slippage, swap, rollover, and
  estimation error. **Corrected 2026-09-15**: on this account, `XAUUSD.vx` charges **-60 points/day** on the
  long side while `GC-Z26` has `swap_mode = 0`, so the cumulative cost is one-sided. At the captured contract
  settings, this is **$0.60 per day per 0.01 lot** (60 × 0.01 × 100 × 0.01). That implies roughly **$12.60
  in 3 weeks**, **$16.80 in 4 weeks**, and **$40 in about 9.5 weeks**. This supersedes the earlier 3–4-week
  claim that swap alone erases the full gap; the correct break-even is much longer. The captured account history
  still shows 7 real paired convergence trades, held ~3–13 hours each, net +$1.57 after commission —
  consistent with swap being a non-issue when the holding period remains short. But n=7 over ~4 days is too
  small to conclude anything about the multi-week scenario; Q-004 remains open for the true time-to-convergence
  distribution. Separately: an 8th pair is currently **open** on the account (found while reconciling, not this
  project's output). Not itself an R-003 orphan-leg event — both legs are open together — but worth noting
  plainly: there is no automated monitoring or kill switch yet, so this position depends entirely on manual
  attention.
- **Consequence:** apparently profitable signals become negative after costs, specifically if the holding
  period before convergence/exit runs into many weeks rather than hours or days.
- **Severity:** critical
- **Mitigation:** executable bid/ask basis, all-in round-trip cost model, conservative uncertainty buffer, and
  minimum-EV gate. New: because the dominant cost is time-dependent (swap), a maximum-holding-period limit or
  a time-decay-aware exit rule may be required once `13_BASIS_MODEL.md` and Q-004 provide the real
  time-to-convergence distribution.
- **Trigger / metric:** realized pair P&L or cost residual persistently below model; expected payoff close to
  cost uncertainty; specifically, any signal design that doesn't bound expected holding time before the full
  time-to-convergence distribution is measured.
- **Owner:** Quant research
- **Status:** open

### R-003: Unmatched or partially filled hedge leg
- **Cause:** asynchronous acceptance, rejection, partial fill, latency, disconnection, or unsupported filling mode
- **Consequence:** unintended directional gold exposure and rapid loss
- **Severity:** critical
- **Mitigation:** preflight both symbols, explicit transaction-driven pair state, actual-filled-volume
  reconciliation, `ORPHANED` and `EMERGENCY_FLATTENING` states, bounded orphan timeout, reconciliation-required
  freeze after ambiguous broker results, emergency flatten, and kill switch. Detailed design: `22_STATE_MACHINE.md`.
- **Trigger / metric:** any pair with non-zero delta mismatch beyond the configured time/exposure limit
- **Owner:** Execution design
- **Status:** open

### R-004: Stale or asynchronous quotes create false basis signal
- **Cause:** spot and futures prices were updated at materially different times or one feed stopped updating.
  **Confirmed to actually occur (2026-09-15):** real tick-level data (`02_quant/11_SPREAD_DEFINITION.md`,
  707,580 synchronized rows) shows `convergence_basis.min = 5.07`, a collapse to ~1/8 of the typical ~41.5
  gap with no nearby support in the distribution (p05 is 39.54) — a real, observed stale/asynchronous-quote
  artifact, not just a hypothetical.
- **Consequence:** the measured opportunity disappears before execution or never existed at executable
  prices. A signal engine reacting to this specific observed row at face value would have proposed a trade
  on a phantom gap.
- **Severity:** high
- **Mitigation:** use timestamped `MqlTick` snapshots, enforce maximum quote age and cross-leg skew, and
  record signal-to-fill latency. The latest Q-003 analyzer run measures `quote_skew_ms` (mean 130.5932ms,
  median 108ms, p95 384ms, p99 452ms, merge tolerance 500ms, n=707,467) — evidence for research candidates,
  not an approved limit.
  The specific anomalous row still hasn't been isolated to check whether its `quote_skew_ms` was elevated
  (it may not be — a large skew isn't the only way a false basis can appear).
- **Trigger / metric:** quote age or `quote_skew_ms` exceeds an empirically validated limit (data now exists
  to derive one; not yet done — see Q-003)
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

### R-006: Signal/Risk engine cannot enforce "no trading when costs remove edge" yet
- **Cause:** `02_quant/14_TRANSACTION_COST_MODEL.md` and `17_EXPECTED_VALUE.md` do not exist yet, so the
  Signal Engine interface defined in `03_system_design/20_SYSTEM_ARCHITECTURE.md` has no real entry/exit
  threshold to enforce — only a placeholder interface.
- **Consequence:** if implementation ever got ahead of documentation, a signal could fire on an
  economically negative-EV gap with no cost-based gate to stop it.
- **Severity:** high
- **Mitigation:** `20_SYSTEM_ARCHITECTURE.md` explicitly marks this invariant as "not yet enforceable" and
  forbids treating any placeholder threshold as real; no MQL5 exists, so no implementation can currently get
  ahead of this.
- **Trigger / metric:** any attempt to write `21_EXECUTION_ENGINE.md`/`22_STATE_MACHINE.md` with a concrete
  numeric signal threshold before `14_TRANSACTION_COST_MODEL.md` and `17_EXPECTED_VALUE.md` are complete.
- **Owner:** Quant research / design
- **Status:** open

---

No further risks recorded yet.
