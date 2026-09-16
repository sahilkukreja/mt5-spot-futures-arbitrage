## Input reference

| Input | What it does |
|---|---|
| `InpEnableTrading` | Master on/off switch for opening new trades |
| `InpAllowedSymbol` | Symbol the EA is allowed to trade (safety check vs wrong chart) |
| `InpMagicNumber` | Unique ID tagging this EA's own trades, so it doesn't touch manual/other-EA positions |
| `InpEntryTF` | Timeframe used for the Donchian breakout signal |
| `InpTrendTF` | Higher timeframe used for the EMA trend filter |
| `InpDonchianEntryPeriod` | Lookback (in bars) for the breakout high/low that triggers entries |
| `InpDonchianExitPeriod` | Lookback for the optional early-exit channel |
| `InpFastEMA` / `InpSlowEMA` | Periods of the two EMAs on `InpTrendTF`; fast > slow = uptrend filter, and vice versa |
| `InpATRPeriod` | Lookback for the ATR (volatility) indicator |
| `InpATRSLMultiplier` | Stop-loss distance = this × ATR |
| `InpATRTPMultiplier` | Take-profit distance = this × ATR |
| `InpTrailingATRMultiplier` | Trailing stop distance = this × ATR, once trailing activates |
| `InpADXPeriod` / `InpMinADX` | ADX lookback and minimum reading required to allow a trade (trend-strength filter) |
| `InpUseFixedRisk` | true = size positions by risk %; false = use `InpFixedLot` every time |
| `InpRiskPercent` | Risk % per trade — **only used if `InpUseMilestoneCompounding=false`** |
| `InpMaxRiskPercent` | Hard ceiling on risk %, regardless of other settings |
| `InpFixedLot` | Lot size used only when `InpUseFixedRisk=false` |
| `InpMaxLot` | Hard cap on lot size, regardless of risk calculation |
| `InpUseBreakeven` / `InpBreakevenAtR` / `InpBreakevenBufferPoints` | Moves SL to entry (+buffer) once price reaches this many multiples of initial risk (R) |
| `InpUsePartialTP` / `InpPartialTPAtR` / `InpPartialTPPercent` | Closes this % of the position once price reaches this many R |
| `InpUseATRTrailing` / `InpStartTrailingAtR` | Enables ATR trailing once profit reaches this many R |
| `InpUseDonchianExit` | Optional early exit if price closes back through the opposite Donchian channel |
| `InpMaxSpreadPoints` | Skips new entries if current spread exceeds this |
| `InpSlippagePoints` | Max acceptable slippage on order execution |
| `InpOnePositionOnly` | If true, blocks new entries while an EA position is already open |
| `InpAllowBuy` / `InpAllowSell` | Direction on/off switches |
| `InpUseSessionFilter`, `InpSessionStartHour/EndHour` | Restricts entries to a broker-time trading window |
| `InpUseNewsTimeBlock`, `InpBlockedTimes` | Blocks entries in the first 15 min of every hour, plus custom time ranges |
| `InpUseDailyLossLimit`, `InpMaxDailyLossPercent`, `InpMaxConsecutiveLosses` | Stops new trades for the day if daily loss % or consecutive-loss count is hit |
| `InpUseWeeklyDrawdownLimit`, `InpMaxWeeklyDrawdownPercent` | Stops new trades for the week if weekly drawdown % is hit |
| `InpUseEquityDrawdownPause`, `InpMaxEquityDrawdownPercent` | Pauses all new trades (manual restart needed) if overall equity drawdown from peak exceeds this |
| `InpUseMilestoneCompounding` | If true, risk % is set by hardcoded equity bands in the code (0.5%→1.5%) instead of `InpRiskPercent` |
| `InpEnableLogs` / `InpDebugSignals` | Logging verbosity |

## On the 20%/month target

I want to be straight with you rather than hand you numbers that look good on paper: **I can't give you a parameter set that reliably produces 20% a month.** Here's the math, not opinion:

20%/month compounded is **~792% annualized**. No systematic trend/breakout strategy — on any instrument, in any properly-tested backtest — sustains that. Firms running billions in systematic strategies target high-single/low-double-digit annual returns and consider 20-30%/year exceptional. A retail EA claiming 20%/month is targeting a return profile that historically correlates with one thing: **high variance strategies that blow up eventually**, not consistent edge. Any backtest that *shows* 20%/month over a short window is very likely one of:

- A short lucky sample (like Run 1's 4-month window — one favorable trend regime)
- Curve-fit parameters exploiting quirks of that specific historical data
- Risk sized so large that the *expected* outcome, over enough time, is ruin — high average return and high ruin probability are the same lever

If I optimize parameters specifically to hit 20%/month in a backtest, I'd almost certainly be optimizing for exactly that failure mode — not something I think serves you well, even if it's what's asked for.

## What I can actually help with

A realistic, honest target for a validated systematic FX/gold strategy is something like **3-8% a month in good conditions, with real months of drawdown mixed in** — and even that needs walk-forward validation across regimes, not one backtest window, before you'd trust it.

If you want, I can:
1. Take your Run 3 config (14.9% DD, PF 1.17 — your best so far) and push risk% moderately higher (say, milestone bands scaled from 0.5-1.5% up to 1-3%) to see what that does to both return *and* drawdown side by side, so you see the real tradeoff instead of a cherry-picked number.
2. Run that across a longer/different historical window to see if the edge holds outside this one 4-month regime.

Want me to do that instead — show you the actual return-vs-drawdown curve as risk% scales, so you can pick a level with eyes open?