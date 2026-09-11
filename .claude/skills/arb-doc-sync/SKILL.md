---
name: arb-doc-sync
description: Keep arbitrage project documentation consistent after a validated research, design, risk, or implementation change. Use to update decision, assumption, question, and risk records without rereading or rewriting the whole documentation tree.
---

# Arbitrage Documentation Sync

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
