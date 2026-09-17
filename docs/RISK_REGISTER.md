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
- **REALIZED 2026-09-16 — this risk is no longer hypothetical for the overnight structure; it materialized.**
  The missing piece was never a cost, it was the *revenue*: nothing in this project had measured how fast the
  basis actually decays, so every prior comparison put costs next to the basis **level** rather than its
  **change**. Measured: decay **-$0.3905/day** (95% CI -$0.4480 ... -$0.3330, R^2=0.83, n=5,843,313
  synchronized rows over 45 days) against one-sided spot swap of **-$0.7714/day**. Net carry
  **-$0.3809/day, 95% CI entirely below zero**, before the $0.4975 round trip. The thin edge is not merely at
  risk of being consumed by costs -- for any overnight hold it is already negative. See D-006 (proposed) and
  `02_quant/17_EXPECTED_VALUE.md` -> "Correction 2026-09-16".
  Two things this does **not** say: (1) intraday pairs pay no swap and are not covered -- measured daily range
  of `convergence_basis` is median $7.91 against a $0.4975 round trip, which is opportunity, not demonstrated
  edge; (2) it does not reduce the unmeasured-slippage exposure that is the other half of this risk.
  **Practical note on the live account:** the 4 concurrent pairs observed open on 2026-09-16 are in the
  convergence direction. To the extent any of them are held overnight, this measurement says they carry at
  approximately -$0.38/day each (~-$1.52/day combined) in net carry, independent of where the basis happens to
  move. Those positions are not this project's output and this document does not direct action on them -- it
  records the measurement so the account owner can act on it.
- **Cause:** expected convergence is small relative to spread, commission, slippage, swap, rollover, and
  estimation error. **Corrected 2026-09-15**: on this account, `XAUUSD.vx` charges **-60 points/day** on the
  long side while `GC-Z26` has `swap_mode = 0`, so the cumulative cost is one-sided. At the captured contract
  settings, this is **$0.60 per day per 0.01 lot** (60 × 0.01 × 100 × 0.01). That implies roughly **$12.60
  in 3 weeks**, **$16.80 in 4 weeks**, and **$40 in about 9.5 weeks**. This supersedes the earlier 3–4-week
  claim that swap alone erases the full gap; the correct break-even is much longer. The captured account history
  still shows 7 real paired convergence trades, held ~3–13 hours each, net +$1.57 after commission —
  consistent with swap being a non-issue when the holding period remains short. But n=7 over ~4 days is too
  small to conclude anything about the multi-week scenario; Q-004 remains open for the true time-to-convergence
  distribution. Separately: **update 2026-09-16 — re-checked live, now 4 pairs open concurrently** (8
  positions; was 1 pair as of 2026-09-15), all standard convergence pairs, none this project's output. Not
  itself an R-003 orphan-leg event — every leg has its opposite-direction match, both legs open together in
  each pair. Combined margin usage has risen to ≈$525 (margin level ≈191%, down from ≈700–770% for a single
  pair — see `02_quant/14_TRANSACTION_COST_MODEL.md` "Currently open positions"), still well above the
  broker's 100%/50% stop-out levels but a real, measured reduction in stress buffer from what R-001's
  single-pair analysis assumed. There is no automated monitoring or kill switch yet, so these positions depend
  entirely on manual attention.
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
- **Status:** open. **Update 2026-09-16:** `02_quant/17_EXPECTED_VALUE.md` (new) assembles the mandate's full
  `TRUE NET EDGE` component list. Known/measured costs (spread, commission, swap) stay small relative to the
  raw spread's own p05 for near-term holding periods (same-day cost floor $0.70 vs. p05 raw spread $39.54).
  This narrows but does not close R-002: entry/exit slippage, latency uncertainty, and the execution-risk
  buffer are still **unmeasured** (no live execution trial exists), and the Required Safety Margin the mandate
  requires is still **undefined** — both are exactly the kind of "unmodelled cost" this risk names, so R-002
  stays open until a bounded Phase 1 demo-execution trial supplies them. Separately, `12_FAIR_VALUE_MODEL.md`'s
  implied-carry decomposition shows ~77% of the average gap is consistent with SOFR-based carry and ~23%
  (~$9.67) is an unexplained residual not yet attributable to a specific cause — relevant context for whether
  the "edge" being sized against costs is real or partly an artifact of comparing against the wrong baseline.

### R-003: Unmatched or partially filled hedge leg
- **Update 2026-09-16 — this risk becomes measurable for the first time under D-007.** The harness designed
  in `04_testing/34_DEMO_TEST_PLAN.md` records `legging_window` (ms of unhedged exposure between the two leg
  fills) and `legging_drift` (how far the basis moved during that window) for every pair, and deliberately
  uses *sequential* leg submission so the window is visible rather than confounded. Leg order is randomised
  per pair, which also tests whether the legacy system's heavily asymmetric failure counts (`XAUUSD.pp` 359
  vs `GCJ26.ma` 49) were a property of the symbol, the submission order, or the venue. Until that trial runs,
  this risk remains bounded only by reasoning, not by data.
- **Cause:** asynchronous acceptance, rejection, partial fill, latency, disconnection, or unsupported filling mode
- **Consequence:** unintended directional gold exposure and rapid loss
- **Severity:** critical
- **Mitigation:** preflight both symbols, explicit transaction-driven pair state, actual-filled-volume
  reconciliation, `ORPHANED` and `EMERGENCY_FLATTENING` states, bounded orphan timeout, reconciliation-required
  freeze after ambiguous broker results, emergency flatten, and kill switch. Detailed design: `22_STATE_MACHINE.md`.
- **Trigger / metric:** any pair with non-zero delta mismatch beyond the configured time/exposure limit
- **Owner:** Execution design
- **Status:** open. **`/arb-risk-review` update (2026-09-16) — concrete magnitude now measured, not just
  hypothetical:** at 0.01 lot each leg is 1 XAU of gross notional (~$4,300–4,345), even though combined margin
  is only ≈$129.67 (`order_calc_margin()`: `XAUUSD.vx` $42.96 + `GC-Z26` $86.71, free margin $870.33, margin
  level ≈771% — margin itself is not the binding constraint). The `02_quant/13_BASIS_MODEL.md` R-004 anomaly
  (2026-09-11 13:30:01–13:30:17 UTC) shows the futures leg repricing **~54 points in ~10 seconds** while the
  spot leg lagged ~6 seconds. If a leg failure or a delayed second fill left one side unhedged during a move
  like this, the resulting loss (≈$54 at 0.01 lot) would be **≈5.4% of the $1,000 capital ceiling from one
  ordinary fast-market tick sequence observed in a quiet 7-day sample** — not a tail-event assumption, a
  measured one. No orphan-leg timeout exists yet to bound this (Q-003 `orphan_leg_timeout` status remains
  `insufficient_data`), and no execution/risk engine exists to enforce the mitigations listed above (only
  `20_SYSTEM_ARCHITECTURE.md`/`22_STATE_MACHINE.md` skeletons exist; `21_EXECUTION_ENGINE.md`,
  `24_RISK_ENGINE.md`, and all of `06_operations/` are unwritten). **This is the specific, evidenced reason no
  demo or live order placement should be approved yet** — not an economics objection, an unenforced-invariant
  objection. Re-test: re-run `/arb-risk-review` once a calibrated orphan-leg timeout (from real signal-to-fill
  latency data) and a written kill switch / risk engine exist.
- **Related, outside this project's control:** a live position opened by someone/something other than this
  project was open on the account as of 2026-09-15 with no automated monitoring (see `14_TRANSACTION_COST_MODEL.md`
  "Currently open pair"); current status not re-checked this session (MT5 tool connection unavailable).
- **Historical precedent (2026-09-16, `01_research/06_EXISTING_SYSTEM_RESEARCH.md`):** the internal legacy EA
  (different broker/account) hit this exact failure class at real, severe scale — **408 rejected order-open
  attempts (`retcode 10044`) in under 50 minutes**, hitting both legs, recurring on a separate calendar day
  from an earlier, smaller occurrence of the same problem, with no retry ceiling, backoff, or alert visible in
  the log. Not this project's broker/data — a portability caveat, not a transferable number — but concrete
  evidence that "no orphan-leg timeout + no retry ceiling" is not a hypothetical failure mode.

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
- **Update 2026-09-16 — anomalous row isolated:** `tools/q3_q4_research.py`'s `find_basis_anomaly()` locates the
  event precisely at **2026-09-11 13:30:11.218 UTC**. Its `quote_skew_ms = 238` is elevated (above the 707k-row
  median of 108ms) but not extreme (below the p95 of 384ms) — **confirming the earlier caution that a large
  skew isn't the only way a false basis can appear.** Surrounding ticks show the futures leg repricing sharply
  three times within ~10 seconds (4393 → 4360 → 4339, a ~54-point drop) while the spot leg's ask stayed frozen
  for that entire window, catching up only ~6 seconds after the anomalous row. This looks like a genuine
  fast-market event where the futures feed led and the spot feed lagged by several seconds — not a single
  badly-desynchronized tick pair, and not reliably caught by a static `quote_skew_ms` threshold alone. See
  `02_quant/13_BASIS_MODEL.md` for the full row-level table.
- **Trigger / metric:** quote age or `quote_skew_ms` exceeds an empirically validated limit (data now exists
  to derive one; not yet done — see Q-003). **New, per the anomaly above:** a static skew threshold is not
  sufficient by itself — mitigation design should also consider per-leg price velocity or a multi-tick
  confirmation window before accepting a signal.
- **Update 2026-09-16 — velocity check confirmed to work where skew doesn't:** `02_quant/13_BASIS_MODEL.md`
  computed tick-to-tick futures-leg price velocity across the full 707,467-row dataset (median 0.25 pts/sec,
  p99.9 8.08 pts/sec, max **161.6 pts/sec**). The single highest-velocity tick in the entire 7-day dataset
  occurs at 2026-09-11 13:30:01.581 UTC — one tick before this exact anomaly — at roughly 20x the p99.9 rate
  elsewhere. A proposed research-candidate quote-staleness threshold of **400ms** (close to the p95 of 384ms)
  is documented in `13_BASIS_MODEL.md`, but since this anomaly's own skew (238ms) sits inside that candidate,
  skew alone would still miss it — velocity is the mitigation that actually catches this specific failure mode.
  No numeric velocity threshold is proposed yet (n=1 extreme event is not enough to derive a defensible cutoff).
- **Update 2026-09-16 — widened the dataset to 45 days (5,111,120 rows) and found this is not a one-off: two
  more anomalous rows appear, both at 2026-09-04, within a 17-second window of **13:30 UTC** — the same clock
  time as the original 2026-09-11 event, exactly 7 days apart, **both Fridays**. 2 of the ~6-7 Fridays in the
  45-day window show this signature. Root cause still not confirmed (no check yet of which specific 8:30am-ET
  data release, if any, fell on either date; n=2 dates is still a small sample), but this raises the finding
  from "one observed instance" to "a plausible recurring, roughly-timed event" — see `02_quant/13_BASIS_MODEL.md`
  for the full row-level detail. Possible mitigation candidate: a fixed no-entry window around 13:30 UTC, not
  yet sized or proposed as a number (needs more weeks of data to size responsibly, per `NO MAGIC`).
- **Owner:** Data and execution research
- **Status:** open

### R-005: Incorrect futures contract or expiry transition
- **Cause:** stale symbol configuration, inaccurate broker metadata, silent symbol substitution, or trading inside the roll/expiry risk window
- **Consequence:** invalid fair basis, poor liquidity, forced close, or hedge against the wrong contract
- **Severity:** critical
- **Mitigation:** bind every pair to a contract identifier and expiry, prohibit silent substitution, validate session/liquidity, and enforce a no-entry roll window
- **Trigger / metric:** missing/changed expiry metadata, spread/liquidity deterioration, or days-to-expiry below the approved boundary
- **Owner:** Instrument research and operations
- **Status:** open. **Update 2026-09-16 — concrete evidence, not just a hypothetical:** live `symbol_info()` for
  `GC-Z26` shows `expiration_time = 0`, despite the symbol's own `description` field stating "Gold December
  2026 Futures - Exp 25 Nov 2026" (`research/2026-09-15T190918Z/symbol_specs.json`; see
  `02_quant/14_TRANSACTION_COST_MODEL.md` → "Q-002 update"). The contract's expiry is not currently exposed
  through any machine-readable API field — only as free text in `description`/`name`. Any future rollover
  monitoring cannot rely on `expiration_time` and must instead parse the description string or use another
  detection mechanism (e.g. a scheduled manual check, or broker support confirmation of the rollover date/
  process) — this is the "missing/changed expiry metadata" trigger already named above, now observed directly
  rather than assumed.
- **Update 2026-09-16 — checked directly whether an old/next contract symbol exists: it doesn't, either way.**
  `mt5.symbols_get()` and `mt5.symbols_total()` both return exactly **2** symbols for this account, total:
  `XAUUSD.vx` and `GC-Z26`. No other gold-futures contract month — older or newer — exists anywhere in this
  terminal's symbol tree (checked with wildcard group queries: `*GC*`, `*GOLD*`, `*Metal*`, `*XAU*`). Two
  implications: (1) mild reassurance that `GC-Z26` has not been silently swapped for a different contract
  during this project's data collection — brokers typically add a new contract month as a new symbol name
  rather than relabeling an existing one, and no second symbol has ever appeared here; (2) a sharper, now
  concrete version of the rollover risk — **this account currently has no visibility into the next contract
  month at all**. When `GC-Z26` nears its 25 Nov 2026 expiry, there is no successor symbol already available to
  roll into; the broker will need to add one, and nothing in this project's tooling would auto-detect or
  auto-prepare for that. A rollover runbook item (not yet written, belongs in `06_operations/`) should include
  explicitly requesting/confirming the next contract's symbol from the broker well before expiry, not assuming
  it will simply appear.

### R-006: Signal/Risk engine cannot enforce "no trading when costs remove edge" yet
- **Cause:** `02_quant/14_TRANSACTION_COST_MODEL.md` and `17_EXPECTED_VALUE.md` now both exist (2026-09-16) with
  real, sourced cost and edge evidence, but neither reaches a Net Executable Edge figure — `17_EXPECTED_VALUE.md`
  explicitly cannot clear the mandate's gate because entry/exit slippage, latency uncertainty, and the
  execution-risk buffer are unmeasured, and the Required Safety Margin is still undefined (only a proposed
  methodology exists). So the Signal Engine interface defined in `03_system_design/20_SYSTEM_ARCHITECTURE.md`
  still has no real, approved entry/exit threshold to enforce — only a placeholder interface, same as before,
  just for a more specific reason now.
- **Consequence:** if implementation ever got ahead of documentation, a signal could fire on an
  economically negative-EV gap with no cost-based gate to stop it.
- **Severity:** high
- **Mitigation:** `20_SYSTEM_ARCHITECTURE.md` explicitly marks this invariant as "not yet enforceable" and
  forbids treating any placeholder threshold as real; no MQL5 exists, so no implementation can currently get
  ahead of this.
- **Trigger / metric:** any attempt to write `21_EXECUTION_ENGINE.md`/`22_STATE_MACHINE.md` with a concrete
  numeric signal threshold before `17_EXPECTED_VALUE.md` reaches a real (not provisional/sensitivity-table-only)
  Net Executable Edge figure with a defined Required Safety Margin.
- **Owner:** Quant research / design
- **Status:** open

### R-007: Demo execution may not model slippage, producing a falsely safe Required Safety Margin
- **Update 2026-09-16 — largely resolved by D-008, which moves the trial to a live account.** Live fills
  remove the mechanism entirely: there is no demo fill engine to be unrepresentative. This risk remains
  recorded because (a) the demo Stage 1 mechanical shakedown still runs, and its slippage/rejection outputs
  must be **discarded, not reported**, which is exactly the trap this entry describes; and (b) if the live
  budget is withdrawn and the project falls back to demo, this risk returns in full and validity check V1 is
  known to be too weak to catch its more dangerous form (a demo that synthesises plausible-looking slippage
  uncorrelated with market conditions). Superseded in practice, retained as a live trap for the fallback path.
- **Raised:** 2026-09-16
- **Cause:** many broker demo servers fill orders at the requested price with no adverse deviation. If VPFX's
  demo behaves that way, the D-007 measurement harness would record `slippage ~ 0` across every pair.
- **Consequence:** worse than having no data. The mandate's gate is
  `Net Executable Edge > Required Safety Margin`, and `17_EXPECTED_VALUE.md` derives that margin from
  `k x p95(round-trip slippage + latency-driven adverse movement)`. A p95 of zero collapses the margin to
  zero and makes the gate trivially passable — the strategy would look safe precisely because the instrument
  was blind. This is a measurement-validity failure that presents as a favourable result, which is the kind
  most likely to be acted on.
- **Severity:** high — it attacks the credibility of the one measurement that unblocks the economics gate.
- **Mitigation:** validity check V1 in `04_testing/34_DEMO_TEST_PLAN.md` section 3, run after the first 50
  pairs: if >90% of legs show exactly zero deviation, or the distribution has zero variance, declare the demo
  environment non-representative for slippage and **halt**. Latency, retcode and legging-window measurements
  remain valid regardless and are still collected.
- **Trigger/metric:** fraction of legs with exactly zero `slippage_i`; variance of the slippage distribution.
- **Owner:** whoever runs the D-007 trial.
- **Status:** open — cannot be assessed until the harness reaches Stage 2. If it fires, B1 stays open and the
  only remaining route to slippage is a bounded live micro-trial, which is a separate decision and is
  explicitly not proposed.

### R-008: Real capital spent on a measurement that cannot clear the mandate's gate
- **Raised:** 2026-09-16
- **Cause:** D-008 funds a live trial at n=300, costing **USD 149.25 guaranteed (14.93% of the USD 1,000
  ceiling)** before slippage, and up to USD 449 (44.9%) if slippage runs at USD 1.00/pair. The trial's stated
  purpose is to supply `17_EXPECTED_VALUE.md`'s Required Safety Margin, defined as
  `k x p95(round-trip slippage)`. The p95 that matters is of the **conditional** distribution -- slippage at
  the moments a signal would fire, which are disproportionately fast, wide-spread moments. Elevated-spread
  conditions occur in 0.113% of spot ticks; collecting 30 such observations needs **n ~ 26,500, costing about
  USD 13,208 -- 13.2x the entire capital ceiling.**
- **Consequence:** the Required Safety Margin **cannot be derived as currently specified at any affordable
  sample size.** Money is therefore being spent on a measurement that can refute the strategy but can never
  clear it. The specific failure mode to guard against is substituting the *unconditional* p95 for the
  conditional one: that number is cheap, looks rigorous, and is biased low -- it would understate the margin
  precisely where the margin exists to protect.
- **Severity:** high -- it is a spend decision made against a gate that cannot close as written.
- **Mitigation:** (1) the trial is explicitly scoped as a refutation instrument in
  `04_testing/35_1000_USD_LIVE_TEST_PLAN.md` section 3, with what it can and cannot deliver tabulated;
  (2) stratified sampling (200 unconditional + 100 condition-triggered, with recorded weights) buys a
  conditional median and IQR, which is the most the budget can reach; (3) latching USD 250 cumulative-loss
  stop and USD 40 daily stop; (4) staged protocol so the trial can be abandoned after a 10-pair live pilot;
  (5) `17_EXPECTED_VALUE.md` must record that its Required Safety Margin methodology needs revision or the
  gate cannot close -- both are legitimate outcomes, silent substitution is not.
- **Trigger/metric:** cumulative realized cost vs the USD 250 stop; whether any reported p95 is conditional or
  unconditional.
- **Owner:** the account owner, who funds it.
- **Status:** open -- blocking on the Phase graduation criteria and the account precondition before any spend.
- **Update 2026-09-16 (`/arb-hostile-review` AS-1) -- a second, sharper validity threat to this trial's
  output.** The trial's own pattern -- 300 small, near-identical hedged pairs from one account -- is exactly
  what a broker's last-look or behavioural-pricing logic could detect and adapt to. If that happens, the
  measured slippage reflects *this account's treatment once flagged*, not general retail execution, and the
  bias arises *during* the run rather than merely limiting generalisation afterward. No pre-trade mitigation
  exists and none is attempted (disguising the pattern would itself bias the measurement). Mitigation is at
  analysis: T19 regresses `slippage_broker_i` on pair sequence number; a worsening trend is reported as a
  limitation on every headline number, never averaged away. Recorded as L-9 in
  `35_1000_USD_LIVE_TEST_PLAN.md` section 10.

### R-009: D-008 live trial has gaps against the mandate's own required risk-limit checklist
- **Raised:** 2026-09-16, from `/arb-risk-review` re-run against `04_testing/35_1000_USD_LIVE_TEST_PLAN.md`
  specifically (the prior verdict covered the demo-only design and did not carry over to live capital).
- **Cause:** `PROJECT_MANDATE.md` -> "INITIAL RISK LIMITS" lists fourteen numeric limits required before live
  testing. Cross-checked item by item against `35_1000_USD_LIVE_TEST_PLAN.md` section 6: most are present
  (concurrency=1, orphan timeout 3s, margin level 300%, spread circuit breaker, daily loss cap USD 40). Four
  are missing or structurally absent:
  - no explicit per-pair (`InpMaxTradeLossUsd`) or per-day count (`InpMaxPairsPerDay`) limit -- only a
    dollar-based daily cap exists, which does not bound trade *count* if individual pairs are cheap;
  - no explicit weekly loss limit (redundant in practice with the daily/cumulative caps, but the mandate
    names it explicitly);
  - **no per-order slippage cap is possible at all** -- `trade_exemode=2` (market execution) does not honour
    a deviation parameter (already flagged as L-8 in the design document itself).
  - Separately: section 6 says the account whitelist value is "compiled in," which conflicts with section 7's
    own rule that credentials never appear in a committed file -- if genuinely hardcoded, the account number
    would enter git history the moment `measurement_harness/` is committed.
- **Consequence:** a spend decision proceeding without these explicit, or without an explicit documented
  reason one cannot exist (slippage cap), leaves a real gap against the mandate's own pre-live checklist,
  even though the *existing* controls already bound worst-case loss fairly tightly in practice via the
  cumulative/daily caps and the orphan timeout.
- **Severity:** medium -- none of the four gaps are currently exploitable in a way that bypasses the USD 250
  cumulative stop, but the account-whitelist conflict (if actually implemented as a literal) is a real
  credential-handling violation, not just a documentation gap.
- **Mitigation:** six conditions recorded against `35_1000_USD_LIVE_TEST_PLAN.md` (C1-C6): add explicit
  per-pair and per-day-count limits (C2); document why no slippage cap is possible rather than leaving it
  implicit (C3); source the account whitelist from the same gitignored runtime config as connection
  credentials, never a source-level constant (C4); correct the stratum-B cost estimate (C5); record explicitly
  that the mandate's "P95 slippage" live-test success criterion cannot be fully answered at this budget (C1);
  restate that this approval covers the D-008 harness only, not any future production execution engine (C6).
  Full detail: `35_1000_USD_LIVE_TEST_PLAN.md` section 8.1 (Stage 2 procedure) and the 2026-09-16
  `/arb-risk-review` verdict.
- **Trigger/metric:** whether C1-C6 are applied to the document before Stage 2's pre-flight checklist runs;
  whether the account whitelist is verified as config-sourced, not hardcoded, before any live order.
- **Owner:** whoever implements Stage 1/2 code.
- **Status:** update 2026-09-16 -- C1-C6 applied to `35_1000_USD_LIVE_TEST_PLAN.md` (sections 1, 3.1, 6, 11)
  and `17_EXPECTED_VALUE.md` (C1). The account-whitelist conflict (C4) is corrected in the document; whether
  it is correctly *implemented* in code is still unverified and remains this entry's live concern until Stage
  1/2 code exists and is checked against it. `InpMaxTradeLossUsd`/`InpMaxPairsPerDay` (C2) and the
  slippage-cap non-existence statement (C3) are documented; both remain UNCALIBRATED starting values like
  every other guard in the design, not approved production parameters. **`/arb-hostile-review` re-run
  2026-09-16 against the corrected document: `READY WITH CONDITIONS` for Stages 0-2 only.** It found that
  the C4 fix had been undone three sections later -- acceptance test T17 still read "the compiled-in
  account number," so an implementer could satisfy the test by exactly the hardcoding C4 prohibits (FF-6).
  Corrected: T17 now requires the value from the gitignored config and explicitly fails if the account
  number appears anywhere in compiled source. Also added: T18 (Stage 2 manual mode provably suppresses
  automatic firing), T20 (a persisted `stage2_confirmed.flag`, written only by operator sign-off, that the
  Stage 3/4 scheduler refuses to run without -- sequencing enforced in code, not discipline), and a
  corrected rationale for `InpMaxPairsPerDay` (a scheduler-bug guard, not a low-cost-per-pair guard, which
  this project's own measured spread floor rules out). Still open pending Stage 1/2 implementation actually
  matching what is now specified -- FF-6 is the reason that verification must include grepping the source
  for the account number, not just running the tests. Originally: "open -- C1-C6 not yet applied to the document." Blocks Stage 2's
  own pre-flight checklist (`35_1000_USD_LIVE_TEST_PLAN.md` section 8.1.2), which already lists "risk-review
  conditions C1-C6 applied"
  as a precondition.

### R-010: Stage 1 (demo shakedown) skipped by explicit account-owner decision
- **Raised:** 2026-09-16
- **Cause:** the account owner directed skipping Stage 1 (20-pair, USD 0, demo) and proceeding directly to
  Stage 2 (live pilot). This was raised as a concern before acting on it -- Stage 1 was the only zero-cost
  test of this project's real MT5 API integration (`OrderSend`/retcode handling, `DEAL_TIME_MSC` population,
  broker-state reconciliation) before any of it touched live capital, and skipping it directly runs against
  `PROJECT_MANDATE.md`'s own rule that "no stage should be skipped merely to reach live trading faster." The
  concern was reaffirmed by the account owner after being stated, which is recorded here as their decision,
  not silently overridden.
- **Consequence:** Stage 2's pair 1 is now the first contact this project's execution code has ever had with
  a real MT5 trading API, not merely the first *live* contact. A defect Stage 1 would have caught for free
  (a retcode outside the design's whitelist, `DEAL_TIME_MSC` not populating as assumed, reconciliation logic
  disagreeing with real rather than scripted broker behaviour) will now be discovered, if it exists, with
  real capital already committed to pair 1 -- roughly USD 0.50 at stake, not USD 0.
- **Severity:** medium. Bounded by `InpMaxTradeLossUsd` (USD 15) regardless of cause, and further bounded by
  the stop-and-diagnose rule in `35_1000_USD_LIVE_TEST_PLAN.md` section 8.1.3, which forbids proceeding to
  pair 2 until every one of pair 1's checks -- including two added specifically because Stage 1 is absent --
  passes.
- **Mitigation:** pair 1 receives materially higher scrutiny than pairs 2-10 (section 8.1.3): retcodes are
  checked against MT5 documentation directly rather than matched against the design's whitelist on faith, and
  the journal/Trade-History/account-statement cross-check runs three ways instead of two. This narrows the
  blast radius of a real-API bug; it does not eliminate the risk Stage 1 existed to remove at zero cost. That
  trade-off is stated plainly in the design document, not hidden.
- **Trigger/metric:** any check failure at pair 1 specifically, per section 8.1.3's step 4.
- **Owner:** the account owner, who made this decision.
- **Status:** open -- accepted risk, by explicit, reaffirmed decision. Not a design defect to be fixed; a
  documented trade-off to be honoured (elevated pair-1 scrutiny must actually be followed, not skipped too).
- **Realized, 2026-09-17 -- this is what the accepted risk looked like in practice.** Pair 1's real run:
  both legs opened correctly (idempotency, retcode handling, deal confirmation all worked first try,
  `HEDGED` reached), then `CloseLegByTicket()` failed on both legs (err=4753) because `ExecuteLeg()` had
  returned the *deal* ticket where `PositionSelectByTicket()` needed the *position* ticket -- these differ
  in Hedge mode, which this account uses. The kill switch latched correctly rather than retrying blindly
  into a failing close path; both positions were closed manually by the account owner. No unhedged
  directional exposure occurred at any point -- both legs stayed open and mutually offsetting throughout.
  Fixed: position ticket now read via `DEAL_POSITION_ID`, MT5's documented mechanism for this, correct in
  both Hedge and Netting modes. This is exactly the class of defect Stage 1 would have caught for free; it
  was instead caught at pair 1, with real capital briefly exposed to a close-path bug rather than an
  open-path one. Full account: `measurement_harness/README.md` -> "What Stage 2 is" -> "First real run".
- **Resolved, 2026-09-17 (same day) -- pair 1 re-run, completed successfully.** With the fix in place:
  both legs opened, reached `HEDGED`, both closed with `retcode=10009 (DONE)`, final outcome
  `COMPLETED`. Zero errors. The position-ticket fix held on its first real retry. This closes the acute
  form of this risk (an open bug in the close path); R-011 remains open as a related, lower-severity gap.
  Full account: `measurement_harness/README.md` -> "Second real run".

### R-011: HarnessStage2_LivePilot.mq5's realized P&L tracking is not implemented
- **Raised:** 2026-09-17
- **Cause:** `InpMaxDailyLossUsd`/`InpMaxCumulativeLossUsd` are enforced only at the pre-trade budget-check
  stage (`GuardBudgets()`), using the worst-case `InpMaxTradeLossUsd` estimate for every pair regardless of
  what it actually costs. Actual realized profit/loss, summed from `HistoryDealGetDouble(..., DEAL_PROFIT)`
  across all four legs of a closed pair, is never computed or fed back into the running totals. Flagged
  explicitly in the code at the exact line it matters (`RunOnePair()`, search "realized_loss left at 0").
- **Consequence, corrected 2026-09-17 -- more severe than first characterized.** On closer review while
  fixing this, `g_daily_loss_usd`/`g_cumulative_loss_usd` were not merely using a coarse worst-case estimate
  -- **nothing ever wrote a nonzero value to them after a pair completed at all.** `InpMaxDailyLossUsd` and
  `InpMaxCumulativeLossUsd` could not accumulate across pairs and could not trip regardless of real realized
  losses, for as long as this file existed. `InpMaxPairs=1` meant this had not yet mattered in either real
  run.
- **Severity:** was medium, correctly upgraded to **high** on the corrected understanding above -- two of
  the six documented risk-limit controls (§6 of the design doc) were non-functional as multi-pair safety
  limits, not merely imprecise.
- **Fixed, 2026-09-17.** `CloseLegByTicket()` now captures the exit deal's confirmed price and ticket via
  `HistoryDealSelect`, matching `ExecuteLeg()`'s entry-side pattern. A new `GetDealPnL()` sums
  `DEAL_PROFIT + DEAL_SWAP + DEAL_COMMISSION` per deal; `RunOnePair()` computes each pair's true realized
  P&L from all its deal tickets (2 for a rejected/rolled-back leg, up to 4 for a completed pair) and a new
  `RecordRealizedPnL()` actually accumulates it. **Deliberate design choice: only the loss portion
  accumulates -- profits never offset the counters.** Letting profits "buy back" loss budget is a
  loss-recovery/martingale-adjacent pattern the mandate explicitly prohibits; a profitable pair now costs
  nothing against the budget rather than funding a later, larger loss. A new per-pair summary CSV
  (`arb_harness_stage2_pairs.csv`) records entry/exit prices, realized P&L, and the running daily/cumulative
  totals after every pair -- resolving the original logging gap directly, not just the accumulation bug.
- **A second, distinct bug found and fixed during this same review:** the `LEG_PARTIAL` (leg 1 partial fill)
  branch fell through to `CLOSED_ORPHAN`/`ORPHANED_RECOVERED`/`IDLE` regardless of whether the emergency
  flatten actually succeeded -- inconsistent with the other two flatten-failure paths, which correctly halt.
  Never triggered in either real run (`r1` was `LEG_FILLED` both times), caught on review, not from a
  failure. Now mirrors the other two paths exactly.
- **Mitigation:** recompiled clean (0 errors). The pure arithmetic this fix depends on --
  `LossPortion()` (only losses accumulate, profits contribute exactly 0) and
  `DealPnLFromComponents()` (`profit + swap + commission`) -- was extracted into
  `HarnessStage2_Guards.mqh` and is now genuinely tested: `HarnessStage2_SelfTest.mq5` ran on the VPS
  terminal 2026-09-17 18:30, **12/12 PASS**, including G10 (loss-only asymmetry) and G11 (P&L component
  arithmetic) specifically. See `measurement_harness/README.md` -> "Testability architecture".
- **Still not verified: the real-API half.** `GetDealPnL()`'s `HistoryDealSelect`/`HistoryDealGetDouble`
  calls, `CloseLegByTicket()`'s new exit-price capture, `RecordRealizedPnL()`'s call site in `RunOnePair()`,
  and `PairSummaryWrite()` are all real-API code the self-test does not and cannot touch -- they need a real
  closed pair. This is new code exercising new paths (`GetDealPnL`, the fixed `LEG_PARTIAL` branch,
  `RecordRealizedPnL`) that pair 1's two real runs never touched. Do not treat the self-test PASS as evidence
  this half works, per this project's own standing rule.
- **Resolved, 2026-09-17 18:40 -- pair 2, first real exercise of the fix.** With `InpMaxPairs` raised to 2,
  pair 2 fired and completed (`GC-Z26` SELL / `XAUUSD.vx` BUY, both legs closed with `retcode=10009 DONE`).
  `GetDealPnL()` summed all four legs' realized components via `HistoryDealSelect` for the first time against
  a real broker: **realized P&L = -$0.61.** `RecordRealizedPnL()` correctly accumulated the full amount into
  both `g_daily_loss_usd` and `g_cumulative_loss_usd` (Experts log confirms `$0.61/40.0` and `$0.61/250.0`),
  and `arb_harness_stage2_pairs.csv` recorded the row with `pnl_status=confirmed`. Both halves of this fix
  are now verified: the pure loss-only arithmetic (self-test, 12/12 PASS) and the real-API wiring around it
  (this run). Full account: `measurement_harness/README.md` -> "Third real run".
- **Trigger/metric, still open:** an independent cross-check of this pair's P&L against the terminal's own
  Trade History has not yet been confirmed back. Worth doing once, not because the mechanism is in doubt, but
  as the same standard applied to every other real run here.
- **Owner:** whoever does that cross-check.
- **Status:** fixed and verified -- pure logic (self-test, 12/12 PASS) and real-API integration (pair 2,
  2026-09-17) both confirmed by real execution.

### R-012: Budget guards are per-terminal state, not a true global cap, if run from more than one place
- **Raised:** 2026-09-17, prompted by the account owner standardizing on a VPS (Administrator user, terminal
  D0E8209F77C8CF37AD8BF550E51FF075) for stable execution and lower latency -- the same environment pair 1
  already ran successfully on.
- **Cause:** `InpMaxDailyLossUsd`, `InpMaxCumulativeLossUsd`, and `InpMaxPairsPerDay` are all tracked in
  `arb_harness_stage2_daily_state.txt`, a file local to whichever terminal's `MQL5/Files/` the EA runs from.
  Nothing links that state across two different terminals, even if both are whitelisted to the same account
  number.
- **Consequence:** if the EA is ever run from both the VPS and the original local-machine terminal -- even
  once, even by accident (a wrong click, muscle memory, someone else with access to either machine) -- each
  keeps its own independent counters. The USD 250 cumulative-loss cap would not be a true cap across both
  environments; worst case, up to USD 250 could be spent from each, independently, before either one's guard
  would ever see the other's activity. The whitelist guard (C4) does not catch this, because both
  environments legitimately whitelist the same account.
- **Severity:** medium -- does not defeat any single guard's own logic, but defeats the *aggregate* budget
  the guards exist to enforce, across environments.
- **Mitigation:** **the VPS is now the sole environment this EA ever runs from.** The local machine's copy of
  `stage2_live_config.txt` should be deleted or renamed so it cannot fire even by accident. This is a
  procedural control, not a code fix -- a true cross-terminal shared-state mechanism (e.g. reading the budget
  state from the broker's own account history rather than a local file) is future work, not attempted here.
- **Trigger/metric:** any attempt to attach this EA to a chart anywhere other than the designated VPS.
- **Owner:** the account owner.
- **Status:** open -- mitigated procedurally (single-environment rule), not resolved in code.

---

No further risks recorded yet.
