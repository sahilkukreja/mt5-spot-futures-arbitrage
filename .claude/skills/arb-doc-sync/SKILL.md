---
name: arb-doc-sync
description: Keep arbitrage project documentation consistent after a validated research, design, risk, or implementation change. Use to update decision, assumption, question, and risk records without rereading or rewriting the whole documentation tree.
---

# Arbitrage Documentation Sync

## Load first

Read `.claude/skills/PROJECT_STATE.md` before anything else. It carries the current gate status, the measured
constants, the canonical dataset, and the pitfalls that have already cost this project time. It is a cache —
`docs/` wins on any conflict.

Synchronize only material changes from the current task.

Read the changed document and search these registers for affected identifiers or terms:

- `docs/DECISION_LOG.md`
- `docs/ASSUMPTIONS.md`
- `docs/OPEN_QUESTIONS.md`
- `docs/RISK_REGISTER.md`

Do not rewrite full registers or copy long analysis into them.

For a decision record: decision, alternatives, reason, risks, evidence, validation, and invalidation condition.

For an assumption: stable ID, statement, status, evidence/validation owner, and result.

For a question: remove it only when the answer is documented and linked; otherwise refine it.

For a risk: stable ID, cause, consequence, severity, mitigation, trigger/metric, owner, and status.

Report exactly which records changed and flag contradictions rather than silently resolving them.

## Known staleness traps in this repository

Sweeps have repeatedly found these; check them specifically:

- Documents claiming another document "does not exist yet" or is "NOT STARTED" when it now has content.
- Q-002/Q-003/Q-004 sub-items resolved in one document but still listed open in another.
- Superseded numeric constants surviving in secondary documents: **USD 0.30/leg spread** (now USD 0.1545 / USD 0.2430),
  **USD 7.50 futures commission** (now USD 10/lot), any **AR(1) half-life** (withdrawn), the **USD 0.70 round trip**
  (now USD 0.4975).
- The mandate-checklist section of `OPEN_QUESTIONS.md` drifting out of sync with the per-question entries
  above it.
- `.claude/skills/PROJECT_STATE.md` — a cache of project state that goes stale by design. Re-sync it when
  gate status, measured constants, or the canonical dataset change.

When a finding inverts a prior conclusion, prefer marking the old text **superseded with the reason** over
deleting it. The error is often more instructive than the correction.

## Sweep the skill files themselves, not just `docs/` (added 2026-09-18)

`.claude/skills/*/SKILL.md`'s own "Project-specific ..." sections are exactly as capable of going stale as
any document in `docs/`, and by 2026-09-18 all seven had — describing an unapproved demo harness after D-008
accepted it and 2 real pairs had already run, repeating a disputed swap figure as settled, saying "no
component has an approved design" while the measurement harness had one. **When syncing after a material
change, check whether any `SKILL.md`'s dated project-specific section now contradicts it, not only `docs/`.**

**Prefer routing to `PROJECT_STATE.md` over restating a number inside a workflow-instruction skill.** A
skill's own "Project-specific inputs" section should explain *what to check and why it matters*
(e.g., "check the current Stage 2 pair count before calling the harness unauthorized") rather than hardcoding
the count itself — the count belongs in `PROJECT_STATE.md`, updated once, read by every skill. Duplicated
"current" facts across multiple skill files is the specific failure mode that caused the 2026-09-18 sweep;
each occurrence found during that sweep is now phrased as "check X, it may have changed" rather than
re-asserting a fixed number, and new skill content should follow the same pattern.
