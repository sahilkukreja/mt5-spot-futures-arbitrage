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
input long   InpAckTimeoutMs         = 5000;
input long   InpFillTimeoutMs        = 10000;
input long   InpOrphanTimeoutMs      = 3000;
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

//====================================================================
// Retry whitelist -- IDENTICAL logic to HarnessStage0_DryRun.mq5's
// IsTransientRetcode(), now over real MT5 TRADE_RETCODE_* values.
// Mirrors MMT_TradePannel_Pro_v284.cpp's ShouldRetry(): explicit
// transient cases, default:false. Pair 1's procedure requires checking
// every retcode actually received against MT5 documentation directly,
// not trusting this whitelist on faith -- it has never faced a real
// broker before this file's first run.
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

//====================================================================
// Journal -- same schema as Stage 0, extended per section 5 with dual
// reference prices and the clock-offset field. Never truncated at
// start (unlike Stage 0's self-test) -- this journal is exactly what
// section 7's restart-reconciliation contract depends on surviving.
//====================================================================
#define JOURNAL_FILE "arb_harness_stage2_journal.csv"
#define STATE_FILE   "arb_harness_stage2_daily_state.txt"

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

string MakeIdemKey(const string run_id, int pair_seq, int leg_id, int attempt)
  {
   return StringFormat("H%s-P%d-L%d-A%d", run_id, pair_seq, leg_id, attempt);
  }

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

bool GuardAccountWhitelisted()
  {
   long current = AccountInfoInteger(ACCOUNT_LOGIN);
   if(g_whitelisted_account <= 0)
      return false;
   return current == g_whitelisted_account;
  }

bool GuardAccountIsReal()
  {
   return (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL;
  }

bool GuardExpiry()
  {
   datetime expiry = StringToTime(InpExpiryHardStopDate);
   if(expiry == 0)
     {
      Print("FATAL: cannot parse InpExpiryHardStopDate");
      return false;
     }
   datetime cutoff = (datetime)((long)expiry - InpExpiryBufferDays * 86400);
   return TimeCurrent() < cutoff;
  }

bool GuardSpread()
  {
   MqlTick tf, ts;
   if(!SymbolInfoTick(InpSymbolFutures, tf) || !SymbolInfoTick(InpSymbolSpot, ts))
      return false;
   double spread_f = tf.ask - tf.bid;
   double spread_s = ts.ask - ts.bid;
   return (spread_f < InpMaxSpreadUsd) && (spread_s < InpMaxSpreadUsd);
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
   double projected_margin = current_margin + margin_f + margin_s;
   if(projected_margin <= 0)
      return true; // no margin required -- guard does not apply
   double projected_level_pct = 100.0 * equity / projected_margin;
   return projected_level_pct > InpMinMarginLevelPct;
  }

bool GuardConcurrency()
  {
   // Concurrency is enforced structurally: OnChartEvent refuses a new
   // trigger while g_state is not IDLE. This function exists for
   // symmetry with the design doc's guard table and as a second,
   // independent check at RISK_CHECKING time.
   return g_state == STATE_IDLE;
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
   if(g_kill_switch_tripped)
     {
      Print("BLOCKED: kill switch is latched (", g_kill_switch_reason, ")");
      return false;
     }
   if(g_pairs_total >= InpMaxPairs)
     {
      Print("BLOCKED: InpMaxPairs (", InpMaxPairs, ") reached for this run");
      return false;
     }
   if(g_pairs_today >= InpMaxPairsPerDay)
     {
      Print("BLOCKED: InpMaxPairsPerDay (", InpMaxPairsPerDay, ") reached");
      return false;
     }
   if(g_daily_loss_usd + projected_worst_case_loss > InpMaxDailyLossUsd)
     {
      Print("BLOCKED: would risk exceeding InpMaxDailyLossUsd (", InpMaxDailyLossUsd, ")");
      return false;
     }
   if(g_cumulative_loss_usd + projected_worst_case_loss > InpMaxCumulativeLossUsd)
     {
      Print("BLOCKED: would risk exceeding InpMaxCumulativeLossUsd (", InpMaxCumulativeLossUsd, ")");
      return false;
     }
   return true;
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
bool BrokerHasKey(const string key, ulong &out_ticket, double &out_price, double &out_volume, long &out_deal_time_msc)
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
         return true;
        }
     }
   return false;
  }

ENUM_LEG_RESULT ExecuteLeg(const string run_id, int pair_seq, int leg_id,
                            const string symbol, ENUM_ORDER_TYPE order_type,
                            double volume, double &out_fill_price, ulong &out_ticket)
  {
   int attempt = 0;
   out_fill_price = 0;
   out_ticket = 0;
   string direction = (order_type == ORDER_TYPE_BUY) ? "BUY" : "SELL";

   while(true)
     {
      attempt++;
      string key = MakeIdemKey(run_id, pair_seq, leg_id, attempt);

      // Defence against re-sending an attempt that actually succeeded.
      ulong bk_ticket; double bk_price, bk_vol; long bk_deal_ms;
      if(BrokerHasKey(key, bk_ticket, bk_price, bk_vol, bk_deal_ms))
        {
         out_fill_price = bk_price;
         out_ticket = bk_ticket;
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
            if(attempt < InpMaxOpenRetries)
               continue;
            return LEG_FAILED_AFTER_RETRIES;
           }
         // Non-transient (or send() itself failed to reach the trade
         // server at all -- treated the same as non-transient: fail
         // closed, no retry, per section 7's default:false pattern).
         return LEG_FAILED_NONTRANSIENT;
        }

      // Filled (fully or partially). Confirm via deal history rather
      // than trusting result fields alone -- HistoryDealSelect gives
      // the authoritative DEAL_TIME_MSC needed for T13.
      ulong deal_ticket = result.deal;
      long t_fill = t_ack;
      double fill_price = result.price;
      double fill_volume = (retcode == TRADE_RETCODE_DONE_PARTIAL) ? result.volume : volume;

      if(deal_ticket != 0 && HistoryDealSelect(deal_ticket))
        {
         fill_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
         long deal_time_msc = (long)HistoryDealGetInteger(deal_ticket, DEAL_TIME_MSC);
         t_fill = ServerMsToLocalEquivalent(deal_time_msc);
        }
      else
        {
         Print("WARNING: OrderSend reported success (retcode=", retcode,
               ") but deal ticket ", deal_ticket, " not found in history -- ",
               "recording result-field price, not deal-confirmed price. Flag this at pair 1 review.");
        }

      out_fill_price = fill_price;
      out_ticket = deal_ticket;

      JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                   (retcode == TRADE_RETCODE_DONE_PARTIAL) ? STATE_LEG1_PARTIAL : STATE_LEG1_FILLED,
                   t_decide, t_send, t_ack, t_fill, retcode,
                   fill_price, fill_volume, key, ref_at_decide, ref_at_send,
                   CurrentClockOffsetMs(), deal_ticket);

      Print("[pair ", pair_seq, " leg ", leg_id, " attempt ", attempt, "] FILLED ticket=", deal_ticket,
            " price=", fill_price, " (ref_at_send was ", ref_at_send, ", slippage=",
            DoubleToString(fill_price - ref_at_send, 5), ")");

      return (retcode == TRADE_RETCODE_DONE_PARTIAL) ? LEG_PARTIAL : LEG_FILLED;
     }
   // Unreachable: every branch inside the loop returns or continues.
   // Kept as an explicit fail-closed default for the compiler's benefit,
   // matching the same pattern in HarnessStage0_DryRun.mq5's ExecuteLeg().
   return LEG_FAILED_NONTRANSIENT;
  }

string RetcodeDescription(int retcode)
  {
   // MT5 does not expose a built-in retcode->string function usable
   // here without CTrade; this is a partial, human-maintained mapping
   // for the common cases. Pair 1's procedure explicitly requires
   // checking the ACTUAL retcode integer against MT5's own
   // documentation directly -- do not trust this mapping alone.
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

// Emergency close of a filled leg by ticket -- used for rollback when
// leg 2 fails after leg 1 filled. Single attempt is intentional: this
// is the flatten path, not the open path; it retries internally via
// the outer orphan-timeout/kill-switch mechanism, not here.
bool CloseLegByTicket(ulong ticket)
  {
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
   Print("EMERGENCY FLATTEN ticket=", ticket, " sent=", sent, " retcode=", result.retcode,
         " (", RetcodeDescription((int)result.retcode), ")");
   return sent && (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL);
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
   if(!GuardBudgets(InpMaxTradeLossUsd))
     { g_state = STATE_IDLE; return; } // GuardBudgets already prints its own reason

   g_run_id = IntegerToString((int)TimeCurrent());
   int pair_seq = g_pairs_total + 1;

   Print("=====================================================================");
   Print("PAIR ", pair_seq, " STARTING. run_id=", g_run_id,
         (pair_seq == 1 ? "  *** THIS IS PAIR 1 -- ELEVATED SCRUTINY PROCEDURE APPLIES (section 8.1.3) ***" : ""));
   Print("=====================================================================");

   g_state = STATE_LEG1_SUBMITTED;
   double leg1_price; ulong leg1_ticket;
   ENUM_LEG_RESULT r1 = ExecuteLeg(g_run_id, pair_seq, 1, InpSymbolFutures, ORDER_TYPE_SELL,
                                    InpVolume, leg1_price, leg1_ticket);

   if(r1 == LEG_FAILED_NONTRANSIENT || r1 == LEG_FAILED_AFTER_RETRIES)
     {
      g_state = STATE_CLOSED;
      g_consecutive_failures++;
      g_pairs_total++;
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
      bool flattened = CloseLegByTicket(leg1_ticket);
      if(!flattened)
         TripKillSwitch("partial-fill flatten failed -- manual intervention required NOW");
      g_state = STATE_CLOSED_ORPHAN;
      g_pairs_total++;
      SavePersistedState();
      Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_ORPHANED_RECOVERED));
      g_state = STATE_IDLE;
      return;
     }

   // r1 == LEG_FILLED
   g_state = STATE_LEG1_FILLED;
   g_state = STATE_LEG2_SUBMITTED;
   double leg2_price; ulong leg2_ticket;
   ENUM_LEG_RESULT r2 = ExecuteLeg(g_run_id, pair_seq, 2, InpSymbolSpot, ORDER_TYPE_BUY,
                                    InpVolume, leg2_price, leg2_ticket);

   double realized_loss = 0;

   if(r2 == LEG_FILLED || r2 == LEG_PARTIAL)
     {
      g_state = STATE_HEDGED;
      Print("HEDGED. leg1=", leg1_ticket, " @", leg1_price, "  leg2=", leg2_ticket, " @", leg2_price);

      if(InpDwellMs > 0)
         Sleep((int)InpDwellMs); // fixed at 0 per section 8.1.1; kept for completeness

      g_state = STATE_UNWINDING;
      bool c1 = CloseLegByTicket(leg1_ticket);
      bool c2 = CloseLegByTicket(leg2_ticket);
      if(!c1 || !c2)
        {
         TripKillSwitch(StringFormat("exit leg failed to close (leg1_ok=%s leg2_ok=%s) -- manual intervention required NOW",
                                      c1 ? "true" : "false", c2 ? "true" : "false"));
         g_state = STATE_HALTED;
         g_pairs_total++;
         SavePersistedState();
         Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_HALTED));
         return;
        }
      g_state = STATE_CLOSED;
      g_consecutive_failures = 0;
      Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_COMPLETED));
     }
   else
     {
      // Leg 2 failed in any form -- roll back leg 1. The single most
      // important path, per 34_DEMO_TEST_PLAN.md section 5.
      g_state = STATE_ORPHANED;
      Print("LEG 2 FAILED -- rolling back leg 1 (ticket ", leg1_ticket, ")");
      g_state = STATE_EMERGENCY_FLATTENING;
      bool flattened = CloseLegByTicket(leg1_ticket);
      if(!flattened)
        {
         TripKillSwitch("rollback of leg 1 failed after leg 2 failure -- manual intervention required NOW");
         g_state = STATE_HALTED;
         g_pairs_total++;
         SavePersistedState();
         Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_HALTED));
         return;
        }
      g_state = STATE_CLOSED_ORPHAN;
      g_consecutive_failures++;
      if(g_consecutive_failures >= InpMaxConsecutiveFailures)
         TripKillSwitch(StringFormat("%d consecutive failures", g_consecutive_failures));
      Print("PAIR ", pair_seq, " outcome: ", OutcomeName(OUTCOME_ORPHANED_RECOVERED));
     }

   g_pairs_total++;
   g_pairs_today++;
   // realized_loss left at 0 here deliberately -- computing true realized
   // P&L requires summing HistoryDealGetDouble(DEAL_PROFIT) across all
   // four legs' deals, not attempted in this pass. Until that is added,
   // InpMaxDailyLossUsd/InpMaxCumulativeLossUsd are enforced only at the
   // PRE-TRADE budget-check stage (GuardBudgets, using the worst-case
   // InpMaxTradeLossUsd estimate), not from realized P&L after the fact.
   // This is a real gap: flag it explicitly at pair 1 review, and do not
   // proceed to Stage 3/4 volumes until realized-P&L tracking is added.
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
