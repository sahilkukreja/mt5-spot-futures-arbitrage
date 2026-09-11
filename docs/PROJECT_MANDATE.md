# PROJECT DEVELOPMENT MANDATE

This is a GREENFIELD quantitative trading system.

Design the system from first principles.

Do NOT treat any previous EA, bot, MQL5 codebase, trading strategy, spreadsheet, indicator, parameter set, or earlier implementation as the baseline architecture.

Previous work may be reviewed later only as:

* reference material
* lessons learned
* ideas to investigate
* examples of possible execution patterns
* sources of historical observations

Previous work must NOT constrain:

* strategy design
* architecture
* signal logic
* execution model
* risk model
* state machine
* technology choices
* parameter definitions
* broker abstraction
* testing methodology.

The new system must justify every major decision independently.

---

# PRIMARY OBJECTIVE

Design and develop a production-quality automated MT5 Spot ↔ Futures arbitrage / hedge trading platform.

Initial research focus:

Gold Spot ↔ Gold Futures or futures-linked instruments.

Potential instruments may include:

Spot:
XAUUSD

Futures / Futures CFD:
GC
GOLD futures-linked CFD
broker-specific futures symbols

However, instrument selection itself must be validated before implementation.

The architecture should eventually support:

* Spot vs Futures
* Futures vs Futures
* Broker A vs Broker B
* Spot Broker A vs Futures Broker B
* cross-account hedging
* cross-terminal execution
* multiple arbitrage pairs.

---

# CAPITAL CONSTRAINT

Initial live testing capital:

USD 1,000 maximum experimental trading capital.

This capital is intended for controlled proof-of-concept and execution validation.

The system must therefore be designed with capital preservation as the highest priority.

Initial order size target:

0.01 lot

where supported by the broker and instrument.

IMPORTANT:

0.01 lot must NOT automatically be assumed to represent equal risk on both hedge legs.

The system must calculate actual economic exposure using:

* contract size
* tick value
* tick size
* quote currency
* margin currency
* instrument price
* lot step
* leverage
* broker margin rules.

If 0.01 Spot and 0.01 Futures create materially unequal exposure, calculate the correct hedge ratio.

The system must explicitly show:

Spot exposure

Futures exposure

Net exposure

Delta mismatch.

---

# INITIAL CAPITAL PROTECTION

The $1,000 account must be treated as experimental risk capital.

The EA must prioritize survival over maximizing returns.

Initial live testing should impose strict limits including:

* 0.01 lot target size
* one hedge pair at a time initially
* no martingale
* no grid averaging
* no doubling after losses
* no uncontrolled averaging down
* no adding positions because spread moved further
* no revenge/recovery sizing
* no leverage optimization for profit
* no hidden directional exposure.

Position sizing may eventually become dynamic, but dynamic sizing is NOT part of initial live validation.

---

# DEVELOPMENT PHILOSOPHY

We will NOT begin by writing an EA.

The project will follow:

DISCOVERY

↓

MARKET RESEARCH

↓

MATHEMATICAL MODEL

↓

STRATEGY DESIGN

↓

COST MODEL

↓

EXECUTION DESIGN

↓

RISK DESIGN

↓

SYSTEM ARCHITECTURE

↓

SIMULATION

↓

IMPLEMENTATION

↓

UNIT TESTING

↓

TICK REPLAY

↓

DEMO TESTING

↓

LIVE OBSERVATION

↓

$1,000 / 0.01 LOT FORWARD TEST

↓

REVIEW

↓

ITERATION

↓

PRODUCTION CONSIDERATION.

No stage should be skipped merely to reach live trading faster.

---

# FUNDAMENTAL QUESTION

Before building the system, determine whether the supposed opportunity is actually arbitrage.

Continuously distinguish among:

TRUE ARBITRAGE

BASIS TRADING

RELATIVE-VALUE TRADING

STATISTICAL ARBITRAGE

LATENCY ARBITRAGE

BROKER PRICE DISLOCATION

MEAN-REVERSION TRADING.

Do not label every Spot/Futures price difference as arbitrage.

---

# CORE RESEARCH QUESTION

For every observed price discrepancy ask:

Why does this spread exist?

Possible causes include:

* futures carry
* interest rates
* financing
* storage
* convenience yield
* futures expiry
* broker markup
* synthetic CFD pricing
* liquidity differences
* stale quotes
* different trading sessions
* contract specification differences
* exchange fees
* FX conversion
* execution latency.

The strategy must identify which part of the observed spread is:

EXPECTED

versus

ABNORMAL.

Only the abnormal/exploitable component should be considered potential edge.

---

# START WITH MARKET MECHANICS

Before developing entry logic, document exactly how the instruments work.

For each candidate instrument collect:

Broker

Symbol

Underlying

Asset type

Contract size

Minimum lot

Lot step

Tick size

Tick value

Margin calculation

Leverage

Commission

Bid/ask spread

Swap

Funding

Expiry

Rollover

Trading hours

Exchange or OTC

Price source

Settlement mechanism

Currency.

Do not design hedge ratios until this information is known.

---

# REAL EXECUTABLE PRICES

All trading decisions must ultimately be based on executable prices.

For example:

If strategy is:

BUY SPOT
SELL FUTURE

potential executable spread is approximately:

Future Bid - Spot Ask

If strategy is:

SELL SPOT
BUY FUTURE

potential executable spread is approximately:

Future Ask - Spot Bid

Mid-price spreads may be used for research and statistics.

Mid prices must NOT be confused with executable trade prices.

---

# TRUE NET EDGE

For every potential trade compute:

Raw Spread

then subtract:

Spot spread cost

Futures spread cost

Spot commission

Futures commission

Expected entry slippage

Expected exit slippage

Financing

Swap

Carry

Rollover

Currency conversion

Latency uncertainty

Execution-risk buffer.

Define:

NET EXECUTABLE EDGE

Only consider trading when:

Net Executable Edge > Required Safety Margin.

The safety margin should initially be conservative because the capital base is only $1,000.

---

# STRATEGY RESEARCH

Research and compare multiple approaches before choosing one.

Candidate approaches include:

1. Absolute basis threshold

2. Percentage basis

3. Normalized price ratio

4. Rolling z-score

5. Dynamic basis model

6. Fair-value futures model

7. Time-to-expiry-adjusted basis

8. Volatility-adjusted spread

9. Percentile-based deviation

10. Mean-reversion model

11. Regime-aware model

12. Transaction-cost-adjusted signal.

Do not assume the most complex model will be best.

Prefer the simplest model that demonstrates robust executable edge.

---

# NO MAGIC OAG/CAG VALUES

Concepts like:

Open At Gap

Close At Gap

may still be useful.

However, do not start with arbitrarily chosen OAG or CAG values.

Derive thresholds from data.

Research:

distribution of spread

median

mean

standard deviation

MAD

percentiles

intraday seasonality

volatility

time to convergence

maximum excursions

execution cost.

Only after studying these should entry and exit thresholds be selected.

Static thresholds can still be implemented as a benchmark.

---

# HEDGE RATIO

Do NOT assume:

0.01 lot Spot = 0.01 lot Futures.

Calculate:

Spot notional

Futures notional

Delta

Tick-value exposure

Currency-adjusted exposure.

Target:

Net Delta ≈ 0

subject to minimum broker lot increments.

If perfect neutralization is impossible because both instruments have a minimum 0.01 lot, calculate and report residual exposure before allowing the trade.

---

# $1,000 CAPITAL ANALYSIS

Before any live trading, explicitly model whether the strategy is practical using $1,000.

Calculate:

Required margin for Spot leg

Required margin for Futures leg

Combined margin

Free margin after entry

Margin level

Expected worst normal spread excursion

Stress spread excursion

Potential directional loss during leg failure

Maximum slippage event

Emergency flatten loss.

Determine whether $1,000 provides sufficient margin.

If not, state clearly that the proposed instrument/broker combination is unsuitable for the test capital.

Never force a strategy to fit the available capital.

---

# INITIAL RISK LIMITS

Develop explicit numerical limits before live testing.

Research and recommend values for:

Maximum trade loss

Maximum daily loss

Maximum weekly loss

Maximum number of trades/day

Maximum simultaneous hedges

Maximum unhedged milliseconds

Maximum slippage

Maximum entry latency

Maximum exit latency

Maximum quote staleness

Maximum bid/ask spread

Maximum margin utilization

Minimum margin level

Maximum abnormal spread excursion.

Do not choose these values arbitrarily.

Tie them to:

capital

instrument volatility

execution statistics

broker specifications.

---

# INITIAL LIVE TEST PHASE

Initial live deployment should be considered an EXECUTION EXPERIMENT, not a profit-maximization phase.

Capital:

$1,000

Target order size:

0.01 lot

Primary objectives:

measure quote behavior

measure latency

measure slippage

measure fill reliability

measure legging time

measure spread dynamics

validate hedge ratios

validate commissions

validate swaps

validate actual margin usage

validate broker behavior.

Profitability is secondary during this phase.

---

# LIVE TEST SUCCESS CRITERIA

The first live phase should answer:

Are both legs reliably executable?

What is average entry slippage?

What is P95 slippage?

What is worst slippage?

How quickly do both legs fill?

How often does one leg fail?

How often do quotes become stale?

Does observed spread survive transaction costs?

What percentage of theoretical signals remain profitable after execution?

What is average convergence time?

How large can spread divergence become?

Does the hedge truly remove directional gold exposure?

---

# CAPITAL SCALING

Capital must NOT automatically be increased after profitable trades.

Scaling should occur only after statistical evidence.

Potential phases:

Phase 0
Data collection only

Phase 1
Demo trading

Phase 2
$1,000 / 0.01 lot

Phase 3
Extended 0.01 live validation

Phase 4
Limited sizing increase

Phase 5
Multiple pairs

Phase 6
Production consideration.

Each phase requires explicit graduation criteria.

---

# RESEARCH EXISTING SYSTEMS

Research publicly available information regarding:

MT5 arbitrage EAs

cross-broker arbitrage

Spot/Futures arbitrage

latency arbitrage

hedging EAs

statistical arbitrage EAs

commercial MT5 arbitrage products

open-source trading systems

academic research

professional basis trading architecture.

Do NOT copy commercial bots.

Extract:

* useful architecture patterns
* execution methods
* risk controls
* common failure modes
* infrastructure patterns.

Treat marketing claims skeptically.

---

# MULTI-AGENT DEVELOPMENT TEAM

Use specialized agents.

## QUANT RESEARCH AGENT

Own:

spread model

basis model

fair value

statistics

signal generation

expected value.

## MARKET MICROSTRUCTURE AGENT

Own:

quotes

bid/ask

liquidity

latency

slippage

stale pricing

execution behavior.

## EXECUTION AGENT

Own:

two-leg order execution

fill logic

legging risk

partial fills

timeouts

retries

emergency flattening.

## RISK AGENT

Own:

capital limits

drawdown

exposure

margin

kill switches

failure limits.

## MT5 ARCHITECT AGENT

Own:

MQL5 architecture

terminal integration

events

state management

broker adapters.

## INFRASTRUCTURE AGENT

Own:

VPS

network

multi-terminal coordination

monitoring

time synchronization.

## TEST ENGINEER

Own:

unit tests

simulation

tick replay

fault injection

forward testing.

## ADVERSARIAL REVIEWER

Its job is to prove that the proposed strategy will fail.

It should actively search for:

hidden assumptions

look-ahead bias

execution assumptions

cost underestimation

margin risk

orphan legs

stale prices

broker restrictions

overfitting.

---

# AGENTIC DEVELOPMENT RULE

Agents must not simply agree with each other.

For every major design proposal use:

PROPOSAL

↓

QUANT REVIEW

↓

EXECUTION REVIEW

↓

RISK REVIEW

↓

ADVERSARIAL REVIEW

↓

DECISION.

Record accepted decisions in:

DECISION_LOG.md

Rejected ideas should also be recorded with the reason for rejection.

---

# DOCUMENTATION AS SOURCE OF TRUTH

Before implementation create:

/docs

/01_research
01_PROBLEM_DEFINITION.md
02_ARBITRAGE_TYPES.md
03_GOLD_MARKET_STRUCTURE.md
04_SPOT_MARKET_MECHANICS.md
05_FUTURES_MARKET_MECHANICS.md
06_EXISTING_SYSTEM_RESEARCH.md
07_BROKER_RESEARCH.md

/02_quant
10_DATA_REQUIREMENTS.md
11_SPREAD_DEFINITION.md
12_FAIR_VALUE_MODEL.md
13_BASIS_MODEL.md
14_TRANSACTION_COST_MODEL.md
15_SIGNAL_RESEARCH.md
16_HEDGE_RATIO.md
17_EXPECTED_VALUE.md

/03_system_design
20_SYSTEM_ARCHITECTURE.md
21_EXECUTION_ENGINE.md
22_STATE_MACHINE.md
23_ORDER_LIFECYCLE.md
24_RISK_ENGINE.md
25_BROKER_ABSTRACTION.md
26_MULTI_TERMINAL_DESIGN.md
27_STATE_PERSISTENCE.md
28_FAILURE_RECOVERY.md
29_OBSERVABILITY.md

/04_testing
30_BACKTEST_LIMITATIONS.md
31_TICK_REPLAY_DESIGN.md
32_SIMULATION_ENGINE.md
33_FAULT_INJECTION.md
34_DEMO_TEST_PLAN.md
35_1000_USD_LIVE_TEST_PLAN.md

/05_development
40_MQL5_ARCHITECTURE.md
41_CODING_STANDARDS.md
42_UNIT_TESTS.md
43_INTEGRATION_TESTS.md
44_RELEASE_PROCESS.md

/06_operations
50_VPS_ARCHITECTURE.md
51_MONITORING.md
52_ALERTING.md
53_KILL_SWITCH.md
54_RECOVERY_RUNBOOK.md

DECISION_LOG.md

ASSUMPTIONS.md

OPEN_QUESTIONS.md

RISK_REGISTER.md

README.md

---

# SOFTWARE DESIGN PRINCIPLES

The implementation should eventually separate:

MARKET DATA

↓

NORMALIZATION

↓

FAIR VALUE / SPREAD ENGINE

↓

SIGNAL ENGINE

↓

RISK ENGINE

↓

EXECUTION ENGINE

↓

BROKER ADAPTER

↓

MT5.

The strategy should NOT directly send orders.

The signal engine should say:

"I want this hedge."

The risk engine decides:

"Is this hedge permitted?"

The execution engine decides:

"How should it be executed?"

The broker adapter handles:

"How does this specific broker/MT5 terminal execute it?"

---

# SAFETY INVARIANTS

The architecture must enforce:

NO DUPLICATE ORDERS

NO UNKNOWN POSITIONS

NO UNBOUNDED DIRECTIONAL EXPOSURE

NO SILENT EXECUTION FAILURES

NO TRADING ON STALE QUOTES

NO TRADING WHEN COSTS REMOVE EDGE

NO TRADING WHEN MARGIN IS UNSAFE

NO ORPHANED HEDGE LEG WITHOUT RECOVERY

NO NEW ENTRY AFTER KILL-SWITCH ACTIVATION.

---

# FIRST DEVELOPMENT MILESTONE

Do NOT write MQL5 code.

Begin with research and architecture.

First create:

01_PROBLEM_DEFINITION.md

02_ARBITRAGE_TYPES.md

03_GOLD_MARKET_STRUCTURE.md

04_SPOT_MARKET_MECHANICS.md

05_FUTURES_MARKET_MECHANICS.md

06_EXISTING_SYSTEM_RESEARCH.md

Then create:

10_DATA_REQUIREMENTS.md

11_SPREAD_DEFINITION.md

12_FAIR_VALUE_MODEL.md

13_BASIS_MODEL.md

14_TRANSACTION_COST_MODEL.md

At the end of this phase answer:

1. Is Spot/Futures Gold arbitrage realistically exploitable using retail MT5 infrastructure?

2. What exact price relationship should we trade?

3. What expected edge remains after all costs?

4. Which broker/instrument structure is suitable?

5. Can a $1,000 account safely support 0.01-lot hedged testing?

6. What data must be collected before choosing entry and exit thresholds?

7. What execution latency is acceptable?

8. What conditions make the strategy economically unviable?

Do not proceed to EA implementation until these questions have evidence-based answers.
