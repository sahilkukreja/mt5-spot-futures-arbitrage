# Decision Log

Append-only record of accepted and rejected design/strategy decisions. Do not copy full analysis here — link to the source document.

Use `/arb-doc-sync` to add or update entries after a validated change.

## Format

### D-000: <short decision title>
- **Status:** proposed | accepted | rejected | superseded
- **Date:** YYYY-MM-DD
- **Decision:** what was decided
- **Alternatives considered:** ...
- **Reason:** ...
- **Evidence:** link to research/design doc
- **Risks:** ...
- **Invalidation condition:** what evidence would overturn this decision

---

### D-001: Adopt VPFX `XAUUSD.vx` / `GC-Z26` as the working Phase 0 test configuration
- **Status:** proposed (not yet cleared by `/arb-risk-review` or `/arb-hostile-review`)
- **Date:** 2026-09-12
- **Decision:** Use VPFX (Ventura Prime FX Limited), single account, hedging mode, `XAUUSD.vx` (spot) vs
  `GC-Z26` (Dec 2026 gold futures, exp 25 Nov 2026) as the concrete instrument pair for all Phase 0 research
  (margin, hedge ratio, cost model), superseding the mandate's placeholder "XAUUSD vs GC" framing with an
  actual, verified broker/symbol pair.
- **Alternatives considered:** none evaluated yet — this is the only broker/account currently available to
  the user. Other brokers/symbols may still be worth comparing before a final Phase 0 decision.
- **Reason:** it's the account the user has live access to and could pull real Specification data from
  immediately, unblocking margin and hedge-ratio calculations without waiting on hypothetical broker data.
- **Evidence:** `docs/01_research/07_BROKER_RESEARCH.md` (spec table, margin-rate schedule), `docs/02_quant/16_HEDGE_RATIO.md`
- **Risks:** single-broker comparison bias — no evidence yet that this is the *best* available combination,
  only that it is *viable*. Live account (not demo) — no orders should be placed under this decision alone.
- **Invalidation condition:** if commission/settlement/rollover data (still open, see `07_BROKER_RESEARCH.md`)
  turns out unfavorable, or a materially better broker/instrument combination surfaces during `/arb-hostile-review`.
- **Evidence update (2026-09-16):** `GC-Z26`'s settlement mechanism is now confirmed from `symbol_info()`
  itself (`trade_calc_mode=SYMBOL_CALC_MODE_CFD`) — it is a cash-settled CFD, not a delivery-linked or
  exchange-cleared future. This is neutral to this decision (no alternative broker/instrument combination is
  known to avoid this — CFD-style gold futures replicas are standard at retail brokers), but it materially
  narrows how `12_FAIR_VALUE_MODEL.md`'s cost-of-carry model should be interpreted — see that document. Also
  found: `GC-Z26`'s `expiration_time` field reads 0 despite the stated 25 Nov 2026 expiry — no
  machine-readable rollover date exists yet (`docs/RISK_REGISTER.md` R-005). Neither finding invalidates this
  decision; both sharpen open items already named in "Risks" above.

### D-002: 0.01/0.01 lot achieves exact physical delta neutrality on this specific pair
- **Status:** accepted (calculation, not a live-trading approval)
- **Date:** 2026-09-12
- **Decision:** For `XAUUSD.vx` vs `GC-Z26` specifically, equal lot sizes produce exact 0 XAU net delta because
  both instruments share contract size 100. This does not generalize to other pairs and must be recalculated
  per instrument combination.
- **Alternatives considered:** dollar-notional matching (rejected — see reasoning in `16_HEDGE_RATIO.md`,
  "What the USD notional difference actually is").
- **Reason:** contract sizes are identical; the ~$42 notional gap is the basis being traded, not hedge error.
- **Evidence:** `docs/02_quant/16_HEDGE_RATIO.md`
- **Risks:** legging risk during the (however brief or extended) window between the two fills is unaddressed
  by this decision — it is a hedge-ratio result, not an execution guarantee.
- **Invalidation condition:** any evidence the two symbols' effective contract size diverges (e.g. a contract
  specification change, or a rollover to a futures month with different terms).

### D-003: Evaluate performance at economic-pair level
- **Status:** proposed
- **Date:** 2026-09-14
- **Decision:** assign a stable `PairID` to both hedge legs and use all-in pair-level P&L as the primary strategy-performance unit
- **Alternatives considered:** rely on native symbol-level or order-level MT5 statistics
- **Reason:** spot and futures legs can show misleading standalone profits, losses, win rates, and drawdowns; the strategy hypothesis exists only at combined-pair level
- **Evidence:** [`docs/01_research/06_EXISTING_SYSTEM_RESEARCH.md`](01_research/06_EXISTING_SYSTEM_RESEARCH.md) — Case Study 002 and public-signal analysis
- **Risks:** incorrect pairing across partial fills, restarts, scale-outs, or emergency closes
- **Invalidation condition:** an independently validated attribution method is shown to preserve the same economic information without deterministic pairing

---

No further decisions recorded yet.

### D-004: Collect synchronized tick-level bid/ask data via Windows VMware + extended Python collector
- **Status:** proposed (not yet cleared by `/arb-risk-review` or `/arb-hostile-review`)
- **Date:** 2026-09-14
- **Decision:** Extend `tools/mt5_data_collector.py` with `collect_tick_data()` (using
  `mt5.copy_ticks_range()`) and `compute_synchronized_basis()` (using `pd.merge_asof()`), and run the
  extended script inside a Windows VMware Fusion VM on the user's Mac (Option A). This is the next bounded
  Phase 0 data-collection step. Option B (a new MQL5 read-only export Script inside the Mac/Wine terminal)
  was evaluated and rejected for this step.
- **Alternatives considered:** Option B — MQL5 Script calling `CopyTicksRange()` inside Mac/Wine MT5,
  writing CSV to the MT5 sandbox. Rejected because: (1) introduces a new MQL5 artifact requiring
  design/review/compilation at Phase 0; (2) Wine sandbox extraction is more friction than Python's
  direct file output; (3) identical underlying tick-history limitation with more moving parts; and
  (4) Python is better suited to the downstream `pd.merge_asof()` synchronized-merge step.
- **Reason:** The MetaTrader5 Python package is Windows-only; VMware is the lowest-friction way to run
  it on the user's Mac without changing the existing script language or pipeline. The tick extension is
  a minimal addition to a script that already has the connection, symbol, and margin logic, and the
  output schema directly feeds `11_SPREAD_DEFINITION.md`'s distributional study.
- **Evidence:** `docs/01_research/08_TICK_DATA_COLLECTION.md` (full design, acceptance criteria, risks,
  validation steps), `tools/mt5_data_collector.py` (extended with tick functions). **Executed 2026-09-15**:
  the `--ticks` run completed on a native Windows machine (not the VMware guest originally planned — see
  `10_DATA_REQUIREMENTS.md` correction), producing 707,580 synchronized rows and satisfying acceptance
  criteria AC-2, AC-6, AC-7, AC-8 (see `02_quant/11_SPREAD_DEFINITION.md`). A later full run on
  2026-09-15 produced 707,467 synchronized rows in `research/2026-09-15T190918Z/`, confirming the
  collection path is repeatable. Status remains `proposed` —
  meeting the acceptance criteria is not the same as formal `/arb-risk-review`/`/arb-hostile-review` clearance.
- **Risks:** (1) VPFX simultaneous-login restriction — use a demo account in the VM or shut down the
  Mac terminal first; (2) shallow terminal tick history — run live for a full session before collecting;
  (3) 64-bit Python required. See `08_TICK_DATA_COLLECTION.md` R-A1 through R-A7.
- **Invalidation condition:** VMware not available or Windows VM not practical — fall back to Option B
  (requires a separate MQL5 script spec and review before implementation).

### D-005: Adopt a layered architecture skeleton before economics are finalized, with uncalibrated parameters explicitly marked
- **Status:** proposed (not yet cleared by `/arb-risk-review` or `/arb-hostile-review`)
- **Date:** 2026-09-15
- **Decision:** Fix the component boundaries `Market Data → Normalization → Fair Value/Spread → Signal → Risk
  → Execution → Broker Adapter → MT5` in `docs/03_system_design/20_SYSTEM_ARCHITECTURE.md` now, while
  `02_quant/12_FAIR_VALUE_MODEL.md` and `14_TRANSACTION_COST_MODEL.md` are still NOT STARTED — but mark every
  parameter that depends on those (thresholds, timeouts, safety margins) as UNCALIBRATED rather than choosing
  values.
- **Alternatives considered:** wait until the full economics milestone (cost model, EV, signal research) is
  complete before writing any `03_system_design/` document. Rejected for this step only because structural
  boundaries (layer responsibilities, state ownership, idempotency, restart reconciliation) do not depend on
  the numeric edge and can be designed/reviewed independently, per this project's own design-skill instruction
  to mark uncalibrated parameters rather than block on them.
- **Reason:** gives later documents (`21_EXECUTION_ENGINE.md`, `22_STATE_MACHINE.md`, `24_RISK_ENGINE.md`) a
  stable interface to fill in once economics close, without pretending the economics milestone is done.
- **Evidence:** `docs/03_system_design/20_SYSTEM_ARCHITECTURE.md`
- **Risks:** if read out of context, this document could be mistaken for a signal that the design/economics
  gate has passed. It explicitly has not — see the document's own "Gate status" section.
- **Invalidation condition:** if D-001 (broker/instrument pair) changes, or if the layer boundaries prove to
  need economics-dependent structure (not just parameters) once the cost model exists.

### D-006: Reject the hold-to-convergence structure (overnight long-spot / short-futures)
- **Status:** proposed (routes through `/arb-risk-review` and `/arb-hostile-review` before acceptance)
- **Date:** 2026-09-16
- **Decision:** Reject any strategy structure whose return depends on holding a long `XAUUSD.vx` /
  short `GC-Z26` pair overnight to capture basis convergence. This rejects a *structure*, not the project:
  intraday relative-value work on the same pair is explicitly not covered by this decision.
- **Alternatives considered:** (a) keep the structure open pending a shorter target holding period —
  rejected, because the finding is a per-day rate, so no overnight holding period escapes it; (b) pursue the
  mirror trade (short spot / long futures), which nets +$0.1238/day on the same measurements — **not
  recommended**, see `17_EXPECTED_VALUE.md` → "The reverse direction". Its entire return is a broker-set swap
  credit that can change without notice, and +$0.1238/day is small against a $2.77 residual std and ~$8 daily
  ranges, which is exactly the "edge small relative to uncertainty" the mandate requires be rejected.
- **Reason:** the trade's revenue term was never measured. The basis decays at **−$0.3905/day**
  (95% CI −$0.4480 … −$0.3330, R²=0.83, n=5,843,313 synchronized rows over 45 days), matching the carry
  model's independent prediction of −$0.4832/day. One-sided spot swap costs **−$0.7714/day**
  (−60 pts/day, ×3 Wednesdays). Net carry **−$0.3809/day, 95% CI entirely below zero**, before the $0.4975
  round trip. The prior analysis compared cost against the basis *level* instead of its *change* and so
  reported a positive residual where the true expected value is negative.
- **Evidence:** [`docs/02_quant/17_EXPECTED_VALUE.md`](02_quant/17_EXPECTED_VALUE.md) → "Correction
  2026-09-16"; [`docs/02_quant/13_BASIS_MODEL.md`](02_quant/13_BASIS_MODEL.md) → "Resolved 2026-09-16";
  `research/export-full/basis_summary.json` via `tools/tick_export_loader.py`.
- **Risks:** the decay rate is measured over a single 45-day window on a single contract approaching a single
  expiry, and swap rates are broker-set and can change. A different swap regime, or a contract at a different
  point in its life, could change the arithmetic — but would not change the method.
- **Invalidation condition:** a sustained spot swap rate whose cost falls below the measured basis decay
  (roughly, spot `swap_long` better than −39 points/day at current spot prices and time to expiry), or
  evidence that the decay rate is materially higher than measured over a longer or different window.
