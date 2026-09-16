# Session records

Dated working records of long research sessions. **Not source of truth.** Where a session record and a `docs/`
document disagree, the document wins.

## Why these exist

Long sessions get context-compacted, and what survives into the polished documents is the *conclusion* — not
the dead ends, the method mistakes, the encoding traps, or the "we already built this last week" moments.
Those are the parts most likely to be repeated. A session record preserves them.

## What belongs in one

- What the session was asked to do.
- An index of findings, each pointing at the canonical document that now owns it.
- **Method corrections and pitfalls** — the most valuable section. Be specific and unflattering.
- Tooling changes and reproduction commands.
- Open items carried forward, and any action items that belong to the user rather than to an agent.

## What does not

- The analysis itself — that goes in `01_research/`, `02_quant/`, etc.
- Any approved threshold or parameter. Session records approve nothing.
- Credentials, account numbers, or anything from `research/` or `legacy/` that has not been sanitized.

## Naming

`YYYY-MM-DD_session-record.md`, one per session. If a single day has more than one distinct session, suffix
`-02`, `-03`.

## Index

- [2026-09-16](2026-09-16_session-record.md) — 45-day tick collection validates the carry model; AR(1) decay
  proxy for Q-004 found unreliable and withdrawn; legacy folder reassessed (408 failure events); symbol
  universe confirmed to be exactly two instruments.
