//+------------------------------------------------------------------+
//|                                       HarnessStage2_Guards.mqh   |
//|                                                                  |
//| PURE DECISION LOGIC ONLY. No function in this file calls any MT5
//| trading, account, or market-data API. Every function here takes
//| its inputs as parameters and returns a decision -- this is what
//| makes it possible to test this logic exhaustively without a
//| broker connection, the same way HarnessStage0_DryRun.mq5 tested
//| its state machine.
//|
//| Included by:
//|   HarnessStage2_LivePilot.mq5 -- thin wrappers gather real values
//|     (AccountInfoInteger, SymbolInfoTick, etc.) and pass them to the
//|     Logic functions here. The wrappers are NOT tested by
//|     HarnessStage2_SelfTest.mq5 -- only what's in this file is.
//|   HarnessStage2_SelfTest.mq5 -- calls every function here directly
//|     with injected values, including deliberately adversarial ones,
//|     and reports PASS/FAIL. Never touches a broker.
//|
//| Quarantine: see measurement_harness/README.md. Never a source for
//| src/, the same way legacy/ never is.
//+------------------------------------------------------------------+
#property strict

//====================================================================
// Retry whitelist. Mirrors MMT_TradePannel_Pro_v284.cpp's
// ShouldRetry(): explicit transient cases, default:false. The
// "canonical" legacy file (best_code.cpp v3.26) had no such function
// at all, which is the documented reason for 408 unhandled OpenLeg
// failures in one legacy session.
//====================================================================
bool IsTransientRetcode(int retcode)
  {
   switch(retcode)
     {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_TIMEOUT:
      case TRADE_RETCODE_CONNECTION:
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
         return true;
      default:
         return false;
     }
  }

// Human-readable retcode names for logging. Pair 1's own procedure
// (design doc section 8.1.3) requires checking the ACTUAL retcode
// integer against MT5's own documentation directly on a real run --
// this mapping is a convenience for the log, never a substitute for
// that check.
string RetcodeDescription(int retcode)
  {
   switch(retcode)
     {
      case TRADE_RETCODE_REQUOTE:            return "REQUOTE";
      case TRADE_RETCODE_REJECT:             return "REJECT";
      case TRADE_RETCODE_INVALID:            return "INVALID";
      case TRADE_RETCODE_INVALID_VOLUME:     return "INVALID_VOLUME";
      case TRADE_RETCODE_INVALID_PRICE:      return "INVALID_PRICE";
      case TRADE_RETCODE_INVALID_STOPS:      return "INVALID_STOPS";
      case TRADE_RETCODE_TRADE_DISABLED:     return "TRADE_DISABLED";
      case TRADE_RETCODE_MARKET_CLOSED:      return "MARKET_CLOSED";
      case TRADE_RETCODE_NO_MONEY:           return "NO_MONEY";
      case TRADE_RETCODE_PRICE_CHANGED:      return "PRICE_CHANGED";
      case TRADE_RETCODE_PRICE_OFF:          return "PRICE_OFF";
      case TRADE_RETCODE_TIMEOUT:            return "TIMEOUT";
      case TRADE_RETCODE_DONE:               return "DONE";
      case TRADE_RETCODE_DONE_PARTIAL:       return "DONE_PARTIAL";
      case TRADE_RETCODE_ERROR:              return "ERROR";
      case TRADE_RETCODE_CONNECTION:         return "CONNECTION";
      case TRADE_RETCODE_TOO_MANY_REQUESTS:  return "TOO_MANY_REQUESTS";
      case TRADE_RETCODE_LOCKED:             return "LOCKED";
      case TRADE_RETCODE_FROZEN:             return "FROZEN";
      case TRADE_RETCODE_CLIENT_DISABLES_AT: return "CLIENT_DISABLES_AT"; // AutoTrading/Algo Trading toggle off in the terminal, not a broker rejection -- real occurrence 2026-09-18/19, pair 11
      default: return "UNMAPPED_" + IntegerToString(retcode);
     }
  }

//====================================================================
// Idempotency key. Format: H{run_id}-P{pair_seq}-L{leg_id}-A{attempt}
//====================================================================
string MakeIdemKey(const string run_id, int pair_seq, int leg_id, int attempt)
  {
   return StringFormat("H%s-P%d-L%d-A%d", run_id, pair_seq, leg_id, attempt);
  }

//====================================================================
// Section 6 guards -- pure logic. Every one fail-safe: only ever
// blocks, never permits. The real-API wrapper for each lives in
// HarnessStage2_LivePilot.mq5 with the same name minus "Logic".
//====================================================================
bool GuardAccountWhitelistedLogic(long current_account, long whitelisted_account)
  {
   if(whitelisted_account <= 0)
      return false; // no whitelist loaded -- fail closed, never "anything goes"
   return current_account == whitelisted_account;
  }

bool GuardAccountIsRealLogic(ENUM_ACCOUNT_TRADE_MODE mode)
  {
   return mode == ACCOUNT_TRADE_MODE_REAL;
  }

bool GuardExpiryLogic(datetime now, datetime expiry, long buffer_days)
  {
   if(expiry == 0)
      return false; // unparseable expiry -- fail closed
   datetime cutoff = (datetime)((long)expiry - buffer_days * 86400);
   return now < cutoff;
  }

bool GuardSpreadLogic(double spread_futures, double spread_spot, double max_spread)
  {
   return (spread_futures < max_spread) && (spread_spot < max_spread);
  }

// Returns the projected post-trade margin level as a percentage via
// out_level_pct, and true/false for whether it clears the minimum.
// projected_margin<=0 is treated as "guard does not apply" (true) --
// matches the live wrapper's existing behaviour, stated explicitly
// here so the self-test can exercise that exact edge case.
bool GuardMarginLevelLogic(double equity, double current_margin, double margin_futures,
                            double margin_spot, double min_level_pct, double &out_level_pct)
  {
   double projected_margin = current_margin + margin_futures + margin_spot;
   if(projected_margin <= 0)
     {
      out_level_pct = 0;
      return true;
     }
   out_level_pct = 100.0 * equity / projected_margin;
   return out_level_pct > min_level_pct;
  }

// Every distinct block reason as its own named return value, so the
// self-test can assert exactly WHICH guard fired, not just pass/fail.
enum ENUM_BUDGET_BLOCK
  {
   BUDGET_OK,
   BUDGET_KILL_SWITCH,
   BUDGET_MAX_PAIRS,
   BUDGET_MAX_PAIRS_PER_DAY,
   BUDGET_DAILY_LOSS,
   BUDGET_CUMULATIVE_LOSS
  };

string BudgetBlockName(ENUM_BUDGET_BLOCK b)
  {
   switch(b)
     {
      case BUDGET_OK:                  return "OK";
      case BUDGET_KILL_SWITCH:         return "KILL_SWITCH";
      case BUDGET_MAX_PAIRS:           return "MAX_PAIRS";
      case BUDGET_MAX_PAIRS_PER_DAY:   return "MAX_PAIRS_PER_DAY";
      case BUDGET_DAILY_LOSS:          return "DAILY_LOSS";
      case BUDGET_CUMULATIVE_LOSS:     return "CUMULATIVE_LOSS";
     }
   return "UNKNOWN";
  }

ENUM_BUDGET_BLOCK GuardBudgetsLogic(bool kill_switch_tripped, int pairs_total, int max_pairs,
                                     int pairs_today, int max_pairs_per_day,
                                     double daily_loss, double projected_worst_case_loss, double max_daily_loss,
                                     double cumulative_loss, double max_cumulative_loss)
  {
   if(kill_switch_tripped)             return BUDGET_KILL_SWITCH;
   if(pairs_total >= max_pairs)        return BUDGET_MAX_PAIRS;
   if(pairs_today >= max_pairs_per_day)return BUDGET_MAX_PAIRS_PER_DAY;
   if(daily_loss + projected_worst_case_loss > max_daily_loss)           return BUDGET_DAILY_LOSS;
   if(cumulative_loss + projected_worst_case_loss > max_cumulative_loss) return BUDGET_CUMULATIVE_LOSS;
   return BUDGET_OK;
  }

//====================================================================
// Realized P&L. Deliberately asymmetric: only the LOSS portion is
// ever returned as nonzero -- profits never produce a negative
// "loss to accumulate". This is what R-011's fix relies on to avoid
// a loss-recovery/martingale-adjacent pattern (PROJECT_MANDATE.md
// prohibits sizing or continuing on the basis of prior profits).
//====================================================================
double LossPortion(double realized_pnl_usd)
  {
   return (realized_pnl_usd < 0) ? -realized_pnl_usd : 0.0;
  }

// A deal's full realized contribution to account P&L -- pure sum, the
// HistoryDealGetDouble lookups themselves live in the real wrapper
// (GetDealPnL in HarnessStage2_LivePilot.mq5), which this is not a
// substitute for testing.
double DealPnLFromComponents(double profit, double swap, double commission)
  {
   return profit + swap + commission;
  }

//====================================================================
// Fast-market / stale-quote guard (R-004). Added 2026-09-18 in direct
// response to both /arb-risk-review and /arb-hostile-review rejecting
// 35_1000_USD_LIVE_TEST_PLAN.md section 8.2 on the same finding:
// GuardSpreadLogic() checks only each leg's own bid-ask spread, never
// quote age or cross-leg staleness, and would NOT have caught the
// 2026-09-11 13:30:11 UTC anomaly (docs/02_quant/13_BASIS_MODEL.md) --
// the futures leg repriced ~54 points in ~10 seconds while the spot
// leg's ask stayed frozen at a normal-width, unremarkable spread.
//
// docs/02_quant/13_BASIS_MODEL.md's own finding: "per-leg price
// velocity would have caught it, with a large margin" -- the single
// highest-velocity tick in the entire 7-day/707,467-row dataset
// (161.6 pts/sec, ~20x the p99.9 rate of 8.08 pts/sec) occurs one tick
// before the anomaly row, while that row's own quote_skew_ms (238ms)
// sits inside the still-unapproved 400ms staleness candidate -- skew
// alone would still have missed it. Velocity is the layer that
// actually catches this specific, real, historical failure mode.
//
// Every threshold here is an INPUT, not a literal -- NO MAGIC VALUES.
// This file proposes no default; HarnessStage2_LivePilot.mq5's inputs
// carry a reasoned-but-explicitly-UNCALIBRATED starting candidate
// (see its own input comments), same pattern as InpMaxSpreadUsd and
// InpMinMarginLevelPct already use.
//====================================================================

// Tick-to-tick price velocity, points/sec, magnitude only (direction
// doesn't matter for a fast-market detector). Returns -1 (a value no
// real velocity can take) when dt_ms<=0 -- a duplicate, out-of-order,
// or unavailable timestamp pair must never silently read as "zero
// movement, safe to proceed." The caller (GuardFastMarketLogic) is
// responsible for treating -1 as a block, not a pass.
double TickVelocityPtsPerSec(double prev_price, long prev_time_ms, double curr_price, long curr_time_ms)
  {
   long dt_ms = curr_time_ms - prev_time_ms;
   if(dt_ms <= 0)
      return -1;
   double dprice = MathAbs(curr_price - prev_price);
   return dprice / (dt_ms / 1000.0);
  }

// How old the most recent tick is, relative to "now" (both already in
// the same clock domain -- the caller is responsible for that, exactly
// as CurrentClockOffsetMs()'s own callers already are elsewhere in this
// project). Floored at 0: a tick that appears to be from the future
// (clock skew, not staleness) is a different failure mode, not this
// guard's job to diagnose -- but it must never read as "negative age,
// therefore very fresh."
long QuoteAgeMs(long now_ms, long tick_time_ms)
  {
   long age = now_ms - tick_time_ms;
   return (age < 0) ? 0 : age;
  }

// Cross-leg quote-skew, magnitude. Already known (13_BASIS_MODEL.md)
// to be necessary but not sufficient alone -- kept here as a
// supplementary signal, not the primary defense.
long CrossLegSkewMs(long time_futures_ms, long time_spot_ms)
  {
   long diff = time_futures_ms - time_spot_ms;
   return (diff < 0) ? -diff : diff;
  }

// Combined fast-market circuit breaker. Fail-safe like every other
// guard in this file: any missing/invalid input (velocity<0 from an
// unusable timestamp pair) blocks, never passes. Velocity is checked
// on BOTH legs independently -- the anomaly this is built against was
// a single-leg event (futures moved, spot didn't), and a leg-summed or
// averaged check would have diluted exactly the signal that catches it.
bool GuardFastMarketLogic(double velocity_futures_pts_sec, double velocity_spot_pts_sec,
                           double max_velocity_pts_sec,
                           long quote_age_futures_ms, long quote_age_spot_ms, long max_quote_age_ms,
                           long cross_leg_skew_ms, long max_cross_leg_skew_ms)
  {
   if(velocity_futures_pts_sec < 0 || velocity_futures_pts_sec > max_velocity_pts_sec)
      return false;
   if(velocity_spot_pts_sec < 0 || velocity_spot_pts_sec > max_velocity_pts_sec)
      return false;
   if(quote_age_futures_ms > max_quote_age_ms)
      return false;
   if(quote_age_spot_ms > max_quote_age_ms)
      return false;
   if(cross_leg_skew_ms > max_cross_leg_skew_ms)
      return false;
   return true;
  }
