# Arbitrage Project Skills

This is the canonical, maintained location for this project's Claude Code skills. There is no other copy —
edit skills here directly so they never drift out of sync.

## Skills

- `/arb-plan` selects the next permitted task and context files.
- `/arb-research` handles market, instrument, data, and quantitative research.
- `/arb-design` produces system, execution, state, recovery, and observability designs.
- `/arb-risk-review` challenges capital, exposure, margin, and operational safety.
- `/arb-implement` is unavailable until the design gate passes, then performs bounded implementation work.
- `/arb-hostile-review` tries to invalidate economics and architecture before implementation or live-stage graduation.
- `/arb-doc-sync` keeps `docs/DECISION_LOG.md`, `docs/ASSUMPTIONS.md`, `docs/OPEN_QUESTIONS.md`, and
  `docs/RISK_REGISTER.md` in sync after a validated change, without rereading or rewriting the whole doc tree.

Keep durable project knowledge in `docs/`. Skills should stay workflow rules (what to read, what to check,
what to produce, what to gate) — not copies of project documents. If a skill's body starts duplicating facts
that belong in `docs/`, move the facts out and leave a pointer.

## Adding or changing a skill

1. Each skill is a folder here with a `SKILL.md` containing YAML frontmatter (`name`, `description`) and a body.
2. Keep the `description` specific and trigger-oriented — it is what Claude uses to decide when to load the skill.
3. Keep the context budget section explicit: name exactly which `docs/` paths the skill may read, and push back
   on any change that would make a skill preload the entire documentation tree or the legacy reference material.
4. Preserve the phase gates already encoded across skills (research → design → risk/hostile review → implement).
   Do not loosen `/arb-implement`'s gate or the "never authorize live trading" language in the review skills
   without an explicit decision recorded in `docs/DECISION_LOG.md`.
5. After changing a skill in a way that affects what gets read/written, sanity-check it against
   `docs/PROJECT_MANDATE.md` — skills route work, the mandate is still the higher authority.

## Legacy reference location

Keep reviewed prior source material under:

`reference/legacy/SPOT-FUR-ARB-BOT/`

Start with source and safe configuration examples only. Do not commit credentials, account identifiers, raw
private logs, compiled binaries, reports, screenshots, or nested archives until they are reviewed. The skills
do not load this folder automatically.
