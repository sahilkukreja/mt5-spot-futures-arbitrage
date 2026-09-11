# Existing System Research

Status: IN PROGRESS (internal legacy review done; public/commercial/academic research still pending)

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
The `/legacy` folder (gitignored, raw/unreviewed) contains a prior in-house EA (SPOT-FUR-ARB-BOT). Per the
project mandate, it may be reviewed here as reference material / lessons learned only — it must not constrain
the new architecture. See `reference/legacy/SPOT-FUR-ARB-BOT/README.md` for the quarantine policy.

Reviewed 2026-09-12, at the user's explicit request. **Important scope note:** the legacy bot was run on
different brokers entirely — symbol suffixes found in its code/logs are `.ma`, `.u`, and `.pp` (e.g.
`GCJ26.ma`, `GCM26.u`, `XAUUSD.u`, `XAUUSD.pp`), none of which match VPFX's `.vx` suffix used in the current
account (`docs/01_research/07_BROKER_RESEARCH.md`). **None of its broker-specific numbers (spreads, margin,
commission, swap, session hours) transfer to VPFX/`XAUUSD.vx`/`GC-Z26`.** Only execution-architecture and
failure-mode lessons are portable, and even those are hypotheses to validate, not adopted design.

### Reusable patterns (architecture/execution ideas worth evaluating independently in `03_system_design/`)

- **Execution-aware gap definition**: legacy used `Bid(Futures) − Ask(Spot)` for a sell-direction pair and
  the mirrored `Ask(Futures) − Bid(Spot)` for buy-direction — i.e. always the executable, not mid, price.
  This matches the mandate's `REAL EXECUTABLE PRICES` section independently; worth treating as a validated
  pattern rather than a coincidence.
- **Confirm timers on entry/exit** (`OAG confirm` / `CAG confirm`, e.g. 800ms in one version): require the
  spread/gap condition to hold continuously for a duration before firing, as an anti-spike filter against a
  single bad tick.
- **State machine with an explicit broken-leg state** (`PSTATUS_BROKEN`): the legacy panel modeled "only one
  leg is open" as its own recognized state rather than an implicit/unhandled condition — directly relevant to
  the mandate's `NO ORPHANED HEDGE LEG WITHOUT RECOVERY` invariant.
- **Async execution with a watchdog + rollback**: later legacy versions (v2.84+) fired both legs
  non-blocking, then rolled back the filled leg if the counterpart didn't fill within a deadline
  (`InpAsyncOpenDeadlineMs`), rather than leaving a naked position.
- **Reconciliation on restart**: legacy scanned deal history on `OnInit` to detect fills that happened while
  the EA was offline — relevant to `docs/03_system_design/28_FAILURE_RECOVERY.md` (not yet written) and the
  general principle (also independently stated in `arb-design`'s skill file) that broker positions are
  authoritative over any locally cached state.
- **Spread filter blocking entries** on abnormally wide bid/ask, independently per leg.
- **Concurrency caps** on simultaneous opening/closing pairs, to bound broker-side load.
- **Quantile-based threshold planning**: a separate "Gap Radar" tool computed rolling Z-scores, percentiles,
  and correlation between legs to suggest OAG (≈P85–P95) / CAG (≈P40–P60) levels from data — directionally
  consistent with the mandate's `NO MAGIC OAG/CAG VALUES` requirement to derive thresholds from observed
  distributions rather than picking them arbitrarily.

### Observations (empirical, from one logged session — `trade_history/analysis/2026-03-01_analysis.md`, EA
v2.82, different broker)

- The raw session log (`sessions/2026-03-01_session.log`) shows this was worse than the analysis note's "twice"
  summary: `GCJ26.ma SELL` was rejected with `retcode 10044` on **every single retry, dozens of times over
  roughly 15+ minutes** (19:13–19:27), across many different confirmed trigger prices (cg ranging 14.00–14.26)
  — i.e. the rejection was persistent and price-independent, not a one-off spike. This is a **hypothesis**,
  not a confirmed root cause (the analysis doc suspects a session-boundary or contract-availability issue),
  and it is broker/contract-specific — but it demonstrates a concrete, sustained failure mode the mandate's
  `EXECUTION AGENT` and `NO ORPHANED HEDGE LEG WITHOUT RECOVERY` invariant must handle: a leg can be
  structurally unopenable for an extended period while the confirm-timer/retry loop keeps re-triggering
  against it with no escalation, alert, or backoff — the legacy panel had no max-retry-then-alert/kill
  behavior visible in this log for the *scheduled* (as opposed to async v2.84+) execution path. Reinforces
  the mandate's `NO NEW ENTRY AFTER KILL-SWITCH ACTIVATION` and the need for a hard retry ceiling with
  escalation, not indefinite re-attempts against a persistently rejecting leg.
- In that session, CAG (auto-close target) was left at 0 on all schedules — i.e. the operator was relying on
  manual close rather than automated mean-reversion exit. Noted only as an observation of past operational
  practice, not a recommendation.

### Rejected pattern

- The bundled `## Input reference.md` file documents an unrelated Donchian-breakout trend-following EA (not
  the spot/futures arbitrage panel) and includes a direct rejection of a "20%/month" return target as
  economically incoherent (≈792%/year annualized) and correlated with ruin-risk position sizing rather than
  genuine edge. **Rejected pattern, recorded as a reference point**: any future expected-value work in
  `docs/02_quant/17_EXPECTED_VALUE.md` should be sanity-checked against realistic systematic-strategy return
  ranges (the note suggests 3–8%/month as an optimistic-but-plausible ceiling for a *validated* systematic FX/
  gold strategy) rather than accepting an aggressive target at face value.

### Not yet done

Public/commercial MT5 arbitrage products, academic research, and broader open-source systems (per the
`## Scope` section above) have not been researched yet — only the internal legacy codebase has been reviewed
so far, at the user's explicit request.
