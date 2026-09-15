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
  validation steps), `tools/mt5_data_collector.py` (extended with tick functions)
- **Risks:** (1) VPFX simultaneous-login restriction — use a demo account in the VM or shut down the
  Mac terminal first; (2) shallow terminal tick history — run live for a full session before collecting;
  (3) 64-bit Python required. See `08_TICK_DATA_COLLECTION.md` R-A1 through R-A7.
- **Invalidation condition:** VMware not available or Windows VM not practical — fall back to Option B
  (requires a separate MQL5 script spec and review before implementation).
