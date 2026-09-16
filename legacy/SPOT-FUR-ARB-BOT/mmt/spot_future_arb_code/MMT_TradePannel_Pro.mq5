//+------------------------------------------------------------------+
//|                       MMT_TradePannel_Pro.mq5                                   |
//|                           v2.82                                   |
//|  Top-Down Control + Time-at-Level Confirmation (OAG & CAG)         |
//|                                                                  |
//|  NEW (v2.82):                                                     |
//|   - OAG confirm: gap must stay "hit" continuously for X ms         |
//|     before scheduled entry opens                                   |
//|   - CAG confirm: gap must stay "hit" continuously for Y ms         |
//|     before auto-close triggers                                     |
//|   - Resets hit-timers on: schedule cancel, open, manual close,     |
//|     auto close                                                     |
//|                                                                  |
//|  Notes:                                                           |
//|   - OAG/CAG are ABS GAP levels (no delta logic)                    |
//|   - If CAG=0 target disabled                                       |
//|   - Idle pairs hidden (only ACTIVE/SCHEDULED shown)                |
//|   - Header compares Terminal total P/L vs List sum P/L             |
//+------------------------------------------------------------------+
#property strict
#property version "2.82"

#include <Trade/Trade.mqh>
CTrade trade;

//====================== INPUTS ======================//
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

// Optional profit gate for auto-close-on-target
// NEW: minimum hold time after OPEN before any auto-close is allowed (minutes)
input int    InpMinHoldMinutes = 0;   // 0 = disabled
input bool   InpTargetCloseRequireProfit = true;
input double InpMinProfitToClose         = 0.0;

// NEW: time-at-level confirmations (milliseconds)
// If set to 0 -> acts immediately on first hit
input int    InpOagConfirmMs   = 800;  // scheduled entry confirm time
input int    InpCagConfirmMs   = 800;  // auto-close confirm time

//====================== UI CONFIG ======================//
input int    UI_X = 10;
input int    UI_Y = 10;
input int    UI_W = 1400;
input int    UI_H_Min = 220;
input bool   UI_AutoHeight = true;
input int    UI_FontBase  = 10;
input string UI_MonoFont  = "Consolas";

//====================== UI COLORS ======================//
input color  InpColPanelBG   = clrAliceBlue;
input color  InpColTitleText = clrBlack;
input color  InpColInfoText  = clrDimGray;
input color  InpColGapText   = clrDodgerBlue;
input color  InpColOpenText  = clrDarkGreen;

input color  InpColStatusProfit = clrBlueViolet;
input color  InpColStatusLoss   = clrRed;
input color  InpColStatusIdle   = clrSilver;
input color  InpColStatusSched  = clrOrange;

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

//====================== GLOBALS ======================//
string g_prefix   = "PGUI_";
int    g_maxPairs = 20;

int    g_visiblePairs[64];
int    g_visibleN = 0;
string g_lastSig  = "";

//====================== DISPLAY FORMAT ======================//
string F2(double v){ return DoubleToString(v,2); }
void LogMsg(const string s){ if(InpEnableLogs) Print("[PGUI] ", s); }

//====================== TIME (ms) ======================//
ulong NowMs()
{
#ifdef __MQL5__
  return (ulong)GetTickCount64();
#else
  return (ulong)GetTickCount();
#endif
}

//====================== HELPERS ======================//
int PipToPoints(string sym,int pips)
{
  int d=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
  return pips*((d==5||d==3)?10:1);
}

bool GetTickSafe(string sym,MqlTick &t)
{
  if(!SymbolSelect(sym,true)) return false;
  if(!SymbolInfoTick(sym,t))  return false;
  return (t.bid>0 && t.ask>0);
}

// SELL_ONLY: gap = Bid(S1) - Ask(S2)
// BUY_ONLY : gap = Ask(S1) - Bid(S2)
bool ComputeGap(double &gap, double &p1, double &p2)
{
  MqlTick t1,t2;
  if(!GetTickSafe(InpSymbol1,t1)) return false;
  if(!GetTickSafe(InpSymbol2,t2)) return false;

  if(InpOpenDirection==DIR_SELL_ONLY) { p1=t1.bid; p2=t2.ask; }
  else                                { p1=t1.ask; p2=t2.bid; }

  gap = p1 - p2;
  return true;
}

// Target hit check: CAG is ABSOLUTE GAP, 0 disables
bool TargetHit_Abs(const double current_gap, const double target_gap)
{
  if(target_gap==0.0) return false;
  if(InpOpenDirection==DIR_SELL_ONLY) return (current_gap <= target_gap);
  return (current_gap >= target_gap);
}

//====================== Numeric sanitization ======================//
// Keep ONLY: optional leading '-', digits, one '.', ignore everything else.
// No rounding, no forced decimals.
string SanitizeNumberString(const string raw)
{
  string s=raw;

  // trim left
  while(StringLen(s)>0)
  {
    int c=StringGetCharacter(s,0);
    if(c==' '||c=='\t') s=StringSubstr(s,1);
    else break;
  }
  // trim right
  while(StringLen(s)>0)
  {
    int last=StringLen(s)-1;
    int c=StringGetCharacter(s,last);
    if(c==' '||c=='\t') s=StringSubstr(s,0,last);
    else break;
  }

  bool hasDot=false;
  string out="";
  for(int i=0;i<StringLen(s);i++)
  {
    int c=StringGetCharacter(s,i);
    if(c==',') continue;

    if(c=='-' && StringLen(out)==0) { out+="-"; continue; }
    if(c>='0' && c<='9') { out+=(string)CharToString((uchar)c); continue; }
    if(c=='.' && !hasDot)
    {
      hasDot=true;
      if(out=="" || out=="-") out+="0";
      out+=".";
      continue;
    }
  }

  if(out=="" || out=="-") return "0";
  if(out=="-0."||out=="0.") return "0";
  return out;
}

double ReadEditNumber(const string objName, string &sanitized_out)
{
  sanitized_out="0";
  if(ObjectFind(0,objName)<0) return 0.0;
  string raw = ObjectGetString(0,objName,OBJPROP_TEXT);
  sanitized_out = SanitizeNumberString(raw);
  return StringToDouble(sanitized_out);
}

void WriteEditSanitized(const string objName, const string sanitized)
{
  if(ObjectFind(0,objName)>=0)
    ObjectSetString(0,objName,OBJPROP_TEXT,sanitized);
}

//====================== PERSISTENCE (Global Variables) ======================//
string GvKeyBase()
{
  return StringFormat("PGUI|%I64d|%s|%s|DIR=%d|", InpMagicNo, InpSymbol1, InpSymbol2, (int)InpOpenDirection);
}
string GvKey(int pairIdx, string field) { return GvKeyBase()+StringFormat("P=%d|%s", pairIdx, field); }

double GvGetD(int pairIdx,string field,double def=0.0)
{
  string k=GvKey(pairIdx,field);
  if(!GlobalVariableCheck(k)) return def;
  return GlobalVariableGet(k);
}
void GvSetD(int pairIdx,string field,double v){ GlobalVariableSet(GvKey(pairIdx,field), v); }
bool GvGetB(int pairIdx,string field,bool def=false){ return (GvGetD(pairIdx,field, def?1.0:0.0) >= 0.5); }
void GvSetB(int pairIdx,string field,bool v){ GvSetD(pairIdx,field, v?1.0:0.0); }

// Per pair fields:
// TARGET (CAG abs), OPENGAP
// Scheduling fields: STATUS(0 idle,2 sched), OAG(abs), SCHED_LOT
// NEW time-at-level fields:
// OAG_HIT_ACTIVE (0/1), OAG_HIT_SINCE_MS
// CAG_HIT_ACTIVE (0/1), CAG_HIT_SINCE_MS

void ResetHitTimers(const int p)
{
  GvSetD(p,"OAG_HIT_ACTIVE",0.0);
  GvSetD(p,"OAG_HIT_SINCE_MS",0.0);
  GvSetD(p,"CAG_HIT_ACTIVE",0.0);
  GvSetD(p,"CAG_HIT_SINCE_MS",0.0);
}
//====================== NEW: BROKEN + SAFE CLOSE + OPEN LOCK ======================//
#define PSTATUS_IDLE     0
#define PSTATUS_LIVE     1
#define PSTATUS_SCHED    2
#define PSTATUS_BROKEN   3



// Verified close with retries + confirmation
bool CloseTicketAndConfirm(ulong ticket, int attempts=6, int waitMs=250)
{
   if(ticket==0) return true;

   for(int i=0; i<attempts; i++)
   {
      if(!PositionSelectByTicket(ticket)) return true; 

      ResetLastError();
      // Explicitly check for valid prices before closing
      string sym = PositionGetString(POSITION_SYMBOL);
      MqlTick t;
      if(!SymbolInfoTick(sym, t)) { Sleep(waitMs); continue; }

      bool ok = trade.PositionClose(ticket);
      long rc = trade.ResultRetcode();
      
      // Success Codes: 10008 (Trade placed), 10009 (Request completed)
      if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
      {
         Sleep(waitMs); // Wait for server sync
         if(!PositionSelectByTicket(ticket)) return true;
      }

      LogMsg(StringFormat("Close Attempt %d Failed: Ticket %I64u, Retcode: %d (%s)", 
                          i+1, ticket, (int)rc, trade.ResultRetcodeDescription()));
      Sleep(waitMs);
   }

   return !PositionSelectByTicket(ticket);
}

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

  // auto-clear stale lock
  if((int)age > maxLockMs)
  {
    SetOpeningLock(p,false);
    return false;
  }
  return true;
}

//====================== PAIR TRACKING ======================//
string MakeComment(int pairIdx,string leg){ return StringFormat("PAIR|IDX=%d|LEG=%s", pairIdx, leg); }

bool ParseComment(string c,int &pairIdx,string &leg)
{
  if(StringFind(c,"PAIR|IDX=")!=0) return false;
  int a=StringFind(c,"IDX=");
  int b=StringFind(c,"|LEG=");
  if(a<0||b<0) return false;

  pairIdx=(int)StringToInteger(StringSubstr(c,a+4,b-(a+4)));
  leg=StringSubstr(c,b+5);
  return (pairIdx>=1);
}

ulong FindTicket(int pairIdx,string leg)
{
  for(int i=PositionsTotal()-1;i>=0;i--)
  {
    ulong tk=PositionGetTicket(i);
    if(!PositionSelectByTicket(tk)) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNo) continue;

    int p; string lg;
    if(ParseComment(PositionGetString(POSITION_COMMENT),p,lg))
      if(p==pairIdx && lg==leg) return tk;
  }
  return 0;
}

bool PairHasAnyLeg(int pairIdx)
{
  return (FindTicket(pairIdx,"S1")!=0 || FindTicket(pairIdx,"S2")!=0);
}



// STATUS: 0=Idle, 1=Live (2 legs), 2=Scheduled, 3=Broken (1 leg)
int GetPairStatus(int p)
{
  bool s1 = (FindTicket(p,"S1") != 0);
  bool s2 = (FindTicket(p,"S2") != 0);

  if(s1 && s2) return PSTATUS_LIVE;
  if(s1 || s2) return PSTATUS_BROKEN;

  if(GvGetD(p,"STATUS",0.0) == 2.0) return PSTATUS_SCHED;
  return PSTATUS_IDLE;
}

int NextFreePairSlot()
{
  for(int p=1;p<=g_maxPairs;p++)
  {
    if(!PairHasAnyLeg(p) && GvGetD(p,"STATUS",0.0) != 2.0)
      return p;
  }
  return -1;
}


// OPENGAP from executed entry prices (fills)
double GetPairOpenGap_FromFills(const int pairIdx, bool &ok)
{
  ok = false;
  ulong a = FindTicket(pairIdx,"S1");
  ulong b = FindTicket(pairIdx,"S2");
  if(a==0 || b==0) return 0.0;

  if(!PositionSelectByTicket(a)) return 0.0;
  double p1 = PositionGetDouble(POSITION_PRICE_OPEN);

  if(!PositionSelectByTicket(b)) return 0.0;
  double p2 = PositionGetDouble(POSITION_PRICE_OPEN);

  ok = (p1>0.0 && p2>0.0);
  return ok ? (p1 - p2) : 0.0;
}

//====================== P/L and Lots (profit-only to match terminal style) ======================//
double GetPairPL_ProfitOnly(int pairIdx)
{
  double total=0.0;
  for(int i=PositionsTotal()-1;i>=0;i--)
  {
    ulong tk = PositionGetTicket(i);
    if(!PositionSelectByTicket(tk)) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNo) continue;

    int p; string lg;
    if(!ParseComment(PositionGetString(POSITION_COMMENT),p,lg)) continue;
    if(p!=pairIdx) continue;

    total += PositionGetDouble(POSITION_PROFIT);
  }
  return total;
}

double GetPairLot_PairSize(int pairIdx)
{
  double v1=0.0,v2=0.0;

  ulong a = FindTicket(pairIdx,"S1");
  if(a!=0 && PositionSelectByTicket(a))
    v1 = PositionGetDouble(POSITION_VOLUME);

  ulong b = FindTicket(pairIdx,"S2");
  if(b!=0 && PositionSelectByTicket(b))
    v2 = PositionGetDouble(POSITION_VOLUME);

  if(v1>0.0 && v2>0.0) return MathMin(v1,v2);
  if(v1>0.0) return v1;
  return v2;
}

double GetTerminalTotalPL_ProfitOnly()
{
  double total=0.0;
  for(int i=PositionsTotal()-1;i>=0;i--)
  {
    ulong tk = PositionGetTicket(i);
    if(!PositionSelectByTicket(tk)) continue;
    total += PositionGetDouble(POSITION_PROFIT);
  }
  return total;
}

double GetVisibleListSumPL()
{
  double s=0.0;
  for(int i=0;i<g_visibleN;i++)
  {
    int p = g_visiblePairs[i];
    int st = GetPairStatus(p);
    if(st==PSTATUS_LIVE || st==PSTATUS_BROKEN)
      s += GetPairPL_ProfitOnly(p);
  }
  return s;
}

double GetVisibleListSumLots()
{
  double s=0.0;
  for(int i=0;i<g_visibleN;i++)
  {
    int p = g_visiblePairs[i];
    int st = GetPairStatus(p);

    if(st==PSTATUS_LIVE || st==PSTATUS_BROKEN)
      s += GetPairLot_PairSize(p);
    else if(st==PSTATUS_SCHED)
      s += GvGetD(p,"SCHED_LOT",0.0);
  }
  return s;
}


//====================== TRADING ======================//
bool OpenLeg(string sym,ENUM_ORDER_TYPE type,double lot,string cmt, long &retcode_out)
{
  retcode_out = -1;

  MqlTick t;
  if(!GetTickSafe(sym,t))
  {
    LogMsg("Tick missing for "+sym);
    return false;
  }

  trade.SetExpertMagicNumber(InpMagicNo);
  trade.SetDeviationInPoints(PipToPoints(sym,InpSlippagePips));
  trade.SetTypeFillingBySymbol(sym);

   // IMPROVEMENT: Manually check for allowed filling mode if default fails
   int filling = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                        trade.SetTypeFillingBySymbol(sym);


  bool ok = (type==ORDER_TYPE_BUY) ? trade.Buy(lot,sym,t.ask,0,0,cmt)
                                   : trade.Sell(lot,sym,t.bid,0,0,cmt);

  retcode_out = (long)trade.ResultRetcode();

  if(!ok)
  {
    LogMsg(StringFormat("OpenLeg FAIL %s %s lot=%s ret=%d (%s)",
                        sym,(type==ORDER_TYPE_BUY?"BUY":"SELL"),
                        DoubleToString(lot,2),
                        (int)retcode_out, trade.ResultRetcodeDescription()));
  }
  return ok;
}

bool OpenPair(int pairIdx,double lot)
{
  if(pairIdx<1 || pairIdx>g_maxPairs)
    return false;

  // local fail cleanup helper pattern
  #define OPENPAIR_FAIL() \
    { \
      GvSetD(pairIdx,"OPEN_TIME_SEC",0.0); \
      SetOpeningLock(pairIdx,false); \
      return false; \
    }

  // If any leg exists, refuse (prevents stacking on broken slots)
  if(PairHasAnyLeg(pairIdx))
  {
    LogMsg("Pair slot not free (has existing leg): "+IntegerToString(pairIdx));
    OPENPAIR_FAIL();
  }

  // Prevent re-entry / repeated schedule fire while opening
  if(IsOpeningLocked(pairIdx))
  {
    LogMsg("OpenPair blocked by OPENING lock: "+IntegerToString(pairIdx));
    OPENPAIR_FAIL();
  }

  SetOpeningLock(pairIdx,true);

  // once we begin opening, disarm schedule so it doesn't keep retriggering
  GvSetD(pairIdx,"STATUS",0.0);

  // reset stale time/timers before a fresh open attempt
  GvSetD(pairIdx,"OPEN_TIME_SEC",0.0);
  ResetHitTimers(pairIdx);

  ENUM_ORDER_TYPE t1,t2;
  if(InpOpenDirection==DIR_SELL_ONLY)
  {
    t1=ORDER_TYPE_SELL;
    t2=ORDER_TYPE_BUY;
  }
  else
  {
    t1=ORDER_TYPE_BUY;
    t2=ORDER_TYPE_SELL;
  }

  LogMsg(StringFormat("OPEN Pair #%d lot=%s", pairIdx, F2(lot)));

  long rc1=-1, rc2=-1;
  bool ok1=false, ok2=false;

  if(InpSymbolToTradeFirstWhenOpening==FIRST_SYMBOL1)
  {
    ok1 = OpenLeg(InpSymbol1,t1,lot,MakeComment(pairIdx,"S1"),rc1);
    if(!ok1)
      OPENPAIR_FAIL();

    ok2 = OpenLeg(InpSymbol2,t2,lot,MakeComment(pairIdx,"S2"),rc2);
    if(!ok2)
    {
      LogMsg("Second leg failed -> rollback first leg");
      trade.SetExpertMagicNumber(InpMagicNo);

      ulong a = FindTicket(pairIdx,"S1");
      bool rb = CloseTicketAndConfirm(a);
      if(!rb)
        LogMsg(StringFormat("CRITICAL: rollback failed for pair %d leg S1", pairIdx));

      OPENPAIR_FAIL();
    }
  }
  else
  {
    ok1 = OpenLeg(InpSymbol2,t2,lot,MakeComment(pairIdx,"S2"),rc1);
    if(!ok1)
      OPENPAIR_FAIL();

    ok2 = OpenLeg(InpSymbol1,t1,lot,MakeComment(pairIdx,"S1"),rc2);
    if(!ok2)
    {
      LogMsg("Second leg failed -> rollback first leg");
      trade.SetExpertMagicNumber(InpMagicNo);

      ulong b = FindTicket(pairIdx,"S2");
      bool rb = CloseTicketAndConfirm(b);
      if(!rb)
        LogMsg(StringFormat("CRITICAL: rollback failed for pair %d leg S2", pairIdx));

      OPENPAIR_FAIL();
    }
  }

  // --------- Both legs should exist now ----------
  bool okGap=false;
  double og = GetPairOpenGap_FromFills(pairIdx, okGap);
  if(okGap)
    GvSetD(pairIdx,"OPENGAP", og);

  // Clear schedule values (defensive)
  GvSetD(pairIdx,"OAG",0.0);
  GvSetD(pairIdx,"SCHED_LOT",0.0);

  // Mark open time for min-hold logic
  GvSetD(pairIdx,"OPEN_TIME_SEC",(double)TimeCurrent());

  SetOpeningLock(pairIdx,false);

  #undef OPENPAIR_FAIL
  return true;
}


void ClosePair(int pairIdx)
{
  ulong a=FindTicket(pairIdx,"S1");
  ulong b=FindTicket(pairIdx,"S2");
  if(a==0 && b==0) return;

  trade.SetExpertMagicNumber(InpMagicNo);
  LogMsg(StringFormat("CLOSE Pair #%d", pairIdx));

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

  if(!okA || !okB)
    LogMsg(StringFormat("WARNING: ClosePair #%d incomplete. okA=%d okB=%d", pairIdx, (int)okA, (int)okB));

  ResetHitTimers(pairIdx);
  GvSetD(pairIdx,"OPEN_TIME_SEC",0.0);
  SetOpeningLock(pairIdx,false);
}

//====================== AUTO RULES (with time-at-level confirmation) ======================//
//====================== AUTO RULES (with time-at-level confirmation) ======================//
void ApplyAutoRules()
{
  double cg,p1,p2;
  if(!ComputeGap(cg,p1,p2)) return;

  ulong now = NowMs();

  for(int p=1;p<=g_maxPairs;p++)
  {
    int status = GetPairStatus(p);

    if(status == PSTATUS_BROKEN) 
    {
        // Skip CAG/OAG logic for broken pairs to prevent erratic calculations
        // Reset timers to be safe
        ResetHitTimers(p);
        continue; 
    }
    // -------------------------
    // SCHEDULED: trigger open when OAG is hit continuously for InpOagConfirmMs
    // -------------------------
    
    if(status==PSTATUS_SCHED)
    {
      double oag = GvGetD(p,"OAG",0.0);
      double lot = GvGetD(p,"SCHED_LOT",0.01);

      // Safety: scheduled but no OAG -> cancel schedule (prevents weird triggers)
      if(oag==0.0)
      {
        GvSetD(p,"STATUS",0.0);
        GvSetD(p,"SCHED_LOT",0.0);
        ResetHitTimers(p);
        continue;
      }

      bool hit_oag = (InpOpenDirection==DIR_SELL_ONLY) ? (cg >= oag) : (cg <= oag);

      if(InpOagConfirmMs<=0)
      {
        if(hit_oag)
        {
          LogMsg(StringFormat("SCHEDULED TRIGGER (no confirm): Pair %d cg=%s OAG=%s", p, F2(cg), F2(oag)));
            bool opened = OpenPair(p, lot);
            if(!opened)
            {
              LogMsg(StringFormat("Scheduled open failed for pair %d -> cancelling schedule to avoid re-trigger loop.", p));
              CancelSchedule(p);     // stop spam retries
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
            LogMsg(StringFormat("SCHEDULED TRIGGER CONFIRMED: Pair %d cg=%s OAG=%s held=%dms",
                                p, F2(cg), F2(oag), (int)elapsed));
            bool opened = OpenPair(p, lot);
            if(!opened)
            {
              LogMsg(StringFormat("Scheduled open failed for pair %d -> cancelling schedule to avoid re-trigger loop.", p));
              CancelSchedule(p);     // stop spam retries
            }
          }
        }
      }
      else
      {
        if(active_oag)
        {
          GvSetD(p,"OAG_HIT_ACTIVE",0.0);
          GvSetD(p,"OAG_HIT_SINCE_MS",0.0);
        }
      }
      continue;
    }

    // -------------------------
    // ACTIVE: close on CAG hit continuously for InpCagConfirmMs
    // -------------------------
    if(status==PSTATUS_LIVE)
    {
      double tg = GvGetD(p,"TARGET",0.0); // CAG abs
      if(tg==0.0)
      {
        // Target disabled -> ensure CAG timer is not running
        if(GvGetD(p,"CAG_HIT_ACTIVE",0.0) >= 0.5)
        {
          GvSetD(p,"CAG_HIT_ACTIVE",0.0);
          GvSetD(p,"CAG_HIT_SINCE_MS",0.0);
        }
        continue;
      }

      // ---- MIN HOLD (wait N minutes after open before allowing ANY auto-close) ----
      if(InpMinHoldMinutes > 0)
      {
        long open_sec = (long)GvGetD(p,"OPEN_TIME_SEC",0.0);

        // If missing (EA restarted), set it now
        if(open_sec <= 0)
        {
          open_sec = (long)TimeCurrent();
          GvSetD(p,"OPEN_TIME_SEC",(double)open_sec);
        }

        long held = (long)TimeCurrent() - open_sec;
        long need = (long)InpMinHoldMinutes * 60;

        if(held < need)
        {
          // Block close; reset CAG timer so it must re-hold later
          if(GvGetD(p,"CAG_HIT_ACTIVE",0.0) >= 0.5)
          {
            GvSetD(p,"CAG_HIT_ACTIVE",0.0);
            GvSetD(p,"CAG_HIT_SINCE_MS",0.0);
          }
          continue;
        }
      }

      bool hit_cag = TargetHit_Abs(cg,tg);

      if(InpCagConfirmMs<=0)
      {
        if(hit_cag)
        {
          double pl = GetPairPL_ProfitOnly(p);
          bool profit_ok = true;
          if(InpTargetCloseRequireProfit) profit_ok = (pl > InpMinProfitToClose);

          if(profit_ok)
          {
            LogMsg(StringFormat("AutoClose CAG (no confirm) P=%d pl=%s cg=%s target=%s",
                                p, F2(pl), F2(cg), F2(tg)));
            ClosePair(p);
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
            double pl = GetPairPL_ProfitOnly(p);
            bool profit_ok = true;
            if(InpTargetCloseRequireProfit) profit_ok = (pl > InpMinProfitToClose);

            if(profit_ok)
            {
              LogMsg(StringFormat("AutoClose CAG CONFIRMED P=%d pl=%s cg=%s target=%s held=%dms",
                                  p, F2(pl), F2(cg), F2(tg), (int)elapsed));
              ClosePair(p);
            }
            else
            {
              // Profit gate blocked -> reset so it must re-hold again
              GvSetD(p,"CAG_HIT_ACTIVE",0.0);
              GvSetD(p,"CAG_HIT_SINCE_MS",0.0);
              LogMsg(StringFormat("CAG held but profit gate blocked P=%d pl=%s (min=%s). Timer reset.",
                                  p, F2(pl), F2(InpMinProfitToClose)));
            }
          }
        }
      }
      else
      {
        if(active_cag)
        {
          GvSetD(p,"CAG_HIT_ACTIVE",0.0);
          GvSetD(p,"CAG_HIT_SINCE_MS",0.0);
        }
      }
      continue;
    }

    // status==0 idle -> nothing
  }
}

//====================== UI LAYOUT ======================//
int Pad(){ return 18; }
int LineH(){ return UI_FontBase + 12; }

int TopH(){ return UI_FontBase + 26; }
int TopEditW(){ return 120; }
int TopBtnW(){ return 220; }
int TopGap(){ return 18; }

int RowH(){ return UI_FontBase + 22; }
int RowBtnW(){ return 110; }
int RowGap(){ return 14; }

//====================== UI OBJECTS ======================//
void ObjDel(const string name){ ObjectDelete(0,name); }

bool CreateRect(string name,int x,int y,int w,int h,color bg)
{
  if(!ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0)) return false;
  ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
  ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
  ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
  ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
  ObjectSetInteger(0,name,OBJPROP_COLOR,bg);
  ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
  ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
  ObjectSetInteger(0,name,OBJPROP_BACK,false);
  ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
  ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  return true;
}

bool CreateLabel(string name,int x,int y,string txt,int fsize,color col)
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

bool CreateLabelMono(string name,int x,int y,string txt,int fsize,color col,string font)
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

bool CreateButton(string name,int x,int y,int w,int h,string txt,color bg,int fsize=10)
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

bool CreateEdit(string name,int x,int y,int w,int h,string txt,int fsize=10)
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

void SetText(const string name,const string txt){ ObjectSetString(0,name,OBJPROP_TEXT,txt); }
void ResetBtn(const string name){ if(ObjectFind(0,name)>=0) ObjectSetInteger(0,name,OBJPROP_STATE,false); }

//====================== Visible list building ======================//
void BuildVisiblePairs()
{
  g_visibleN = 0;
  for(int p=1;p<=g_maxPairs;p++)
  {
    int st = GetPairStatus(p);
    if(st==PSTATUS_LIVE || st==PSTATUS_SCHED || st==PSTATUS_BROKEN)
    {
      if(g_visibleN < (int)ArraySize(g_visiblePairs))
        g_visiblePairs[g_visibleN++] = p;
    }
  }
}

string VisibleSignature()
{
  string s = IntegerToString(g_visibleN) + "|";
  for(int i=0;i<g_visibleN;i++)
    s += IntegerToString(g_visiblePairs[i]) + ",";
  return s;
}

int CalcPanelH(int rows)
{
  int pad=Pad();
  int h = 0;
  h += 10 + LineH(); // title
  h += LineH();      // syms
  h += LineH();      // dir
  h += LineH()+10;   // gap
  h += LineH();      // prices
  h += LineH()+10;   // totals
  h += TopH()+16;    // top controls
  h += LineH()+10;   // list header
  h += (rows<=0 ? LineH()+10 : rows*(RowH()+8));
  h += pad + 20;
  if(h < UI_H_Min) h = UI_H_Min;
  return h;
}

//====================== UI BUILD / DELETE ======================//
void DeleteUI()
{
  ObjDel(g_prefix+"PANEL");
  ObjDel(g_prefix+"TITLE");
  ObjDel(g_prefix+"SYMS");
  ObjDel(g_prefix+"DIR");
  ObjDel(g_prefix+"GAP");
  ObjDel(g_prefix+"PRICES");
  ObjDel(g_prefix+"TOTALS");

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

  for(int r=0;r<64;r++)
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
  int pad = Pad();
  int rows = g_visibleN;
  int panelH = UI_AutoHeight ? CalcPanelH(rows) : UI_H_Min;

  CreateRect(g_prefix+"PANEL", UI_X, UI_Y, UI_W, panelH, InpColPanelBG);

  int x0 = UI_X + pad;
  int y  = UI_Y + 6;

  CreateLabel(g_prefix+"TITLE", x0, y,
              "Enter LOT | OAG | CAG then click OPEN/SCHEDULE (OAG=0 opens now, OAG!=0 schedules)\r\n"
              "Time confirm: OAG>= "+IntegerToString(InpOagConfirmMs)+"ms, CAG>= "+IntegerToString(InpCagConfirmMs)+"ms",
              UI_FontBase-3, InpColTitleText);

  y += LineH()+6;

  CreateLabel(g_prefix+"SYMS", x0, y, "S1: "+InpSymbol1+"  |  S2: "+InpSymbol2, UI_FontBase, InpColInfoText);
  y += LineH()+5;

  string dir = (InpOpenDirection==DIR_SELL_ONLY) ? "SELL_ONLY (Bid1-Ask2)" : "BUY_ONLY (Ask1-Bid2)";
  CreateLabel(g_prefix+"DIR", x0, y, "Dir: "+dir, UI_FontBase, InpColInfoText);
  y += LineH()+8;

  CreateLabel(g_prefix+"GAP", x0, y, "GAP: --", UI_FontBase+6, InpColGapText);
  y += LineH()+14;

  CreateLabel(g_prefix+"PRICES", x0, y, "P1: --   P2: --", UI_FontBase, InpColInfoText);
  y += LineH()+8;

  CreateLabel(g_prefix+"TOTALS", x0, y, "Terminal Total P/L: -- | List Sum P/L: -- | List Sum Lot: --", UI_FontBase, InpColOpenText);
  y += LineH()+10;

  // Top controls
  int topH=TopH();

  CreateLabel(g_prefix+"LOT_LBL", x0, y+6, "Lot:", UI_FontBase, InpColInfoText);
  CreateEdit (g_prefix+"LOT_EDIT", x0+55, y, TopEditW(), topH, "0.01", UI_FontBase+3);

  int x = x0 + 60 + TopEditW() + TopGap();

  CreateLabel(g_prefix+"OAG_LBL", x-4, y+6, "OAG:", UI_FontBase, InpColInfoText);
  CreateEdit (g_prefix+"OAG_EDIT", x+60, y, TopEditW(), topH, "0", UI_FontBase+3);

  x = x + 70 + TopEditW() + TopGap();

  CreateLabel(g_prefix+"CAG_LBL", x-4, y+6, "CAG:", UI_FontBase, InpColInfoText);
  CreateEdit (g_prefix+"CAG_EDIT", x+60, y, TopEditW(), topH, "0", UI_FontBase+3);

  x = x + 80 + TopEditW() + TopGap();

  CreateButton(g_prefix+"BTN_OPEN_SCHED", x, y, TopBtnW(), topH, "OPEN / SCHEDULE", InpColBtnOpenBG, UI_FontBase-2);
  x += TopBtnW() + TopGap();

  CreateButton(g_prefix+"BTN_CLOSE_ALL", x, y, 170, topH, "CLOSE ALL", InpColBtnCloseAllBG, UI_FontBase-2);

  y += topH + 14;

  // List header
  int c0=x0;          // PAIR
  int c1=c0+180;      // LOT
  int c2=c1+110;      // OPENGAP
  int c3=c2+110;      // OAG
  int c4=c3+110;      // CAG
  int c5=c4+110;      // PL
  int c6=c5+340;      // update
  CreateLabelMono(g_prefix+"COL_HDR0", c0, y, "PAIR",      UI_FontBase, InpColInfoText, UI_MonoFont);
  CreateLabelMono(g_prefix+"COL_HDR1", c1, y, "LOT",       UI_FontBase, InpColInfoText, UI_MonoFont);
  CreateLabelMono(g_prefix+"COL_HDR2", c2, y, "OPEN_GAP",  UI_FontBase, InpColInfoText, UI_MonoFont);
  CreateLabelMono(g_prefix+"COL_HDR3", c3, y, "OAG",       UI_FontBase, InpColInfoText, UI_MonoFont);
  CreateLabelMono(g_prefix+"COL_HDR4", c4, y, "CAG(TGT)",  UI_FontBase, InpColInfoText, UI_MonoFont);
  CreateLabelMono(g_prefix+"COL_HDR5", c5, y, "P/L",       UI_FontBase, InpColInfoText, UI_MonoFont);

  y += LineH()+8;

  if(g_visibleN<=0)
  {
    CreateLabel(g_prefix+"EMPTY", x0, y, "No Active / Scheduled pairs.", UI_FontBase+1, InpColInfoText);
    return;
  }

  // Rows
  for(int r=0;r<g_visibleN;r++)
  {
    int p = g_visiblePairs[r];
    int ry = y + r*(RowH()+8);

    CreateLabelMono(g_prefix+"R_PAIR_"+IntegerToString(r), c0, ry, "P: "+IntegerToString(p), UI_FontBase, InpColInfoText, UI_MonoFont);
    CreateLabelMono(g_prefix+"R_LOT_"+IntegerToString(r),  c1, ry, "--", UI_FontBase, InpColInfoText, UI_MonoFont);
    CreateLabelMono(g_prefix+"R_OG_"+IntegerToString(r),   c2, ry, "--", UI_FontBase, InpColInfoText, UI_MonoFont);
    CreateLabelMono(g_prefix+"R_OAG_"+IntegerToString(r),  c3, ry, "--", UI_FontBase, InpColInfoText, UI_MonoFont);
    CreateLabelMono(g_prefix+"R_TG_"+IntegerToString(r),   c4, ry, "--", UI_FontBase, InpColInfoText, UI_MonoFont);
    CreateLabelMono(g_prefix+"R_PL_"+IntegerToString(r),   c5, ry, "--", UI_FontBase, InpColInfoText, UI_MonoFont);

    int bx = UI_X + c6 - (RowBtnW()+RowGap()+RowBtnW());
    string upd = g_prefix+"BTN_UPDATE_"+IntegerToString(r);
    string cls = g_prefix+"BTN_CLOSE_"+IntegerToString(r);

    CreateButton(upd, bx, ry-2, RowBtnW(), RowH(), "UPDATE", InpColBtnUpdateBG, UI_FontBase-2);
    CreateButton(cls, bx + RowBtnW() + RowGap(), ry-2, RowBtnW(), RowH(), "CLOSE", InpColBtnCloseAllBG, UI_FontBase-2);
  }
}

//====================== UI Refresh values ======================//
void RefreshUITextOnly()
{

  double gap,p1,p2;
  bool ok = ComputeGap(gap,p1,p2);

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
          StringFormat("Terminal Total P/L: %s | List Sum P/L: %s | List Sum Lot: %s",
                       F2(terminalPL), F2(listPL), F2(listLot)));

  for(int r=0;r<g_visibleN;r++)
  {
    int p = g_visiblePairs[r];
    int st = GetPairStatus(p);

    string nPair = g_prefix+"R_PAIR_"+IntegerToString(r);
    string nLot  = g_prefix+"R_LOT_"+IntegerToString(r);
    string nOG   = g_prefix+"R_OG_"+IntegerToString(r);
    string nOAG  = g_prefix+"R_OAG_"+IntegerToString(r);
    string nTG   = g_prefix+"R_TG_"+IntegerToString(r);
    string nPL   = g_prefix+"R_PL_"+IntegerToString(r);

    string bUpd = g_prefix+"BTN_UPDATE_"+IntegerToString(r);
    string bCls = g_prefix+"BTN_CLOSE_"+IntegerToString(r);

    if(st==PSTATUS_SCHED ) // scheduled
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
    }
    else if(st==PSTATUS_BROKEN)
    {
      // show broken
      double lot = GetPairLot_PairSize(p);
      double pl  = GetPairPL_ProfitOnly(p);

      double tg = GvGetD(p,"TARGET",0.0);

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
      SetText(bCls, "CLOSE"); // close the remaining orphan leg
    }
    else // active
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
      SetText(nOG,   (og==0.0?"--":F2(og)));
      SetText(nOAG,  "--");
      SetText(nTG,   F2(tg));
      SetText(nPL,   F2(pl));

      color rowCol = (pl>=0.0)?InpColStatusProfit:InpColStatusLoss;
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

//====================== Ensure GV fields exist ======================//
void EnsureGVInit()
{
  for(int p=1;p<=g_maxPairs;p++)
  {
    if(!GlobalVariableCheck(GvKey(p,"STATUS")))        GvSetD(p,"STATUS",0.0);
    if(!GlobalVariableCheck(GvKey(p,"OAG")))           GvSetD(p,"OAG",0.0);
    if(!GlobalVariableCheck(GvKey(p,"SCHED_LOT")))     GvSetD(p,"SCHED_LOT",0.0);
    if(!GlobalVariableCheck(GvKey(p,"TARGET")))        GvSetD(p,"TARGET",0.0);
    if(!GlobalVariableCheck(GvKey(p,"OPENGAP")))       GvSetD(p,"OPENGAP",0.0);

    if(!GlobalVariableCheck(GvKey(p,"OPENING")))           GvSetD(p,"OPENING",0.0);
    if(!GlobalVariableCheck(GvKey(p,"OPENING_SINCE_MS")))  GvSetD(p,"OPENING_SINCE_MS",0.0);
    // new hit-timer state
    if(!GlobalVariableCheck(GvKey(p,"OPEN_TIME_SEC")))   GvSetD(p,"OPEN_TIME_SEC",0.0);
    if(!GlobalVariableCheck(GvKey(p,"OAG_HIT_ACTIVE")))    GvSetD(p,"OAG_HIT_ACTIVE",0.0);
    if(!GlobalVariableCheck(GvKey(p,"OAG_HIT_SINCE_MS")))  GvSetD(p,"OAG_HIT_SINCE_MS",0.0);
    if(!GlobalVariableCheck(GvKey(p,"CAG_HIT_ACTIVE")))    GvSetD(p,"CAG_HIT_ACTIVE",0.0);
    if(!GlobalVariableCheck(GvKey(p,"CAG_HIT_SINCE_MS")))  GvSetD(p,"CAG_HIT_SINCE_MS",0.0);
  }
}

//====================== Init/Timer ======================//
int DetectMaxPairIdxFromPositions()
{
  int mx=0;
  for(int i=PositionsTotal()-1;i>=0;i--)
  {
    ulong tk=PositionGetTicket(i);
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

  trade.SetExpertMagicNumber(InpMagicNo);

  EnsureGVInit();

  BuildVisiblePairs();
  g_lastSig = VisibleSignature();

  DeleteUI();
  BuildUI();
  RefreshUITextOnly();

  int ms = InpRefreshMs;
  if(ms < 50) ms = 50;
  EventSetMillisecondTimer(ms);

  LogMsg("Initialized v2.82. MaxPairs=" + IntegerToString(g_maxPairs) +
         " OAGconfirm=" + IntegerToString(InpOagConfirmMs) +
         "ms CAGconfirm=" + IntegerToString(InpCagConfirmMs) + "ms");
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  EventKillTimer();
  DeleteUI();
  LogMsg("Deinitialized.");
}

void OnTimer()
{
   static bool inTick=false;
   if(inTick) return;
   inTick=true;
   // 1. ALWAYS Run Trade Logic (High Priority)
   ApplyAutoRules();
   // 2. Only rebuild UI structure if the list of active pairs changes
   BuildVisiblePairs();
   string sig = VisibleSignature();
   if(sig != g_lastSig)
   {
      g_lastSig = sig;
      DeleteUI();
      BuildUI();
   }
   // 3. Refresh the text (Prices/PL) - this is lighter than BuildUI
   RefreshUITextOnly();
   inTick=false;
}


//====================== Top input readers ======================//
double ReadTopLot()
{
  string s;
  double v = ReadEditNumber(g_prefix+"LOT_EDIT", s);
  WriteEditSanitized(g_prefix+"LOT_EDIT", s);
  if(v<=0) v=0.01;
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

void CancelSchedule(int p)
{
  GvSetD(p,"STATUS",0.0);
  GvSetD(p,"OAG",0.0);
  GvSetD(p,"SCHED_LOT",0.0);
  GvSetD(p,"TARGET",0.0);

  ResetHitTimers(p);
  SetOpeningLock(p,false);
}

//====================== Chart Events ======================//
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
  if(id!=CHARTEVENT_OBJECT_CLICK) return;
  if(StringFind(sparam,g_prefix)!=0) return;

  ResetBtn(sparam);

  // OPEN/SCHEDULE (top-down)
  if(sparam == g_prefix+"BTN_OPEN_SCHED")
  {
    double lot = ReadTopLot();
    double oag = ReadTopOAG();
    double cag = ReadTopCAG();   // ABS target, 0 disables

    int p = NextFreePairSlot();
    if(p<0) { LogMsg("No free slot available."); return; }

    // target is EXACTLY top CAG (abs). Never computed/shifted.
    GvSetD(p,"TARGET", cag);

    // ALWAYS reset timers when arming a new plan on a slot
    ResetHitTimers(p);

    if(oag==0.0)
    {
      // OPEN NOW
      GvSetD(p,"STATUS",0.0);
      GvSetD(p,"OAG",0.0);
      GvSetD(p,"SCHED_LOT",0.0);

      LogMsg(StringFormat("OPEN NOW: slot=%d lot=%s OAG=0 CAG=%s", p, F2(lot), F2(cag)));
      OpenPair(p, lot);
    }
    else
    {
      // SCHEDULE
      GvSetD(p,"OAG", oag);
      GvSetD(p,"SCHED_LOT", lot);
      GvSetD(p,"STATUS", 2.0);

      LogMsg(StringFormat("SCHEDULE: slot=%d lot=%s OAG=%s CAG=%s (confirm %dms)",
                          p, F2(lot), F2(oag), F2(cag), InpOagConfirmMs));
    }
    return;
  }

  if(sparam == g_prefix+"BTN_CLOSE_ALL")
  {
    for(int p=1; p<=g_maxPairs; p++)
    {
      int st = GetPairStatus(p);
      if(st==PSTATUS_LIVE || st==PSTATUS_BROKEN)
        ClosePair(p);
    }
    return;
  }

  // Per-row: UPDATE uses TOP CAG (abs). CLOSE cancels scheduled or closes live.
  for(int r=0;r<g_visibleN;r++)
  {
    string upd = g_prefix+"BTN_UPDATE_"+IntegerToString(r);
    string cls = g_prefix+"BTN_CLOSE_"+IntegerToString(r);

    int p = g_visiblePairs[r];

    if(sparam == upd)
    {
      double cag = ReadTopCAG(); // abs only
      GvSetD(p,"TARGET", cag);

      // safer: reset CAG timer so it must re-hold again at the new target
      GvSetD(p,"CAG_HIT_ACTIVE",0.0);
      GvSetD(p,"CAG_HIT_SINCE_MS",0.0);

      LogMsg(StringFormat("UPDATE CAG: pair=%d newCAG=%s (timer reset)", p, F2(cag)));
      return;
    }

    if(sparam == cls)
    {
      int st = GetPairStatus(p);
      if(st==PSTATUS_SCHED)
      {
        CancelSchedule(p);
        LogMsg(StringFormat("CANCEL SCHEDULE: pair=%d", p));
      }
      else if(st==PSTATUS_LIVE || st==PSTATUS_BROKEN)
      {
        ClosePair(p);
      }
      return;
    }
  }
}
//+------------------------------------------------------------------+