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

---

No further risks recorded yet.
