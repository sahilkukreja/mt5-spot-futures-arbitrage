//+------------------------------------------------------------------+
//|                                      HarnessStage2_LivePilot.mq5 |
//|                                                                  |
//| STAGE 2 -- LIVE PILOT. Design: docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md
//| sections 5 (measurement definitions), 6 (risk controls), 8.1 (operational
//| procedure), 9 (acceptance tests T13-T20).
//|
//| THIS FILE PLACES REAL ORDERS ON A REAL ACCOUNT. Unlike
//| HarnessStage0_DryRun.mq5, it is NOT incapable of trading -- it calls
//| OrderSend against the live MT5 API. Every safety control in this file
//| is a documented, reviewed mitigation, not a guarantee. Read
//| docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md sections 6 and 8.1
//| before running this against real capital.
//|
//| WHAT THIS IS NOT PROVEN TO DO YET: this file compiles clean and its
//| logic mirrors HarnessStage0_DryRun.mq5's proven state machine as
//| closely as real I/O allows -- but Stage 0 needed FOUR real runs and
//| three real bug fixes before it was trustworthy, and that was against
//| a fully scripted, deterministic simulated broker. This file has never
//| been run against any broker, simulated or real. Do not treat a clean
//| compile as evidence it works. Pair 1's elevated scrutiny procedure
//| (design doc section 8.1.3) exists because of exactly this gap, not as
//| a formality.
//|
//| Fires exactly one pair per explicit operator button click. Never on a
//| timer, tick, or init. InpMaxPairs defaults to 1 -- raise it only after
//| pair 1 has been fully verified per section 8.1.3's checklist.
//|
//| Quarantine: see measurement_harness/README.md. Never a source for
//| src/, the same way legacy/ never is.
//+------------------------------------------------------------------+
#property copyright "MT5 Spot-Futures Arbitrage -- research project"
#property version   "0.100"
#property strict

// All pure decision logic (retry whitelist, guards, P&L semantics) lives
// in this shared include, so it can be exhaustively tested by
// HarnessStage2_SelfTest.mq5 without a broker connection. Functions
// below with the same name minus "Logic"/"Components" are thin
// wrappers: gather a real value, delegate the decision here.
#include "HarnessStage2_Guards.mqh"

//====================================================================
// Inputs. Every numeric value here is UNCALIBRATED -- a starting value
// derived in docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md section 6,
// not an approved production parameter. All are fail-safe: each only
// ever stops activity, never permits it.
//====================================================================
input string InpSymbolFutures        = "GC-Z26";
input string InpSymbolSpot           = "XAUUSD.vx";
input double InpVolume               = 0.01;
input int    InpMaxPairs             = 1;       // deliberately 1 for the first real test
input int    InpMaxPairsPerDay       = 50;
input double InpMaxTradeLossUsd      = 15.0;
input double InpMaxDailyLossUsd      = 40.0;
input double InpMaxCumulativeLossUsd = 250.0;
input int    InpMaxOpenRetries       = 3;
input int    InpMaxConsecutiveFailures = 3;
input double InpMaxSpreadUsd         = 3.00;    // circuit breaker, not a filter (D-H1)
input double InpMinMarginLevelPct    = 300.0;
// Fast-market/stale-quote guard (R-004), added 2026-09-18 -- catches what
// InpMaxSpreadUsd cannot: the 2026-09-11 13:30 UTC anomaly had a NORMAL
// per-leg spread on both legs while futures repriced ~54 points in ~10s
// and spot stayed frozen. docs/02_quant/13_BASIS_MODEL.md found per-leg
// price velocity catches this "with a large margin" (the documented
// extreme is 161.6 pts/sec vs a measured p99.9 of 8.08 pts/sec across
// 707,467 rows); 20.0 here is a reasoned but explicitly UNCALIBRATED
// starting candidate (roughly 2.5x p99.9, ~8x below the one observed
// extreme) -- an operator decision informed by the data, not a value
// this file invents authority for. Same status as InpMaxSpreadUsd.
input double InpMaxVelocityPtsPerSec = 20.0;    // UNCALIBRATED -- see comment above
input long   InpMaxQuoteAgeMs        = 2000;    // UNCALIBRATED -- a tick older than this is stale, not just slow
input long   InpMaxCrossLegSkewMs    = 400;     // UNCALIBRATED -- the 384ms p95 candidate from 13_BASIS_MODEL.md;
                                                  // known NOT sufficient alone (the R-004 row's own skew was 238,
                                                  // inside this threshold) -- kept only as a supplementary signal,
                                                  // per HarnessStage2_Guards.mqh's GuardFastMarketLogic() comment
input long   InpVelocityLookbackMs   = 3000;    // window scanned via CopyTicksRange() before each fire
// InpAckTimeoutMs REMOVED (R-013, 2026-09-18): was declared but never
// enforced anywhere -- OrderSend() here is synchronous, so there is no
// separate "waiting for ack" phase distinct from "waiting for fill" to
// bound; the whole call blocks until the server responds either way.
// A real ack-timeout only means something once OrderSendAsync() is
// used (a bigger, deliberate design change, not made here -- see
// docs/Gold-Basis-EA-Strategy-and-System-Design.md section 8's note
// that async dispatch is a later alternative, not the current policy).
// Removing a dead input is preferred over leaving one that implies an
// enforcement guarantee that does not exist.
input long   InpFillTimeoutMs        = 10000;   // wall-clock ceiling on ExecuteLeg()'s retry loop -- FIX R-013
input long   InpOrphanTimeoutMs      = 3000;    // wall-clock ceiling on CloseLegByTicket()'s retry loop -- FIX R-013
input long   InpDwellMs              = 0;       // fixed per section 8.1.1, not varied in Stage 2
input long   InpMagicNumber          = 20260916;
input string InpExpiryHardStopDate   = "2026.11.25 00:00:00"; // GC-Z26 expiry; refuse within 14 days
input long   InpExpiryBufferDays     = 14;
input int    InpSlippagePoints       = 50;      // OrderSend deviation, points -- NOT a slippage cap
                                                  // (trade_exemode=MARKET does not honour one; see
                                                  // the design doc section 6 "No per-order slippage
                                                  // cap" note. This parameter affects only whether
                                                  // FOK/IOC-style rejection happens, not fill quality.)

//====================================================================
// Account whitelist config. Read from the terminal's own MQL5/Files
// sandbox at runtime -- this is OUTSIDE the git repository entirely
// (a different folder on disk from measurement_harness/), so it can
// never be accidentally committed regardless of .gitignore. The value
// itself is never printed to the Experts log or written to any file
// this project version-controls. Condition C4.
//
// File format, one line: AccountNumber=<login>
//====================================================================
#define WHITELIST_CONFIG_FILE "stage2_live_config.txt"

long ReadWhitelistedAccount()
  {
   int h = FileOpen(WHITELIST_CONFIG_FILE, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      Print("FATAL: whitelist config '", WHITELIST_CONFIG_FILE, "' not found in MQL5/Files. ",
            "Create it there (NOT in the git repo) with one line: AccountNumber=<your account number>");
      return -1;
     }
   long result = -1;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      int eq = StringFind(line, "AccountNumber=");
      if(eq == 0)
        {
         string val = StringSubstr(line, StringLen("AccountNumber="));
         StringTrimLeft(val); StringTrimRight(val);
         result = StringToInteger(val);
        }
     }
   FileClose(h);
   if(result <= 0)
     {
      Print("FATAL: whitelist config found but 'AccountNumber=' missing or invalid.");
      return -1;
     }
   return result;
  }

//====================================================================
// Section 5 -- state machine. Names match HarnessStage0_DryRun.mq5 and
// 34_DEMO_TEST_PLAN.md section 5 exactly.
//====================================================================
enum ENUM_HARNESS_STATE
  {
   STATE_STARTUP_RECONCILING,
   STATE_IDLE,
   STATE_RISK_CHECKING,
   STATE_LEG1_SUBMITTED,
   STATE_LEG1_FILLED,
   STATE_LEG1_PARTIAL,
   STATE_LEG2_SUBMITTED,
   STATE_HEDGED,
   STATE_UNWINDING,
   STATE_ORPHANED,
   STATE_EMERGENCY_FLATTENING,
   STATE_CLOSED,
   STATE_CLOSED_ORPHAN,
   STATE_RECONCILIATION_REQUIRED,
   STATE_HALTED
  };

string StateName(ENUM_HARNESS_STATE s)
  {
   switch(s)
     {
      case STATE_STARTUP_RECONCILING:    return "STARTUP_RECONCILING";
      case STATE_IDLE:                   return "IDLE";
      case STATE_RISK_CHECKING:          return "RISK_CHECKING";
      case STATE_LEG1_SUBMITTED:         return "LEG1_SUBMITTED";
      case STATE_LEG1_FILLED:            return "LEG1_FILLED";
      case STATE_LEG1_PARTIAL:           return "LEG1_PARTIAL";
      case STATE_LEG2_SUBMITTED:         return "LEG2_SUBMITTED";
      case STATE_HEDGED:                 return "HEDGED";
      case STATE_UNWINDING:              return "UNWINDING";
      case STATE_ORPHANED:               return "ORPHANED";
      case STATE_EMERGENCY_FLATTENING:   return "EMERGENCY_FLATTENING";
      case STATE_CLOSED:                 return "CLOSED";
      case STATE_CLOSED_ORPHAN:          return "CLOSED_ORPHAN";
      case STATE_RECONCILIATION_REQUIRED:return "RECONCILIATION_REQUIRED";
      case STATE_HALTED:                 return "HALTED";
     }
   return "UNKNOWN";
  }

ENUM_HARNESS_STATE g_state = STATE_STARTUP_RECONCILING;

// IsTransientRetcode() and RetcodeDescription() now live in
// HarnessStage2_Guards.mqh -- pure functions, exhaustively tested by
// HarnessStage2_SelfTest.mq5. Pair 1's procedure still requires
// checking every retcode actually received against MT5's own
// documentation directly on a real run; this whitelist is not a
// substitute for that, only a starting point derived from it.

//====================================================================
// Journal -- same schema as Stage 0, extended per section 5 with dual
// reference prices and the clock-offset field. Never truncated at
// start (unlike Stage 0's self-test) -- this journal is exactly what
// section 7's restart-reconciliation contract depends on surviving.
//====================================================================
#define JOURNAL_FILE      "arb_harness_stage2_journal.csv"
#define STATE_FILE        "arb_harness_stage2_daily_state.txt"
#define PAIR_SUMMARY_FILE "arb_harness_stage2_pairs.csv"

int g_journal_handle = INVALID_HANDLE;

bool JournalOpenForAppend()
  {
   g_journal_handle = FileOpen(JOURNAL_FILE, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(g_journal_handle == INVALID_HANDLE)
     {
      Print("FATAL: cannot open journal file ", JOURNAL_FILE, " err=", GetLastError());
      return false;
     }
   FileSeek(g_journal_handle, 0, SEEK_END);
   return true;
  }

void JournalClose()
  {
   if(g_journal_handle != INVALID_HANDLE)
     {
      FileClose(g_journal_handle);
      g_journal_handle = INVALID_HANDLE;
     }
  }

// Fields: run_id,pair_seq,leg_id,attempt,symbol,direction,volume,state,
//         t_decide_ms,t_send_ms,t_ack_ms,t_fill_ms,retcode,fill_price,
//         fill_volume,idempotency_key,ref_at_decide,ref_at_send,
//         clock_offset_ms,ticket
void JournalWrite(const string run_id, int pair_seq, int leg_id, int attempt,
                   const string symbol, const string direction, double volume,
                   ENUM_HARNESS_STATE state, long t_decide, long t_send,
                   long t_ack, long t_fill, int retcode,
                   double fill_price, double fill_volume, const string idem_key,
                   double ref_at_decide, double ref_at_send, long clock_offset_ms,
                   ulong ticket)
  {
   if(g_journal_handle == INVALID_HANDLE)
      return;
   string line = StringFormat(
      "%s,%d,%d,%d,%s,%s,%.2f,%s,%d,%d,%d,%d,%d,%.5f,%.2f,%s,%.5f,%.5f,%d,%I64u",
      run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
      StateName(state), (int)t_decide, (int)t_send, (int)t_ack, (int)t_fill,
      retcode, fill_price, fill_volume, idem_key,
      ref_at_decide, ref_at_send, (int)clock_offset_ms, ticket);
   FileWriteString(g_journal_handle, line + "\r\n");
   FileFlush(g_journal_handle);
  }

// MakeIdemKey() now lives in HarnessStage2_Guards.mqh.

//====================================================================
// Clock domains (section 5.1 / FF-5). GetTickCount64() is monotonic
// ms-since-boot -- real millisecond resolution, no whole-second
// quantization. tick.time_msc is the broker's own ms-precision
// timestamp. Anchoring both to a shared baseline at OnInit avoids
// TimeGMT()'s coarse (whole-second) resolution entirely. This is a
// drift measurement between two clocks since init, not an absolute
// "true UTC" measurement -- stated honestly, not oversold.
//====================================================================
long g_baseline_server_ms = 0;
long g_baseline_local_ms  = 0;
bool g_baseline_set       = false;

bool EstablishClockBaseline()
  {
   MqlTick t;
   if(!SymbolInfoTick(InpSymbolSpot, t))
      return false;
   g_baseline_server_ms = (long)t.time_msc;
   g_baseline_local_ms  = (long)GetTickCount64();
   g_baseline_set = true;
   return true;
  }

long CurrentClockOffsetMs()
  {
   if(!g_baseline_set)
      return 0;
   MqlTick t;
   if(!SymbolInfoTick(InpSymbolSpot, t))
      return 0;
   long server_delta = (long)t.time_msc - g_baseline_server_ms;
   long local_delta   = (long)GetTickCount64() - g_baseline_local_ms;
   return server_delta - local_delta;
  }

// Converts a server-domain ms timestamp (e.g. DEAL_TIME_MSC) into the
// same local-monotonic-equivalent domain as t_decide/t_send, so latency
// can be computed as a plain subtraction in one consistent domain.
long ServerMsToLocalEquivalent(long server_ms)
  {
   return g_baseline_local_ms + (server_ms - g_baseline_server_ms);
  }

//====================================================================
// Section 6 -- guards. Every one fail-safe: only ever blocks, never
// permits.
//====================================================================
string  g_whitelisted_account_note = "";
long    g_whitelisted_account = -1;

// Thin wrappers below: gather a real value, delegate the decision to
// HarnessStage2_Guards.mqh's *Logic() function. Only the Logic
// functions are exercised by HarnessStage2_SelfTest.mq5 -- these
// wrappers themselves still require a broker connection and are
// exactly what pair-by-pair real runs continue to validate.

bool GuardAccountWhitelisted()
  {
   long current = AccountInfoInteger(ACCOUNT_LOGIN);
   return GuardAccountWhitelistedLogic(current, g_whitelisted_account);
  }

bool GuardAccountIsReal()
  {
   ENUM_ACCOUNT_TRADE_MODE mode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   return GuardAccountIsRealLogic(mode);
  }

bool GuardExpiry()
  {
   datetime expiry = StringToTime(InpExpiryHardStopDate);
   if(expiry == 0)
      Print("FATAL: cannot parse InpExpiryHardStopDate");
   return GuardExpiryLogic(TimeCurrent(), expiry, InpExpiryBufferDays);
  }

bool GuardSpread()
  {
   MqlTick tf, ts;
   if(!SymbolInfoTick(InpSymbolFutures, tf) || !SymbolInfoTick(InpSymbolSpot, ts))
      return false;
   return GuardSpreadLogic(tf.ask - tf.bid, ts.ask - ts.bid, InpMaxSpreadUsd);
  }

bool GuardMarginLevel()
  {
   double margin_f = 0, margin_s = 0;
   if(!OrderCalcMargin(ORDER_TYPE_SELL, InpSymbolFutures, InpVolume,
                        SymbolInfoDouble(InpSymbolFutures, SYMBOL_BID), margin_f))
      return false;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, InpSymbolSpot, InpVolume,
                        SymbolInfoDouble(InpSymbolSpot, SYMBOL_ASK), margin_s))
      return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double current_margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double level_pct;
   return GuardMarginLevelLogic(equity, current_margin, margin_f, margin_s, InpMinMarginLevelPct, level_pct);
  }

bool GuardConcurrency()
  {
   // Concurrency is enforced structurally: OnChartEvent refuses a new
   // trigger while g_state is not IDLE. This function exists for
   // symmetry with the design doc's guard table and as a second,
   // independent check at RISK_CHECKING time.
   return g_state == STATE_IDLE;
  }

// Scans the most recent InpVelocityLookbackMs of real ticks for one
// symbol via CopyTicksRange() and returns the single highest tick-to-
// tick velocity found (mid price, points/sec). Returns -1 (the same
// "invalid, fail closed" sentinel TickVelocityPtsPerSec itself returns
// for dt<=0) if fewer than 2 ticks are available in the window --
// a data gap right before firing is itself not a condition this guard
// should silently wave through.
double MaxVelocityInWindow(const string symbol, long now_server_ms)
  {
   MqlTick ticks[];
   ulong to_msc = (ulong)now_server_ms;
   ulong from_msc = (to_msc > (ulong)InpVelocityLookbackMs) ? to_msc - (ulong)InpVelocityLookbackMs : 0;
   int n = CopyTicksRange(symbol, ticks, COPY_TICKS_INFO, from_msc, to_msc);
   if(n < 2)
      return -1;
   double max_v = 0;
   for(int i = 1; i < n; i++)
     {
      double mid_prev = (ticks[i-1].bid + ticks[i-1].ask) / 2.0;
      double mid_curr = (ticks[i].bid + ticks[i].ask) / 2.0;
      double v = TickVelocityPtsPerSec(mid_prev, (long)ticks[i-1].time_msc, mid_curr, (long)ticks[i].time_msc);
      if(v < 0)
         return -1; // a bad timestamp pair anywhere in the window invalidates the whole read -- fail closed
      if(v > max_v)
         max_v = v;
     }
   return max_v;
  }

// Real-API wrapper for the fast-market/stale-quote guard (R-004).
// Gathers real tick history via CopyTicksRange(), delegates the
// decision to GuardFastMarketLogic() in HarnessStage2_Guards.mqh.
// NOT covered by HarnessStage2_SelfTest.mq5 -- only a real pair run
// exercises this function itself; the self-test's G13-G17 cover the
// pure logic it delegates to, including a replay of the actual
// 2026-09-11 anomaly.
bool GuardFastMarket()
  {
   long now_server_ms = (long)TimeCurrent() * 1000;

   double velocity_futures = MaxVelocityInWindow(InpSymbolFutures, now_server_ms);
   double velocity_spot    = MaxVelocityInWindow(InpSymbolSpot, now_server_ms);

   MqlTick t_futures, t_spot;
   if(!SymbolInfoTick(InpSymbolFutures, t_futures) || !SymbolInfoTick(InpSymbolSpot, t_spot))
     {
      Print("BLOCKED: fast-market guard cannot read current ticks for one or both symbols");
      return false;
     }
   long age_futures = QuoteAgeMs(now_server_ms, (long)t_futures.time_msc);
   long age_spot    = QuoteAgeMs(now_server_ms, (long)t_spot.time_msc);
   long skew        = CrossLegSkewMs((long)t_futures.time_msc, (long)t_spot.time_msc);

   bool ok = GuardFastMarketLogic(velocity_futures, velocity_spot, InpMaxVelocityPtsPerSec,
                                   age_futures, age_spot, InpMaxQuoteAgeMs,
                                   skew, InpMaxCrossLegSkewMs);
   if(!ok)
      Print("BLOCKED: fast-market guard (velocity_fut=", DoubleToString(velocity_futures, 2),
            " velocity_spot=", DoubleToString(velocity_spot, 2), " max_v=", InpMaxVelocityPtsPerSec,
            " age_fut=", age_futures, " age_spot=", age_spot, " max_age=", InpMaxQuoteAgeMs,
            " skew=", skew, " max_skew=", InpMaxCrossLegSkewMs, ")");
   return ok;
  }

//====================================================================
// Persisted daily/run state -- survives an EA detach/reattach between
// pairs, which the operator may legitimately do between Stage 2 pairs.
// Without this, InpMaxDailyLossUsd/InpMaxPairsPerDay/
// InpMaxCumulativeLossUsd would silently reset on every reattach.
//====================================================================
string g_state_day = "";
double g_cumulative_loss_usd = 0;
double g_daily_loss_usd = 0;
int    g_pairs_today = 0;
int    g_pairs_total = 0;
int    g_consecutive_failures = 0;
bool   g_kill_switch_tripped = false;
string g_kill_switch_reason = "";

void LoadPersistedState()
  {
   string today = TimeToString(TimeCurrent(), TIME_DATE);
   int h = FileOpen(STATE_FILE, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      g_state_day = today;
      return; // first run ever -- defaults are all zero, correct
     }
   string day_read = "";
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      string parts[];
      int n = StringSplit(line, '=', parts);
      if(n < 2) continue;
      if(parts[0] == "day")               day_read = parts[1];
      else if(parts[0] == "cumulative_loss_usd") g_cumulative_loss_usd = StringToDouble(parts[1]);
      else if(parts[0] == "daily_loss_usd")      g_daily_loss_usd = StringToDouble(parts[1]);
      else if(parts[0] == "pairs_today")         g_pairs_today = (int)StringToInteger(parts[1]);
      else if(parts[0] == "pairs_total")         g_pairs_total = (int)StringToInteger(parts[1]);
      else if(parts[0] == "consecutive_failures")g_consecutive_failures = (int)StringToInteger(parts[1]);
      else if(parts[0] == "kill_switch")         g_kill_switch_tripped = (parts[1] == "1");
      else if(parts[0] == "kill_switch_reason")  g_kill_switch_reason = parts[1];
     }
   FileClose(h);
   if(day_read != today)
     {
      // New calendar day -- reset the daily counter, keep cumulative.
      Print("New session day (", today, ", was ", day_read, ") -- resetting daily counters. ",
            "Cumulative loss and kill-switch state carry forward.");
      g_daily_loss_usd = 0;
      g_pairs_today = 0;
     }
   g_state_day = today;
  }

void SavePersistedState()
  {
   int h = FileOpen(STATE_FILE, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      Print("WARNING: cannot persist daily/cumulative state -- err=", GetLastError());
      return;
     }
   FileWriteString(h, "day=" + g_state_day + "\r\n");
   FileWriteString(h, "cumulative_loss_usd=" + DoubleToString(g_cumulative_loss_usd, 2) + "\r\n");
   FileWriteString(h, "daily_loss_usd=" + DoubleToString(g_daily_loss_usd, 2) + "\r\n");
   FileWriteString(h, "pairs_today=" + IntegerToString(g_pairs_today) + "\r\n");
   FileWriteString(h, "pairs_total=" + IntegerToString(g_pairs_total) + "\r\n");
   FileWriteString(h, "consecutive_failures=" + IntegerToString(g_consecutive_failures) + "\r\n");
   FileWriteString(h, "kill_switch=" + (g_kill_switch_tripped ? "1" : "0") + "\r\n");
   FileWriteString(h, "kill_switch_reason=" + g_kill_switch_reason + "\r\n");
   FileClose(h);
  }

void TripKillSwitch(const string reason)
  {
   g_kill_switch_tripped = true;
   g_kill_switch_reason  = reason;
   SavePersistedState();
   Print("=====================================================================");
   Print("KILL SWITCH TRIPPED: ", reason);
   Print("This is LATCHING. It will not clear on its own or on EA restart.");
   Print("Manual operator action required: inspect, resolve, then delete or edit ",
         STATE_FILE, " (kill_switch=0) before this EA will fire again.");
   Print("=====================================================================");
  }

bool GuardBudgets(double projected_worst_case_loss)
  {
   ENUM_BUDGET_BLOCK block = GuardBudgetsLogic(g_kill_switch_tripped, g_pairs_total, InpMaxPairs,
      g_pairs_today, InpMaxPairsPerDay, g_daily_loss_usd, projected_worst_case_loss, InpMaxDailyLossUsd,
      g_cumulative_loss_usd, InpMaxCumulativeLossUsd);
   if(block == BUDGET_OK)
      return true;
   Print("BLOCKED: ", BudgetBlockName(block), " (kill_switch_reason='", g_kill_switch_reason, "', ",
         "pairs=", g_pairs_total, "/", InpMaxPairs, " today=", g_pairs_today, "/", InpMaxPairsPerDay,
         " daily=$", g_daily_loss_usd, "/", InpMaxDailyLossUsd,
         " cumulative=$", g_cumulative_loss_usd, "/", InpMaxCumulativeLossUsd, ")");
   return false;
  }

// FIX (R-011, 2026-09-17): this is the piece that was entirely missing
// before -- g_daily_loss_usd and g_cumulative_loss_usd were declared,
// read by GuardBudgets(), and persisted, but nothing ever WROTE a
// nonzero value to them after a pair completed. In practice this meant
// InpMaxDailyLossUsd and InpMaxCumulativeLossUsd never actually
// accumulated across pairs and could not trip regardless of real
// losses -- a more serious gap than R-011's original framing ("enforced
// from a worst-case estimate") implied. Caught on review after pair 1's
// first successful run, not from any failure -- InpMaxPairs=1 meant it
// had not yet mattered in practice.
//
// Only the LOSS portion of realized P&L is accumulated -- profits never
// reduce these counters. This is deliberate: letting profits "buy back"
// loss budget is a loss-recovery / martingale-adjacent pattern, and
// PROJECT_MANDATE.md explicitly prohibits sizing or continuing on that
// basis. A pair that makes money simply costs nothing against the
// budget; it does not fund a later, larger loss.
void RecordRealizedPnL(double pnl_usd)
  {
   double loss = LossPortion(pnl_usd);
   g_daily_loss_usd += loss;
   g_cumulative_loss_usd += loss;
  }

//====================================================================
// Real leg executor. Same idempotency/retry contract as Stage 0's
// ExecuteLeg(), now against the live MT5 API. Every "send" is one
// distinct idempotency key; a key is only ever used once.
//====================================================================
enum ENUM_LEG_RESULT
  {
   LEG_FILLED,
   LEG_PARTIAL,
   LEG_FAILED_NONTRANSIENT,
   LEG_FAILED_AFTER_RETRIES,
   LEG_HALTED
  };

// Queries broker deal history for a deal whose comment matches this
// exact idempotency key -- the real-API equivalent of Stage 0's
// simulated-ledger BrokerHasKey(). Used before any retry, per section 7.
// BUG FIX (found by pair 1's real execution, 2026-09-17): originally this
// returned only the DEAL ticket, which was then passed to
// PositionSelectByTicket() -- wrong in Hedge mode, where that function
// expects the POSITION ticket. A position's ticket is NOT always equal to
// the deal ticket that opened it; DEAL_POSITION_ID is the documented,
// authoritative way to get the position ticket from a deal, and is what
// this now returns as out_position_ticket, separate from the deal ticket
// (kept for journal/audit purposes, where the deal is the right unit).
bool BrokerHasKey(const string key, ulong &out_ticket, double &out_price, double &out_volume,
                   long &out_deal_time_msc, ulong &out_position_ticket)
  {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      string cmt = HistoryDealGetString(ticket, DEAL_COMMENT);
      if(cmt == key)
        {
         out_ticket = ticket;
         out_price  = HistoryDealGetDouble(ticket, DEAL_PRICE);
         out_volume = HistoryDealGetDouble(ticket, DEAL_VOLUME);
         out_deal_time_msc = (long)HistoryDealGetInteger(ticket, DEAL_TIME_MSC);
         out_position_ticket = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
         return true;
        }
     }
   return false;
  }

ENUM_LEG_RESULT ExecuteLeg(const string run_id, int pair_seq, int leg_id,
                            const string symbol, ENUM_ORDER_TYPE order_type,
                            double volume, double &out_fill_price, ulong &out_ticket,
                            ulong &out_position_ticket)
  {
   int attempt = 0;
   out_fill_price = 0;
   out_ticket = 0;
   out_position_ticket = 0;
   string direction = (order_type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   long t_leg_start = (long)GetTickCount64(); // R-013: wall-clock ceiling, see the retry decision below

   while(true)
     {
      attempt++;
      string key = MakeIdemKey(run_id, pair_seq, leg_id, attempt);

      // Defence against re-sending an attempt that actually succeeded.
      ulong bk_ticket; double bk_price, bk_vol; long bk_deal_ms; ulong bk_position;
      if(BrokerHasKey(key, bk_ticket, bk_price, bk_vol, bk_deal_ms, bk_position))
        {
         out_fill_price = bk_price;
         out_ticket = bk_ticket;
         out_position_ticket = bk_position;
         JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                      STATE_LEG1_FILLED, 0, 0, 0, (long)bk_deal_ms, 0,
                      bk_price, bk_vol, key, 0, 0, CurrentClockOffsetMs(), bk_ticket);
         Print("[pair ", pair_seq, " leg ", leg_id, " attempt ", attempt,
               "] ADOPTED FROM BROKER HISTORY (pre-send check) ticket=", bk_ticket, " price=", bk_price);
         return LEG_FILLED;
        }

      long t_decide = (long)GetTickCount64();
      MqlTick tick_decide;
      SymbolInfoTick(symbol, tick_decide);
      double ref_at_decide = (order_type == ORDER_TYPE_BUY) ? tick_decide.ask : tick_decide.bid;

      long t_send = (long)GetTickCount64();
      MqlTick tick_send;
      SymbolInfoTick(symbol, tick_send);
      double ref_at_send = (order_type == ORDER_TYPE_BUY) ? tick_send.ask : tick_send.bid;

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action    = TRADE_ACTION_DEAL;
      request.symbol    = symbol;
      request.volume    = volume;
      request.type      = order_type;
      request.price     = ref_at_send;
      request.deviation = InpSlippagePoints;
      request.magic     = InpMagicNumber;
      request.comment   = key;

      int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
      if((filling & SYMBOL_FILLING_FOK) != 0)      request.type_filling = ORDER_FILLING_FOK;
      else if((filling & SYMBOL_FILLING_IOC) != 0) request.type_filling = ORDER_FILLING_IOC;
      else                                         request.type_filling = ORDER_FILLING_FOK;

      Print("[pair ", pair_seq, " leg ", leg_id, " attempt ", attempt, "] SENDING ", direction,
            " ", symbol, " vol=", volume, " ref_price=", ref_at_send, " key=", key);

      bool sent = OrderSend(request, result);
      long t_ack = (long)GetTickCount64();
      int  retcode = (int)result.retcode;

      JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                   STATE_LEG1_SUBMITTED, t_decide, t_send, t_ack, 0, retcode,
                   0, 0, key, ref_at_decide, ref_at_send, CurrentClockOffsetMs(), 0);

      bool filled = sent && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL);

      if(!sent || !filled)
        {
         Print("[pair ", pair_seq, " leg ", leg_id, " attempt ", attempt, "] retcode=", retcode,
               " (", RetcodeDescription(retcode), ") sent=", sent);

         if(IsTransientRetcode(retcode))
           {
            long elapsed_ms = (long)GetTickCount64() - t_leg_start;
            // FIX (R-013, 2026-09-18): InpFillTimeoutMs was a declared,
            // never-referenced input -- InpMaxOpenRetries alone bounded
            // attempt COUNT, not wall-clock TIME, so a slow broker could
            // in principle retry InpMaxOpenRetries times over an
            // unbounded elapsed duration. Now bounded by both.
            if(attempt < InpMaxOpenRetries && elapsed_ms < InpFillTimeoutMs)
               continue;
            Print("[pair ", pair_seq, " leg ", leg_id, "] retry loop ending: attempt=", attempt,
                  "/", InpMaxOpenRetries, " elapsed=", elapsed_ms, "ms/", InpFillTimeoutMs, "ms");
            return LEG_FAILED_AFTER_RETRIES;
           }
         // Non-transient (or send() itself failed to reach the trade
         // server at all -- treated the same as non-transient: fail
         // closed, no retry, per section 7's default:false pattern).
         return LEG_FAILED_NONTRANSIENT;
        }

      // Filled (fully or partially). Confirm via deal history rather
      // than trusting result fields alone -- HistoryDealSelect gives
      // the authoritative DEAL_TIME_MSC needed for T13, and
      // DEAL_POSITION_ID gives the POSITION ticket -- NOT the same as
      // the deal ticket in Hedge mode. This is the fix for the pair 1
      // bug: PositionSelectByTicket() must be called with the position
      // ticket, never the deal ticket.
      ulong deal_ticket = result.deal;
      ulong position_ticket = 0;
      long t_fill = t_ack;
      double fill_price = result.price;
      double fill_volume = (retcode == TRADE_RETCODE_DONE_PARTIAL) ? result.volume : volume;

      if(deal_ticket != 0 && HistoryDealSelect(deal_ticket))
        {
         fill_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
         long deal_time_msc = (long)HistoryDealGetInteger(deal_ticket, DEAL_TIME_MSC);
         t_fill = ServerMsToLocalEquivalent(deal_time_msc);
         position_ticket = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
        }
      else
        {
         Print("WARNING: OrderSend reported success (retcode=", retcode,
               ") but deal ticket ", deal_ticket, " not found in history -- ",
               "recording result-field price, not deal-confirmed price. Flag this at pair 1 review.");
        }

      if(position_ticket == 0)
        {
         // Fallback only -- in Hedge mode the position ticket equals the
         // ticket of the order that opened it, so result.order is a
         // reasonable best-effort guess, but it is NOT confirmed the way
         // the DEAL_POSITION_ID path is. Flagged loudly on purpose.
         position_ticket = result.order;
         Print("WARNING: could not confirm position ticket via DEAL_POSITION_ID -- ",
               "falling back to result.order=", result.order, " (unconfirmed). ",
               "Verify this manually against the terminal's Trade tab before trusting it.");
        }

      out_fill_price = fill_price;
      out_ticket = deal_ticket;
      out_position_ticket = position_ticket;

      JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                   (retcode == TRADE_RETCODE_DONE_PARTIAL) ? STATE_LEG1_PARTIAL : STATE_LEG1_FILLED,
                   t_decide, t_send, t_ack, t_fill, retcode,
                   fill_price, fill_volume, key, ref_at_decide, ref_at_send,
                   CurrentClockOffsetMs(), deal_ticket);

      // Signed per section 5's convention: positive always means adverse
      // to the trade (dir=+1 BUY, dir=-1 SELL). Fixed here 2026-09-17 --
      // the first version printed the raw fill-ref difference unsigned,
      // which reads backwards for a SELL (a lower fill looked "negative"
      // when it is actually adverse).
      double dir = (order_type == ORDER_TYPE_BUY) ? 1.0 : -1.0;
      double signed_slippage = (fill_price - ref_at_send) * dir;
      Print("[pair ", pair_seq, " leg ", leg_id, " attempt ", attempt, "] FILLED deal=", deal_ticket,
            " position=", position_ticket, " price=", fill_price, " (ref_at_send was ", ref_at_send,
            ", slippage=", DoubleToString(signed_slippage, 5), ", +=adverse)");

      return (retcode == TRADE_RETCODE_DONE_PARTIAL) ? LEG_PARTIAL : LEG_FILLED;
     }
   // Unreachable: every branch inside the loop returns or continues.
   // Kept as an explicit fail-closed default for the compiler's benefit,
   // matching the same pattern in HarnessStage0_DryRun.mq5's ExecuteLeg().
   return LEG_FAILED_NONTRANSIENT;
  }

// RetcodeDescription() now lives in HarnessStage2_Guards.mqh.

// Returns a deal's full realized contribution to account P&L --
// profit + swap + commission, all in account currency (USD here).
// Used to compute a pair's true realized P&L from its deal tickets
// (R-011). Returns 0 if the deal cannot be found -- callers must not
// treat a silent 0 as "confirmed breakeven"; it may mean "not found".
double GetDealPnL(ulong deal_ticket)
  {
   if(deal_ticket == 0 || !HistoryDealSelect(deal_ticket))
      return 0;
   return DealPnLFromComponents(
      HistoryDealGetDouble(deal_ticket, DEAL_PROFIT),
      HistoryDealGetDouble(deal_ticket, DEAL_SWAP),
      HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION));
  }

// Emergency close of a filled leg by ticket -- used for rollback when
// leg 2 fails after leg 1 filled.
//
// FIX (R-013, 2026-09-18): originally a single attempt, documented as
// "retries internally via the outer orphan-timeout/kill-switch
// mechanism, not here" -- but no such mechanism existed anywhere else
// in this file, and InpOrphanTimeoutMs was a declared, never-referenced
// input (confirmed by grep, RISK_REGISTER.md R-013). A single transient
// retcode (e.g. REQUOTE) on the highest-stakes call in this whole EA
// -- flattening an orphaned leg -- immediately tripped the kill switch
// with no attempt to recover. Now retries on the same IsTransientRetcode
// whitelist ExecuteLeg() already uses, bounded by wall-clock
// InpOrphanTimeoutMs, not by an attempt count -- an orphan close must
// stop trying and escalate to the kill switch by a bounded TIME, not
// after an arbitrary number of attempts that could itself take
// arbitrarily long. Non-transient failures still return false on the
// first attempt, unchanged.
//
// FIX (R-011, 2026-09-17): captures the exit deal's confirmed price and
// ticket via HistoryDealSelect, the same way ExecuteLeg() already does
// for entries. Before this fix, a pair's realized P&L could not be
// computed from the journal or Experts log at all -- only from the
// terminal's own Trade History, discovered when reviewing pair 1's
// first successful run.
bool CloseLegByTicket(ulong ticket, double &out_close_price, ulong &out_close_deal)
  {
   out_close_price = 0;
   out_close_deal = 0;
   long t_start = (long)GetTickCount64();
   int attempt = 0;

   while(true)
     {
      attempt++;

      if(!PositionSelectByTicket(ticket))
        {
         Print("CRITICAL: cannot select position ", ticket, " for emergency close -- err=", GetLastError());
         return false;
        }
      string symbol = PositionGetString(POSITION_SYMBOL);
      double volume = PositionGetDouble(POSITION_VOLUME);
      long   type   = PositionGetInteger(POSITION_TYPE);

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      MqlTick t;
      SymbolInfoTick(symbol, t);

      request.action    = TRADE_ACTION_DEAL;
      request.symbol     = symbol;
      request.volume      = volume;
      request.position     = ticket;
      request.magic     = InpMagicNumber;
      request.deviation = InpSlippagePoints;
      request.comment   = "EMERGENCY_FLATTEN";

      if(type == POSITION_TYPE_BUY)
        {
         request.type = ORDER_TYPE_SELL;
         request.price = t.bid;
        }
      else
        {
         request.type = ORDER_TYPE_BUY;
         request.price = t.ask;
        }

      int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
      if((filling & SYMBOL_FILLING_FOK) != 0)      request.type_filling = ORDER_FILLING_FOK;
      else if((filling & SYMBOL_FILLING_IOC) != 0) request.type_filling = ORDER_FILLING_IOC;
      else                                         request.type_filling = ORDER_FILLING_FOK;

      bool sent = OrderSend(request, result);
      bool ok = sent && (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL);

      if(!ok)
        {
         Print("EMERGENCY FLATTEN attempt ", attempt, " position=", ticket, " sent=", sent,
               " retcode=", result.retcode, " (", RetcodeDescription((int)result.retcode), ")");
         long elapsed_ms = (long)GetTickCount64() - t_start;
         if(IsTransientRetcode((int)result.retcode) && elapsed_ms < InpOrphanTimeoutMs)
           {
            Print("EMERGENCY FLATTEN retrying position=", ticket, " -- transient retcode, ",
                  elapsed_ms, "ms of ", InpOrphanTimeoutMs, "ms orphan-timeout budget used");
            continue;
           }
         Print("EMERGENCY FLATTEN GIVING UP position=", ticket, " after ", attempt, " attempt(s), ",
               elapsed_ms, "ms elapsed (", (IsTransientRetcode((int)result.retcode) ? "orphan timeout exceeded"
               : "non-transient retcode"), ")");
         return false;
        }

      double close_price = result.price;
      if(result.deal != 0 && HistoryDealSelect(result.deal))
        {
         close_price = HistoryDealGetDouble(result.deal, DEAL_PRICE);
         out_close_deal = result.deal;
        }
      else
        {
         Print("WARNING: close reported success but deal ", result.deal, " not found in history -- ",
               "using result-field price, not deal-confirmed. Flag this at pair 1 review.");
        }
      out_close_price = close_price;

      Print("EMERGENCY FLATTEN position=", ticket, " deal=", result.deal, " attempt=", attempt,
            " retcode=", result.retcode, " (", RetcodeDescription((int)result.retcode),
            ") close_price=", close_price);
      return true;
     }
   // Unreachable: every branch inside the loop returns or continues.
   // Kept as an explicit fail-closed default for the compiler's benefit,
   // matching the same pattern in ExecuteLeg() and HarnessStage0_DryRun.mq5.
   return false;
  }

//====================================================================
// Pair-level flow. Concurrency=1 enforced structurally in
// OnChartEvent, which refuses a new trigger unless g_state == IDLE.
//====================================================================
string g_run_id = "";

enum ENUM_OUTCOME_STAGE2
  {
   OUTCOME_COMPLETED,
   OUTCOME_REJECTED_BROKER,
   OUTCOME_ORPHANED_RECOVERED,
   OUTCOME_ORPHANED_UNRESOLVED,
   OUTCOME_HALTED
  };

string OutcomeName(int o)
  {
   switch(o)
     {
      case OUTCOME_COMPLETED:           return "COMPLETED";
      case OUTCOME_REJECTED_BROKER:     return "REJECTED_BROKER";
      case OUTCOME_ORPHANED_RECOVERED:  return "ORPHANED_RECOVERED";
      case OUTCOME_ORPHANED_UNRESOLVED: return "ORPHANED_UNRESOLVED";
      case OUTCOME_HALTED:              return "HALTED";
     }
   return "UNKNOWN";
  }

// Pair-level P&L summary, added 2026-09-17 (R-011). One row per pair
// attempt, so a pair's realized outcome is readable directly from a
// CSV without cross-referencing the terminal's Trade History. Written
// once, at the end of RunOnePair(), regardless of outcome.
void PairSummaryWrite(const string run_id, int pair_seq, int outcome,
                       double leg1_entry, double leg1_exit,
                       double leg2_entry, double leg2_exit,
                       double realized_pnl_usd, bool pnl_confirmed,
                       double daily_loss_after, double cumulative_loss_after)
  {
   bool is_new = !FileIsExist(PAIR_SUMMARY_FILE);
   int h = FileOpen(PAIR_SUMMARY_FILE, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      Print("WARNING: cannot write pair summary -- err=", GetLastError());
      return;
     }
   FileSeek(h, 0, SEEK_END);
   if(is_new)
      FileWriteString(h, "run_id,pair_seq,outcome,leg1_entry,leg1_exit,leg2_entry,leg2_exit,"
                          "realized_pnl_usd,pnl_status,daily_loss_after,cumulative_loss_after\r\n");
   string line = StringFormat("%s,%d,%s,%.5f,%.5f,%.5f,%.5f,%.2f,%s,%.2f,%.2f",
      run_id, pair_seq, OutcomeName(outcome),
      leg1_entry, leg1_exit, leg2_entry, leg2_exit,
      realized_pnl_usd, pnl_confirmed ? "confirmed" : "INCOMPLETE",
      daily_loss_after, cumulative_loss_after);
   FileWriteString(h, line + "\r\n");
   FileFlush(h);
   FileClose(h);
  }

void RunOnePair()
  {
   g_state = STATE_RISK_CHECKING;

   if(!GuardAccountWhitelisted())
     { Print("BLOCKED: account whitelist mismatch"); g_state = STATE_IDLE; return; }
   if(!GuardAccountIsReal())
     { Print("BLOCKED: account is not ACCOUNT_TRADE_MODE_REAL"); g_state = STATE_IDLE; return; }
   if(!GuardExpiry())
     { Print("BLOCKED: within expiry hard-stop buffer of ", InpExpiryHardStopDate); g_state = STATE_IDLE; return; }
   if(!GuardSpread())
     { Print("BLOCKED: spread circuit breaker (InpMaxSpreadUsd=", InpMaxSpreadUsd, ")"); g_state = STATE_IDLE; return; }
   if(!GuardMarginLevel())
     { Print("BLOCKED: projected margin level below InpMinMarginLevelPct (", InpMinMarginLevelPct, "%)"); g_state = STATE_IDLE; return; }
   if(!GuardFastMarket())
     { g_state = STATE_IDLE; return; } // GuardFastMarket already prints its own reason (R-004)
   if(!GuardBudgets(InpMaxTradeLossUsd))
     { g_state = STATE_IDLE; return; } // GuardBudgets already prints its own reason

   g_run_id = IntegerToString((int)TimeCurrent());
   int pair_seq = g_pairs_total + 1;

   Print("=====================================================================");
   Print("PAIR ", pair_seq, " STARTING. run_id=", g_run_id,
         (pair_seq == 1 ? "  *** THIS IS PAIR 1 -- ELEVATED SCRUTINY PROCEDURE APPLIES (section 8.1.3) ***" : ""));
   Print("=====================================================================");

   g_state = STATE_LEG1_SUBMITTED;
   double leg1_price; ulong leg1_deal; ulong leg1_position;
   ENUM_LEG_RESULT r1 = ExecuteLeg(g_run_id, pair_seq, 1, InpSymbolFutures, ORDER_TYPE_SELL,
                                    InpVolume, leg1_price, leg1_deal, leg1_position);

   if(r1 == LEG_FAILED_NONTRANSIENT || r1 == LEG_FAILED_AFTER_RETRIES)
     {
      g_state = STATE_CLOSED;
      g_consecutive_failures++;
      g_pairs_total++;
      // No deal ever filled -- genuinely zero cost, not an estimate.
      PairSummaryWrite(g_run_id, pair_seq, OUTCOME_REJECTED_BROKER, 0, 0, 0, 0, 0, true,
                        g_daily_loss_usd, g_cumulative_loss_usd);
      SavePersistedState();
      if(g_consecutive_failures >= InpMaxConsecutiveFailures)
         TripKillSwitch(StringFormat("%d consecutive failures", g_consecutive_failures));
      Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_REJECTED_BROKER), " (no exposure created)");
      g_state = STATE_IDLE;
      return;
     }

   if(r1 == LEG_PARTIAL)
     {
      g_state = STATE_LEG1_PARTIAL;
      g_state = STATE_ORPHANED;
      Print("LEG 1 PARTIAL FILL -- treating as exposure, emergency-flattening residual");
      g_state = STATE_EMERGENCY_FLATTENING;
      double close_price; ulong close_deal;
      bool flattened = CloseLegByTicket(leg1_position, close_price, close_deal);

      // BUG FIX, 2026-09-17: this branch previously fell through to
      // CLOSED_ORPHAN/ORPHANED_RECOVERED/IDLE regardless of whether the
      // flatten succeeded -- inconsistent with the other two
      // flatten-failure paths below, which correctly halt instead.
      // Never triggered in either real run so far (r1 was LEG_FILLED
      // both times), caught on review while adding PairSummaryWrite,
      // whose HALTED-vs-ORPHANED_RECOVERED row would otherwise have
      // contradicted this branch's own final state and log line.
      if(!flattened)
        {
         TripKillSwitch("partial-fill flatten failed -- manual intervention required NOW");
         g_state = STATE_HALTED;
         g_pairs_total++;
         PairSummaryWrite(g_run_id, pair_seq, OUTCOME_HALTED, leg1_price, close_price, 0, 0, 0, false,
                           g_daily_loss_usd, g_cumulative_loss_usd);
         SavePersistedState();
         Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_HALTED));
         return;
        }

      double pnl = GetDealPnL(leg1_deal) + GetDealPnL(close_deal);
      RecordRealizedPnL(pnl);
      PairSummaryWrite(g_run_id, pair_seq, OUTCOME_ORPHANED_RECOVERED, leg1_price, close_price, 0, 0,
                        pnl, true, g_daily_loss_usd, g_cumulative_loss_usd);
      Print("Pair ", pair_seq, " realized P&L: $", DoubleToString(pnl, 2),
            "  (running: daily loss $", DoubleToString(g_daily_loss_usd, 2), "/", InpMaxDailyLossUsd,
            ", cumulative loss $", DoubleToString(g_cumulative_loss_usd, 2), "/", InpMaxCumulativeLossUsd, ")");
      g_state = STATE_CLOSED_ORPHAN;
      g_pairs_total++;
      g_pairs_today++;
      SavePersistedState();
      Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_ORPHANED_RECOVERED));
      g_state = STATE_IDLE;
      return;
     }

   // r1 == LEG_FILLED
   g_state = STATE_LEG1_FILLED;

   // 2026-09-18: re-run the fast-market guard here, immediately before Leg 2
   // dispatches, not only before Leg 1. tools/simulate_execution.py's offline
   // replay found that a fast-market event starting after the initial guard
   // passes but before Leg 2 sends would previously slip through entirely --
   // exactly the shape of the real 2026-09-11 anomaly (three repricings within
   // ~10 seconds). This reuses the same already-tested GuardFastMarketLogic()
   // (G17 self-test); it does not add a new threshold. If it trips here, Leg 1
   // is already open and must be flattened -- this is NOT a "decline to enter"
   // path like the pre-Leg-1 guard, it is a rollback path, identical to the
   // existing "Leg 2 failed" handling below.
   if(!GuardFastMarket())
     {
      g_state = STATE_ORPHANED;
      Print("LEG 2 PRE-DISPATCH FAST-MARKET GUARD TRIPPED -- rolling back leg 1 (position ", leg1_position, ") before Leg 2 ever sent");
      g_state = STATE_EMERGENCY_FLATTENING;
      double guard_close_price; ulong guard_close_deal;
      bool guard_flattened = CloseLegByTicket(leg1_position, guard_close_price, guard_close_deal);
      if(!guard_flattened)
        {
         TripKillSwitch("rollback of leg 1 failed after pre-leg-2 fast-market guard trip -- manual intervention required NOW");
         g_state = STATE_HALTED;
         g_pairs_total++;
         PairSummaryWrite(g_run_id, pair_seq, OUTCOME_HALTED, leg1_price, guard_close_price, 0, 0, 0, false,
                           g_daily_loss_usd, g_cumulative_loss_usd);
         SavePersistedState();
         Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_HALTED));
         return;
        }
      g_state = STATE_CLOSED_ORPHAN;
      g_consecutive_failures++;
      g_pairs_total++;
      g_pairs_today++;
      double guard_pnl = GetDealPnL(leg1_deal) + GetDealPnL(guard_close_deal);
      RecordRealizedPnL(guard_pnl);
      PairSummaryWrite(g_run_id, pair_seq, OUTCOME_ORPHANED_RECOVERED, leg1_price, guard_close_price, 0, 0,
                        guard_pnl, true, g_daily_loss_usd, g_cumulative_loss_usd);
      Print("Pair ", pair_seq, " realized P&L: $", DoubleToString(guard_pnl, 2),
            "  (running: daily loss $", DoubleToString(g_daily_loss_usd, 2), "/", InpMaxDailyLossUsd,
            ", cumulative loss $", DoubleToString(g_cumulative_loss_usd, 2), "/", InpMaxCumulativeLossUsd, ")");
      if(g_consecutive_failures >= InpMaxConsecutiveFailures)
         TripKillSwitch(StringFormat("%d consecutive failures", g_consecutive_failures));
      Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_ORPHANED_RECOVERED));
      SavePersistedState();
      g_state = STATE_IDLE;
      return;
     }

   g_state = STATE_LEG2_SUBMITTED;
   double leg2_price; ulong leg2_deal; ulong leg2_position;
   ENUM_LEG_RESULT r2 = ExecuteLeg(g_run_id, pair_seq, 2, InpSymbolSpot, ORDER_TYPE_BUY,
                                    InpVolume, leg2_price, leg2_deal, leg2_position);

   if(r2 == LEG_FILLED || r2 == LEG_PARTIAL)
     {
      g_state = STATE_HEDGED;
      Print("HEDGED. leg1 position=", leg1_position, " @", leg1_price,
            "  leg2 position=", leg2_position, " @", leg2_price);

      if(InpDwellMs > 0)
         Sleep((int)InpDwellMs); // fixed at 0 per section 8.1.1; kept for completeness

      g_state = STATE_UNWINDING;
      double leg1_close_price, leg2_close_price; ulong leg1_close_deal, leg2_close_deal;
      bool c1 = CloseLegByTicket(leg1_position, leg1_close_price, leg1_close_deal);
      bool c2 = CloseLegByTicket(leg2_position, leg2_close_price, leg2_close_deal);
      if(!c1 || !c2)
        {
         TripKillSwitch(StringFormat("exit leg failed to close (leg1_ok=%s leg2_ok=%s) -- manual intervention required NOW",
                                      c1 ? "true" : "false", c2 ? "true" : "false"));
         g_state = STATE_HALTED;
         g_pairs_total++;
         PairSummaryWrite(g_run_id, pair_seq, OUTCOME_HALTED, leg1_price, leg1_close_price,
                           leg2_price, leg2_close_price, 0, false, g_daily_loss_usd, g_cumulative_loss_usd);
         SavePersistedState();
         Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_HALTED));
         return;
        }
      g_state = STATE_CLOSED;
      g_consecutive_failures = 0;
      g_pairs_total++;
      g_pairs_today++;
      double pnl = GetDealPnL(leg1_deal) + GetDealPnL(leg2_deal) + GetDealPnL(leg1_close_deal) + GetDealPnL(leg2_close_deal);
      RecordRealizedPnL(pnl);
      PairSummaryWrite(g_run_id, pair_seq, OUTCOME_COMPLETED, leg1_price, leg1_close_price,
                        leg2_price, leg2_close_price, pnl, true, g_daily_loss_usd, g_cumulative_loss_usd);
      Print("Pair ", pair_seq, " realized P&L: $", DoubleToString(pnl, 2),
            "  (running: daily loss $", DoubleToString(g_daily_loss_usd, 2), "/", InpMaxDailyLossUsd,
            ", cumulative loss $", DoubleToString(g_cumulative_loss_usd, 2), "/", InpMaxCumulativeLossUsd, ")");
      Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_COMPLETED));
     }
   else
     {
      // Leg 2 failed in any form -- roll back leg 1. The single most
      // important path, per 34_DEMO_TEST_PLAN.md section 5.
      g_state = STATE_ORPHANED;
      Print("LEG 2 FAILED -- rolling back leg 1 (position ", leg1_position, ")");
      g_state = STATE_EMERGENCY_FLATTENING;
      double close_price; ulong close_deal;
      bool flattened = CloseLegByTicket(leg1_position, close_price, close_deal);
      if(!flattened)
        {
         TripKillSwitch("rollback of leg 1 failed after leg 2 failure -- manual intervention required NOW");
         g_state = STATE_HALTED;
         g_pairs_total++;
         PairSummaryWrite(g_run_id, pair_seq, OUTCOME_HALTED, leg1_price, close_price, 0, 0, 0, false,
                           g_daily_loss_usd, g_cumulative_loss_usd);
         SavePersistedState();
         Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_HALTED));
         return;
        }
      g_state = STATE_CLOSED_ORPHAN;
      g_consecutive_failures++;
      g_pairs_total++;
      g_pairs_today++;
      double pnl = GetDealPnL(leg1_deal) + GetDealPnL(close_deal);
      RecordRealizedPnL(pnl);
      PairSummaryWrite(g_run_id, pair_seq, OUTCOME_ORPHANED_RECOVERED, leg1_price, close_price, 0, 0,
                        pnl, true, g_daily_loss_usd, g_cumulative_loss_usd);
      Print("Pair ", pair_seq, " realized P&L: $", DoubleToString(pnl, 2),
            "  (running: daily loss $", DoubleToString(g_daily_loss_usd, 2), "/", InpMaxDailyLossUsd,
            ", cumulative loss $", DoubleToString(g_cumulative_loss_usd, 2), "/", InpMaxCumulativeLossUsd, ")");
      if(g_consecutive_failures >= InpMaxConsecutiveFailures)
         TripKillSwitch(StringFormat("%d consecutive failures", g_consecutive_failures));
      Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_ORPHANED_RECOVERED));
     }

   SavePersistedState();
   g_state = STATE_IDLE;
  }

//====================================================================
// Manual trigger -- a single chart button. Never a timer. T18.
//====================================================================
#define BTN_TRIGGER "Stage2TriggerButton"

void CreateTriggerButton()
  {
   ObjectCreate(0, BTN_TRIGGER, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, BTN_TRIGGER, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, BTN_TRIGGER, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, BTN_TRIGGER, OBJPROP_XSIZE, 220);
   ObjectSetInteger(0, BTN_TRIGGER, OBJPROP_YSIZE, 40);
   ObjectSetString(0, BTN_TRIGGER, OBJPROP_TEXT, "FIRE ONE PAIR (Stage 2)");
   ObjectSetInteger(0, BTN_TRIGGER, OBJPROP_BGCOLOR, clrFireBrick);
   ObjectSetInteger(0, BTN_TRIGGER, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, BTN_TRIGGER, OBJPROP_SELECTABLE, false);
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK || sparam != BTN_TRIGGER)
      return;
   ObjectSetInteger(0, BTN_TRIGGER, OBJPROP_STATE, false); // un-press the button visually

   if(g_state != STATE_IDLE)
     {
      Print("BLOCKED: a pair is already in flight (state=", StateName(g_state), "). ",
            "Concurrency is 1 -- wait for it to reach CLOSED or CLOSED_ORPHAN.");
      return;
     }
   RunOnePair();
  }

//====================================================================
// Startup reconciliation -- required before any new pair may fire.
// Queries real broker positions for anything bearing InpMagicNumber
// with no corresponding CLOSED row in the journal.
//====================================================================
bool StartupReconciling()
  {
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      Print("=====================================================================");
      Print("STARTUP RECONCILIATION: found an OPEN position with this EA's magic number.");
      Print("  ticket=", ticket, " symbol=", PositionGetString(POSITION_SYMBOL),
            " volume=", PositionGetDouble(POSITION_VOLUME));
      Print("This means either a prior run left exposure unresolved, or this EA was just");
      Print("attached to a chart that already has a position from a previous session.");
      Print("Per section 7 of the design doc, this is never auto-adopted. Refusing to fire");
      Print("any new pair until this is resolved by direct operator inspection.");
      Print("=====================================================================");
      return false;
     }
   return true;
  }

//====================================================================
// Entry point.
//====================================================================
int OnInit()
  {
   Print("=====================================================================");
   Print("HarnessStage2_LivePilot -- LIVE. This places real orders. InpMaxPairs=", InpMaxPairs);
   Print("=====================================================================");

   g_whitelisted_account = ReadWhitelistedAccount();
   if(g_whitelisted_account <= 0)
      return(INIT_FAILED);

   if(!GuardAccountWhitelisted())
     {
      Print("FATAL: current account does not match the whitelisted account number in ",
            WHITELIST_CONFIG_FILE, ". Refusing to initialise.");
      return(INIT_FAILED);
     }
   if(!GuardAccountIsReal())
     {
      Print("FATAL: current account is not ACCOUNT_TRADE_MODE_REAL. This EA only runs on ",
            "the whitelisted live account, by design. Refusing to initialise.");
      return(INIT_FAILED);
     }
   if(!GuardExpiry())
     {
      Print("FATAL: within ", InpExpiryBufferDays, " days of the ", InpSymbolFutures,
            " expiry hard stop (", InpExpiryHardStopDate, "). Refusing to initialise.");
      return(INIT_FAILED);
     }

   if(!EstablishClockBaseline())
     {
      Print("FATAL: cannot establish clock baseline (no tick available for ", InpSymbolSpot, ")");
      return(INIT_FAILED);
     }

   LoadPersistedState();
   if(g_kill_switch_tripped)
     {
      Print("FATAL: kill switch is latched from a previous run (", g_kill_switch_reason, "). ",
            "Manual operator action required before this EA will initialise.");
      return(INIT_FAILED);
     }

   if(!JournalOpenForAppend())
      return(INIT_FAILED);

   if(!StartupReconciling())
     {
      JournalClose();
      return(INIT_FAILED);
     }

   CreateTriggerButton();
   g_state = STATE_IDLE;

   Print("Ready. Account whitelist OK. Pairs so far this run: ", g_pairs_total,
         "  today: ", g_pairs_today, "  cumulative loss so far: $", g_cumulative_loss_usd);
   Print("Click 'FIRE ONE PAIR' to fire exactly one pair. Nothing fires automatically.");
   Print("Journal: ", TerminalInfoString(TERMINAL_DATA_PATH), "\\MQL5\\Files\\", JOURNAL_FILE);
   Print("Pair summary (P&L per pair): ", TerminalInfoString(TERMINAL_DATA_PATH), "\\MQL5\\Files\\", PAIR_SUMMARY_FILE);

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjectDelete(0, BTN_TRIGGER);
   JournalClose();
  }

// No automatic action on tick -- firing is manual-only (T18).
void OnTick()
  {
  }
