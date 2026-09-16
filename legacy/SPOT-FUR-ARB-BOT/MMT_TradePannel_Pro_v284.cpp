//+------------------------------------------------------------------+
//| MMT_TradePannel_Pro.mq5                                          |
//| v2.84 Hybrid-Async                                               |
//| Async execution engine grafted onto v2.83 synchronous safety     |
//|                                                                  |
//| v2.84 Additions over v2.83:                                      |
//|  - Non-blocking async leg execution (auto-rules path)            |
//|  - Parallel Dispatch: all triggered pairs fire simultaneously     |
//|  - PSTATUS_TRANSIT: new state while async orders are in-flight   |
//|  - Watchdog timer: auto-rollback on deadline expiry               |
//|  - OnTradeTransaction: real-time fill confirmation               |
//|  - Retry matrix: per-error-code retry strategy                   |
//|  - Crash recovery: deal history reconciliation on OnInit         |
//|  - Manual buttons remain synchronous for operational safety      |
//+------------------------------------------------------------------+
#property strict
#property version "2.84"

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================//
// INPUTS                                                           //
//==================================================================//

input long   InpMagicNo        = 123;
input string InpSymbol1        = "GC-J26";
input string InpSymbol2        = "XAUUSD";

enum ENUM_OPEN_DIR { DIR_BUY_ONLY=1, DIR_SELL_ONLY=2 };
input ENUM_OPEN_DIR InpOpenDirection = DIR_SELL_ONLY;

enum ENUM_FIRST_SYMBOL { FIRST_SYMBOL1=0, FIRST_SYMBOL2=1 };
input ENUM_FIRST_SYMBOL InpSymbolToTradeFirstWhenOpening = FIRST_SYMBOL1;
input ENUM_FIRST_SYMBOL InpSymbolToCloseFirst            = FIRST_SYMBOL1;

input int    InpMaxPairs       = 20;
input int    InpRefreshMs      = 200;
input int    InpSlippagePips   = 1;
input bool   InpEnableLogs     = true;

// Auto-close constraints
input int    InpMinHoldMinutes = 0;      // 0 = disabled
input bool   InpTargetCloseRequireProfit = true;
input double InpMinProfitToClose         = 0.0;

// Time-at-level confirmations
input int    InpOagConfirmMs   = 800;    // scheduled entry confirm time
input int    InpCagConfirmMs   = 800;    // auto-close confirm time

// v2.84.1 Execution quality
// Trigger the CAG close this many points BEFORE your target to absorb expected fill
// slippage from sequential execution.  Set to the typical drift you observe in logs.
// Example: CAG=25.70, Buffer=0.35 → fires when gap ≤ 26.05 so fills land near 25.70.
// For BUY_ONLY the offset is subtracted (fires when gap ≥ target-buffer).
// Set to 0.0 to disable (matches v2.83 behaviour exactly).
input double InpCagSlippageBuffer = 0.0; // points; tune from log drift

// v2.84 Async settings
input int    InpAsyncOpenDeadlineMs  = 2500; // ms before watchdog rolls back stuck open
input int    InpAsyncCloseDeadlineMs = 4000; // ms before watchdog retries stuck close
input int    InpMaxOpenRetries       = 3;    // max retries for open legs
input int    InpMaxCloseRetries      = 5;    // max retries for close legs

//==================================================================//
// UI CONFIG                                                        //
//==================================================================//

input int    UI_X = 10;
input int    UI_Y = 10;
input int    UI_W = 1400;
input int    UI_H_Min = 220;
input bool   UI_AutoHeight = true;
input int    UI_FontBase  = 10;
input string UI_MonoFont  = "Consolas";

//==================================================================//
// UI COLORS                                                        //
//==================================================================//

input color  InpColPanelBG   = clrAliceBlue;
input color  InpColTitleText = clrBlack;
input color  InpColInfoText  = clrDimGray;
input color  InpColGapText   = clrDodgerBlue;
input color  InpColOpenText  = clrDarkGreen;

input color  InpColStatusProfit  = clrBlueViolet;
input color  InpColStatusLoss    = clrRed;
input color  InpColStatusIdle    = clrSilver;
input color  InpColStatusSched   = clrOrange;
input color  InpColStatusTransit = clrGold;    // v2.84: in-flight color

// Buttons
input color  InpColBtnOpenBG     = clrPink;
input color  InpColBtnCloseAllBG = (color)0xB71C1C;
input color  InpColBtnUpdateBG   = (color)0x1B5E20;
input color  InpColBtnText       = clrWhite;
input color  InpColBtnBorder     = clrBlack;

// Edit
input color  InpColEditText      = clrBlack;
input color  InpColEditBG        = clrWhite;
input color  InpColEditBorder    = clrGray;

//==================================================================//
// GLOBALS                                                          //
//==================================================================//

string g_prefix   = "PGUI_";
int    g_maxPairs = 20;

int    g_visiblePairs[64];
int    g_visibleN = 0;
string g_lastSig  = "";

// Pair status values
#define PSTATUS_IDLE     0
#define PSTATUS_LIVE     1
#define PSTATUS_SCHED    2
#define PSTATUS_BROKEN   3
#define PSTATUS_TRANSIT  4   // v2.84: async orders in-flight

struct PairRuntime
{
   bool   hasS1;
   bool   hasS2;
   ulong  tkS1;
   ulong  tkS2;
   double volS1;
   double volS2;
   double pl;
   double openS1;
   double openS2;
};

PairRuntime g_rt[64];

//==================================================================//
// v2.84: ASYNC ENGINE STRUCTS & GLOBALS                           //
//==================================================================//

#define MAX_PENDING 64

struct PendingOrder
{
   bool            active;
   ulong           reqId;        // async request_id from OrderSendAsync
   int             pairIdx;
   string          leg;          // "S1" or "S2"
   bool            isOpen;       // true=opening leg, false=closing leg
   ulong           closeTicket;  // ticket being closed (isOpen=false only)
   ulong           sentMs;
   ulong           deadlineMs;
   int             retries;
   ENUM_ORDER_TYPE orderType;
   string          symbol;
   double          lot;
   double          sentPrice;
};

PendingOrder g_pending[MAX_PENDING];
int          g_inFlight = 0;    // count of currently active pending slots

//==================================================================//
// LOGGING                                                          //
//==================================================================//

string F2(double v){ return DoubleToString(v,2); }

void LogMsg(const string s)
{
   if(InpEnableLogs) Print("[PGUI] ", s);
}

void LogPair(const int pairIdx, const string action, const string detail="")
{
   if(!InpEnableLogs) return;
   string msg = StringFormat("[PGUI] Pair %d | %s", pairIdx, action);
   if(detail!="") msg += " | " + detail;
   Print(msg);
}

void LogTradeResult(const string scope, const string sym, const bool ok,
                    const long retcode, const string extra="")
{
   if(!InpEnableLogs) return;
   string msg = StringFormat("[PGUI] %s | sym=%s ok=%d ret=%d (%s)",
                             scope, sym, (int)ok, (int)retcode,
                             trade.ResultRetcodeDescription());
   if(extra!="") msg += " | " + extra;
   Print(msg);
}

//==================================================================//
// TIME                                                             //
//==================================================================//

ulong NowMs()
{
#ifdef __MQL5__
   return (ulong)GetTickCount64();
#else
   return (ulong)GetTickCount();
#endif
}

//==================================================================//
// BASIC HELPERS                                                    //
//==================================================================//

int PipToPoints(string sym, int pips)
{
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   return pips * ((d==5||d==3) ? 10 : 1);
}

bool GetTickSafe(string sym, MqlTick &t)
{
   if(!SymbolSelect(sym, true)) return false;
   if(!SymbolInfoTick(sym, t))  return false;
   return (t.bid>0 && t.ask>0);
}

// SELL_ONLY: gap = Bid(S1) - Ask(S2)
// BUY_ONLY : gap = Ask(S1) - Bid(S2)
bool ComputeGap(double &gap, double &p1, double &p2)
{
   MqlTick t1, t2;
   if(!GetTickSafe(InpSymbol1, t1)) return false;
   if(!GetTickSafe(InpSymbol2, t2)) return false;

   if(InpOpenDirection==DIR_SELL_ONLY)
   {
      p1 = t1.bid;
      p2 = t2.ask;
   }
   else
   {
      p1 = t1.ask;
      p2 = t2.bid;
   }

   gap = p1 - p2;
   return true;
}

// CAG is absolute target gap. Zero means disabled.
bool TargetHit_Abs(const double current_gap, const double target_gap)
{
   if(target_gap==0.0) return false;
   if(InpOpenDirection==DIR_SELL_ONLY) return (current_gap <= target_gap);
   return (current_gap >= target_gap);
}

// Returns the effective trigger threshold after applying InpCagSlippageBuffer.
// For SELL_ONLY: fire earlier (higher gap) → add buffer.
// For BUY_ONLY:  fire earlier (lower gap)  → subtract buffer.
double AdjustedCagTarget(const double tg)
{
   if(tg==0.0 || InpCagSlippageBuffer==0.0) return tg;
   return tg + (InpOpenDirection==DIR_SELL_ONLY ? InpCagSlippageBuffer : -InpCagSlippageBuffer);
}

//==================================================================//
// EDIT INPUT SANITIZATION                                          //
//==================================================================//

string SanitizeNumberString(const string raw)
{
   string s = raw;

   while(StringLen(s)>0)
   {
      int c = StringGetCharacter(s,0);
      if(c==' '||c=='\t') s = StringSubstr(s,1);
      else break;
   }

   while(StringLen(s)>0)
   {
      int last = StringLen(s)-1;
      int c    = StringGetCharacter(s, last);
      if(c==' '||c=='\t') s = StringSubstr(s,0,last);
      else break;
   }

   bool hasDot = false;
   string out  = "";
   for(int i=0; i<StringLen(s); i++)
   {
      int c = StringGetCharacter(s,i);
      if(c==',') continue;

      if(c=='-' && StringLen(out)==0)
      {
         out += "-";
         continue;
      }

      if(c>='0' && c<='9')
      {
         out += (string)CharToString((uchar)c);
         continue;
      }

      if(c=='.' && !hasDot)
      {
         hasDot = true;
         if(out=="" || out=="-") out += "0";
         out += ".";
         continue;
      }
   }

   if(out=="" || out=="-") return "0";
   if(out=="-0." || out=="0.") return "0";
   return out;
}

double ReadEditNumber(const string objName, string &sanitized_out)
{
   sanitized_out = "0";
   if(ObjectFind(0, objName)<0) return 0.0;

   string raw   = ObjectGetString(0, objName, OBJPROP_TEXT);
   sanitized_out = SanitizeNumberString(raw);
   return StringToDouble(sanitized_out);
}

void WriteEditSanitized(const string objName, const string sanitized)
{
   if(ObjectFind(0, objName)>=0)
      ObjectSetString(0, objName, OBJPROP_TEXT, sanitized);
}

//==================================================================//
// GLOBAL VARIABLE STORAGE                                          //
//==================================================================//

string GvKeyBase()
{
   return StringFormat("PGUI|%I64d|%s|%s|DIR=%d|",
                       InpMagicNo, InpSymbol1, InpSymbol2, (int)InpOpenDirection);
}

string GvKey(int pairIdx, string field)
{
   return GvKeyBase() + StringFormat("P=%d|%s", pairIdx, field);
}

double GvGetD(int pairIdx, string field, double def=0.0)
{
   string k = GvKey(pairIdx, field);
   if(!GlobalVariableCheck(k)) return def;
   return GlobalVariableGet(k);
}

void GvSetD(int pairIdx, string field, double v)
{
   GlobalVariableSet(GvKey(pairIdx, field), v);
}

//==================================================================//
// PAIR STATE HELPERS                                               //
//==================================================================//

void SetOpeningLock(int p, bool on)
{
   if(on)
   {
      GvSetD(p,"OPENING",1.0);
      GvSetD(p,"OPENING_SINCE_MS",(double)NowMs());
   }
   else
   {
      GvSetD(p,"OPENING",0.0);
      GvSetD(p,"OPENING_SINCE_MS",0.0);
   }
}

bool IsOpeningLocked(int p, int maxLockMs=5000)
{
   if(GvGetD(p,"OPENING",0.0) < 0.5) return false;

   ulong since = (ulong)GvGetD(p,"OPENING_SINCE_MS",0.0);
   ulong now   = NowMs();
   ulong age   = (now>=since ? (now-since) : 0);

   if((int)age > maxLockMs)
   {
      SetOpeningLock(p,false);
      return false;
   }
   return true;
}

void SetClosingLock(int p, bool on)
{
   if(on)
   {
      GvSetD(p,"CLOSING",1.0);
      GvSetD(p,"CLOSING_SINCE_MS",(double)NowMs());
   }
   else
   {
      GvSetD(p,"CLOSING",0.0);
      GvSetD(p,"CLOSING_SINCE_MS",0.0);
   }
}

bool IsClosingLocked(int p, int maxLockMs=7000)
{
   if(GvGetD(p,"CLOSING",0.0) < 0.5) return false;

   ulong since = (ulong)GvGetD(p,"CLOSING_SINCE_MS",0.0);
   ulong now   = NowMs();
   ulong age   = (now>=since ? (now-since) : 0);

   if((int)age > maxLockMs)
   {
      SetClosingLock(p,false);
      return false;
   }
   return true;
}

void ResetOagHit(const int p)
{
   GvSetD(p,"OAG_HIT_ACTIVE",0.0);
   GvSetD(p,"OAG_HIT_SINCE_MS",0.0);
}

void ClearScheduleState(const int p, const bool clearTarget)
{
   GvSetD(p,"STATUS",0.0);
   GvSetD(p,"OAG",0.0);
   GvSetD(p,"SCHED_LOT",0.0);

   if(clearTarget)
      GvSetD(p,"TARGET",0.0);

   ResetOagHit(p);
}

void ResetCagHit(const int p)
{
   GvSetD(p,"CAG_HIT_ACTIVE",0.0);
   GvSetD(p,"CAG_HIT_SINCE_MS",0.0);
}

void ResetHitTimers(const int p)
{
   ResetOagHit(p);
   ResetCagHit(p);
}

void CancelSchedule(int p)
{
   ClearScheduleState(p, true);
   ResetCagHit(p);
   SetOpeningLock(p,false);
   LogPair(p,"SCHEDULE_CANCELLED");
}

void ClearLiveMeta(const int p, const bool clearTarget)
{
   GvSetD(p,"OPENGAP",0.0);
   GvSetD(p,"OPEN_TIME_SEC",0.0);
   GvSetD(p,"CLOSE_TRIGGER_GAP",0.0);

   if(clearTarget)
      GvSetD(p,"TARGET",0.0);

   ResetCagHit(p);
   SetOpeningLock(p,false);
   SetClosingLock(p,false);
}

void ClearPairState(const int p)
{
   ClearScheduleState(p, true);
   ClearLiveMeta(p, true);
   // v2.84: clear transit state too
   ClearTransitState(p);
}

// v2.84: Transit state helpers (GV-backed)
void SetTransitState(const int p, const bool isOpen)
{
   GvSetD(p,"TRANSIT",1.0);
   GvSetD(p,"TRANSIT_MS",(double)NowMs());
   GvSetD(p,"TRANSIT_OP", isOpen ? 1.0 : 0.0);
   GvSetD(p,"TRANSIT_S1",0.0);
   GvSetD(p,"TRANSIT_S2",0.0);
}

void ClearTransitState(const int p)
{
   GvSetD(p,"TRANSIT",0.0);
   GvSetD(p,"TRANSIT_MS",0.0);
   GvSetD(p,"TRANSIT_OP",0.0);
   GvSetD(p,"TRANSIT_S1",0.0);
   GvSetD(p,"TRANSIT_S2",0.0);
}

bool IsInTransit(const int p)
{
   return (GvGetD(p,"TRANSIT",0.0) >= 0.5);
}

void ReconcilePairState(const int p)
{
   bool s1 = g_rt[p].hasS1;
   bool s2 = g_rt[p].hasS2;
   double st = GvGetD(p,"STATUS",0.0);

   // While in transit, don't reconcile (let WatchdogTick or OnTradeTransaction handle it)
   if(IsInTransit(p)) return;

   // Completely flat
   if(!s1 && !s2)
   {
      if(st==2.0)
      {
         double oag = GvGetD(p,"OAG",0.0);
         double lot = GvGetD(p,"SCHED_LOT",0.0);

         if(oag!=0.0 && lot>0.0)
         {
            GvSetD(p,"OPENGAP",0.0);
            GvSetD(p,"OPEN_TIME_SEC",0.0);
            SetOpeningLock(p,false);
            SetClosingLock(p,false);
            ResetCagHit(p);
            return;
         }

         CancelSchedule(p);
         return;
      }

      ClearPairState(p);
      return;
   }

   GvSetD(p,"STATUS",0.0);
   GvSetD(p,"OAG",0.0);
   GvSetD(p,"SCHED_LOT",0.0);
   ResetOagHit(p);
   SetOpeningLock(p,false);

   if(s1 && s2)
   {
      if(GvGetD(p,"OPEN_TIME_SEC",0.0) <= 0.0)
         GvSetD(p,"OPEN_TIME_SEC",(double)TimeCurrent());
   }
   else
   {
      ResetCagHit(p);
   }
}

void ReconcileAllPairStates()
{
   for(int p=1; p<=g_maxPairs; p++)
      ReconcilePairState(p);
}

//==================================================================//
// POSITION / COMMENT TRACKING                                      //
//==================================================================//

string MakeComment(int pairIdx, string leg)
{
   return StringFormat("PAIR|IDX=%d|LEG=%s", pairIdx, leg);
}

bool ParseComment(string c, int &pairIdx, string &leg)
{
   if(StringFind(c,"PAIR|IDX=")!=0) return false;

   int a = StringFind(c,"IDX=");
   int b = StringFind(c,"|LEG=");
   if(a<0 || b<0) return false;

   pairIdx = (int)StringToInteger(StringSubstr(c, a+4, b-(a+4)));
   leg     = StringSubstr(c, b+5);
   return (pairIdx>=1);
}

ulong FindTicket(int pairIdx, string leg)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNo) continue;

      int p; string lg;
      if(ParseComment(PositionGetString(POSITION_COMMENT),p,lg))
         if(p==pairIdx && lg==leg) return tk;
   }
   return 0;
}

bool FailOpenStart(const int pairIdx)
{
   GvSetD(pairIdx,"OPEN_TIME_SEC",0.0);
   SetOpeningLock(pairIdx,false);
   ClearTransitState(pairIdx);
   return false;
}

bool PairHasAnyLeg(int pairIdx)
{
   return (FindTicket(pairIdx,"S1")!=0 || FindTicket(pairIdx,"S2")!=0);
}

int GetPairStatus(int p)
{
   // v2.84: check transit state first — prevents misclassifying partial fills as BROKEN
   if(IsInTransit(p)) return PSTATUS_TRANSIT;

   bool s1 = g_rt[p].hasS1;
   bool s2 = g_rt[p].hasS2;

   if(s1 && s2) return PSTATUS_LIVE;
   if(s1 || s2) return PSTATUS_BROKEN;

   if(GvGetD(p,"STATUS",0.0)==2.0) return PSTATUS_SCHED;
   return PSTATUS_IDLE;
}

int NextFreePairSlot()
{
   for(int p=1; p<=g_maxPairs; p++)
   {
      if(!g_rt[p].hasS1 && !g_rt[p].hasS2 &&
         GvGetD(p,"STATUS",0.0)!=2.0     &&
         !IsInTransit(p))
         return p;
   }
   return -1;
}

void ResetSessionStateOnInit()
{
   for(int p=1; p<=g_maxPairs; p++)
   {
      ResetHitTimers(p);
      SetOpeningLock(p,false);
      SetClosingLock(p,false);
      ClearTransitState(p);  // v2.84: also clear any stale transit from previous session
   }
}

//==================================================================//
// P/L, LOT, OPEN GAP                                               //
//==================================================================//

double GetPairOpenGap_FromFills(const int pairIdx, bool &ok)
{
   ok = (g_rt[pairIdx].hasS1  && g_rt[pairIdx].hasS2 &&
         g_rt[pairIdx].openS1 > 0.0 && g_rt[pairIdx].openS2 > 0.0);

   return ok ? (g_rt[pairIdx].openS1 - g_rt[pairIdx].openS2) : 0.0;
}

double GetPairPL_ProfitOnly(int pairIdx)
{
   return g_rt[pairIdx].pl;
}

double GetPairLot_PairSize(int pairIdx)
{
   double v1 = g_rt[pairIdx].volS1;
   double v2 = g_rt[pairIdx].volS2;

   if(v1>0.0 && v2>0.0) return MathMin(v1,v2);
   if(v1>0.0) return v1;
   return v2;
}

double GetTerminalTotalPL_ProfitOnly()
{
   double total = 0.0;
   for(int p=1; p<=g_maxPairs; p++)
      total += g_rt[p].pl;
   return total;
}

double GetVisibleListSumPL()
{
   double s = 0.0;
   for(int i=0; i<g_visibleN; i++)
   {
      int p  = g_visiblePairs[i];
      int st = GetPairStatus(p);
      if(st==PSTATUS_LIVE || st==PSTATUS_BROKEN)
         s += g_rt[p].pl;
   }
   return s;
}

double GetVisibleListSumLots()
{
   double s = 0.0;
   for(int i=0; i<g_visibleN; i++)
   {
      int p  = g_visiblePairs[i];
      int st = GetPairStatus(p);

      if(st==PSTATUS_LIVE || st==PSTATUS_BROKEN)
      {
         double v1 = g_rt[p].volS1;
         double v2 = g_rt[p].volS2;
         if(v1>0.0 && v2>0.0) s += MathMin(v1,v2);
         else if(v1>0.0)      s += v1;
         else                 s += v2;
      }
      else if(st==PSTATUS_SCHED)
      {
         s += GvGetD(p,"SCHED_LOT",0.0);
      }
      else if(st==PSTATUS_TRANSIT)
      {
         // Show scheduled lot while in-flight
         s += GvGetD(p,"SCHED_LOT",0.0);
      }
   }
   return s;
}

//==================================================================//
// TRADE EXECUTION — HELPERS                                        //
//==================================================================//

ENUM_ORDER_TYPE_FILLING GetBestFilling(const string sym)
{
   long fm = (long)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   if((fm & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;

   if((fm & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;
}

void PrepareTradeForSymbol(const string sym)
{
   trade.SetExpertMagicNumber(InpMagicNo);
   trade.SetDeviationInPoints(PipToPoints(sym, InpSlippagePips));
   trade.SetTypeFilling(GetBestFilling(sym));
   trade.SetAsyncMode(false);
}

//==================================================================//
// v2.84: PENDING ORDER MANAGEMENT                                  //
//==================================================================//

void InitPendingArray()
{
   for(int i=0; i<MAX_PENDING; i++)
   {
      g_pending[i].active      = false;
      g_pending[i].reqId       = 0;
      g_pending[i].pairIdx     = 0;
      g_pending[i].leg         = "";
      g_pending[i].isOpen      = true;
      g_pending[i].closeTicket = 0;
      g_pending[i].sentMs      = 0;
      g_pending[i].deadlineMs  = 0;
      g_pending[i].retries     = 0;
      g_pending[i].symbol      = "";
      g_pending[i].lot         = 0.0;
      g_pending[i].sentPrice   = 0.0;
   }
   g_inFlight = 0;
}

int FindFreePendingSlot()
{
   for(int i=0; i<MAX_PENDING; i++)
      if(!g_pending[i].active) return i;
   return -1;
}

int FindPendingByReqId(ulong reqId)
{
   if(reqId==0) return -1;
   for(int i=0; i<MAX_PENDING; i++)
      if(g_pending[i].active && g_pending[i].reqId==reqId) return i;
   return -1;
}

int FindPendingByTicket(ulong ticket)
{
   if(ticket==0) return -1;
   for(int i=0; i<MAX_PENDING; i++)
      if(g_pending[i].active && !g_pending[i].isOpen && g_pending[i].closeTicket==ticket)
         return i;
   return -1;
}

// Count active pending orders for a given pair
int CountPairPending(const int pairIdx)
{
   int n = 0;
   for(int i=0; i<MAX_PENDING; i++)
      if(g_pending[i].active && g_pending[i].pairIdx==pairIdx) n++;
   return n;
}

void FreePendingSlot(const int i)
{
   if(i<0 || i>=MAX_PENDING) return;
   if(!g_pending[i].active) return;
   g_pending[i].active = false;
   g_inFlight = MathMax(0, g_inFlight-1);
}

// Rebuild g_inFlight from scratch (safe recalculation)
void RecalcInFlight()
{
   int n = 0;
   for(int i=0; i<MAX_PENDING; i++)
      if(g_pending[i].active) n++;
   g_inFlight = n;
}

//==================================================================//
// v2.84: ASYNC LEG DISPATCH                                        //
//==================================================================//

// Returns the request_id on success, 0 on failure.
ulong FireLegAsync(const string sym, const ENUM_ORDER_TYPE type, const double lot,
                   const string cmt, long &retcode_out)
{
   retcode_out = -1;

   MqlTick t;
   if(!GetTickSafe(sym, t))
   {
      LogMsg("FireLegAsync: no tick for " + sym);
      return 0;
   }

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = sym;
   req.magic        = InpMagicNo;
   req.volume       = lot;
   req.deviation    = PipToPoints(sym, InpSlippagePips);
   req.type_filling = GetBestFilling(sym);
   req.type         = type;
   req.price        = (type==ORDER_TYPE_BUY) ? t.ask : t.bid;
   req.comment      = cmt;

   ResetLastError();
   bool ok = OrderSendAsync(req, res);

   retcode_out = (long)res.retcode;

   LogMsg(StringFormat("FireLegAsync %s %s lot=%.2f ok=%d rc=%d reqId=%I64u",
                       (type==ORDER_TYPE_BUY?"BUY":"SELL"), sym, lot,
                       (int)ok, (int)res.retcode, res.request_id));

   if(ok && res.retcode==TRADE_RETCODE_PLACED)
      return res.request_id;

   return 0;
}

// Fire an async close for a given ticket. Returns request_id or 0.
ulong FireCloseAsync(const ulong ticket, long &retcode_out)
{
   retcode_out = -1;
   if(ticket==0) return 0;

   if(!PositionSelectByTicket(ticket)) return 0;

   string sym   = PositionGetString(POSITION_SYMBOL);
   long   ptype = PositionGetInteger(POSITION_TYPE);
   double vol   = PositionGetDouble(POSITION_VOLUME);

   MqlTick tk;
   if(!GetTickSafe(sym, tk))
   {
      LogMsg("FireCloseAsync: no tick for " + sym);
      return 0;
   }

   ENUM_ORDER_TYPE closeType = (ptype==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.position     = ticket;
   req.symbol       = sym;
   req.magic        = InpMagicNo;
   req.volume       = vol;
   req.deviation    = PipToPoints(sym, InpSlippagePips);
   req.type_filling = GetBestFilling(sym);
   req.type         = closeType;
   req.price        = (closeType==ORDER_TYPE_SELL) ? tk.bid : tk.ask;
   req.comment      = "PAIR_CLOSE";

   ResetLastError();
   bool ok = OrderSendAsync(req, res);

   retcode_out = (long)res.retcode;

   LogMsg(StringFormat("FireCloseAsync ticket=%I64u sym=%s ok=%d rc=%d reqId=%I64u",
                       ticket, sym, (int)ok, (int)res.retcode, res.request_id));

   if(ok && res.retcode==TRADE_RETCODE_PLACED)
      return res.request_id;

   return 0;
}

//==================================================================//
// v2.84: ASYNC OPEN PAIR                                           //
//==================================================================//

// Non-blocking open: fires both legs asynchronously. Returns true if both orders
// were accepted by the server (PLACED). The pair enters PSTATUS_TRANSIT until
// OnTradeTransaction confirms fills or WatchdogTick rolls back.
bool OpenPairAsync(int pairIdx, double lot)
{
   if(pairIdx<1 || pairIdx>g_maxPairs) return false;
   if(PairHasAnyLeg(pairIdx))
   {
      LogPair(pairIdx,"ASYNC_OPEN_BLOCKED","slot already has a leg");
      return false;
   }
   if(IsOpeningLocked(pairIdx))
   {
      LogPair(pairIdx,"ASYNC_OPEN_BLOCKED","opening lock active");
      return false;
   }
   if(IsInTransit(pairIdx))
   {
      LogPair(pairIdx,"ASYNC_OPEN_BLOCKED","already in transit");
      return false;
   }

   int s1slot = FindFreePendingSlot();
   if(s1slot<0) { LogMsg("OpenPairAsync: pending table full"); return false; }
   int s2slot = FindFreePendingSlot();
   // We need two free slots; temporarily mark s1 active to find a different s2 slot
   g_pending[s1slot].active = true;
   s2slot = FindFreePendingSlot();
   g_pending[s1slot].active = false;
   if(s2slot<0 || s2slot==s1slot)
   {
      LogMsg("OpenPairAsync: not enough pending slots");
      return false;
   }

   ENUM_ORDER_TYPE t1, t2;
   if(InpOpenDirection==DIR_SELL_ONLY) { t1=ORDER_TYPE_SELL; t2=ORDER_TYPE_BUY; }
   else                                { t1=ORDER_TYPE_BUY;  t2=ORDER_TYPE_SELL; }

   string sym1  = InpSymbol1;
   string sym2  = InpSymbol2;
   string leg1  = "S1";
   string leg2  = "S2";
   ENUM_ORDER_TYPE ot1 = t1, ot2 = t2;

   if(InpSymbolToTradeFirstWhenOpening==FIRST_SYMBOL2)
   {
      // Swap so "first" still fires first; the legs keep their names
      sym1 = InpSymbol2; ot1 = t2; leg1 = "S2";
      sym2 = InpSymbol1; ot2 = t1; leg2 = "S1";
   }

   SetOpeningLock(pairIdx, true);
   SetTransitState(pairIdx, true);
   GvSetD(pairIdx,"STATUS",0.0);
   GvSetD(pairIdx,"OPEN_TIME_SEC",0.0);
   ResetHitTimers(pairIdx);

   LogPair(pairIdx,"ASYNC_OPEN_START", StringFormat("lot=%s", F2(lot)));

   ulong now    = NowMs();
   ulong dl     = now + (ulong)InpAsyncOpenDeadlineMs;
   long  rc1=-1, rc2=-1;

   ulong rId1 = FireLegAsync(sym1, ot1, lot, MakeComment(pairIdx, leg1), rc1);
   ulong rId2 = FireLegAsync(sym2, ot2, lot, MakeComment(pairIdx, leg2), rc2);

   bool ok1 = (rId1 != 0);
   bool ok2 = (rId2 != 0);

   if(!ok1 && !ok2)
   {
      LogPair(pairIdx,"ASYNC_OPEN_FAIL","both legs rejected immediately");
      SetOpeningLock(pairIdx,false);
      ClearTransitState(pairIdx);
      return false;
   }

   // Fill pending slots
   if(ok1)
   {
      g_pending[s1slot].active      = true;
      g_pending[s1slot].reqId       = rId1;
      g_pending[s1slot].pairIdx     = pairIdx;
      g_pending[s1slot].leg         = leg1;
      g_pending[s1slot].isOpen      = true;
      g_pending[s1slot].closeTicket = 0;
      g_pending[s1slot].sentMs      = now;
      g_pending[s1slot].deadlineMs  = dl;
      g_pending[s1slot].retries     = 0;
      g_pending[s1slot].orderType   = ot1;
      g_pending[s1slot].symbol      = sym1;
      g_pending[s1slot].lot         = lot;
      g_inFlight++;
   }
   else
   {
      // Leg 1 rejected immediately — mark S1 attempt failed in transit GV
      GvSetD(pairIdx,"TRANSIT_S1",-1.0);
   }

   if(ok2)
   {
      g_pending[s2slot].active      = true;
      g_pending[s2slot].reqId       = rId2;
      g_pending[s2slot].pairIdx     = pairIdx;
      g_pending[s2slot].leg         = leg2;
      g_pending[s2slot].isOpen      = true;
      g_pending[s2slot].closeTicket = 0;
      g_pending[s2slot].sentMs      = now;
      g_pending[s2slot].deadlineMs  = dl;
      g_pending[s2slot].retries     = 0;
      g_pending[s2slot].orderType   = ot2;
      g_pending[s2slot].symbol      = sym2;
      g_pending[s2slot].lot         = lot;
      g_inFlight++;
   }
   else
   {
      GvSetD(pairIdx,"TRANSIT_S2",-1.0);
   }

   // If one leg was immediately rejected, the watchdog will handle rollback
   // within InpAsyncOpenDeadlineMs ms.
   return (ok1 || ok2);
}

//==================================================================//
// v2.84: ASYNC CLOSE PAIR                                          //
//==================================================================//

bool ClosePairAsync(int pairIdx)
{
   if(IsClosingLocked(pairIdx))
   {
      LogPair(pairIdx,"ASYNC_CLOSE_BLOCKED","closing lock active");
      return false;
   }
   if(IsInTransit(pairIdx))
   {
      LogPair(pairIdx,"ASYNC_CLOSE_BLOCKED","pair in transit");
      return false;
   }

   ulong tkA = FindTicket(pairIdx,"S1");
   ulong tkB = FindTicket(pairIdx,"S2");
   if(tkA==0 && tkB==0) return true;

   int sA = -1, sB = -1;
   if(tkA!=0) { sA = FindFreePendingSlot(); if(sA>=0) g_pending[sA].active=true; }
   if(tkB!=0) { sB = FindFreePendingSlot(); if(sA>=0) g_pending[sA].active=false; }

   SetClosingLock(pairIdx,true);
   SetTransitState(pairIdx,false); // false = closing transit

   ulong now = NowMs();
   ulong dl  = now + (ulong)InpAsyncCloseDeadlineMs;
   LogPair(pairIdx,"ASYNC_CLOSE_START");

   long rcA=-1, rcB=-1;

   if(tkA!=0 && sA>=0)
   {
      ulong rId = FireCloseAsync(tkA, rcA);
      if(rId!=0)
      {
         g_pending[sA].active      = true;
         g_pending[sA].reqId       = rId;
         g_pending[sA].pairIdx     = pairIdx;
         g_pending[sA].leg         = "S1";
         g_pending[sA].isOpen      = false;
         g_pending[sA].closeTicket = tkA;
         g_pending[sA].sentMs      = now;
         g_pending[sA].deadlineMs  = dl;
         g_pending[sA].retries     = 0;
         g_inFlight++;
      }
      else
      {
         if(sA>=0) g_pending[sA].active = false;
         GvSetD(pairIdx,"TRANSIT_S1",-1.0);
      }
   }

   if(tkB!=0 && sB>=0)
   {
      ulong rId = FireCloseAsync(tkB, rcB);
      if(rId!=0)
      {
         g_pending[sB].active      = true;
         g_pending[sB].reqId       = rId;
         g_pending[sB].pairIdx     = pairIdx;
         g_pending[sB].leg         = "S2";
         g_pending[sB].isOpen      = false;
         g_pending[sB].closeTicket = tkB;
         g_pending[sB].sentMs      = now;
         g_pending[sB].deadlineMs  = dl;
         g_pending[sB].retries     = 0;
         g_inFlight++;
      }
      else
      {
         if(sB>=0) g_pending[sB].active = false;
         GvSetD(pairIdx,"TRANSIT_S2",-1.0);
      }
   }

   return true;
}

// Called when both legs of an async close are confirmed (or timed out)
void FinalizeAsyncClose(const int pairIdx)
{
   bool stillA = (FindTicket(pairIdx,"S1")!=0);
   bool stillB = (FindTicket(pairIdx,"S2")!=0);

   ResetHitTimers(pairIdx);
   GvSetD(pairIdx,"OPEN_TIME_SEC",0.0);
   SetOpeningLock(pairIdx,false);
   SetClosingLock(pairIdx,false);
   ClearTransitState(pairIdx);

   if(!stillA && !stillB)
   {
      // Realized gap: read the last known fill prices from deal history for this pair.
      // We look for the two most recent OUT deals with our magic number + pair comment.
      double triggerGap  = GvGetD(pairIdx,"CLOSE_TRIGGER_GAP",0.0);
      double realizedGap = 0.0;
      bool   gotGap      = false;

      if(triggerGap != 0.0)
      {
         // Scan last ~30 seconds of deal history for close fills
         datetime from = TimeCurrent() - 30;
         if(HistorySelect(from, TimeCurrent()))
         {
            double fillS1 = 0.0, fillS2 = 0.0;
            int    deals  = HistoryDealsTotal();

            for(int i=deals-1; i>=0; i--)
            {
               ulong dTk = HistoryDealGetTicket(i);
               if(!HistoryDealSelect(dTk)) continue;
               if((long)HistoryDealGetInteger(dTk,DEAL_MAGIC) != InpMagicNo) continue;

               int    dp; string dleg;
               string dcmt = HistoryDealGetString(dTk,DEAL_COMMENT);
               // Close deals are tagged PAIR_CLOSE; match via position_id back to open comment
               // Simpler: match the open-leg position by checking which position was closed here
               ulong  posId = (ulong)HistoryDealGetInteger(dTk, DEAL_POSITION_ID);

               // Find which leg this position belonged to by checking open deals
               for(int j=0; j<deals; j++)
               {
                  ulong eTk = HistoryDealGetTicket(j);
                  if(!HistoryDealSelect(eTk)) continue;
                  if((ulong)HistoryDealGetInteger(eTk,DEAL_POSITION_ID) != posId) continue;
                  if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(eTk,DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
                  if((long)HistoryDealGetInteger(eTk,DEAL_MAGIC) != InpMagicNo) continue;

                  string ecmt = HistoryDealGetString(eTk, DEAL_COMMENT);
                  if(!ParseComment(ecmt, dp, dleg)) continue;
                  if(dp != pairIdx) continue;

                  // Re-select close deal to read its price
                  if(!HistoryDealSelect(dTk)) continue;
                  double fillPrice = HistoryDealGetDouble(dTk, DEAL_PRICE);

                  if(dleg=="S1" && fillS1==0.0) fillS1 = fillPrice;
                  if(dleg=="S2" && fillS2==0.0) fillS2 = fillPrice;
                  break;
               }

               if(fillS1!=0.0 && fillS2!=0.0) break;
            }

            if(fillS1!=0.0 && fillS2!=0.0)
            {
               realizedGap = fillS1 - fillS2;
               gotGap      = true;
            }
         }
      }

      GvSetD(pairIdx,"CLOSE_TRIGGER_GAP",0.0);
      ClearPairState(pairIdx);

      if(gotGap && triggerGap!=0.0)
      {
         double slippage = realizedGap - triggerGap;  // +ve = worse for SELL_ONLY close
         LogPair(pairIdx,"ASYNC_CLOSE_OK",
                 StringFormat("triggerGap=%s realizedGap=%s slippage=%s",
                              F2(triggerGap), F2(realizedGap), F2(slippage)));
      }
      else
      {
         LogPair(pairIdx,"ASYNC_CLOSE_OK");
      }
   }
   else
   {
      LogPair(pairIdx,"ASYNC_CLOSE_INCOMPLETE",
              StringFormat("stillA=%d stillB=%d", (int)stillA, (int)stillB));
   }
}

// Called when both legs of an async open are confirmed
void FinalizeAsyncOpen(const int pairIdx, const double lot)
{
   SetOpeningLock(pairIdx,false);
   ClearTransitState(pairIdx);

   RefreshPairRuntime();

   bool okGap = false;
   double og  = GetPairOpenGap_FromFills(pairIdx, okGap);
   if(okGap) GvSetD(pairIdx,"OPENGAP", og);

   GvSetD(pairIdx,"OAG",0.0);
   GvSetD(pairIdx,"SCHED_LOT",0.0);
   GvSetD(pairIdx,"OPEN_TIME_SEC",(double)TimeCurrent());

   LogPair(pairIdx,"ASYNC_OPEN_OK",
           StringFormat("openGap=%s", okGap ? F2(og) : "n/a"));
}

//==================================================================//
// v2.84: RETRY MATRIX                                              //
//==================================================================//

// Returns true if the error code should be retried (delay handled by caller)
bool ShouldRetry(const long retcode, int &waitMs)
{
   waitMs = 0;
   switch((int)retcode)
   {
      case TRADE_RETCODE_REQUOTE:            waitMs=0;   return true;  // immediate retry with fresh tick
      case TRADE_RETCODE_PRICE_CHANGED:      waitMs=0;   return true;
      case TRADE_RETCODE_PRICE_OFF:          waitMs=50;  return true;
      case TRADE_RETCODE_TOO_MANY_REQUESTS:  waitMs=500; return true;
      case TRADE_RETCODE_CONNECTION:         waitMs=200; return true;
      case TRADE_RETCODE_TIMEOUT:            waitMs=100; return true;
      // Fatal — do not retry
      case TRADE_RETCODE_INVALID:            return false;
      case TRADE_RETCODE_INVALID_VOLUME:     return false;
      case TRADE_RETCODE_INVALID_PRICE:      return false;
      case TRADE_RETCODE_TRADE_DISABLED:     return false;
      case TRADE_RETCODE_MARKET_CLOSED:      return false;
      case TRADE_RETCODE_NO_MONEY:           return false;
      default:                               return false;
   }
}

//==================================================================//
// v2.84: WATCHDOG TICK                                             //
//==================================================================//
// Called each OnTimer. Inspects all active pending orders.
// - If deadline expired for an open: rollback any filled leg.
// - If deadline expired for a close: retry or log incomplete.
//
void WatchdogTick()
{
   if(g_inFlight==0) return;

   ulong now = NowMs();

   for(int i=0; i<MAX_PENDING; i++)
   {
      if(!g_pending[i].active) continue;
      if(now < g_pending[i].deadlineMs) continue;

      // Deadline passed — this order is stuck
      int    p   = g_pending[i].pairIdx;
      string leg = g_pending[i].leg;
      bool   op  = g_pending[i].isOpen;

      LogPair(p, "WATCHDOG_EXPIRED",
              StringFormat("leg=%s isOpen=%d retries=%d reqId=%I64u",
                           leg, (int)op, g_pending[i].retries, g_pending[i].reqId));

      if(op)
      {
         // Stuck async open — check if the other leg filled
         // If this leg is still pending (position not yet there), check if OTHER leg filled
         bool thisLegFilled = (FindTicket(p, leg) != 0);

         if(!thisLegFilled)
         {
            // This leg never filled. Check if the other leg did.
            string otherLeg = (leg=="S1") ? "S2" : "S1";
            ulong  otherTk  = FindTicket(p, otherLeg);

            if(otherTk != 0)
            {
               // Other leg filled, this one didn't — rollback other leg synchronously
               LogPair(p,"WATCHDOG_ROLLBACK",
                       StringFormat("closing filled %s to flatten", otherLeg));
               CloseTicketAndConfirm(otherTk);
            }

            // Clear all pending for this pair
            for(int j=0; j<MAX_PENDING; j++)
               if(g_pending[j].active && g_pending[j].pairIdx==p && g_pending[j].isOpen)
                  FreePendingSlot(j);

            SetOpeningLock(p,false);
            ClearTransitState(p);
            ClearPairState(p);
            LogPair(p,"WATCHDOG_OPEN_ABORTED");
         }
         else
         {
            // This leg actually filled (position exists), but we still timed out
            // waiting for the transaction event — just confirm it here
            GvSetD(p,"TRANSIT_" + leg, 1.0);
            FreePendingSlot(i);

            // Check if both legs now confirmed
            bool s1ok = (GvGetD(p,"TRANSIT_S1",0.0) >= 0.5);
            bool s2ok = (GvGetD(p,"TRANSIT_S2",0.0) >= 0.5);
            if(s1ok && s2ok && CountPairPending(p)==0)
            {
               double lot = g_pending[i].lot;  // already freed, but stored value
               FinalizeAsyncOpen(p, lot);
            }
         }
      }
      else
      {
         // Stuck async close
         int maxRetries = InpMaxCloseRetries;
         int retries    = g_pending[i].retries;

         if(retries < maxRetries)
         {
            // Retry the close
            ulong ticket = g_pending[i].closeTicket;
            if(!PositionSelectByTicket(ticket))
            {
               // Position already gone — close succeeded silently
               GvSetD(p,"TRANSIT_" + leg, 1.0);
               FreePendingSlot(i);
            }
            else
            {
               long rc = -1;
               ulong newReqId = FireCloseAsync(ticket, rc);
               if(newReqId != 0)
               {
                  g_pending[i].reqId      = newReqId;
                  g_pending[i].sentMs     = now;
                  g_pending[i].deadlineMs = now + (ulong)InpAsyncCloseDeadlineMs;
                  g_pending[i].retries++;
                  LogPair(p,"WATCHDOG_CLOSE_RETRY",
                          StringFormat("leg=%s retry=%d", leg, g_pending[i].retries));
               }
               else
               {
                  LogPair(p,"WATCHDOG_CLOSE_RETRY_FAIL",
                          StringFormat("leg=%s rc=%d", leg, (int)rc));
                  FreePendingSlot(i);
                  SetClosingLock(p,false);
                  ClearTransitState(p);
               }
            }
         }
         else
         {
            // Exhausted retries — log and abandon
            LogPair(p,"WATCHDOG_CLOSE_ABANDONED",
                    StringFormat("leg=%s maxRetries=%d reached", leg, maxRetries));
            FreePendingSlot(i);
            SetClosingLock(p,false);
            ClearTransitState(p);
         }

         // Check if all close pending for this pair are done
         if(CountPairPending(p)==0 && IsInTransit(p))
            FinalizeAsyncClose(p);
      }
   }
}

//==================================================================//
// TRADE EXECUTION — SYNCHRONOUS (kept for manual buttons)         //
//==================================================================//

bool OpenLeg(string sym, ENUM_ORDER_TYPE type, double lot, string cmt, long &retcode_out)
{
   retcode_out = -1;

   MqlTick t;
   if(!GetTickSafe(sym, t))
   {
      LogMsg("Tick missing for " + sym);
      return false;
   }

   PrepareTradeForSymbol(sym);

   bool ok = (type==ORDER_TYPE_BUY)
             ? trade.Buy(lot, sym, t.ask, 0, 0, cmt)
             : trade.Sell(lot, sym, t.bid, 0, 0, cmt);

   retcode_out = (long)trade.ResultRetcode();

   LogTradeResult(ok ? "OpenLeg OK" : "OpenLeg FAIL", sym, ok, retcode_out,
                  StringFormat("type=%s lot=%s",
                               (type==ORDER_TYPE_BUY?"BUY":"SELL"),
                               DoubleToString(lot,2)));
   return ok;
}

bool CloseTicketAndConfirm(ulong ticket, int attempts=2, int waitMs=100)
{
   if(ticket==0) return true;

   MqlTradeRequest req;
   MqlTradeResult  res;

   for(int i=0; i<attempts; i++)
   {
      if(!PositionSelectByTicket(ticket)) return true;

      ZeroMemory(req);
      ZeroMemory(res);

      string sym   = PositionGetString(POSITION_SYMBOL);
      long   ptype = PositionGetInteger(POSITION_TYPE);
      double vol   = PositionGetDouble(POSITION_VOLUME);

      MqlTick tk;
      if(!GetTickSafe(sym, tk))
      {
         LogMsg("CloseTicket: no tick for " + sym);
         Sleep(waitMs);
         continue;
      }

      req.action       = TRADE_ACTION_DEAL;
      req.position     = ticket;
      req.symbol       = sym;
      req.magic        = InpMagicNo;
      req.volume       = vol;
      req.deviation    = PipToPoints(sym, InpSlippagePips);
      req.type_filling = GetBestFilling(sym);
      req.type         = (ptype==POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
      req.price        = (req.type==ORDER_TYPE_SELL ? tk.bid : tk.ask);
      req.comment      = "PAIR_CLOSE";

      ResetLastError();
      bool ok = OrderSend(req, res);

      LogMsg(StringFormat(
         "Close attempt %d | ticket=%I64u sym=%s type=%s vol=%.2f ok=%d rc=%d ext=%d",
         i+1, ticket, sym,
         (ptype==POSITION_TYPE_BUY ? "BUY" : "SELL"),
         vol, (int)ok, (int)res.retcode, (int)res.retcode_external));

      if(ok && (res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_PLACED))
      {
         Sleep(waitMs);
         if(!PositionSelectByTicket(ticket)) return true;
      }

      Sleep(waitMs);
   }

   return !PositionSelectByTicket(ticket);
}

bool HandleOpenRollback(const int pairIdx, const string firstLeg)
{
   LogPair(pairIdx,"ROLLBACK","second leg failed, closing first leg");

   ulong firstTk = FindTicket(pairIdx, firstLeg);
   bool rb = CloseTicketAndConfirm(firstTk);

   if(rb && !PairHasAnyLeg(pairIdx))
      ClearPairState(pairIdx);
   else
   {
      ClearScheduleState(pairIdx, false);
      SetOpeningLock(pairIdx,false);
      LogPair(pairIdx,"ROLLBACK_FAIL_OR_PARTIAL","pair left non-flat after open failure");
   }

   return false;
}

// Synchronous open — used by manual button only
bool OpenPair(int pairIdx, double lot)
{
   if(pairIdx<1 || pairIdx>g_maxPairs) return false;
   if(PairHasAnyLeg(pairIdx))
   {
      LogPair(pairIdx,"OPEN_BLOCKED","slot already has a leg");
      return false;
   }
   if(IsOpeningLocked(pairIdx))
   {
      LogPair(pairIdx,"OPEN_BLOCKED","opening lock active");
      return false;
   }

   SetOpeningLock(pairIdx,true);
   GvSetD(pairIdx,"STATUS",0.0);
   GvSetD(pairIdx,"OPEN_TIME_SEC",0.0);
   ResetHitTimers(pairIdx);

   ENUM_ORDER_TYPE t1, t2;
   if(InpOpenDirection==DIR_SELL_ONLY) { t1=ORDER_TYPE_SELL; t2=ORDER_TYPE_BUY; }
   else                                { t1=ORDER_TYPE_BUY;  t2=ORDER_TYPE_SELL; }

   LogPair(pairIdx,"OPEN_START",StringFormat("lot=%s", F2(lot)));

   long rc1=-1, rc2=-1;
   bool ok1=false, ok2=false;

   if(InpSymbolToTradeFirstWhenOpening==FIRST_SYMBOL1)
   {
      ok1 = OpenLeg(InpSymbol1, t1, lot, MakeComment(pairIdx,"S1"), rc1);
      if(!ok1) return FailOpenStart(pairIdx);
      ok2 = OpenLeg(InpSymbol2, t2, lot, MakeComment(pairIdx,"S2"), rc2);
      if(!ok2) return HandleOpenRollback(pairIdx, "S1");
   }
   else
   {
      ok1 = OpenLeg(InpSymbol2, t2, lot, MakeComment(pairIdx,"S2"), rc1);
      if(!ok1) return FailOpenStart(pairIdx);
      ok2 = OpenLeg(InpSymbol1, t1, lot, MakeComment(pairIdx,"S1"), rc2);
      if(!ok2) return HandleOpenRollback(pairIdx, "S2");
   }

   RefreshPairRuntime();

   bool okGap = false;
   double og  = GetPairOpenGap_FromFills(pairIdx, okGap);
   if(okGap) GvSetD(pairIdx,"OPENGAP", og);

   GvSetD(pairIdx,"OAG",0.0);
   GvSetD(pairIdx,"SCHED_LOT",0.0);
   GvSetD(pairIdx,"OPEN_TIME_SEC",(double)TimeCurrent());
   SetOpeningLock(pairIdx,false);

   LogPair(pairIdx,"OPEN_OK",StringFormat("openGap=%s", okGap ? F2(og) : "n/a"));
   return true;
}

// Synchronous close — used by manual button only
void ClosePair(int pairIdx)
{
   if(IsClosingLocked(pairIdx))
   {
      LogPair(pairIdx,"CLOSE_BLOCKED","closing lock active");
      return;
   }
   SetClosingLock(pairIdx,true);

   ulong a = FindTicket(pairIdx,"S1");
   ulong b = FindTicket(pairIdx,"S2");
   if(a==0 && b==0) { SetClosingLock(pairIdx,false); return; }

   LogPair(pairIdx,"CLOSE_START");

   bool okA=true, okB=true;

   if(InpSymbolToCloseFirst==FIRST_SYMBOL1)
   {
      if(a!=0) okA = CloseTicketAndConfirm(a);
      if(b!=0) okB = CloseTicketAndConfirm(b);
   }
   else
   {
      if(b!=0) okB = CloseTicketAndConfirm(b);
      if(a!=0) okA = CloseTicketAndConfirm(a);
   }

   bool stillA = (FindTicket(pairIdx,"S1")!=0);
   bool stillB = (FindTicket(pairIdx,"S2")!=0);

   ResetHitTimers(pairIdx);
   GvSetD(pairIdx,"OPEN_TIME_SEC",0.0);
   SetOpeningLock(pairIdx,false);

   if(!stillA && !stillB)
   {
      ClearPairState(pairIdx);
      LogPair(pairIdx,"CLOSE_OK");
   }
   else
   {
      LogPair(pairIdx,"CLOSE_INCOMPLETE",
              StringFormat("okA=%d okB=%d stillA=%d stillB=%d",
                           (int)okA,(int)okB,(int)stillA,(int)stillB));
   }
   SetClosingLock(pairIdx,false);
}

//==================================================================//
// AUTO RULES — uses async path for speed                           //
//==================================================================//

void ApplyAutoRules()
{
   double cg, p1, p2;
   if(!ComputeGap(cg,p1,p2)) return;

   ulong now = NowMs();

   for(int p=1; p<=g_maxPairs; p++)
   {
      int status = GetPairStatus(p);

      if(status==PSTATUS_BROKEN)
      {
         ResetHitTimers(p);
         continue;
      }

      // Transit pairs are handled by WatchdogTick / OnTradeTransaction — skip here
      if(status==PSTATUS_TRANSIT) continue;

      //---------------------------//
      // Scheduled entry handling  //
      //---------------------------//
      if(status==PSTATUS_SCHED)
      {
         double oag = GvGetD(p,"OAG",0.0);
         double lot = GvGetD(p,"SCHED_LOT",0.01);

         if(oag==0.0 || lot<=0.0)
         {
            CancelSchedule(p);
            continue;
         }

         bool hit_oag = (InpOpenDirection==DIR_SELL_ONLY) ? (cg >= oag) : (cg <= oag);

         if(InpOagConfirmMs<=0)
         {
            if(hit_oag)
            {
               LogPair(p,"SCHEDULE_TRIGGER_NOW",
                       StringFormat("cg=%s oag=%s", F2(cg), F2(oag)));

               // v2.84: async dispatch
               bool opened = OpenPairAsync(p, lot);
               if(!opened)
               {
                  LogPair(p,"SCHEDULE_OPEN_FAIL","cancelling schedule");
                  CancelSchedule(p);
               }
               else
               {
                  // Disarm the schedule — pair is now in transit
                  GvSetD(p,"STATUS",0.0);
                  GvSetD(p,"OAG",0.0);
                  GvSetD(p,"SCHED_LOT",0.0);
               }
            }
            continue;
         }

         bool  active_oag = (GvGetD(p,"OAG_HIT_ACTIVE",0.0) >= 0.5);
         ulong since_oag  = (ulong)GvGetD(p,"OAG_HIT_SINCE_MS",0.0);

         if(hit_oag)
         {
            if(!active_oag)
            {
               GvSetD(p,"OAG_HIT_ACTIVE",1.0);
               GvSetD(p,"OAG_HIT_SINCE_MS",(double)now);
            }
            else
            {
               ulong elapsed = (now >= since_oag ? (now - since_oag) : 0);
               if((int)elapsed >= InpOagConfirmMs)
               {
                  LogPair(p,"SCHEDULE_TRIGGER_CONFIRMED",
                          StringFormat("cg=%s oag=%s held=%dms", F2(cg), F2(oag), (int)elapsed));

                  bool opened = OpenPairAsync(p, lot);
                  if(!opened)
                  {
                     LogPair(p,"SCHEDULE_OPEN_FAIL","cancelling schedule");
                     CancelSchedule(p);
                  }
                  else
                  {
                     GvSetD(p,"STATUS",0.0);
                     GvSetD(p,"OAG",0.0);
                     GvSetD(p,"SCHED_LOT",0.0);
                  }
               }
            }
         }
         else if(active_oag)
         {
            ResetOagHit(p);
         }

         continue;
      }

      //---------------------------//
      // Live pair auto-close      //
      //---------------------------//
      if(status==PSTATUS_LIVE)
      {
         double tg = GvGetD(p,"TARGET",0.0);
         if(tg==0.0)
         {
            if(GvGetD(p,"CAG_HIT_ACTIVE",0.0) >= 0.5) ResetCagHit(p);
            continue;
         }

         if(InpMinHoldMinutes > 0)
         {
            long open_sec = (long)GvGetD(p,"OPEN_TIME_SEC",0.0);
            if(open_sec<=0)
            {
               open_sec = (long)TimeCurrent();
               GvSetD(p,"OPEN_TIME_SEC",(double)open_sec);
            }
            long held = (long)TimeCurrent() - open_sec;
            long need = (long)InpMinHoldMinutes * 60;
            if(held < need)
            {
               if(GvGetD(p,"CAG_HIT_ACTIVE",0.0) >= 0.5) ResetCagHit(p);
               continue;
            }
         }

         // AdjustedCagTarget adds InpCagSlippageBuffer so the trigger fires early enough
         // that by the time both async legs fill, the realized gap lands near the true tg.
         double tgAdj     = AdjustedCagTarget(tg);
         bool   hit_cag   = TargetHit_Abs(cg, tgAdj);

         if(InpCagConfirmMs<=0)
         {
            if(hit_cag)
            {
               double pl        = GetPairPL_ProfitOnly(p);
               bool   profit_ok = true;
               if(InpTargetCloseRequireProfit) profit_ok = (pl > InpMinProfitToClose);

               if(profit_ok)
               {
                  LogPair(p,"AUTOCLOSE_NOW",
                          StringFormat("pl=%s cg=%s triggerAdj=%s target=%s buf=%s",
                                       F2(pl), F2(cg), F2(tgAdj), F2(tg),
                                       F2(InpCagSlippageBuffer)));
                  GvSetD(p,"CLOSE_TRIGGER_GAP", cg);
                  ClosePairAsync(p);  // v2.84: async
               }
            }
            continue;
         }

         bool  active_cag = (GvGetD(p,"CAG_HIT_ACTIVE",0.0) >= 0.5);
         ulong since_cag  = (ulong)GvGetD(p,"CAG_HIT_SINCE_MS",0.0);

         if(hit_cag)
         {
            if(!active_cag)
            {
               GvSetD(p,"CAG_HIT_ACTIVE",1.0);
               GvSetD(p,"CAG_HIT_SINCE_MS",(double)now);
            }
            else
            {
               ulong elapsed = (now >= since_cag ? (now - since_cag) : 0);
               if((int)elapsed >= InpCagConfirmMs)
               {
                  double pl        = GetPairPL_ProfitOnly(p);
                  bool   profit_ok = true;
                  if(InpTargetCloseRequireProfit) profit_ok = (pl > InpMinProfitToClose);

                  if(profit_ok)
                  {
                     LogPair(p,"AUTOCLOSE_CONFIRMED",
                             StringFormat("pl=%s cg=%s triggerAdj=%s target=%s buf=%s held=%dms",
                                          F2(pl), F2(cg), F2(tgAdj), F2(tg),
                                          F2(InpCagSlippageBuffer), (int)elapsed));
                     GvSetD(p,"CLOSE_TRIGGER_GAP", cg);
                     ClosePairAsync(p);  // v2.84: async
                  }
                  else
                  {
                     ResetCagHit(p);
                     LogPair(p,"AUTOCLOSE_BLOCKED_BY_PROFIT",
                             StringFormat("pl=%s min=%s", F2(pl), F2(InpMinProfitToClose)));
                  }
               }
            }
         }
         else if(active_cag)
         {
            ResetCagHit(p);
         }
      }
   }
}

//==================================================================//
// UI LAYOUT                                                        //
//==================================================================//

int Pad()     { return 18; }
int LineH()   { return UI_FontBase + 12; }
int TopH()    { return UI_FontBase + 26; }
int TopEditW(){ return 120; }
int TopBtnW() { return 220; }
int TopGap()  { return 18; }
int RowH()    { return UI_FontBase + 22; }
int RowBtnW() { return 110; }
int RowGap()  { return 14; }

//==================================================================//
// UI OBJECT HELPERS                                                //
//==================================================================//

void ObjDel(const string name){ ObjectDelete(0,name); }

bool CreateRect(string name, int x, int y, int w, int h, color bg)
{
   if(!ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0)) return false;
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,InpColBtnBorder);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   return true;
}

bool CreateLabel(string name, int x, int y, string txt, int fsize, color col)
{
   if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0)) return false;
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fsize);
   ObjectSetInteger(0,name,OBJPROP_COLOR,col);
   ObjectSetString (0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   return true;
}

bool CreateLabelMono(string name, int x, int y, string txt, int fsize, color col, string font)
{
   if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0)) return false;
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fsize);
   ObjectSetInteger(0,name,OBJPROP_COLOR,col);
   ObjectSetString (0,name,OBJPROP_FONT,font);
   ObjectSetString (0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   return true;
}

bool CreateButton(string name, int x, int y, int w, int h, string txt, color bg, int fsize=10)
{
   if(!ObjectCreate(0,name,OBJ_BUTTON,0,0,0)) return false;
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_COLOR,InpColBtnText);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,InpColBtnBorder);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fsize);
   ObjectSetString (0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
   return true;
}

bool CreateEdit(string name, int x, int y, int w, int h, string txt, int fsize=10)
{
   if(!ObjectCreate(0,name,OBJ_EDIT,0,0,0)) return false;
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_COLOR,InpColEditText);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,InpColEditBG);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,InpColEditBorder);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fsize);
   ObjectSetString (0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   return true;
}

void SetText(const string name, const string txt)
{
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
}

void ResetBtn(const string name)
{
   if(ObjectFind(0,name)>=0)
      ObjectSetInteger(0,name,OBJPROP_STATE,false);
}

//==================================================================//
// VISIBLE LIST                                                     //
//==================================================================//

void BuildVisiblePairs()
{
   g_visibleN = 0;
   for(int p=1; p<=g_maxPairs; p++)
   {
      int st = GetPairStatus(p);
      if(st==PSTATUS_LIVE || st==PSTATUS_SCHED || st==PSTATUS_BROKEN || st==PSTATUS_TRANSIT)
      {
         if(g_visibleN < (int)ArraySize(g_visiblePairs))
            g_visiblePairs[g_visibleN++] = p;
      }
   }
}

string VisibleSignature()
{
   string s = IntegerToString(g_visibleN) + "|";
   for(int i=0; i<g_visibleN; i++)
      s += IntegerToString(g_visiblePairs[i]) + ",";
   return s;
}

//==================================================================//
// UI BUILD / DELETE                                                //
//==================================================================//

int CalcPanelH(int rows)
{
   int h = 0;
   h += 10 + LineH();
   h += LineH();
   h += LineH();
   h += LineH()+10;
   h += LineH();
   h += LineH()+10;
   h += TopH()+16;
   h += LineH()+10;
   h += (rows<=0 ? LineH()+10 : rows*(RowH()+8));
   h += Pad() + 20;
   if(h < UI_H_Min) h = UI_H_Min;
   return h;
}

void DeleteUI()
{
   ObjDel(g_prefix+"PANEL");
   ObjDel(g_prefix+"TITLE");
   ObjDel(g_prefix+"SYMS");
   ObjDel(g_prefix+"DIR");
   ObjDel(g_prefix+"GAP");
   ObjDel(g_prefix+"PRICES");
   ObjDel(g_prefix+"TOTALS");
   ObjDel(g_prefix+"INFLIGHT");

   ObjDel(g_prefix+"LOT_LBL");
   ObjDel(g_prefix+"LOT_EDIT");
   ObjDel(g_prefix+"OAG_LBL");
   ObjDel(g_prefix+"OAG_EDIT");
   ObjDel(g_prefix+"CAG_LBL");
   ObjDel(g_prefix+"CAG_EDIT");
   ObjDel(g_prefix+"BTN_OPEN_SCHED");
   ObjDel(g_prefix+"BTN_CLOSE_ALL");

   ObjDel(g_prefix+"COL_HDR0");
   ObjDel(g_prefix+"COL_HDR1");
   ObjDel(g_prefix+"COL_HDR2");
   ObjDel(g_prefix+"COL_HDR3");
   ObjDel(g_prefix+"COL_HDR4");
   ObjDel(g_prefix+"COL_HDR5");

   ObjDel(g_prefix+"EMPTY");

   for(int r=0; r<64; r++)
   {
      ObjDel(g_prefix+"R_PAIR_"+IntegerToString(r));
      ObjDel(g_prefix+"R_LOT_"+IntegerToString(r));
      ObjDel(g_prefix+"R_OG_"+IntegerToString(r));
      ObjDel(g_prefix+"R_OAG_"+IntegerToString(r));
      ObjDel(g_prefix+"R_TG_"+IntegerToString(r));
      ObjDel(g_prefix+"R_PL_"+IntegerToString(r));
      ObjDel(g_prefix+"BTN_UPDATE_"+IntegerToString(r));
      ObjDel(g_prefix+"BTN_CLOSE_"+IntegerToString(r));
   }
}

void BuildUI()
{
   int rows   = g_visibleN;
   int panelH = UI_AutoHeight ? CalcPanelH(rows) : UI_H_Min;

   CreateRect(g_prefix+"PANEL", UI_X, UI_Y, UI_W, panelH, InpColPanelBG);

   int x0 = UI_X + Pad();
   int y  = UI_Y + 6;

   CreateLabel(
      g_prefix+"TITLE",
      x0, y,
      "Enter LOT | OAG | CAG then click OPEN/SCHEDULE (OAG=0 opens now, OAG!=0 schedules)\r\n"
      "OAG confirm>=" + IntegerToString(InpOagConfirmMs) +
      "ms | CAG confirm>=" + IntegerToString(InpCagConfirmMs) +
      "ms | v2.84 Async",
      UI_FontBase-3, InpColTitleText
   );

   y += LineH()+6;

   CreateLabel(g_prefix+"SYMS", x0, y,
               "S1: "+InpSymbol1+"  |  S2: "+InpSymbol2,
               UI_FontBase, InpColInfoText);
   y += LineH()+5;

   string dir = (InpOpenDirection==DIR_SELL_ONLY) ? "SELL_ONLY (Bid1-Ask2)" : "BUY_ONLY (Ask1-Bid2)";
   CreateLabel(g_prefix+"DIR", x0, y, "Dir: "+dir, UI_FontBase, InpColInfoText);
   y += LineH()+8;

   CreateLabel(g_prefix+"GAP", x0, y, "GAP: --", UI_FontBase+6, InpColGapText);
   y += LineH()+14;

   CreateLabel(g_prefix+"PRICES", x0, y, "P1: --   P2: --", UI_FontBase, InpColInfoText);
   y += LineH()+8;

   CreateLabel(g_prefix+"TOTALS", x0, y,
               "Terminal Total P/L: -- | List Sum P/L: -- | List Sum Lot: --",
               UI_FontBase, InpColOpenText);
   y += LineH()+10;

   int topH = TopH();

   CreateLabel(g_prefix+"LOT_LBL", x0, y+6, "Lot:", UI_FontBase, InpColInfoText);
   CreateEdit (g_prefix+"LOT_EDIT", x0+55, y, TopEditW(), topH, "0.01", UI_FontBase+3);

   int x = x0 + 60 + TopEditW() + TopGap();
   CreateLabel(g_prefix+"OAG_LBL", x-4, y+6, "OAG:", UI_FontBase, InpColInfoText);
   CreateEdit (g_prefix+"OAG_EDIT", x+60, y, TopEditW(), topH, "0", UI_FontBase+3);

   x = x + 70 + TopEditW() + TopGap();
   CreateLabel(g_prefix+"CAG_LBL", x-4, y+6, "CAG:", UI_FontBase, InpColInfoText);
   CreateEdit (g_prefix+"CAG_EDIT", x+60, y, TopEditW(), topH, "0", UI_FontBase+3);

   x = x + 80 + TopEditW() + TopGap();
   CreateButton(g_prefix+"BTN_OPEN_SCHED", x, y, TopBtnW(), topH,
                "OPEN / SCHEDULE", InpColBtnOpenBG, UI_FontBase-2);
   x += TopBtnW() + TopGap();
   CreateButton(g_prefix+"BTN_CLOSE_ALL", x, y, 170, topH,
                "CLOSE ALL", InpColBtnCloseAllBG, UI_FontBase-2);

   y += topH + 14;

   int c0=x0, c1=c0+180, c2=c1+110, c3=c2+110, c4=c3+110, c5=c4+110, c6=c5+340;

   CreateLabelMono(g_prefix+"COL_HDR0", c0, y, "PAIR",     UI_FontBase, InpColInfoText, UI_MonoFont);
   CreateLabelMono(g_prefix+"COL_HDR1", c1, y, "LOT",      UI_FontBase, InpColInfoText, UI_MonoFont);
   CreateLabelMono(g_prefix+"COL_HDR2", c2, y, "OPEN_GAP", UI_FontBase, InpColInfoText, UI_MonoFont);
   CreateLabelMono(g_prefix+"COL_HDR3", c3, y, "OAG",      UI_FontBase, InpColInfoText, UI_MonoFont);
   CreateLabelMono(g_prefix+"COL_HDR4", c4, y, "CAG(TGT)", UI_FontBase, InpColInfoText, UI_MonoFont);
   CreateLabelMono(g_prefix+"COL_HDR5", c5, y, "P/L",      UI_FontBase, InpColInfoText, UI_MonoFont);

   y += LineH()+8;

   if(g_visibleN<=0)
   {
      CreateLabel(g_prefix+"EMPTY", x0, y,
                  "No Active / Scheduled pairs.", UI_FontBase+1, InpColInfoText);
      return;
   }

   for(int r=0; r<g_visibleN; r++)
   {
      int p  = g_visiblePairs[r];
      int ry = y + r*(RowH()+8);
      int bx = c6 - (RowBtnW()+RowGap()+RowBtnW());

      CreateLabelMono(g_prefix+"R_PAIR_"+IntegerToString(r), c0, ry, "P: "+IntegerToString(p), UI_FontBase, InpColInfoText, UI_MonoFont);
      CreateLabelMono(g_prefix+"R_LOT_"+IntegerToString(r),  c1, ry, "--", UI_FontBase, InpColInfoText, UI_MonoFont);
      CreateLabelMono(g_prefix+"R_OG_"+IntegerToString(r),   c2, ry, "--", UI_FontBase, InpColInfoText, UI_MonoFont);
      CreateLabelMono(g_prefix+"R_OAG_"+IntegerToString(r),  c3, ry, "--", UI_FontBase, InpColInfoText, UI_MonoFont);
      CreateLabelMono(g_prefix+"R_TG_"+IntegerToString(r),   c4, ry, "--", UI_FontBase, InpColInfoText, UI_MonoFont);
      CreateLabelMono(g_prefix+"R_PL_"+IntegerToString(r),   c5, ry, "--", UI_FontBase, InpColInfoText, UI_MonoFont);

      CreateButton(g_prefix+"BTN_UPDATE_"+IntegerToString(r), bx,                     ry-2, RowBtnW(), RowH(), "UPDATE", InpColBtnUpdateBG,   UI_FontBase-2);
      CreateButton(g_prefix+"BTN_CLOSE_"+IntegerToString(r),  bx+RowBtnW()+RowGap(), ry-2, RowBtnW(), RowH(), "CLOSE",  InpColBtnCloseAllBG, UI_FontBase-2);
   }
}

//==================================================================//
// UI REFRESH                                                       //
//==================================================================//

void RefreshPairRuntime()
{
   for(int i=0; i<ArraySize(g_rt); i++)
      ZeroMemory(g_rt[i]);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNo) continue;

      int p; string leg;
      if(!ParseComment(PositionGetString(POSITION_COMMENT), p, leg)) continue;
      if(p<1 || p>g_maxPairs) continue;

      double vol    = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);

      g_rt[p].pl += profit;

      if(leg=="S1")
      {
         g_rt[p].hasS1  = true;
         g_rt[p].tkS1   = tk;
         g_rt[p].volS1  = vol;
         g_rt[p].openS1 = open;
      }
      else if(leg=="S2")
      {
         g_rt[p].hasS2  = true;
         g_rt[p].tkS2   = tk;
         g_rt[p].volS2  = vol;
         g_rt[p].openS2 = open;
      }
   }
}

void RefreshUITextOnly()
{
   double gap, p1, p2;
   bool ok = ComputeGap(gap, p1, p2);

   if(!ok)
   {
      SetText(g_prefix+"GAP","GAP: --");
      SetText(g_prefix+"PRICES","P1: --   P2: --");
   }
   else
   {
      SetText(g_prefix+"GAP","GAP: "+F2(gap));
      SetText(g_prefix+"PRICES","P1: "+F2(p1)+"   P2: "+F2(p2));
   }

   double terminalPL = GetTerminalTotalPL_ProfitOnly();
   double listPL     = GetVisibleListSumPL();
   double listLot    = GetVisibleListSumLots();

   SetText(g_prefix+"TOTALS",
           StringFormat("Terminal Total P/L: %s | List Sum P/L: %s | List Sum Lot: %s | InFlight: %d",
                        F2(terminalPL), F2(listPL), F2(listLot), g_inFlight));

   for(int r=0; r<g_visibleN; r++)
   {
      int p  = g_visiblePairs[r];
      int st = GetPairStatus(p);

      string nPair = g_prefix+"R_PAIR_"+IntegerToString(r);
      string nLot  = g_prefix+"R_LOT_"+IntegerToString(r);
      string nOG   = g_prefix+"R_OG_"+IntegerToString(r);
      string nOAG  = g_prefix+"R_OAG_"+IntegerToString(r);
      string nTG   = g_prefix+"R_TG_"+IntegerToString(r);
      string nPL   = g_prefix+"R_PL_"+IntegerToString(r);
      string bUpd  = g_prefix+"BTN_UPDATE_"+IntegerToString(r);
      string bCls  = g_prefix+"BTN_CLOSE_"+IntegerToString(r);

      // v2.84: Transit row
      if(st==PSTATUS_TRANSIT)
      {
         double lot = GvGetD(p,"SCHED_LOT",0.0);
         bool   isOpenTrans = (GvGetD(p,"TRANSIT_OP",0.0) >= 0.5);
         int    pending     = CountPairPending(p);
         string transitLbl  = isOpenTrans ? "(OPENING)" : "(CLOSING)";

         SetText(nPair, "PAIR "+IntegerToString(p)+" "+transitLbl);
         SetText(nLot,  F2(lot));
         SetText(nOG,   "--");
         SetText(nOAG,  "--");
         SetText(nTG,   F2(GvGetD(p,"TARGET",0.0)));
         SetText(nPL,   StringFormat("WAIT[%d]", pending));

         ObjectSetInteger(0,nPair,OBJPROP_COLOR,InpColStatusTransit);
         ObjectSetInteger(0,nLot, OBJPROP_COLOR,InpColStatusTransit);
         ObjectSetInteger(0,nOG,  OBJPROP_COLOR,InpColStatusTransit);
         ObjectSetInteger(0,nOAG, OBJPROP_COLOR,InpColStatusTransit);
         ObjectSetInteger(0,nTG,  OBJPROP_COLOR,InpColStatusTransit);
         ObjectSetInteger(0,nPL,  OBJPROP_COLOR,InpColStatusTransit);

         SetText(bUpd, "UPDATE");
         SetText(bCls, "ABORT");
         continue;
      }

      if(st==PSTATUS_SCHED)
      {
         double oag = GvGetD(p,"OAG",0.0);
         double cag = GvGetD(p,"TARGET",0.0);
         double lot = GvGetD(p,"SCHED_LOT",0.01);

         SetText(nPair, "PAIR "+IntegerToString(p)+" (SCHED)");
         SetText(nLot,  F2(lot));
         SetText(nOG,   "--");
         SetText(nOAG,  F2(oag));
         SetText(nTG,   F2(cag));
         SetText(nPL,   "PENDING");

         ObjectSetInteger(0,nPair,OBJPROP_COLOR,InpColStatusSched);
         ObjectSetInteger(0,nLot, OBJPROP_COLOR,InpColStatusSched);
         ObjectSetInteger(0,nOG,  OBJPROP_COLOR,InpColStatusSched);
         ObjectSetInteger(0,nOAG, OBJPROP_COLOR,InpColStatusSched);
         ObjectSetInteger(0,nTG,  OBJPROP_COLOR,InpColStatusSched);
         ObjectSetInteger(0,nPL,  OBJPROP_COLOR,InpColStatusSched);

         SetText(bUpd, "UPDATE");
         SetText(bCls, "CANCEL");
         continue;
      }

      if(st==PSTATUS_BROKEN)
      {
         double lot = GetPairLot_PairSize(p);
         double pl  = GetPairPL_ProfitOnly(p);
         double tg  = GvGetD(p,"TARGET",0.0);

         SetText(nPair, "PAIR "+IntegerToString(p)+" (BROKEN)");
         SetText(nLot,  F2(lot));
         SetText(nOG,   "--");
         SetText(nOAG,  "--");
         SetText(nTG,   F2(tg));
         SetText(nPL,   F2(pl));

         ObjectSetInteger(0,nPair,OBJPROP_COLOR,InpColStatusLoss);
         ObjectSetInteger(0,nLot, OBJPROP_COLOR,InpColStatusLoss);
         ObjectSetInteger(0,nOG,  OBJPROP_COLOR,InpColStatusLoss);
         ObjectSetInteger(0,nOAG, OBJPROP_COLOR,InpColStatusLoss);
         ObjectSetInteger(0,nTG,  OBJPROP_COLOR,InpColStatusLoss);
         ObjectSetInteger(0,nPL,  OBJPROP_COLOR,InpColStatusLoss);

         SetText(bUpd, "UPDATE");
         SetText(bCls, "CLOSE");
         continue;
      }

      // PSTATUS_LIVE
      {
         double lot = GetPairLot_PairSize(p);
         double pl  = GetPairPL_ProfitOnly(p);

         bool ok2=false;
         double og = GetPairOpenGap_FromFills(p, ok2);
         if(ok2) GvSetD(p,"OPENGAP",og);
         else    og = GvGetD(p,"OPENGAP",0.0);

         double tg = GvGetD(p,"TARGET",0.0);

         SetText(nPair, "PAIR "+IntegerToString(p)+" (LIVE)");
         SetText(nLot,  F2(lot));
         SetText(nOG,   (og==0.0 ? "--" : F2(og)));
         SetText(nOAG,  "--");
         SetText(nTG,   F2(tg));
         SetText(nPL,   F2(pl));

         color rowCol = (pl>=0.0) ? InpColStatusProfit : InpColStatusLoss;
         ObjectSetInteger(0,nPair,OBJPROP_COLOR,rowCol);
         ObjectSetInteger(0,nLot, OBJPROP_COLOR,rowCol);
         ObjectSetInteger(0,nOG,  OBJPROP_COLOR,rowCol);
         ObjectSetInteger(0,nOAG, OBJPROP_COLOR,rowCol);
         ObjectSetInteger(0,nTG,  OBJPROP_COLOR,rowCol);
         ObjectSetInteger(0,nPL,  OBJPROP_COLOR,rowCol);

         SetText(bUpd, "UPDATE");
         SetText(bCls, "CLOSE");
      }
   }

   ChartRedraw(0);
}

//==================================================================//
// v2.84: CRASH RECOVERY — Deal History Reconciliation              //
//==================================================================//
// Scans last 24h of deal history on startup. Logs any orphaned legs
// (opened but never closed with no current position) so the user can
// manually review slippage or partial fills from a previous session.
//
void ReconcileFromHistory()
{
   datetime from = TimeCurrent() - 86400;
   if(!HistorySelect(from, TimeCurrent())) return;

   int deals = HistoryDealsTotal();
   if(deals==0) return;

   // Build a simple summary: for each pair+leg, track last open/close
   // We just log orphaned states; we don't auto-correct (too dangerous).

   struct DealSummary
   {
      int    pairIdx;
      string leg;
      bool   hasOpen;
      bool   hasClose;
      double openPrice;
      datetime openTime;
   };

   DealSummary summary[128];
   int sumN = 0;

   for(int i=0; i<deals; i++)
   {
      ulong dTicket = HistoryDealGetTicket(i);
      if(!HistoryDealSelect(dTicket)) continue;
      if((long)HistoryDealGetInteger(dTicket, DEAL_MAGIC)!=InpMagicNo) continue;

      string cmt   = HistoryDealGetString(dTicket, DEAL_COMMENT);
      int    entry = (int)HistoryDealGetInteger(dTicket, DEAL_ENTRY);
      double price = HistoryDealGetDouble(dTicket, DEAL_PRICE);
      datetime dt  = (datetime)HistoryDealGetInteger(dTicket, DEAL_TIME);

      int    pairIdx; string leg;
      bool   isPairOpen = ParseComment(cmt, pairIdx, leg);

      // Also recognize PAIR_CLOSE comments — match by position ID
      if(!isPairOpen && cmt=="PAIR_CLOSE")
      {
         ulong posId = (ulong)HistoryDealGetInteger(dTicket, DEAL_POSITION_ID);
         // Find which pair+leg this position belonged to
         for(int j=0; j<sumN; j++)
         {
            if(summary[j].hasOpen && !summary[j].hasClose)
            {
               // Heuristic: we can't perfectly match without storing pos tickets
               // Just mark it closed if same symbol + same order as last open
               // This is a best-effort history scan; real state is in g_rt[]
            }
         }
         continue;
      }

      if(!isPairOpen) continue;
      if(entry != (int)DEAL_ENTRY_IN) continue;

      // Find or create summary entry
      int idx = -1;
      for(int j=0; j<sumN; j++)
         if(summary[j].pairIdx==pairIdx && summary[j].leg==leg) { idx=j; break; }

      if(idx<0 && sumN<128)
      {
         idx = sumN++;
         summary[idx].pairIdx   = pairIdx;
         summary[idx].leg       = leg;
         summary[idx].hasOpen   = false;
         summary[idx].hasClose  = false;
         summary[idx].openPrice = 0.0;
         summary[idx].openTime  = 0;
      }

      if(idx>=0)
      {
         summary[idx].hasOpen   = true;
         summary[idx].openPrice = price;
         summary[idx].openTime  = dt;
      }
   }

   // Now check which opened legs have no current position
   for(int j=0; j<sumN; j++)
   {
      if(!summary[j].hasOpen) continue;

      // Check if there is a current position for this pair+leg
      ulong curTk = FindTicket(summary[j].pairIdx, summary[j].leg);
      if(curTk==0)
      {
         // No current position — this leg was closed at some point.
         // Log it as informational.
         LogMsg(StringFormat(
            "HISTORY: Pair %d %s was opened at %s on %s — now flat (closed or expired).",
            summary[j].pairIdx, summary[j].leg,
            F2(summary[j].openPrice),
            TimeToString(summary[j].openTime, TIME_DATE|TIME_MINUTES)));
      }
      else
      {
         // Position still open — this is the active leg, normal state.
         LogMsg(StringFormat(
            "HISTORY: Pair %d %s confirmed live (ticket=%I64u).",
            summary[j].pairIdx, summary[j].leg, curTk));
      }
   }
}

//==================================================================//
// INIT / DEINIT / TIMER                                            //
//==================================================================//

void EnsureGVInit()
{
   for(int p=1; p<=g_maxPairs; p++)
   {
      if(!GlobalVariableCheck(GvKey(p,"STATUS")))           GvSetD(p,"STATUS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OAG")))              GvSetD(p,"OAG",0.0);
      if(!GlobalVariableCheck(GvKey(p,"SCHED_LOT")))        GvSetD(p,"SCHED_LOT",0.0);
      if(!GlobalVariableCheck(GvKey(p,"TARGET")))           GvSetD(p,"TARGET",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPENGAP")))          GvSetD(p,"OPENGAP",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPENING")))          GvSetD(p,"OPENING",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPENING_SINCE_MS"))) GvSetD(p,"OPENING_SINCE_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPEN_TIME_SEC")))    GvSetD(p,"OPEN_TIME_SEC",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OAG_HIT_ACTIVE")))   GvSetD(p,"OAG_HIT_ACTIVE",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OAG_HIT_SINCE_MS"))) GvSetD(p,"OAG_HIT_SINCE_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CAG_HIT_ACTIVE")))   GvSetD(p,"CAG_HIT_ACTIVE",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CAG_HIT_SINCE_MS"))) GvSetD(p,"CAG_HIT_SINCE_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSING")))          GvSetD(p,"CLOSING",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSING_SINCE_MS"))) GvSetD(p,"CLOSING_SINCE_MS",0.0);
      // v2.84: transit GVs
      if(!GlobalVariableCheck(GvKey(p,"TRANSIT")))            GvSetD(p,"TRANSIT",0.0);
      if(!GlobalVariableCheck(GvKey(p,"TRANSIT_MS")))         GvSetD(p,"TRANSIT_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"TRANSIT_OP")))         GvSetD(p,"TRANSIT_OP",0.0);
      if(!GlobalVariableCheck(GvKey(p,"TRANSIT_S1")))         GvSetD(p,"TRANSIT_S1",0.0);
      if(!GlobalVariableCheck(GvKey(p,"TRANSIT_S2")))         GvSetD(p,"TRANSIT_S2",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSE_TRIGGER_GAP"))) GvSetD(p,"CLOSE_TRIGGER_GAP",0.0);
   }
}

int DetectMaxPairIdxFromPositions()
{
   int mx = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNo) continue;

      int p; string lg;
      if(ParseComment(PositionGetString(POSITION_COMMENT),p,lg))
         if(p>mx) mx=p;
   }
   return mx;
}

int OnInit()
{
   g_maxPairs = InpMaxPairs;
   if(g_maxPairs < 1)  g_maxPairs = 1;
   if(g_maxPairs > 50) g_maxPairs = 50;

   int mx = DetectMaxPairIdxFromPositions();
   if(mx > g_maxPairs) g_maxPairs = MathMin(mx, 50);

   EnsureGVInit();
   InitPendingArray();         // v2.84

   ResetSessionStateOnInit();
   RefreshPairRuntime();
   ReconcileAllPairStates();

   ReconcileFromHistory();     // v2.84: crash recovery scan

   BuildVisiblePairs();
   g_lastSig = VisibleSignature();

   DeleteUI();
   BuildUI();
   RefreshUITextOnly();

   int ms = InpRefreshMs;
   if(ms < 50) ms = 50;
   EventSetMillisecondTimer(ms);

   LogMsg(StringFormat(
      "Initialized v2.84 Hybrid-Async | MaxPairs=%d | OAGconfirm=%dms | CAGconfirm=%dms"
      " | OpenDeadline=%dms | CloseDeadline=%dms",
      g_maxPairs, InpOagConfirmMs, InpCagConfirmMs,
      InpAsyncOpenDeadlineMs, InpAsyncCloseDeadlineMs));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteUI();
   LogMsg("Deinitialized. InFlight at deinit: " + IntegerToString(g_inFlight));
}

//==================================================================//
// v2.84: OnTradeTransaction — real-time fill confirmation          //
//==================================================================//

void OnTradeTransaction(
   const MqlTradeTransaction& trans,
   const MqlTradeRequest&     request,
   const MqlTradeResult&      result)
{
   // --- Path 1: request_id matching (most direct) ---
   if(trans.type == TRADE_TRANSACTION_REQUEST && result.request_id != 0)
   {
      int idx = FindPendingByReqId(result.request_id);
      if(idx >= 0)
      {
         int    p      = g_pending[idx].pairIdx;
         string leg    = g_pending[idx].leg;
         bool   isOpen = g_pending[idx].isOpen;

         if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
         {
            LogPair(p, "TXN_CONFIRMED",
                    StringFormat("leg=%s isOpen=%d rc=%d reqId=%I64u",
                                 leg, (int)isOpen, (int)result.retcode, result.request_id));

            GvSetD(p,"TRANSIT_"+leg, 1.0);
            FreePendingSlot(idx);

            bool s1ok = (GvGetD(p,"TRANSIT_S1",0.0) >= 0.5);
            bool s2ok = (GvGetD(p,"TRANSIT_S2",0.0) >= 0.5);

            if(s1ok && s2ok && CountPairPending(p)==0)
            {
               if(isOpen)
                  FinalizeAsyncOpen(p, request.volume);
               else
                  FinalizeAsyncClose(p);
            }
         }
         else
         {
            // Server rejected the order
            int waitMs = 0;
            bool canRetry = ShouldRetry((long)result.retcode, waitMs);
            int maxRetries = isOpen ? InpMaxOpenRetries : InpMaxCloseRetries;

            LogPair(p,"TXN_REJECTED",
                    StringFormat("leg=%s rc=%d retry=%d/%d",
                                 leg, (int)result.retcode,
                                 g_pending[idx].retries, maxRetries));

            if(canRetry && g_pending[idx].retries < maxRetries)
            {
               if(waitMs > 0) Sleep(waitMs);

               long newRc = -1;
               ulong newReqId = 0;

               if(isOpen)
                  newReqId = FireLegAsync(g_pending[idx].symbol,
                                          g_pending[idx].orderType,
                                          g_pending[idx].lot,
                                          MakeComment(p, leg),
                                          newRc);
               else
                  newReqId = FireCloseAsync(g_pending[idx].closeTicket, newRc);

               if(newReqId != 0)
               {
                  g_pending[idx].reqId       = newReqId;
                  g_pending[idx].sentMs      = NowMs();
                  g_pending[idx].deadlineMs  = NowMs() + (ulong)(isOpen ? InpAsyncOpenDeadlineMs : InpAsyncCloseDeadlineMs);
                  g_pending[idx].retries++;
               }
               else
               {
                  // Retry also failed
                  FreePendingSlot(idx);
                  if(isOpen)
                  {
                     // Rollback any filled leg
                     string otherLeg = (leg=="S1") ? "S2" : "S1";
                     ulong  otherTk  = FindTicket(p, otherLeg);
                     if(otherTk!=0) CloseTicketAndConfirm(otherTk);
                     SetOpeningLock(p,false);
                     ClearTransitState(p);
                     ClearPairState(p);
                     LogPair(p,"TXN_OPEN_ABORTED_AFTER_RETRY","retries exhausted");
                  }
                  else
                  {
                     if(CountPairPending(p)==0) FinalizeAsyncClose(p);
                  }
               }
            }
            else
            {
               // Fatal error or retries exhausted
               FreePendingSlot(idx);
               if(isOpen)
               {
                  string otherLeg = (leg=="S1") ? "S2" : "S1";
                  ulong  otherTk  = FindTicket(p, otherLeg);
                  if(otherTk!=0) CloseTicketAndConfirm(otherTk);
                  SetOpeningLock(p,false);
                  ClearTransitState(p);
                  ClearPairState(p);
                  LogPair(p,"TXN_FATAL",
                          StringFormat("leg=%s rc=%d — aborted", leg, (int)result.retcode));
               }
               else
               {
                  if(CountPairPending(p)==0) FinalizeAsyncClose(p);
               }
            }
         }
         return;
      }
   }

   // --- Path 2: Deal-add confirmation for open legs ---
   // Fires when a position is actually created (DEAL_ENTRY_IN with our comment)
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dTicket = trans.deal;
      if(!HistoryDealSelect(dTicket)) return;
      if((long)HistoryDealGetInteger(dTicket, DEAL_MAGIC) != InpMagicNo) return;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dTicket, DEAL_ENTRY);
      string          cmt   = HistoryDealGetString(dTicket, DEAL_COMMENT);

      if(entry == DEAL_ENTRY_IN)
      {
         int pairIdx; string leg;
         if(!ParseComment(cmt, pairIdx, leg)) return;

         // If there's a transit open in progress and this leg just confirmed via deal
         if(IsInTransit(pairIdx) && GvGetD(pairIdx,"TRANSIT_OP",0.0) >= 0.5)
         {
            // Mark this leg as confirmed
            if(GvGetD(pairIdx,"TRANSIT_"+leg, 0.0) < 0.5)
            {
               GvSetD(pairIdx,"TRANSIT_"+leg, 1.0);
               LogPair(pairIdx,"DEAL_OPEN_CONFIRMED",
                       StringFormat("leg=%s via DEAL_ADD", leg));

               bool s1ok = (GvGetD(pairIdx,"TRANSIT_S1",0.0) >= 0.5);
               bool s2ok = (GvGetD(pairIdx,"TRANSIT_S2",0.0) >= 0.5);

               if(s1ok && s2ok && CountPairPending(pairIdx)==0)
                  FinalizeAsyncOpen(pairIdx, 0.0);
            }
         }
      }
      else if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
      {
         // A position was closed — check if we have a pending close for this ticket
         ulong posId = (ulong)HistoryDealGetInteger(dTicket, DEAL_POSITION_ID);
         int idx = FindPendingByTicket(posId);
         if(idx >= 0)
         {
            int    p   = g_pending[idx].pairIdx;
            string leg = g_pending[idx].leg;
            GvSetD(p,"TRANSIT_"+leg, 1.0);
            FreePendingSlot(idx);
            LogPair(p,"DEAL_CLOSE_CONFIRMED",
                    StringFormat("leg=%s via DEAL_ADD", leg));

            if(CountPairPending(p)==0 && IsInTransit(p))
               FinalizeAsyncClose(p);
         }
      }
   }
}

//==================================================================//
// OnTimer — v2.84 Heartbeat Order                                  //
//==================================================================//
// Priority:
//  1. WatchdogTick  — resolve stuck/expired async orders
//  2. RefreshRuntime + Reconcile
//  3. ApplyAutoRules (only when inFlight==0 to prevent stacking)
//  4. UI refresh
//
void OnTimer()
{
   static bool inTick = false;
   if(inTick) return;
   inTick = true;

   // Step 1: Watchdog — checks all pending order deadlines
   WatchdogTick();

   // Step 2: Ground-truth refresh
   RefreshPairRuntime();
   ReconcileAllPairStates();

   // Step 3: Auto-rules — only dispatch new orders when nothing is in flight.
   // This prevents stacking new triggers on top of unresolved ones.
   if(g_inFlight == 0)
      ApplyAutoRules();

   // Step 4: Refresh runtime again (async fills may have landed since step 2)
   RefreshPairRuntime();

   // Step 5: Rebuild visible list and update UI
   BuildVisiblePairs();
   string sig = VisibleSignature();
   if(sig != g_lastSig)
   {
      g_lastSig = sig;
      DeleteUI();
      BuildUI();
   }

   RefreshUITextOnly();
   inTick = false;
}

//==================================================================//
// TOP INPUT READERS                                                //
//==================================================================//

double ReadTopLot()
{
   string s;
   double v = ReadEditNumber(g_prefix+"LOT_EDIT", s);
   WriteEditSanitized(g_prefix+"LOT_EDIT", s);
   if(v<=0) v = 0.01;
   return v;
}

double ReadTopOAG()
{
   string s;
   double v = ReadEditNumber(g_prefix+"OAG_EDIT", s);
   WriteEditSanitized(g_prefix+"OAG_EDIT", s);
   return v;
}

double ReadTopCAG()
{
   string s;
   double v = ReadEditNumber(g_prefix+"CAG_EDIT", s);
   WriteEditSanitized(g_prefix+"CAG_EDIT", s);
   return v;
}

//==================================================================//
// CHART EVENT HANDLING                                             //
//==================================================================//

void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if(id!=CHARTEVENT_OBJECT_CLICK) return;
   if(StringFind(sparam,g_prefix)!=0) return;

   RefreshPairRuntime();
   ResetBtn(sparam);

   //---------------------------//
   // Top OPEN / SCHEDULE       //
   //---------------------------//
   if(sparam == g_prefix+"BTN_OPEN_SCHED")
   {
      double lot = ReadTopLot();
      double oag = ReadTopOAG();
      double cag = ReadTopCAG();

      int p = NextFreePairSlot();
      if(p<0)
      {
         LogMsg("No free slot available.");
         return;
      }

      GvSetD(p,"TARGET", cag);
      ResetHitTimers(p);

      if(oag==0.0)
      {
         GvSetD(p,"STATUS",0.0);
         GvSetD(p,"OAG",0.0);
         GvSetD(p,"SCHED_LOT",0.0);

         LogPair(p,"OPEN_NOW",StringFormat("lot=%s cag=%s", F2(lot), F2(cag)));
         // Manual open: synchronous for reliable UI feedback
         OpenPair(p, lot);
      }
      else
      {
         GvSetD(p,"OAG", oag);
         GvSetD(p,"SCHED_LOT", lot);
         GvSetD(p,"STATUS", 2.0);

         LogPair(p,"SCHEDULE_SET",
                 StringFormat("lot=%s oag=%s cag=%s confirm=%dms",
                              F2(lot), F2(oag), F2(cag), InpOagConfirmMs));
      }
      return;
   }

   //---------------------------//
   // Top CLOSE ALL             //
   //---------------------------//
   if(sparam == g_prefix+"BTN_CLOSE_ALL")
   {
      for(int p=1; p<=g_maxPairs; p++)
      {
         int st = GetPairStatus(p);
         if(st==PSTATUS_LIVE || st==PSTATUS_BROKEN)
            ClosePair(p);   // sync for button — all pairs close before returning
      }
      return;
   }

   //---------------------------//
   // Per-row buttons           //
   //---------------------------//
   for(int r=0; r<g_visibleN; r++)
   {
      string upd = g_prefix+"BTN_UPDATE_"+IntegerToString(r);
      string cls = g_prefix+"BTN_CLOSE_"+IntegerToString(r);

      int p = g_visiblePairs[r];

      if(sparam == upd)
      {
         double cag = ReadTopCAG();
         GvSetD(p,"TARGET", cag);
         ResetCagHit(p);
         LogPair(p,"TARGET_UPDATED",StringFormat("newCAG=%s", F2(cag)));
         return;
      }

      if(sparam == cls)
      {
         int st = GetPairStatus(p);

         if(st==PSTATUS_SCHED)
         {
            CancelSchedule(p);
            LogPair(p,"ROW_CANCEL");
         }
         else if(st==PSTATUS_TRANSIT)
         {
            // Abort in-flight async open: clear pending for this pair and rollback
            LogPair(p,"ROW_ABORT_TRANSIT","user aborted in-flight order");
            for(int i=0; i<MAX_PENDING; i++)
               if(g_pending[i].active && g_pending[i].pairIdx==p)
                  FreePendingSlot(i);

            // Rollback any filled leg
            ulong tkS1 = FindTicket(p,"S1");
            ulong tkS2 = FindTicket(p,"S2");
            if(tkS1!=0) CloseTicketAndConfirm(tkS1);
            if(tkS2!=0) CloseTicketAndConfirm(tkS2);

            SetOpeningLock(p,false);
            SetClosingLock(p,false);
            ClearTransitState(p);
            ClearPairState(p);
         }
         else if(st==PSTATUS_LIVE || st==PSTATUS_BROKEN)
         {
            ClosePair(p);   // sync close for manual button
         }
         return;
      }
   }
}
//+------------------------------------------------------------------+
