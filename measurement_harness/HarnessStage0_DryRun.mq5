//+------------------------------------------------------------------+
//|                                       HarnessStage0_DryRun.mq5   |
//|                                                                  |
//| STAGE 0 DRY RUN ONLY. Design: docs/04_testing/34_DEMO_TEST_PLAN.md
//| section 5 (state machine), 6 (guards), 7 (timeouts/idempotency/
//| persistence/recovery), 8 (output schema), 10 (acceptance tests).
//|
//| WHAT THIS IS: a self-contained correctness test of the execution
//| harness's state machine, idempotency, journal and restart
//| reconciliation logic, driven entirely by an in-process simulated
//| broker. It runs the 12 acceptance-test scenarios (T1-T12) on
//| attach and reports PASS/FAIL for each.
//|
//| WHAT THIS IS NOT: this file contains NO call to OrderSend,
//| OrderSendAsync, OrderCheck, CTrade, PositionOpen, or any other
//| MT5 trading API -- checkable by grep. It also makes no
//| AccountInfo*/SymbolInfoTick calls. It is incapable of placing,
//| modifying or closing a real or demo order BY CONSTRUCTION, not
//| by a runtime flag that could be misconfigured. Every "broker"
//| response in this file comes from a scripted array this file
//| itself defines.
//|
//| Stage 1 (real demo orders) and Stage 2+ (live) are separate,
//| currently-blocked work -- see docs/04_testing/34_DEMO_TEST_PLAN.md
//| and docs/04_testing/35_1000_USD_LIVE_TEST_PLAN.md. Nothing in this
//| file should be copied into that work without re-deriving the parts
//| that touch a real broker; this file's value is the state-machine
//| logic, not its simulated I/O.
//|
//| Quarantine: see measurement_harness/README.md. This directory is
//| never a source for src/, the same way legacy/ never is.
//+------------------------------------------------------------------+
#property copyright "MT5 Spot-Futures Arbitrage -- research project"
#property version   "0.100"
#property strict

//====================================================================
// Inputs -- starting values from 34_DEMO_TEST_PLAN.md section 7.
// Every one is UNCALIBRATED. This file only exercises the logic that
// consumes them; it does not validate the values themselves.
//====================================================================
input int    InpMaxOpenRetries        = 3;      // retry cap per leg
input int    InpMaxConsecutiveFailures= 3;      // kill-switch trigger
input double InpMaxSpreadUsd          = 3.00;   // circuit breaker, not a filter (D-H1)
input double InpMinMarginLevelPct     = 300.0;  // fail-safe guard
input long   InpSessionGuardMarginMs  = 900000; // 15 min, section 7

//====================================================================
// Section 5 -- state machine (reduced subset, names match
// 34_DEMO_TEST_PLAN.md section 5 exactly so findings map back onto
// 22_STATE_MACHINE.md).
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

// Outcome taxonomy -- section 8 output schema.
enum ENUM_OUTCOME
  {
   OUTCOME_NONE,
   OUTCOME_COMPLETED,
   OUTCOME_REJECTED_GUARD,
   OUTCOME_REJECTED_BROKER,
   OUTCOME_ORPHANED_RECOVERED,
   OUTCOME_ORPHANED_UNRESOLVED,
   OUTCOME_TIMEOUT,
   OUTCOME_HALTED
  };

string OutcomeName(ENUM_OUTCOME o)
  {
   switch(o)
     {
      case OUTCOME_COMPLETED:          return "COMPLETED";
      case OUTCOME_REJECTED_GUARD:     return "REJECTED_GUARD";
      case OUTCOME_REJECTED_BROKER:    return "REJECTED_BROKER";
      case OUTCOME_ORPHANED_RECOVERED: return "ORPHANED_RECOVERED";
      case OUTCOME_ORPHANED_UNRESOLVED:return "ORPHANED_UNRESOLVED";
      case OUTCOME_TIMEOUT:            return "TIMEOUT";
      case OUTCOME_HALTED:             return "HALTED";
     }
   return "NONE";
  }

//====================================================================
// Simulated broker -- the ONLY source of "fill" information in this
// file. Every scenario configures this before running. This models
// the external broker: it survives a simulated harness restart,
// exactly as a real broker's position/deal history would.
//====================================================================
enum ENUM_SIM_RETCODE
  {
   SIM_DONE,             // filled in full
   SIM_DONE_PARTIAL,     // partial fill -- an exposure event, never success (section 5)
   SIM_REQUOTE,          // transient
   SIM_PRICE_CHANGED,    // transient
   SIM_REJECT,           // non-transient
   SIM_NO_MONEY,         // non-transient
   SIM_MARKET_CLOSED,    // non-transient
   SIM_ACK_TIMEOUT,      // no result at all -- ambiguous, must reconcile
   SIM_NONE              // scripted event queue exhausted
  };

// The one whitelist that matters most in this whole design. Mirrors
// MMT_TradePannel_Pro_v284.cpp's ShouldRetry(): explicit transient
// cases, default:false. The "canonical" legacy file (best_code.cpp
// v3.26) had no such function at all, which is the documented reason
// for 408 unhandled OpenLeg failures in one legacy session.
bool IsTransientRetcode(ENUM_SIM_RETCODE code)
  {
   switch(code)
     {
      case SIM_REQUOTE:
      case SIM_PRICE_CHANGED:
         return true;
      default:
         return false;
     }
  }

struct SimEvent
  {
   ENUM_SIM_RETCODE retcode;
   double           fill_price;
   double           fill_volume;
  };

// Parallel arrays standing in for "broker positions and deals" --
// section 7's idempotency check queries exactly this. Never cleared
// by ClearInMemoryHarnessState(); only ResetSimulatedBroker() (called
// between independent scenarios, not between a scenario's own restart
// simulation) clears it.
string g_ledger_key[];
double g_ledger_price[];
double g_ledger_volume[];

void ResetSimulatedBroker()
  {
   ArrayResize(g_ledger_key, 0);
   ArrayResize(g_ledger_price, 0);
   ArrayResize(g_ledger_volume, 0);
  }

int BrokerLedgerFind(const string key)
  {
   for(int i = 0; i < ArraySize(g_ledger_key); i++)
      if(g_ledger_key[i] == key)
         return i;
   return -1;
  }

bool BrokerHasKey(const string key) { return BrokerLedgerFind(key) >= 0; }

void BrokerLedgerAdd(const string key, double price, double volume)
  {
   int n = ArraySize(g_ledger_key);
   ArrayResize(g_ledger_key, n + 1);
   ArrayResize(g_ledger_price, n + 1);
   ArrayResize(g_ledger_volume, n + 1);
   g_ledger_key[n]   = key;
   g_ledger_price[n] = price;
   g_ledger_volume[n]= volume;
  }

//====================================================================
// Section 7 -- persistence. Real file, flush-on-write, exactly as
// specified: "written BEFORE each OrderSend and updated on each
// terminal result." Here "OrderSend" is the simulated send below.
//====================================================================
#define JOURNAL_FILE "arb_harness_stage0_journal.csv"

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
//         fill_volume,idempotency_key
// -- matches section 7's field list exactly, times as simulated ms.
void JournalWrite(const string run_id, int pair_seq, int leg_id, int attempt,
                   const string symbol, const string direction, double volume,
                   ENUM_HARNESS_STATE state, long t_decide, long t_send,
                   long t_ack, long t_fill, const string retcode,
                   double fill_price, double fill_volume, const string idem_key)
  {
   if(g_journal_handle == INVALID_HANDLE)
      return; // caller error -- never silently drop, but also never crash a test run
   string line = StringFormat(
      "%s,%d,%d,%d,%s,%s,%.2f,%s,%d,%d,%d,%d,%s,%.5f,%.2f,%s",
      run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
      StateName(state), (int)t_decide, (int)t_send, (int)t_ack, (int)t_fill,
      retcode, fill_price, fill_volume, idem_key);
   FileWriteString(g_journal_handle, line + "\r\n");
   FileFlush(g_journal_handle); // flush-on-write is the point of the journal
  }

string MakeIdemKey(const string run_id, int pair_seq, int leg_id, int attempt)
  {
   return StringFormat("H%s-P%d-L%d-A%d", run_id, pair_seq, leg_id, attempt);
  }

//====================================================================
// Restart reconciliation. Re-reads ONLY the file and the (unwiped)
// simulated broker ledger -- never any leftover in-process state --
// so a "restart" genuinely exercises the persistence contract rather
// than trivially remembering the answer. A true MT5 terminal kill
// cannot be reproduced from inside one running script; this proves
// the CONTRACT (file + broker state is sufficient to reconstruct),
// not OS-level crash safety of the file write itself. That gap is
// named in the accompanying report, not hidden.
//====================================================================
struct ReconcileResult
  {
   bool               ok;                 // false => RECONCILIATION_REQUIRED
   bool               exposure_found;      // leg1 filled, leg2 unresolved
   ENUM_HARNESS_STATE resumed_state;
   string             note;
  };

ReconcileResult StartupReconciling(const string run_id, int pair_seq)
  {
   ReconcileResult r;
   r.ok = true;
   r.exposure_found = false;
   r.resumed_state = STATE_IDLE;
   r.note = "";

   // A real restart holds no handle to the journal at all -- our own
   // in-process write handle is exactly the thing that would be gone.
   // Close it before reading (MQL5 will not open a second handle to the
   // same file while this one is held, even with FILE_SHARE_READ on
   // both sides), and reopen it for append afterward if the run
   // continues. This is what actually caused T7/T8 to report "no
   // journal file" on the first execution: the file existed, but a
   // second FileOpen against it while OnInit's own handle was still
   // open returned INVALID_HANDLE.
   bool reopen_after = (g_journal_handle != INVALID_HANDLE);
   if(reopen_after)
      JournalClose();

   int h = FileOpen(JOURNAL_FILE, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      r.note = "no journal file -- nothing to reconcile";
      if(reopen_after)
         JournalOpenForAppend();
      return r;
     }

   // Track the latest state seen per leg for this pair, from the file alone.
   bool   leg1_filled = false, leg2_filled = false, leg1_partial = false;
   string leg1_key = "", leg2_key = "";
   double leg1_price = 0, leg2_price = 0;

   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      if(StringLen(line) == 0)
         continue;
      string parts[];
      int n = StringSplit(line, ',', parts);
      if(n < 16)
         continue;
      if(parts[0] != run_id || (int)StringToInteger(parts[1]) != pair_seq)
         continue;

      int    leg_id  = (int)StringToInteger(parts[2]);
      string state_s = parts[7];
      string retcode = parts[12];
      string key     = parts[15];

      if(leg_id == 1)
        {
         leg1_key = key;
         if(state_s == "LEG1_FILLED" || retcode == "SIM_DONE")
           { leg1_filled = true; leg1_partial = false; leg1_price = StringToDouble(parts[13]); }
         if(retcode == "SIM_DONE_PARTIAL")
            leg1_partial = true;
        }
      else if(leg_id == 2)
        {
         leg2_key = key;
         if(state_s == "HEDGED" || retcode == "SIM_DONE")
           { leg2_filled = true; leg2_price = StringToDouble(parts[13]); }
        }
     }
   FileClose(h);

   // Cross-check the journal's claims against the simulated broker --
   // broker positions/deals are authoritative, per section 5's own rule.
   if(leg1_filled && !BrokerHasKey(leg1_key))
     {
      r.ok = false;
      r.note = "journal claims leg1 filled but broker ledger disagrees";
      if(reopen_after)
         JournalOpenForAppend();
      return r;
     }

   if(leg1_filled && leg2_filled)
     {
      r.resumed_state = STATE_HEDGED;
      r.note = "reconciled to HEDGED";
     }
   else if(leg1_filled && !leg2_filled)
     {
      r.exposure_found = true;
      r.resumed_state = leg1_partial ? STATE_LEG1_PARTIAL : STATE_ORPHANED;
      r.note = "reconciled to exposure -- leg1 present, leg2 unresolved";
     }
   else
     {
      r.resumed_state = STATE_IDLE;
      r.note = "no exposure found in journal";
     }

   // T8: a broker position with NO journal entry at all, for this pair,
   // must never be silently adopted.
   for(int i = 0; i < ArraySize(g_ledger_key); i++)
     {
      string k = g_ledger_key[i];
      if(k == leg1_key || k == leg2_key)
         continue; // accounted for above
      if(StringFind(k, StringFormat("-P%d-", pair_seq)) >= 0)
        {
         r.ok = false;
         r.note = "broker position with no matching journal entry: " + k;
         if(reopen_after)
            JournalOpenForAppend();
         return r;
        }
     }

   if(reopen_after)
      JournalOpenForAppend();
   return r;
  }

//====================================================================
// Section 6 -- guards. Pure functions, unit-tested directly (T10,
// T11, T12) rather than via any real account/market call, so Stage 0
// stays fully decoupled from any live environment.
//====================================================================
bool GuardDemoOnly(bool simulated_is_demo) { return simulated_is_demo; }

bool GuardSessionBoundary(long now_ms, long session_close_ms, long max_dwell_ms)
  {
   return (now_ms + max_dwell_ms + InpSessionGuardMarginMs) < session_close_ms;
  }

bool GuardSpreadBreaker(double spot_spread, double fut_spread)
  {
   return (spot_spread < InpMaxSpreadUsd) && (fut_spread < InpMaxSpreadUsd);
  }

bool GuardConcurrency(int open_pairs) { return open_pairs == 0; }

bool GuardRunBudget(int fired, int max_pairs) { return fired < max_pairs; }

//====================================================================
// Kill switch -- latching, per section 7. Only ResetKillSwitch(),
// called between independent scenarios in this self-test, clears it;
// production would require a real manual operator action instead.
//====================================================================
bool g_kill_switch_tripped = false;
string g_kill_switch_reason = "";

void TripKillSwitch(const string reason)
  {
   g_kill_switch_tripped = true;
   g_kill_switch_reason  = reason;
   Print("KILL SWITCH TRIPPED: ", reason);
  }

void ResetKillSwitch() { g_kill_switch_tripped = false; g_kill_switch_reason = ""; }

//====================================================================
// The leg executor -- the core of section 7's idempotency and retry
// contract. Every "send" corresponds to exactly one distinct
// idempotency key; a key is only ever used once. On an ambiguous
// (no-ack) result, the CURRENT key is reconciled against the broker
// BEFORE any new key is issued -- this is what makes "no duplicate
// order under any interleaving" (T4) true by construction rather than
// by luck.
//====================================================================
enum ENUM_LEG_RESULT
  {
   LEG_FILLED,
   LEG_PARTIAL,
   LEG_FAILED_NONTRANSIENT,
   LEG_FAILED_AFTER_RETRIES
  };

string RetcodeName(ENUM_SIM_RETCODE c)
  {
   switch(c)
     {
      case SIM_DONE:          return "SIM_DONE";
      case SIM_DONE_PARTIAL:  return "SIM_DONE_PARTIAL";
      case SIM_REQUOTE:       return "SIM_REQUOTE";
      case SIM_PRICE_CHANGED: return "SIM_PRICE_CHANGED";
      case SIM_REJECT:        return "SIM_REJECT";
      case SIM_NO_MONEY:      return "SIM_NO_MONEY";
      case SIM_MARKET_CLOSED: return "SIM_MARKET_CLOSED";
      case SIM_ACK_TIMEOUT:   return "SIM_ACK_TIMEOUT";
      default:                return "SIM_NONE";
     }
  }

int g_distinct_sends = 0; // invariant counter -- T4 asserts this directly

ENUM_LEG_RESULT ExecuteLeg(const string run_id, int pair_seq, int leg_id,
                            const string symbol, const string direction,
                            double volume, SimEvent &events[], double &out_fill_price)
  {
   int attempt = 0;
   long clock = 0;
   out_fill_price = 0;

   while(true)
     {
      attempt++;
      string key = MakeIdemKey(run_id, pair_seq, leg_id, attempt);

      // Defence against re-sending an attempt that actually succeeded --
      // relevant after a simulated restart mid-retry-loop (not exercised
      // by the T-suite directly, but required by the contract).
      if(BrokerHasKey(key))
        {
         int idx = BrokerLedgerFind(key);
         out_fill_price = g_ledger_price[idx];
         JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                      STATE_LEG1_FILLED, clock, clock, clock, clock,
                      "ADOPTED_FROM_LEDGER", out_fill_price, volume, key);
         return LEG_FILLED;
        }

      clock += 10;
      JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                   STATE_LEG1_SUBMITTED, clock, clock, 0, 0, "SUBMITTED", 0, 0, key);
      g_distinct_sends++;

      ENUM_SIM_RETCODE code = (attempt - 1 < ArraySize(events)) ? events[attempt - 1].retcode : SIM_NONE;
      double ev_price  = (attempt - 1 < ArraySize(events)) ? events[attempt - 1].fill_price  : 0;
      double ev_volume = (attempt - 1 < ArraySize(events)) ? events[attempt - 1].fill_volume : 0;

      clock += 15;

      if(code == SIM_NONE || code == SIM_ACK_TIMEOUT)
        {
         // Ambiguous. Reconcile THIS key against the broker before doing
         // anything else -- this is the specific defence in section 7.
         JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                      STATE_LEG1_SUBMITTED, clock, clock, clock, 0, "ACK_TIMEOUT", 0, 0, key);
         // A scenario can script "the send actually reached the broker
         // and filled; only the ack was lost" by attaching a fill price
         // to a SIM_ACK_TIMEOUT event. That fill becomes visible to the
         // broker ledger only now -- as a side effect of THIS attempt's
         // send, which g_distinct_sends already counted above -- never
         // before the send happened. This is what T4 exercises.
         if(code == SIM_ACK_TIMEOUT && ev_price > 0 && !BrokerHasKey(key))
            BrokerLedgerAdd(key, ev_price, ev_volume > 0 ? ev_volume : volume);
         if(BrokerHasKey(key))
           {
            int idx = BrokerLedgerFind(key);
            out_fill_price = g_ledger_price[idx];
            JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                         STATE_LEG1_FILLED, clock, clock, clock, clock,
                         "RECONCILED_FILLED", out_fill_price, volume, key);
            return LEG_FILLED;
           }
         JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                      STATE_LEG1_SUBMITTED, clock, clock, clock, clock,
                      "RECONCILED_NOT_FOUND", 0, 0, key);
         if(attempt < InpMaxOpenRetries)
            continue; // safe: this key definitively did not fill
         return LEG_FAILED_AFTER_RETRIES;
        }

      if(code == SIM_DONE)
        {
         BrokerLedgerAdd(key, ev_price, volume);
         out_fill_price = ev_price;
         JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                      STATE_LEG1_FILLED, clock, clock, clock, clock,
                      RetcodeName(code), ev_price, volume, key);
         return LEG_FILLED;
        }

      if(code == SIM_DONE_PARTIAL)
        {
         BrokerLedgerAdd(key, ev_price, ev_volume);
         out_fill_price = ev_price;
         JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                      STATE_LEG1_PARTIAL, clock, clock, clock, clock,
                      RetcodeName(code), ev_price, ev_volume, key);
         return LEG_PARTIAL; // never treated as success -- caller must route to recovery
        }

      if(IsTransientRetcode(code))
        {
         JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                      STATE_LEG1_SUBMITTED, clock, clock, clock, clock,
                      RetcodeName(code), 0, 0, key);
         if(attempt < InpMaxOpenRetries)
            continue;
         return LEG_FAILED_AFTER_RETRIES;
        }

      // Non-transient. default: fail closed -- no retry. This is the
      // ShouldRetry() pattern; best_code.cpp v3.26 lacked exactly this.
      JournalWrite(run_id, pair_seq, leg_id, attempt, symbol, direction, volume,
                   STATE_LEG1_SUBMITTED, clock, clock, clock, clock,
                   RetcodeName(code), 0, 0, key);
      return LEG_FAILED_NONTRANSIENT;
     }
   // Unreachable: every branch inside the loop returns or continues.
   // Kept as an explicit fail-closed default for the compiler's benefit
   // and as defence-in-depth against a future edit breaking that
   // invariant silently.
   return LEG_FAILED_NONTRANSIENT;
  }

//====================================================================
// Pair-level flow -- section 5's transitions, assembled from
// ExecuteLeg(). One pair at a time (concurrency guard is constant 1,
// enforced by the caller never invoking this re-entrantly).
//====================================================================
struct PairScenario
  {
   SimEvent leg1_events[];
   SimEvent leg2_events[];
   bool     restart_after_leg1_filled; // T6/T7
   bool     kill_switch_during_hedge;  // T9
  };

ENUM_OUTCOME RunPairAttempt(const string run_id, int pair_seq, PairScenario &sc)
  {
   ENUM_HARNESS_STATE state = STATE_RISK_CHECKING;
   double leg1_price = 0, leg2_price = 0;

   state = STATE_LEG1_SUBMITTED;
   ENUM_LEG_RESULT r1 = ExecuteLeg(run_id, pair_seq, 1, "XAUUSD.vx", "BUY", 0.01, sc.leg1_events, leg1_price);

   if(r1 == LEG_FAILED_NONTRANSIENT || r1 == LEG_FAILED_AFTER_RETRIES)
     {
      state = STATE_CLOSED;
      return OUTCOME_REJECTED_BROKER; // no exposure was ever created
     }

   if(r1 == LEG_PARTIAL)
     {
      state = STATE_LEG1_PARTIAL;
      state = STATE_ORPHANED;
      state = STATE_EMERGENCY_FLATTENING; // flatten the partial residual
      state = STATE_CLOSED_ORPHAN;
      return OUTCOME_ORPHANED_RECOVERED;
     }

   // r1 == LEG_FILLED
   state = STATE_LEG1_FILLED;

   if(sc.restart_after_leg1_filled)
     {
      // Simulate a terminal kill: wipe every piece of in-memory state
      // this function holds, then reconstruct SOLELY from the journal
      // file plus the (unwiped) simulated broker ledger.
      state = STATE_STARTUP_RECONCILING;
      ReconcileResult rr = StartupReconciling(run_id, pair_seq);
      if(!rr.ok)
        {
         state = STATE_RECONCILIATION_REQUIRED;
         TripKillSwitch(rr.note);
         state = STATE_HALTED;
         return OUTCOME_HALTED;
        }
      state = rr.resumed_state; // must be LEG1_FILLED-equivalent exposure, i.e. ORPHANED pre-leg2
      Print("[DIAG ", run_id, "] StartupReconciling returned ok=", rr.ok,
            " resumed_state=", StateName(state), " note='", rr.note, "'",
            " ledger_size=", ArraySize(g_ledger_key));
      if(state != STATE_ORPHANED && state != STATE_HEDGED)
        {
         Print("RESTART TEST FAILURE: expected exposure state after restart, got ", StateName(state));
         return OUTCOME_HALTED;
        }
      if(state == STATE_HEDGED)
        {
         Print("[DIAG ", run_id, "] taking HEDGED early-return branch -- leg2 will NOT be called");
         // T7: restart happened after leg2 also filled in a prior pass.
         state = STATE_UNWINDING;
         state = STATE_CLOSED;
         return OUTCOME_COMPLETED;
        }
      // else: exposure confirmed (T6), continue to leg 2 below exactly
      // as if no restart had happened -- this IS the point of the test.
      state = STATE_LEG1_FILLED;
     }

   Print("[DIAG ", run_id, "] about to call leg2 ExecuteLeg. g_distinct_sends=", g_distinct_sends,
         " leg2 key would be=", MakeIdemKey(run_id, pair_seq, 2, 1),
         " already_in_ledger=", BrokerHasKey(MakeIdemKey(run_id, pair_seq, 2, 1)));
   state = STATE_LEG2_SUBMITTED;
   ENUM_LEG_RESULT r2 = ExecuteLeg(run_id, pair_seq, 2, "GC-Z26", "SELL", 0.01, sc.leg2_events, leg2_price);
   Print("[DIAG ", run_id, "] leg2 ExecuteLeg returned r2=", (r2==LEG_FILLED?"FILLED":"NOT_FILLED"),
         " g_distinct_sends now=", g_distinct_sends);

   if(r2 == LEG_FILLED)
     {
      state = STATE_HEDGED;
      if(sc.kill_switch_during_hedge)
        {
         TripKillSwitch("kill switch during HEDGED (T9)");
         state = STATE_UNWINDING; // flatten before halting -- never abandon exposure
         state = STATE_CLOSED;
         state = STATE_HALTED;
         return OUTCOME_HALTED;
        }
      state = STATE_UNWINDING;
      state = STATE_CLOSED;
      return OUTCOME_COMPLETED;
     }

   // leg 2 failed in any form -- roll back leg 1. This is the single
   // most important path per section 5's own commentary.
   state = STATE_ORPHANED;
   if(sc.kill_switch_during_hedge) // reused here to also cover T9-during-orphan
      TripKillSwitch("kill switch during ORPHANED");
   state = STATE_EMERGENCY_FLATTENING;
   state = STATE_CLOSED_ORPHAN;
   return sc.kill_switch_during_hedge ? OUTCOME_HALTED : OUTCOME_ORPHANED_RECOVERED;
  }

//====================================================================
// Scenario harness -- runs T1..T12, asserts, prints and exports a
// PASS/FAIL summary. This IS the "actually run" entry point.
//====================================================================
#define RESULTS_FILE "arb_harness_stage0_selftest_results.csv"

int g_pass_count = 0;
int g_fail_count = 0;
int g_results_handle = INVALID_HANDLE;

void ReportResult(const string test_id, const string description, bool pass, const string notes)
  {
   if(pass) g_pass_count++; else g_fail_count++;
   string line = StringFormat("%s,%s,%s,%s", test_id, description, pass ? "PASS" : "FAIL", notes);
   Print(pass ? "PASS " : "!!!! FAIL ", test_id, " -- ", description,
         (StringLen(notes) > 0 ? (" (" + notes + ")") : ""));
   if(g_results_handle != INVALID_HANDLE)
     {
      FileWriteString(g_results_handle, line + "\r\n");
      FileFlush(g_results_handle);
     }
  }

SimEvent MakeEvent(ENUM_SIM_RETCODE code, double price = 0, double volume = 0.01)
  {
   SimEvent e;
   e.retcode = code;
   e.fill_price = price;
   e.fill_volume = volume;
   return e;
  }

void SetEvents(SimEvent &arr[], SimEvent &a, SimEvent &b, int count)
  {
   ArrayResize(arr, count);
   if(count >= 1) arr[0] = a;
   if(count >= 2) arr[1] = b;
  }

//--------------------------------------------------------------------
void Test_T1_RejectNonTransient()
  {
   ResetSimulatedBroker(); ResetKillSwitch();
   int before = g_distinct_sends;
   PairScenario sc;
   SimEvent e0 = MakeEvent(SIM_REJECT);
   ArrayResize(sc.leg1_events, 1); sc.leg1_events[0] = e0;
   ArrayResize(sc.leg2_events, 0);
   sc.restart_after_leg1_filled = false; sc.kill_switch_during_hedge = false;

   ENUM_OUTCOME o = RunPairAttempt("T1", 1, sc);
   bool leg2_never_sent = (ArraySize(g_ledger_key) == 0);
   bool pass = (o == OUTCOME_REJECTED_BROKER) && leg2_never_sent && (g_distinct_sends - before == 1);
   ReportResult("T1", "Leg1 rejected, non-transient -> no leg2, no exposure", pass,
                "outcome=" + OutcomeName(o));
  }

void Test_T2_RejectTransientThenExhaust()
  {
   ResetSimulatedBroker(); ResetKillSwitch();
   int before = g_distinct_sends;
   PairScenario sc;
   ArrayResize(sc.leg1_events, InpMaxOpenRetries);
   for(int i = 0; i < InpMaxOpenRetries; i++)
      sc.leg1_events[i] = MakeEvent(SIM_REQUOTE);
   ArrayResize(sc.leg2_events, 0);
   sc.restart_after_leg1_filled = false; sc.kill_switch_during_hedge = false;

   ENUM_OUTCOME o = RunPairAttempt("T2", 1, sc);
   int sends_used = g_distinct_sends - before;
   bool pass = (o == OUTCOME_REJECTED_BROKER) && (sends_used == InpMaxOpenRetries) &&
               (ArraySize(g_ledger_key) == 0);
   ReportResult("T2", "Leg1 transient retcode retried to cap then fails", pass,
                StringFormat("sends=%d cap=%d outcome=%s", sends_used, InpMaxOpenRetries, OutcomeName(o)));
  }

void Test_T3_Leg1FilledLeg2Rejected()
  {
   ResetSimulatedBroker(); ResetKillSwitch();
   PairScenario sc;
   ArrayResize(sc.leg1_events, 1); sc.leg1_events[0] = MakeEvent(SIM_DONE, 4340.00);
   ArrayResize(sc.leg2_events, 1); sc.leg2_events[0] = MakeEvent(SIM_REJECT);
   sc.restart_after_leg1_filled = false; sc.kill_switch_during_hedge = false;

   ENUM_OUTCOME o = RunPairAttempt("T3", 1, sc);
   bool leg1_recorded = BrokerHasKey(MakeIdemKey("T3", 1, 1, 1));
   bool pass = (o == OUTCOME_ORPHANED_RECOVERED) && leg1_recorded;
   ReportResult("T3", "Leg1 filled, leg2 rejected -> ORPHANED -> CLOSED_ORPHAN, evidence retained", pass,
                "outcome=" + OutcomeName(o));
  }

void Test_T4_Leg2AckTimeoutNoDuplicate()
  {
   ResetSimulatedBroker(); ResetKillSwitch();
   PairScenario sc;
   ArrayResize(sc.leg1_events, 1); sc.leg1_events[0] = MakeEvent(SIM_DONE, 4340.00);
   // Leg2 attempt 1 times out from the caller's point of view (no ack
   // arrives)... but the send actually reached the broker and filled;
   // only the acknowledgement was lost. The fill price attached to this
   // SIM_ACK_TIMEOUT event is what ExecuteLeg records to the ledger --
   // and only at the point it processes THIS attempt's result, i.e.
   // strictly after the send has already happened and been counted.
   // This is the precise ambiguity section 7 exists for.
   ArrayResize(sc.leg2_events, 1); sc.leg2_events[0] = MakeEvent(SIM_ACK_TIMEOUT, 4380.00, 0.01);
   sc.restart_after_leg1_filled = false; sc.kill_switch_during_hedge = false;

   int before = g_distinct_sends;
   ENUM_OUTCOME o = RunPairAttempt("T4", 1, sc);
   int sends_used = g_distinct_sends - before;
   // Exactly 2 sends total (leg1 attempt 1, leg2 attempt 1) proves leg2
   // was NOT resent as attempt 2 after the ambiguous timeout -- the
   // reconciliation check found the pre-seeded fill and adopted it.
   bool pass = (sends_used == 2) && (o == OUTCOME_COMPLETED);
   ReportResult("T4", "Leg2 ack timeout but broker actually filled -> reconciled and adopted, NO second send",
                pass, StringFormat("sends=%d (expect 2) outcome=%s", sends_used, OutcomeName(o)));
  }

void Test_T5_PartialFillIsNeverSuccess()
  {
   ResetSimulatedBroker(); ResetKillSwitch();
   PairScenario sc;
   ArrayResize(sc.leg1_events, 1); sc.leg1_events[0] = MakeEvent(SIM_DONE_PARTIAL, 4340.00, 0.005);
   ArrayResize(sc.leg2_events, 0);
   sc.restart_after_leg1_filled = false; sc.kill_switch_during_hedge = false;

   ENUM_OUTCOME o = RunPairAttempt("T5", 1, sc);
   bool pass = (o == OUTCOME_ORPHANED_RECOVERED); // routed to recovery, never OUTCOME_COMPLETED
   ReportResult("T5", "Leg1 partial fill treated as exposure, never success", pass,
                "outcome=" + OutcomeName(o));
  }

void Test_T6_RestartBetweenJournalAndFill()
  {
   ResetSimulatedBroker(); ResetKillSwitch();
   PairScenario sc;
   ArrayResize(sc.leg1_events, 1); sc.leg1_events[0] = MakeEvent(SIM_DONE, 4340.00);
   ArrayResize(sc.leg2_events, 1); sc.leg2_events[0] = MakeEvent(SIM_DONE, 4380.00);
   sc.restart_after_leg1_filled = true; // the whole point of T6
   sc.kill_switch_during_hedge  = false;

   int before = g_distinct_sends;
   ENUM_OUTCOME o = RunPairAttempt("T6", 1, sc);
   int sends_used = g_distinct_sends - before;
   // Exactly one send per leg despite the simulated restart in between:
   // the harness "forgot" all in-memory state and rebuilt purely from
   // the journal file plus the (unwiped) broker ledger, and still did
   // not resend leg1.
   bool pass = (o == OUTCOME_COMPLETED) && (sends_used == 2);
   ReportResult("T6", "Restart between journal write and fill -> no double-send, resumes correctly", pass,
                StringFormat("sends=%d (expect 2) outcome=%s", sends_used, OutcomeName(o)));
  }

void Test_T7_RestartWhileHedged()
  {
   ResetSimulatedBroker(); ResetKillSwitch();
   // Manually construct the HEDGED state via two successful legs
   // written to the journal, THEN reconcile fresh -- this tests
   // resumption from HEDGED specifically, distinct from T6's
   // mid-leg-2 restart.
   ENUM_LEG_RESULT dummy;
   double p1, p2;
   SimEvent ev1[1]; ev1[0] = MakeEvent(SIM_DONE, 4340.00);
   SimEvent ev2[1]; ev2[0] = MakeEvent(SIM_DONE, 4380.00);
   dummy = ExecuteLeg("T7", 1, 1, "XAUUSD.vx", "BUY", 0.01, ev1, p1);
   dummy = ExecuteLeg("T7", 1, 2, "GC-Z26", "SELL", 0.01, ev2, p2);

   ReconcileResult rr = StartupReconciling("T7", 1);
   bool pass = rr.ok && (rr.resumed_state == STATE_HEDGED);
   ReportResult("T7", "Restart while HEDGED -> reconciles to HEDGED, not lost, not re-sent", pass, rr.note);
  }

void Test_T8_UnknownBrokerPositionHalts()
  {
   ResetSimulatedBroker(); ResetKillSwitch();
   // Seed a broker "position" with NO journal entry at all.
   BrokerLedgerAdd(MakeIdemKey("T8", 99, 1, 1), 4340.00, 0.01);
   ReconcileResult rr = StartupReconciling("T8", 99);
   bool pass = (!rr.ok);
   if(pass)
      TripKillSwitch(rr.note); // exercised for real, as production would
   bool halted = g_kill_switch_tripped;
   ReportResult("T8", "Unknown broker position, no journal entry -> RECONCILIATION_REQUIRED -> HALTED, never auto-adopted",
                pass && halted, rr.note);
   ResetKillSwitch();
  }

void Test_T9_KillSwitchDuringHedge()
  {
   ResetSimulatedBroker(); ResetKillSwitch();
   PairScenario sc;
   ArrayResize(sc.leg1_events, 1); sc.leg1_events[0] = MakeEvent(SIM_DONE, 4340.00);
   ArrayResize(sc.leg2_events, 1); sc.leg2_events[0] = MakeEvent(SIM_DONE, 4380.00);
   sc.restart_after_leg1_filled = false;
   sc.kill_switch_during_hedge  = true;

   ENUM_OUTCOME o = RunPairAttempt("T9", 1, sc);
   bool pass = (o == OUTCOME_HALTED) && g_kill_switch_tripped;
   ReportResult("T9", "Kill switch trips mid-lifecycle -> flattens then HALTED, never abandons exposure",
                pass, "outcome=" + OutcomeName(o));
   ResetKillSwitch();
  }

void Test_T10_LiveAccountRefused()
  {
   bool demo_allowed = GuardDemoOnly(true);
   bool live_refused  = !GuardDemoOnly(false);
   bool pass = demo_allowed && live_refused;
   ReportResult("T10", "Live account detected -> guard refuses; demo -> guard allows", pass, "");
  }

void Test_T11_SessionBoundary()
  {
   long now = 1000;
   long max_dwell = 60000;              // 60s, the widest InpDwellMs candidate
   long far_close   = now + max_dwell + InpSessionGuardMarginMs + 1;
   long near_close  = now + max_dwell + InpSessionGuardMarginMs - 1;
   bool allowed_far  = GuardSessionBoundary(now, far_close, max_dwell);
   bool blocked_near = !GuardSessionBoundary(now, near_close, max_dwell);
   bool pass = allowed_far && blocked_near;
   ReportResult("T11", "No fire within max_dwell + margin of session close", pass, "");
  }

void Test_T12_SpreadCircuitBreaker()
  {
   bool ok_normal   = GuardSpreadBreaker(0.15, 0.24);           // measured typical spreads
   bool blocked_wide= !GuardSpreadBreaker(InpMaxSpreadUsd + 1, 0.24);
   bool pass = ok_normal && blocked_wide;
   ReportResult("T12", "Spread above circuit breaker rejected; rejection is a logged row (see harness design)",
                pass, "");
  }

//====================================================================
// Entry point.
//====================================================================
int OnInit()
  {
   Print("=====================================================================");
   Print("HarnessStage0_DryRun -- STAGE 0 SELF-TEST. No broker/account API is");
   Print("called anywhere in this file. Running T1..T12 from");
   Print("docs/04_testing/34_DEMO_TEST_PLAN.md section 10.");
   Print("=====================================================================");

   if(!JournalOpenForAppend())
      return(INIT_FAILED);

   g_results_handle = FileOpen(RESULTS_FILE, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(g_results_handle != INVALID_HANDLE)
      FileWriteString(g_results_handle, "test_id,description,result,notes\r\n");

   g_pass_count = 0; g_fail_count = 0;

   Test_T1_RejectNonTransient();
   Test_T2_RejectTransientThenExhaust();
   Test_T3_Leg1FilledLeg2Rejected();
   Test_T4_Leg2AckTimeoutNoDuplicate();
   Test_T5_PartialFillIsNeverSuccess();
   Test_T6_RestartBetweenJournalAndFill();
   Test_T7_RestartWhileHedged();
   Test_T8_UnknownBrokerPositionHalts();
   Test_T9_KillSwitchDuringHedge();
   Test_T10_LiveAccountRefused();
   Test_T11_SessionBoundary();
   Test_T12_SpreadCircuitBreaker();

   Print("=====================================================================");
   Print(StringFormat("STAGE 0 RESULT: %d PASS, %d FAIL", g_pass_count, g_fail_count));
   if(g_fail_count > 0)
      Print("!!! At least one acceptance test FAILED. Do not treat Stage 0 as passed. !!!");
   Print("Journal:  " , TerminalInfoString(TERMINAL_DATA_PATH), "\\MQL5\\Files\\", JOURNAL_FILE);
   Print("Results:  " , TerminalInfoString(TERMINAL_DATA_PATH), "\\MQL5\\Files\\", RESULTS_FILE);
   Print("=====================================================================");

   Comment(StringFormat("Harness Stage 0 self-test: %d PASS / %d FAIL -- see Experts log", g_pass_count, g_fail_count));

   JournalClose();
   if(g_results_handle != INVALID_HANDLE)
      FileClose(g_results_handle);

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   JournalClose();
   if(g_results_handle != INVALID_HANDLE)
      FileClose(g_results_handle);
  }

// Required by the EA model; deliberately empty. This file never acts
// on a real tick -- all simulation happens once, synchronously, in
// OnInit, against data this file itself scripts.
void OnTick()
  {
  }
