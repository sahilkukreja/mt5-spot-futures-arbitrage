# Session record — 2026-09-16

Status: **working record, not source of truth.** Every finding below has been promoted into the canonical
document named beside it. If this file and a `docs/` document ever disagree, the `docs/` document wins.

**Why this file exists:** the working session that produced the 2026-09-16 round of evidence was long enough to
be context-compacted twice. This record preserves what was learned — including the method mistakes and dead
ends, which are the parts most likely to be repeated by a future session that only reads the polished
documents.

**Scope caveat:** this is a record of *research*, not of approved strategy. Nothing here approves a threshold,
a parameter, or live trading. See `docs/PROJECT_MANDATE.md`.

---

## 1. What this session was asked to do

In order, as requested:

1. Review the repo and plan next steps.
2. Close five identified gaps: `12_FAIR_VALUE_MODEL.md` and `13_BASIS_MODEL.md` being formula-only placeholders
   despite a 707k-row tick dataset already existing; `14_TRANSACTION_COST_MODEL.md` blocked on Q-002; Q-004
   having only n=7 realized pairs; no `17_EXPECTED_VALUE.md` existing; `RISK_REGISTER.md` R-002 needing an EV
   update.
3. Record `/arb-risk-review` findings in `RISK_REGISTER.md`.
4. Advance Q-002 (price source, opposite-direction restriction), Q-003 (all three sub-items), Q-004
   (time-to-convergence), and the mandate's undefined Required Safety Margin — with a persistent identifier
   scheme for Q-004 pair tracking.
5. Reassess the whole `legacy/` folder as historical work (reference/lessons-learned only, per the mandate).
6. Extend tick collection over a wider time-to-expiry window to actually test the carry model's prediction.
7. Verify that `GC-Z26` genuinely has 45 days of legitimate quoted history, and check whether an older or
   alternate gold-futures symbol exists at the broker.

---

## 2. Findings that are now durable

Each one lives in the canonical document listed; this is the index, not the analysis.

| Finding | Canonical home |
|---|---|
| Implied annualized carry rate held stable at **4.74% → 4.71%** (3 bp) when `T_years` widened 60% (0.1923–0.2115 → 0.1902–0.3124) across a 7x larger sample (707,467 → 5,111,120 rows). This is a genuine pass of the carry model's central falsifiable prediction. | `02_quant/12_FAIR_VALUE_MODEL.md` → "45-day validation" |
| Unexplained residual over SOFR (3.64%, FRED, 2026-09-15) is **~1.07 pp ≈ $11.90 ≈ 23%** of the mean mid-basis — stable across both collections, so a structural feature rather than a narrow-window artifact. Still cannot distinguish "broker CFD markup" from "genuine mispricing" with one broker's quotes. | `02_quant/12_FAIR_VALUE_MODEL.md` |
| 45 days is the **real ceiling** of local terminal tick history, not an arbitrary choice — `copy_ticks_range()` lookback plateaus at the same tick count between 45 and 60 days back. | `02_quant/12_FAIR_VALUE_MODEL.md` |
| `GC-Z26` was **not** thinly quoted or newly listed inside that window — tick density held at 54k–220k ticks/day back to the earliest sampled day, with zero-tick days landing exactly on Saturdays. | `02_quant/12_FAIR_VALUE_MODEL.md` |
| The R-004 stale-quote anomaly went from 1 occurrence to 3, and the two datable ones (2026-09-04 13:30:01–07 UTC, 2026-09-11 13:30:11 UTC) are **both Fridays, 7 days apart, within 17 seconds of 13:30 UTC**. | `02_quant/13_BASIS_MODEL.md` → "Anomaly isolated"; `RISK_REGISTER.md` R-004 |
| `GC-Z26` settlement mechanism resolved: `trade_calc_mode` = `SYMBOL_CALC_MODE_CFD` (read from the symbol spec, not the marketing name) — cash-settled CFD. But `expiration_time` reads **0** despite the description saying "Exp 25 Nov 2026": no machine-readable expiry exists. | `02_quant/14_TRANSACTION_COST_MODEL.md` → "Q-002 update"; `DECISION_LOG.md` D-001 |
| Opposite-direction positions are permitted — **8 real filled instances**, none rejected, 2026-09-11 to 2026-09-15. Direct evidence, not just absence of a documented restriction. | `OPEN_QUESTIONS.md` Q-002 |
| Futures commission corrected to **$10/lot round trip** ($0.10 per 0.01/0.01 pair); the earlier $7.50 figure was an unsourced assumption and is now recorded as invalidated. | `02_quant/14_TRANSACTION_COST_MODEL.md`; `ASSUMPTIONS.md` A-004 |
| The live account is running **4 concurrent pairs**, not 1 — margin usage ≈$525, margin level ≈191% (vs ≈771% for a single pair). Materially different risk picture from what was documented. | `02_quant/14_TRANSACTION_COST_MODEL.md`; `RISK_REGISTER.md` R-002 |
| Margin-stress multiplier is **not** the binding risk at 0.01 lot — a 20% adverse move adds only ≈$26 to the ≈$130 baseline. The binding risk is notional directional exposure during a leg mismatch (R-003). | `OPEN_QUESTIONS.md` Q-003; `01_research/07_BROKER_RESEARCH.md` |
| Quote-skew p95 = 384 ms, p99 = 452 ms → **400 ms research candidate** (explicitly not approved). Confirmed blind spot: the R-004 anomaly's own skew was 238 ms, inside the candidate, so a skew-only gate would have missed it. | `02_quant/13_BASIS_MODEL.md` → "Quote-staleness threshold" |
| This account's entire symbol universe is **exactly 2 symbols** — `XAUUSD.vx` and `GC-Z26`. No other gold futures month exists, older or newer. Mild reassurance against silent contract substitution; a sharp new rollover risk, since there is no successor symbol to roll into. | `RISK_REGISTER.md` R-005 |
| The legacy EA's failure rate is far worse than first recorded: **408 `OpenLeg FAIL` events in under 50 minutes** on 2026-03-02, hitting *both* legs (XAUUSD.pp 359, GCJ26.ma 49), recurring on a separate day from the originally noted 2026-03-01 session. One rollback event observed. | `01_research/06_EXISTING_SYSTEM_RESEARCH.md` |
| The legacy retry matrix (`ShouldRetry()`, `InpMaxOpenRetries`) exists only in `MMT_TradePannel_Pro_v284.cpp` — verified directly that `best_code.cpp` (v3.26, the file the legacy README calls canonical production) has **no** retry logic at all: single-attempt `OrderSend` per leg. | `01_research/06_EXISTING_SYSTEM_RESEARCH.md` |

---

## 3. Method corrections and pitfalls — the reusable part

These cost real time. A future session should read this section before the polished documents.

### 3.1 The AR(1) decay proxy for Q-004 is not robust, and a short window hid it

The tick-level mean-reversion half-life estimate (`Δbasis_t = a + b·basis_{t-1}`, half-life = `ln(2)/(-b)`) was
re-run on the 45-day dataset and **every half-life estimate inflated massively** — 1-minute grid went from
≈112 min to ≈1,437 min; 240-minute grid from ≈1,491 min to ≈82,987 min, with no method change at all. The
diagnostic: the fit's own implied local mean swings ~35 points across resampling grids on the same series
(51.11 at 1-min vs 15.78 at 240-min).

**Cause:** the raw dollar `convergence_basis` series is not stationary over 45 days — it is contaminated by the
~8% drift in the underlying spot price (roughly $4,072 on 2026-08-02 to the low $4,300s by 2026-09-16). AR(1)
mean-reversion estimation on a trending series measures the trend, not the reversion.

**Status:** withdrawn as usable Q-004 evidence. **Proposed fix (not yet implemented):** re-run the same method
on the *implied annualized carry rate* series, which independently proved far more stationary.

**Generalizable lesson:** a decay/half-life estimate from a short window must be re-tested at a longer window
before being trusted. The short-window number looked perfectly plausible and was wrong.

### 3.2 Non-ASCII characters in `print()` crash on the Windows console

The 45-day collection crashed with `UnicodeEncodeError: 'charmap' codec can't encode character '→'` —
traced to a `→` in a print statement inside `tools/mt5_data_collector.py`'s `_to_df()`. The Windows console
codepage is cp1252. Em-dash (`—`, U+2014) is safe; arrow (`→`, U+2192) is not.

**This masked a real success.** The retry logic had emitted misleading errors on earlier attempts ("Terminal:
Call failed", then "Success" with empty data) — those were separate transient issues. Attempt 3 actually
fetched the data fine, and the print-statement crash destroyed the run anyway. Do not diagnose a data or
connectivity problem before ruling out an encoding crash in the reporting path.

All `tools/*.py` files were scanned by codepoint after the fix; only em-dashes remain.

### 3.3 Legacy log files are UTF-16 — plain grep silently finds nothing

`legacy/SPOT-FUR-ARB-BOT/trade_history/sessions/2026-03-02_session.log` is UTF-16 encoded. A plain ASCII/UTF-8
`grep` for "FAIL", "retcode", etc. returned **zero matches**, giving the false impression that the session had
no failures. Decoding explicitly in Python (`raw.decode('utf-16')`) revealed 408 real failure events.

**Rule for any future legacy-folder search:** check the file encoding before concluding a search found nothing.

### 3.4 Context compaction caused duplicated work

A persistent pair-tracking mechanism (`update_pair_log`, `PAIR_LOG_PATH`) was rebuilt inside
`mt5_data_collector.py`, duplicating an already-committed standalone `tools/pair_ledger.py` written in a part
of the session hidden by compaction. Detected when `git diff HEAD` showed zero difference for files that had
just been edited, and `git log` / `git show --stat` revealed the existing commit `03dde63 "research"`.

**Rule:** after a compaction, run `git log` and `git diff HEAD` before building anything that sounds like it
might already exist.

### 3.5 Stale cross-references accumulate between documents

Two were found by self-consistency check: `17_EXPECTED_VALUE.md` said Q-002's opposite-direction item was
"fully open" after it had been resolved; `RISK_REGISTER.md` R-006 said `14_TRANSACTION_COST_MODEL.md` and
`17_EXPECTED_VALUE.md` "do not exist yet" when both existed. Both corrected. Worth a periodic sweep —
`/arb-doc-sync` exists for exactly this.

### 3.6 Data-quality caveat left open

`open_pairs_censored.csv` from the 45-day run shows negative `duration_hours_at_snapshot` values (as low as
−0.65h) — almost certainly a small clock-sync offset between this machine and the broker server, not a real
negative duration. It does not affect any closed-pair statistic (those use `close_time − open_time` and are
immune to a constant clock offset). Noted in `13_BASIS_MODEL.md`, not investigated further.

---

## 4. Tooling changes made this session

- **`tools/pair_ledger.py`** — added `load_open_pairs(path)` and a `--open-pairs-csv` flag, now the preferred
  input. The older `load_censored_pairs()` is fallback-only: it does a naive same-symbol cross-product and can
  fabricate spurious pairs. Verified end-to-end on a real run — ledger grew 7 → 12 pairs (8 closed, 4 open) and
  correctly transitioned the 8th pair from open to closed rather than duplicating it. Stable PairID is
  `{spot_position_id}_{fut_position_id}`; "closed" is a terminal state.
- **`tools/q3_q4_research.py`** — added `_ar1_halflife()`, `analyze_basis_decay()`, `find_basis_anomaly()`,
  `analyze_fair_value()`, and the CLI flags `--decay-resample-minutes`, `--anomaly-threshold`, `--expiry-date`,
  `--sofr-rate`, `--sofr-rate-date`.
- **`tools/mt5_data_collector.py`** — kept `collect_open_positions()` / `match_open_pairs()`; removed the
  duplicated ledger functions (see 3.4); fixed the cp1252 crash (see 3.2).
- **`tools/research_questions.py`** — removed a duplicated `serialize_positions()`; added `orphan_candidate_legs`
  and `next_step` to its summary output.

Reproduction command for the fair-value/decay analysis:

```
python tools/q3_q4_research.py --expiry-date 2026-11-25 --sofr-rate 0.0364 --sofr-rate-date 2026-09-15
```

Archived outputs (in the gitignored `research/`, **not** committed):
`research/2026-09-15T190918Z/` (7-day, 707,467 rows) and `research/2026-09-16T140628Z/` (45-day, 5,111,120
rows, ~1 GB `basis_synchronized.csv`), plus the persistent `research/pair_ledger.csv`.

---

## 5. Open items carried forward

Not done, in rough priority order:

1. **Re-implement the Q-004 decay proxy on the implied-rate series** (or de-trend the basis series) — proposed
   in 3.1, not yet built. This is the single largest outstanding piece of Q-004 evidence.
2. **Root-cause the Friday ~13:30 UTC R-004 clustering** — check which US economic release, if any, lands at
   08:30 ET on 2026-09-04 and 2026-09-11. Two occurrences is a pattern worth one hour of checking, not yet a
   conclusion.
3. **Write a rollover runbook item** (`06_operations/`) — explicitly request and confirm the next contract's
   symbol from the broker well before 25 Nov 2026, rather than assuming it appears. Driven by the R-005 finding
   that no successor symbol exists in this terminal today.
4. **Promote sanitized legacy findings** into `reference/legacy/SPOT-FUR-ARB-BOT/{source,configs,docs,samples}/`
   per the quarantine policy. Offered, not yet requested.
5. **Broader open-source/academic research** on spot-futures gold basis — the remaining unaddressed item from
   `06_EXISTING_SYSTEM_RESEARCH.md`'s original scope.
6. **Ask broker support** for the `XAUUSD.vx` price source (Q-002). Confirmed *not* answerable from public
   sources — one WebSearch and two WebFetch attempts against vpfx.net found only that VPFX is Labuan
   FSA-regulated (MB/20/0046) and offers MT5 CFDs; no page discloses gold feed methodology. The `exchange: "CME"`
   field on `XAUUSD.vx` is flagged unreliable — spot gold is not CME-listed.

## 6. Action items that belong to the user, not to a future session

Two credentials were found in the gitignored `legacy/` dump during the reassessment and are flagged (without
being reproduced) in `01_research/06_EXISTING_SYSTEM_RESEARCH.md` → "Security note on this legacy dump": an MT5
demo account login/password in `legacy/SPOT-FUR-ARB-BOT/Untitled-1.js`, and a Telegram bot token hardcoded as
an `InpTeleToken` default in `.../latest code/MMT_Gap_Alerts_TG.mq5`. Neither has ever been committed.
**Both should be rotated by the account owner.** No agent can do this.

---

## 7. Standing constraints honored (and to keep honoring)

- Legacy material is reference and lessons-learned **only** — never an architecture, strategy, or parameter
  baseline. Everything in section 2's legacy rows is a cautionary finding, not a design input.
- Credentials found in `legacy/` are never reproduced in a committed file and never committed.
- ~~`research/` is gitignored and stays that way~~ — **changed 2026-09-16 by explicit user decision.**
  `research/` is now version-controlled so work can move between machines, with large tick/basis CSVs stored
  via Git LFS (`.gitattributes`). The part that has not changed: `research/` is still **not source of truth**,
  and findings are still promoted into `docs/` by hand after review.
- The account number is deliberately not printed by the tools and must not be pasted into any committed file.
- Nothing is committed to git unless explicitly asked.
- No threshold in this record is approved. 400 ms, the velocity signal, and every other number here remain
  `UNCALIBRATED` research candidates.
