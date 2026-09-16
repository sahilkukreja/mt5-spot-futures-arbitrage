# Existing System Research

Status: IN PROGRESS (internal legacy review done and reassessed 2026-09-16 against the full legacy file tree —
see the strengthened 2026-03-02 finding below; public/commercial MQL5-ecosystem research done; broader
open-source/academic research still pending)

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
- **Per-error-code retry classification, validated as a good pattern but confirmed NOT to have reached the
  actual production file — read the source, not just the version-history claims (2026-09-16):**
  `MMT_TradePannel_Pro_v284.cpp` has a real `ShouldRetry(retcode, waitMs)` function that whitelists a small set
  of transient codes (requote, price-changed/off, too-many-requests, connection, timeout) as retryable with a
  code-specific backoff, and treats everything else — **including any unrecognized/"unknown" retcode, via an
  explicit `default: return false`** — as fatal, not retried, capped by `InpMaxOpenRetries=3`. This is a good
  pattern worth adopting directly: default-to-non-retryable for unrecognized broker error codes, rather than
  default-to-retry. **However**, `best_code.cpp` (v3.26, the file the legacy README names as canonical
  production) was checked directly (not just inferred from `CODE_VERSIONS.md`'s summary) and contains **no**
  `ShouldRetry`, no `InpMaxOpenRetries`, and no per-error-code classification at all — each `OpenLeg` call is a
  single `OrderSend`/`OrderSendAsync` attempt that logs and returns on failure, with nothing tracking a
  rejection streak across repeated trigger re-fires over time. `best_code.cpp` does have
  `CloseSingleOpenLeg(...)` rollback for leg2-failed-after-leg1-filled (the partial-fill case), but that is a
  different mechanism from a cross-attempt circuit breaker, and does not stop the same OAG condition from
  re-firing a brand-new single-shot attempt every time it re-triggers. **Do not assume the "latest/canonical"
  legacy file carries forward every safety mechanism documented for an earlier version** — verify the actual
  source. This project's own execution engine needs a cross-attempt, per-symbol consecutive-rejection counter
  with cooldown/escalation, independent of and in addition to any per-order-send retry logic.
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

### Observations (empirical, from two logged sessions on consecutive days — EA `MMT_TradePannel_Pro`,
different broker, symbols `GCJ26.ma`/`XAUUSD.pp`)

- **2026-03-01** (`trade_history/analysis/2026-03-01_analysis.md`, raw log `sessions/2026-03-01_session.log`,
  labeled EA v2.82): this was worse than the analysis note's "twice" summary — `GCJ26.ma SELL` was rejected
  with `retcode 10044` on every single retry, dozens of times over roughly 15+ minutes (19:13–19:27), across
  many different confirmed trigger prices (cg ranging 14.00–14.26).
- **2026-03-02 update (this review, reassessed 2026-09-16) — materially larger and more severe than the prior
  write-up implied.** The raw log `sessions/2026-03-02_session.log` is UTF-16 encoded (a plain ASCII/UTF-8
  grep silently finds nothing in it — worth remembering if this folder is searched again). Decoded, it shows
  **408 `OpenLeg FAIL ... ret=10044` events in under 50 minutes** (01:26:09–02:16:18), not "dozens over 15
  minutes" — and critically, **the rejections hit both legs, not just the futures leg**: `XAUUSD.pp` (the spot
  leg) failed **359 times**, `GCJ26.ma` (futures) failed **49 times**, all the same retcode. This changes the
  most likely explanation: a rejection that also hits a liquid, continuously-tradeable spot gold symbol is
  harder to explain by "futures contract session boundary" alone (the 2026-03-01 analysis's leading
  hypothesis) — it looks more consistent with an account-, connection-, or broker-side condition (e.g. trading
  temporarily disabled, a margin/permission check, or a broker-wide state) than a symbol-specific one. Still a
  **hypothesis, not a confirmed root cause** — this project has no access to that broker's server-side logs.
  The failures stopped abruptly at 02:16:18 and normal fills resumed immediately after (`SCHEDULED TRIGGER
  CONFIRMED` → `OPEN` with no further `FAIL` lines), which is more consistent with a time-boxed condition
  clearing than a permanent block. One rollback event is visible in the log (`"Second leg failed -> rollback
  first leg"` at 02:16:18) — i.e., in at least one of the 408 attempts, one leg did fill before the other
  failed, and the panel's rollback path fired correctly even under this sustained failure condition. That the
  same structural failure **recurred on a separate calendar day** against the same symbol pair, with no
  evidence the operator diagnosed or fixed it between sessions, is itself the strongest part of this finding:
  this was a durable, multi-day, multi-hundred-attempt failure mode, not a one-off. It demonstrates a concrete,
  severe failure mode the mandate's `EXECUTION AGENT` and `NO ORPHANED HEDGE LEG WITHOUT RECOVERY` invariant
  must handle: a leg (or both legs) can be structurally unopenable for hours while a confirm-timer/retry loop
  keeps re-triggering against it roughly once a minute with no escalation, alert, circuit breaker, or backoff
  — 408 consecutive rejected order attempts against a live broker is also itself an operational/reputational
  risk (rate-limiting, account flagging) independent of the missed-trade cost. Reinforces the mandate's
  `NO NEW ENTRY AFTER KILL-SWITCH ACTIVATION` and the need for a hard retry ceiling with escalation — e.g.
  halt-and-alert after N consecutive rejections on the same symbol within a short window — not indefinite
  re-attempts against a persistently rejecting leg.
- In the 2026-03-01 session, CAG (auto-close target) was left at 0 on all schedules — i.e. the operator was
  relying on manual close rather than automated mean-reversion exit. Noted only as an observation of past
  operational practice, not a recommendation.

### Security note on this legacy dump (2026-09-16, do not act on this as a strategy/architecture finding)

Two files in `legacy/SPOT-FUR-ARB-BOT/` contain live-looking plaintext credentials: an MT5 demo-account
login/password (`Untitled-1.js`) and a Telegram bot token (`mmt/spot_future_arb_code/latest code/MMT_Gap_Alerts_TG.mq5`,
hardcoded as the `InpTeleToken` input default). Neither is reproduced here. Both files are already excluded by
`.gitignore` (the whole `legacy/` folder is quarantined and has never been committed), and nothing has been
promoted into `reference/legacy/` yet, so there is no git-history exposure from this repo. Recommend the user
rotate both credentials (regenerate the Telegram bot token via BotFather; change the demo account password) as
a precaution, and never let either value be copied into `reference/legacy/` or any committed file during future
promotion.

### Rejected pattern

- The bundled `## Input reference.md` file documents an unrelated Donchian-breakout trend-following EA (not
  the spot/futures arbitrage panel) and includes a direct rejection of a "20%/month" return target as
  economically incoherent (≈792%/year annualized) and correlated with ruin-risk position sizing rather than
  genuine edge. **Rejected pattern, recorded as a reference point**: any future expected-value work in
  `docs/02_quant/17_EXPECTED_VALUE.md` should be sanity-checked against realistic systematic-strategy return
  ranges (the note suggests 3–8%/month as an optimistic-but-plausible ceiling for a *validated* systematic FX/
  gold strategy) rather than accepting an aggressive target at face value.
- **Re-read in full 2026-09-16 — the strategy logic is correctly irrelevant, but its risk-control input table
  is a reusable pattern that was missed on the first pass.** Independent of the (unrelated) Donchian strategy,
  the same file's input reference documents a portable risk-limit vocabulary directly relevant to this
  project's still-unwritten `03_system_design/24_RISK_ENGINE.md` and the mandate's still-empty `INITIAL RISK
  LIMITS` section: a daily-loss-percent limit plus a separate consecutive-loss-count limit (two independent
  gates, not one), a weekly-drawdown-percent limit, and an equity-drawdown-from-peak "pause" that explicitly
  requires **manual restart** rather than auto-resuming once the drawdown condition clears. That last one is
  the notable pattern: distinguishing a limit that blocks new entries temporarily (auto-clears) from one that
  halts and requires a human to explicitly re-arm the system — directly analogous to the mandate's own `NO NEW
  ENTRY AFTER KILL-SWITCH ACTIVATION` invariant, now with a concrete precedent for *which* triggers should be
  auto-clearing vs. human-gated. This is a **reusable pattern for the risk engine's limit taxonomy**, not a
  recommendation to reuse any of the file's actual numeric thresholds (those are for a different instrument,
  strategy, and account).

---

## Case Study 001 — Gold Futures Spot Arbitrage EA

- Product: [Gold Futures Spot Arbitrage EA](https://www.mql5.com/en/market/product/174063)
- MQL5 product ID: `174063`
- Research date: 2026-09-14
- Evidence: public product description and four user-supplied product screenshots
- Classification: cost-of-carry / basis-convergence trading with hedged exposure; not risk-free arbitrage
- IP boundary: study public claims and observable behaviour only. Do not decompile, copy proprietary code, or make this product the project baseline.

### Publicly confirmed

The seller states that the product:

- is designed only for a Gold Futures / Spot Gold pair;
- trades the futures/spot price distance rather than predicting outright gold direction;
- relies on futures convergence toward spot as expiry approaches;
- requires exact broker symbol names and the correct futures expiration date;
- uses a broker-dependent `Shrink` input, especially for long-spot swap;
- is sensitive to news, volatility, spread, execution, swap, commission, and contract conditions;
- should be configured and tested for the specific broker before live use.

The seller suggests a practical `Shrink` range of approximately `0.5–1.0`, but this is a vendor claim, not a universal parameter.

### Observed from screenshots

These are UI observations, not proof of the underlying algorithm.

#### Visible inputs

| Input | Observed value |
|---|---:|
| Fixed Lotsize (0 = Auto) | 0.1 |
| Lot Steps | 0.1 |
| Futures symbol (Bid leg) | `GC6M.f` |
| Spot symbol (Ask leg) | `XAUUSD.f` |
| Brick size (price units) | 0.5 |
| 1 = simple; 2 = classic reversal | 2.0 |
| Snap initial baseline to nearest Step | false |
| Debug logs | true |
| Exclude immediate 1-step reversals from MA | true |
| Equality tolerance | 0.001 |
| Min. UP - DN ($) | 1.5 |
| Min Delta to trade | 5.0 |
| Worst Delta | 100.0 |
| Max risk % of balance at worst delta | 15.0 |
| Magic number | 777 |
| Min profit ($ per 10k balance) | 10.0 |
| Profit uplift with more pairs | 0.5 |
| Global profit take (% of balance, 0 = off) | 0.5 |
| Max allowed spread (points) per symbol | 60 |
| No first entry after this hour (-1 = off) | 21 |
| Min ms between send attempts | 500 |
| Duplicate window for same FP | 8 |
| If second leg not live within this, close orphan | 5 |
| Allow at most 1 new pair per second | true |
| Initial Delta Start | 0.0 |
| ExpDate | 2026-05-26 00:00:00 |
| Shrink Per Day ($0.5 to $1.0) | 0.7 |
| Delta to Shrink Space | 0.5 |

One subsequent input appears to begin with `Force Close`; its full label/value is not visible and is intentionally not transcribed.

#### Dashboard and chart state

The dashboard exposes `Shrink OK`, `Bands OK`, `Delta OK`, `Width OK`, `DEL > UP_BB`, `Hour OK`, `LOCK OK`, a position-count gate, upper-band/trade-level values, per-second permission, cooldown, last-try lock, days to expiry, shrunk delta, and live delta. It also provides manual `ARBITRAGE`, `CLOSE ALL`, and `Slow Exit` controls.

Example displayed values are `Days to Expire = 33`, `Shrunk Delta = 26.40`, and `DELTA = 18.21`. A separate chart overlay shows entry/exit booleans, futures/spot volumes, step count, a live delta, upper/lower ranges, and window/halt state. These support a gated state machine but do not reveal exact formulas.

#### Visible tester summary

| Metric | Screenshot value |
|---|---:|
| Total net profit | 16,988.72 |
| Gross profit | 158,870.00 |
| Gross loss | -141,881.28 |
| Profit factor | 1.12 |
| Expected payoff | 18.02 |
| Recovery factor | 2.84 |
| Sharpe ratio | 0.05 |
| Maximal balance drawdown | 5,992.12 (28.39%) |
| Relative balance drawdown | 28.39% (5,992.12) |
| Total trades | 943 |
| Profit trades | 504 (53.45%) |
| Loss trades | 439 (46.55%) |

The screenshot does not establish the test period, tick quality, broker conditions, commissions, swap treatment, slippage, rollover method, or reproducibility. A profit factor of `1.12` leaves a thin edge that cost-model errors can erase. The displayed 28.39% drawdown is not acceptable as a target for the initial USD 1,000 experiment.

### Working interpretation — hypotheses, not facts

The UI suggests this candidate behaviour:

1. Calculate an executable basis, plausibly `FutureBid - SpotAsk`, for sell-future/buy-spot.
2. Adjust a baseline or threshold as expiry approaches using `Shrink Per Day`.
3. Apply upper/lower bands plus minimum-width and delta gates.
4. Represent delta movement in fixed price steps or "bricks," possibly with reversal logic.
5. Scale into multiple hedged pairs subject to risk, time, spread, rate-limit, and cooldown gates.
6. Exit pairs or all exposure through profit and slow-exit logic.
7. Flatten an orphan leg when the second leg misses its timeout.

Items to resolve experimentally:

- whether shrink is linear and adjusts the baseline, entry space, or both;
- construction and lookback of the upper/lower bands;
- whether "brick" is Renko-like state, discretized delta movement, or order spacing;
- exact classic-reversal, scale-in, pairing, sizing, and exit rules;
- swap allocation and futures rollover handling;
- stale-quote, dislocation, partial-fill, rejection, and reconnection behaviour.

### Independent models to test

Do not implement the commercial product's presumed rules directly. Test independent candidates on the same broker tick data:

| Model | Description |
|---|---|
| A | Fixed executable-delta threshold |
| B | Linear expiry shrink |
| C | Rolling basis bands |
| D | Expiry-normalized residual / z-score |
| E | Cost-of-carry fair value plus broker carry adjustment |

Executable directions:

```text
cash-and-carry basis = futures_bid - spot_ask
legs                 = SELL future + BUY spot

reverse basis        = futures_ask - spot_bid
legs                 = BUY future + SELL spot
```

Every test must gate entry using estimated net profitability:

```text
expected_net_profit =
    expected_convergence
  - spot_spread
  - futures_spread
  - commissions
  - expected_slippage
  - expected_swap
  - rollover_cost
  - execution_buffer
```

Entry is allowed only when expected net profit clears a conservative minimum-EV threshold after contract-size and currency normalization.

### Execution-safety requirements extracted

- Validate symbols, contract specifications, expiry, and rollover.
- Require fresh synchronized quotes and use executable bid/ask basis.
- Pre-check spread, commission, swap, margin, slippage, and expected net profit.
- Use deterministic pair IDs, duplicate suppression, rate limiting, and cooldown.
- Implement a two-leg lifecycle with orphan timeout, emergency flatten, and bounded unhedged exposure.
- Enforce daily-loss, total-drawdown, margin, and position-count circuit breakers.
- Log every decision, order, fill, rejection, and recovery action.
- Never approve live deployment from a vendor backtest screenshot.

### Proposed research implementation

```text
research/basis_model/
├── ingest_ticks.py
├── normalize_contracts.py
├── executable_basis.py
├── expiry_model.py
├── transaction_costs.py
└── signal_simulator.py
```

This remains research work. Per project gates, do not write the production MQL5 EA until the economics, broker specifications, data quality, cost model, failure modes, and conservative USD 1,000 risk limits are approved.

---

## Case Study 002 — Spot vs Future Gold Arbitrage EA

- Product: [Spot vs Future Gold Arbitrage EA](https://www.mql5.com/en/market/product/165173)
- Related evidence: [public MQL5 signal](https://www.mql5.com/en/signals/2376164)
- MQL5 product ID: `165173`
- Research date: 2026-09-14
- Classification: retail MT5 gold basis-convergence system
- Evidence boundary: public seller description, update history, comments, and public signal statistics. No source code or private material was inspected.

### Publicly confirmed seller claims

The seller describes the system as:

- buying Spot Gold (`XAUUSD`) and selling a broker-provided Gold Futures symbol;
- opening both legs at approximately the same time;
- closing the pair when a configured spread target is reached;
- using no technical indicators or directional gold forecast;
- requiring a broker that offers both instruments;
- exposing maximum-spread and position-size controls.

The public update history also mentions configurable exit gap, maximum slippage, maximum profit, hold/exit timing, and a minimum-gap condition intended to avoid unsuitable trades near futures expiry. These are vendor-described features, not verified implementation details.

The public material does not establish ounce-normalized hedge sizing, fair-value/cost-of-carry modelling, quote-age validation, cost-adjusted expected value, partial-fill recovery, or deterministic roll selection.

### Public signal snapshot

The related signal is useful because it exposes live-account statistics from a starting deposit close to this project's USD 1,000 experimental ceiling. The following values were observed on 2026-09-14 and are time-varying:

| Metric | Observed value |
|---|---:|
| Initial deposit | USD 1,000 |
| Trading history | 17 weeks / 76 trading days |
| Trades | 1,600 |
| Profitable trades | 829 (51.81%) |
| Losing trades | 771 (48.19%) |
| Gross profit | USD 17,027.36 |
| Gross loss | USD -16,570.87 |
| Net trading profit | USD 456.49 |
| Profit factor | approximately 1.03 |
| Expected payoff | USD 0.29 per trade |
| Sharpe ratio | 0.02 |
| Recovery factor | 0.49 |
| Maximum deposit load | 65.74% |
| Maximum balance drawdown | USD 934.19 (47.70%) |

The displayed growth cannot be interpreted as a simple return on the original deposit because the account also shows material deposits and withdrawals. MQL5 displays a warning that a large drawdown may occur again. The account has traded multiple futures expiries, including `GOLD.Aug`, `GOLD.Dec`, and `GOLD.May`, which is evidence that contract-roll handling is operationally relevant.

The signal reports legs by symbol rather than by economic hedge pair. Consequently, symbol-level profit, win rate, and drawdown cannot prove paired-strategy profitability. A credible evaluation requires reconstruction using a stable pair identifier and both legs' fills, costs, and holding period.

### Interpretation

This signal is evidence that the relationship is being traded, not proof of a durable edge. A profit factor near `1.03`, expected payoff of `USD 0.29`, high deposit load, and large displayed balance drawdown indicate a thin, execution-sensitive outcome. Small errors in spread, commission, slippage, swap, rollover, or cash-flow-adjusted performance can consume the apparent advantage.

This reinforces rather than replaces the independent profitability gate:

```text
expected_net_profit =
    expected_convergence
  - spot_spread
  - futures_spread
  - commissions
  - entry_and_exit_slippage
  - expected_swap
  - rollover_cost
  - execution_uncertainty_buffer
```

Do not infer that the seller's sizing, risk limits, or exit gap are suitable for this project's account.

### Extracted requirements

- Journal every hedge as a single economic `PairID`; retain leg-level order/deal identifiers beneath it.
- Report cash-flow-adjusted return and pair-level P&L, not only MT5 account headline statistics.
- Make the active futures contract and expiry explicit in every signal, pair, and journal record.
- Prohibit silent substitution of a different expiry while a pair is open.
- Define a no-entry roll window and validate spread/liquidity before selecting the next contract.
- Treat maximum spread, maximum slippage, holding time, and expiry distance as independent gates.
- Reject a candidate edge that is small relative to cost-model or execution uncertainty.

---

## MQL5 Ecosystem and Platform Evidence

### Search classification

The MQL5 ecosystem contains products, public signals, articles, forum opinions, CodeBase examples, and freelance requirements. Their evidential weight differs:

| Source type | Permitted use | Not sufficient for |
|---|---|---|
| Official MQL5 documentation | Platform behaviour and API requirements | Strategy profitability |
| Public live signal | Observed account statistics and traded symbols | Pair-level economics without reconstruction |
| Product page/update log | Seller claims and visible feature inventory | Verification of algorithms or results |
| Technical article/CodeBase | Candidate implementation patterns | Production correctness without testing |
| Forum discussion | Failure-mode discovery and questions | Treating opinions as facts |
| Freelance specification | Market demand and requested controls | Evidence that a system works |

The [Spot vs Future Arbitrage forum discussion](https://www.mql5.com/en/forum/507793) repeatedly identifies slippage, latency, commissions, spreads, and opaque CFD price formation as practical failure modes. These are community opinions, but they define testable risks. Crypto-exchange/MT5 gold arbitrage products were excluded because they introduce different price sources, counterparties, transfers, funding, and operational risks.

### Official execution semantics

Official MQL5 documentation establishes that:

- [`OrderSendAsync`](https://www.mql5.com/en/docs/trading/ordersendasync) returning success confirms submission, not acceptance or fill;
- [`OnTradeTransaction`](https://www.mql5.com/en/docs/event_handlers/ontradetransaction) may receive several events per request, and event arrival order is not guaranteed;
- [`SymbolInfoTick`](https://www.mql5.com/en/docs/marketinformation/symbolinfotick) returns bid, ask, and last-update time together in an `MqlTick` structure;
- [`SymbolSelect`](https://www.mql5.com/en/docs/marketinformation/symbolselect) can add a required instrument to Market Watch, but failure must be handled;
- [symbol properties](https://www.mql5.com/en/docs/constants/environment_state/marketinfoconstants) expose futures start/expiry, contract size, tick size/value, volume constraints, swap model, triple-swap day, filling modes, order modes, and margin-related data.

Therefore the production design must not equate `request sent` with `leg live`. It must reconstruct state from transaction events and reconcile current orders, deals, and positions after reconnect or restart.

### Candidate two-leg execution policies

Two policies remain hypotheses to compare on demo infrastructure:

1. **Sequential-confirm:** submit one leg, confirm its fill, then submit the hedge. This simplifies state reasoning but increases naked-exposure time.
2. **Dual-async:** pre-check both legs, submit both asynchronously in immediate succession, and track each transaction chain independently. This can reduce submission skew but creates two simultaneously uncertain requests.

Neither policy is accepted yet. Compare them using rejection rate, partial fills, submission skew, fill skew, adverse price movement during unmatched exposure, emergency-flatten success, and final pair P&L.

Minimum lifecycle states to model during later system design:

```text
IDLE
SIGNAL_VALID
REQUESTS_PENDING
PARTIAL_OR_ORPHAN
HEDGED
CLOSE_PENDING
EMERGENCY_FLATTEN
FLAT
HALTED
```

The exact transitions belong in `docs/03_system_design/` only after the research and quant gates pass.

### Quote and execution telemetry

Capture at minimum:

```text
pair_id
spot_symbol
futures_symbol
futures_expiry
spot_quote_time_msc
futures_quote_time_msc
quote_skew_ms
signal_time_msc
spot_request_time_msc
futures_request_time_msc
spot_fill_time_msc
futures_fill_time_msc
inter_leg_fill_ms
requested_price_per_leg
filled_price_per_leg
slippage_per_leg
commission_per_leg
swap_per_leg
emergency_action_and_result
```

Use executable bid/ask prices and reject stale or materially asynchronous quotes. Do not calculate the tradeable basis from independently sampled prices without preserving their timestamps.

### Article patterns worth testing

The MQL5 article [Dynamic Multi-Pair EA: Spread Filter System](https://www.mql5.com/en/articles/20371) demonstrates absolute and volatility-relative spread gates, cooldowns, timer monitoring, and visible tradeability state. These are useful patterns, but hard-coded pip heuristics and sequential price reads must not be copied. Contract metadata and synchronized `MqlTick` values should drive normalization.

The article [Low-Frequency Quantitative Trading Strategies Part 2](https://www.mql5.com/en/articles/21811) supports a research-first screening workflow and distinguishes lead/lag analysis from cointegration. Its XAUUSD/GDX example is not evidence for futures-basis convergence. For this project, expiry and carry provide the primary economic hypothesis; generic correlation is insufficient.

### Smallest next empirical test

On one candidate broker demo account, capture synchronized `MqlTick` snapshots and complete transaction events for Spot Gold and one explicitly identified Gold Futures contract without opening live positions. Validate symbol metadata, quote freshness, executable basis construction, session overlap, expiry fields, volume/contract-size normalization, and estimated round-trip costs. Only after the passive dataset passes those checks should sequential-confirm and dual-async execution be compared with the minimum permitted demo volume.

### Not yet done

Broader open-source trading systems and academic research (per the `## Scope` section above) have not been
researched yet.
