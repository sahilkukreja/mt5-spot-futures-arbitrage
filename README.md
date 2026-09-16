# MT5 Spot–Futures Arbitrage — Greenfield Project

Status: **Phase 0 — Discovery / Documentation**. No strategy is approved. No MQL5 code exists yet.

This is a from-scratch (greenfield) design of an automated MT5 Spot ↔ Futures arbitrage/hedge platform,
starting with Gold Spot vs Gold Futures. See the full mandate at
[`docs/PROJECT_MANDATE.md`](docs/PROJECT_MANDATE.md) for the governing rules, phase gates, capital
constraints, and safety invariants — it takes precedence over anything below.

## Repository layout

```text
docs/                     Source of truth. All research, quant models, design, testing, and ops docs.
  PROJECT_MANDATE.md       Governing mandate — read this first.
  ROADMAP.md               Gate status and the ordered path from research close-out to implementation.
  DECISION_LOG.md          Accepted/rejected decisions.
  ASSUMPTIONS.md           Tracked assumptions and their validation status.
  OPEN_QUESTIONS.md        Unresolved questions blocking decisions.
  RISK_REGISTER.md         Identified risks, mitigations, owners.
  01_research/             Market/instrument mechanics research (current milestone).
  02_quant/                Spread, fair value, basis, cost, signal, hedge-ratio, EV models (current milestone).
  03_system_design/        Architecture, execution engine, state machine, recovery, observability.
  04_testing/              Simulation, tick replay, fault injection, demo/live test plans.
  05_development/          MQL5 architecture, coding standards, test plans.
  06_operations/           VPS, monitoring, alerting, kill switch, runbooks.
  sessions/                Dated working records of long research sessions — method corrections, pitfalls,
                            and carried-forward items. Not source of truth; see its README.

.claude/skills/            Claude Code skills that route and gate work by phase (see below).

reference/legacy/          Quarantined, reviewed-only prior project material. Not a baseline. Empty until
                            content is manually reviewed and promoted — see its README for the policy.

legacy/                    Raw, UNREVIEWED dump of the prior EA project. Gitignored. Reference only —
                            never a source of architecture, strategy, or parameters. Nothing here is
                            committed until manually reviewed and sanitized into reference/legacy/.

src/                       Empty. No implementation until the design gate in docs/03_system_design/ passes.
tools/                     Read-only research/data-collection scripts (e.g. MT5 terminal queries). Not the
                            trading system — never places, modifies, or closes an order. See tools/README.md.
research/                  Output of tools/ scripts and other local data/notebooks. Version-controlled (see
                            below) so work can move between machines — but still NOT source of truth; promote
                            findings into docs/ by hand after review.
                            Large tick/basis CSVs are stored via Git LFS (see .gitattributes). Run
                            `git lfs install` once on each machine before cloning or pulling, or the big
                            files arrive as pointer stubs instead of data.
```

## How to work on this project (Claude Code)

Skills under `.claude/skills/` gate and route work by phase:

- `/arb-plan` — pick the next permitted task and the files it may touch.
- `/arb-research` — market/instrument/data/quant research (`docs/01_research/`, `docs/02_quant/`).
- `/arb-design` — architecture and execution design (`docs/03_system_design/`), only after economics are documented.
- `/arb-risk-review` — capital, exposure, margin, kill-switch review.
- `/arb-hostile-review` — adversarial challenge before implementation or any live-stage graduation.
- `/arb-implement` — bounded implementation, only after its design gate has passed.
- `/arb-doc-sync` — keep `DECISION_LOG.md` / `ASSUMPTIONS.md` / `OPEN_QUESTIONS.md` / `RISK_REGISTER.md` in sync after a validated change.

Do not write MQL5 or start implementation before `docs/01_research/` and `docs/02_quant/` first-milestone
documents are complete and reviewed (see `docs/PROJECT_MANDATE.md` → "FIRST DEVELOPMENT MILESTONE").

## Parameter and future-scope policy

All unresolved questions remain parameterized research questions. A parameter must have a defined unit,
source, validation method, uncertainty, and status before it can become a design or runtime value. Do not
replace missing evidence with a hardcoded threshold, timeout, multiplier, or assumed broker behavior.

Current examples include:

- quote-staleness and cross-leg skew thresholds;
- orphan-leg timeout and emergency-flatten timing;
- margin-stress multiplier and account-level safety limits;
- time-to-convergence and maximum holding-period parameters;
- settlement, rollover, price-source, slippage, and execution-latency inputs.

Calibration, automated execution, broader broker support, multi-pair scaling, adaptive sizing, and other
strategy enhancements are future scope. They may be designed as interfaces or test scenarios, but they must
remain marked `UNCALIBRATED`, `UNRESOLVED`, or `FUTURE` until the required evidence and review gates pass.
Research outputs can inform these parameters; they do not approve live values or live trading.

## Capital and safety constraints (non-negotiable)

- Experimental capital ceiling: **USD 1,000**. Capital preservation outranks return.
- No martingale, grid averaging, loss-recovery sizing, or hidden directional exposure.
- 0.01 lot per leg is a *starting target*, not an assumption of equal exposure — hedge ratio must be calculated.
- No live trading until the phased graduation criteria in the mandate are met.

Full detail: [`docs/PROJECT_MANDATE.md`](docs/PROJECT_MANDATE.md).
