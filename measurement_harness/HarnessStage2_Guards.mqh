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
