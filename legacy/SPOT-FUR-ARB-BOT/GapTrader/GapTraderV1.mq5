//+------------------------------------------------------------------+
//|                                                   PairGapEA.mq5   |
//|  Price-Gap Hedge EA (MT5) - PRICE GAP BASED                       |
//|                                                                    |
//|  GAP = Px(Symbol1) - Px(Symbol2)  [NO MID]                         |
//|                                                                    |
//|  Execution-aware GAP (recommended):                                |
//|   - SELL_ONLY (SELL S1 / BUY S2):  GAP = Bid1 - Ask2               |
//|   - BUY_ONLY  (BUY S1 / SELL S2):  GAP = Ask1 - Bid2               |
//|                                                                    |
//|  Robust Pair Handling:                                             |
//|   - Counts FULL pairs only (both legs exist)                       |
//|   - Auto-closes orphan legs                                        |
//|   - Min hold time before close                                     |
//|                                                                    |
//|  Logs + GAP display refresh every N seconds via OnTimer            |
//+------------------------------------------------------------------+
#property strict
#property version "2.30"

#include <Trade/Trade.mqh>
CTrade trade;

//====================== INPUTS ======================//
input long   InpMagicNo = 123;

enum ENUM_OPEN_DIR { DIR_BUY_ONLY=1, DIR_SELL_ONLY=2 };
input ENUM_OPEN_DIR InpOpenDirection = DIR_SELL_ONLY;

input string InpSymbol1 = "GC-J26";
input string InpSymbol2 = "XAUUSD";

input double InpInitialLot = 0.01;

enum ENUM_FIRST_SYMBOL { FIRST_SYMBOL1=0, FIRST_SYMBOL2=1 };
input ENUM_FIRST_SYMBOL InpSymbolToTradeFirstWhenOpening = FIRST_SYMBOL1;
input ENUM_FIRST_SYMBOL InpSymbolToCloseFirst            = FIRST_SYMBOL1;

input int    InpMaxSlippagePips = 1;
input bool   InpEnableTradeOnSameLevel = false;

input int    InpMinHoldMinutes = 0;       // Minimum hold before close
input bool   InpAutoCloseOrphans = true;  // Close orphan leg automatically

// logs + chart display refresh
input bool   InpEnableLogs        = true;
input bool   InpShowGapOnChart    = true;
input int    InpChartRefreshSec   = 2;    // update chart comment every N seconds (default 2)

//---------------- Slots (PRICE GAP UNITS) ----------------//
input int    InpNumberOfPairs1      = 1;
input double InpDifferenceToTrade1  = 22.0;
input double InpDifferenceToCut1    = 0.0;

input int    InpNumberOfPairs2      = 0;
input double InpDifferenceToTrade2  = 22.0;
input double InpDifferenceToCut2    = 0.0;

input int    InpNumberOfPairs3      = 0;
input double InpDifferenceToTrade3  = 0.0;
input double InpDifferenceToCut3    = 0.0;

input int    InpNumberOfPairs4      = 0;
input double InpDifferenceToTrade4  = 0.0;
input double InpDifferenceToCut4    = 0.0;

input int    InpNumberOfPairs5      = 0;
input double InpDifferenceToTrade5  = 0.0;
input double InpDifferenceToCut5    = 0.0;

input int    InpNumberOfPairs6      = 0;
input double InpDifferenceToTrade6  = 0.0;
input double InpDifferenceToCut6    = 0.0;

input int    InpNumberOfPairs7      = 0;
input double InpDifferenceToTrade7  = 0.0;
input double InpDifferenceToCut7    = 0.0;

//====================== STRUCT ======================//
struct SlotCfg
{
  int    pairs;
  double trade_level;
  double cut_level;
};

SlotCfg slots[7];
double  g_prevGap = 0.0;

//====================== LOGGING ======================//
void LogMsg(const string msg)
{
  if(InpEnableLogs)
    Print("[PairGapEA] ", msg);
}

//====================== HELPERS ======================//
int PipToPoints(string sym,int pips)
{
  int d=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
  return pips*((d==5||d==3)?10:1);
}

int SymDigitsSafe(string sym)
{
  int d=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
  if(d<=0) d=5;
  return d;
}

bool GetTickSafe(string sym,MqlTick &t)
{
  if(!SymbolSelect(sym,true)) return false;
  if(!SymbolInfoTick(sym,t))  return false;
  return (t.bid>0 && t.ask>0);
}

// PRICE GAP (NO MID) - execution-aware by direction
// SELL_ONLY: gap = Bid1 - Ask2
// BUY_ONLY : gap = Ask1 - Bid2
bool ComputeGap(double &gap, double &p1, double &p2)
{
  MqlTick t1,t2;
  if(!GetTickSafe(InpSymbol1,t1)) return false;
  if(!GetTickSafe(InpSymbol2,t2)) return false;

  if(InpOpenDirection==DIR_SELL_ONLY)
  {
    p1 = t1.bid; // SELL S1 at Bid
    p2 = t2.ask; // BUY  S2 at Ask
  }
  else
  {
    p1 = t1.ask; // BUY  S1 at Ask
    p2 = t2.bid; // SELL S2 at Bid
  }

  gap = p1 - p2;
  return true;
}

//====================== PAIR TRACKING ======================//
string MakeComment(int s,int p,string leg)
{
  return StringFormat("PAIR|SLOT=%d|PAIR=%d|LEG=%s",s+1,p,leg);
}

bool ParseComment(string c,int &s,int &p,string &leg)
{
  if(StringFind(c,"PAIR|SLOT=")!=0) return false;

  int a=StringFind(c,"SLOT=");
  int b=StringFind(c,"|PAIR=");
  int d=StringFind(c,"|LEG=");

  s=(int)StringToInteger(StringSubstr(c,a+5,b-(a+5)))-1;
  p=(int)StringToInteger(StringSubstr(c,b+6,d-(b+6)));
  leg=StringSubstr(c,d+5);

  return (s>=0 && s<7 && p>=1);
}

ulong FindTicket(int s,int p,string leg)
{
  for(int i=PositionsTotal()-1;i>=0;i--)
  {
    ulong tk=PositionGetTicket(i);
    if(!PositionSelectByTicket(tk)) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNo) continue;

    int ss,pp; string lg;
    if(ParseComment(PositionGetString(POSITION_COMMENT),ss,pp,lg))
      if(ss==s && pp==p && lg==leg) return tk;
  }
  return 0;
}

// FULL pairs only
int CountFullPairs(int s)
{
  int c=0;
  for(int p=1;p<=slots[s].pairs;p++)
    if(FindTicket(s,p,"S1")!=0 && FindTicket(s,p,"S2")!=0)
      c++;
  return c;
}

int NextFreePair(int s)
{
  for(int p=1;p<=slots[s].pairs;p++)
    if(FindTicket(s,p,"S1")==0 && FindTicket(s,p,"S2")==0)
      return p;
  return -1;
}

void HandleOrphans(int s)
{
  if(!InpAutoCloseOrphans) return;

  for(int p=1;p<=slots[s].pairs;p++)
  {
    ulong a=FindTicket(s,p,"S1");
    ulong b=FindTicket(s,p,"S2");

    if(a!=0 && b==0)
    {
      LogMsg(StringFormat("Orphan detected SLOT=%d PAIR=%d -> closing S1 ticket=%I64u", s+1, p, a));
      trade.SetExpertMagicNumber(InpMagicNo);
      trade.PositionClose(a);
    }
    if(b!=0 && a==0)
    {
      LogMsg(StringFormat("Orphan detected SLOT=%d PAIR=%d -> closing S2 ticket=%I64u", s+1, p, b));
      trade.SetExpertMagicNumber(InpMagicNo);
      trade.PositionClose(b);
    }
  }
}

//====================== TRADE ======================//
bool OpenLeg(string sym,ENUM_ORDER_TYPE type,double lot,string cmt)
{
  MqlTick t; if(!GetTickSafe(sym,t)) { LogMsg("OpenLeg tick missing for "+sym); return false; }

  trade.SetExpertMagicNumber(InpMagicNo);
  trade.SetDeviationInPoints(PipToPoints(sym,InpMaxSlippagePips));
  trade.SetTypeFillingBySymbol(sym);

  bool ok = (type==ORDER_TYPE_BUY)?
            trade.Buy(lot,sym,t.ask,0,0,cmt):
            trade.Sell(lot,sym,t.bid,0,0,cmt);

  if(!ok)
    LogMsg(StringFormat("OpenLeg FAILED sym=%s type=%s lot=%.4f ret=%d (%s)",
                        sym,
                        (type==ORDER_TYPE_BUY?"BUY":"SELL"),
                        lot,
                        (int)trade.ResultRetcode(),
                        trade.ResultRetcodeDescription()));
  else
    LogMsg(StringFormat("OpenLeg OK sym=%s type=%s lot=%.4f",
                        sym, (type==ORDER_TYPE_BUY?"BUY":"SELL"), lot));

  return ok;
}

bool OpenPair(int s,int p)
{
  ENUM_ORDER_TYPE t1,t2;
  if(InpOpenDirection==DIR_SELL_ONLY)
  { t1=ORDER_TYPE_SELL; t2=ORDER_TYPE_BUY; }
  else
  { t1=ORDER_TYPE_BUY;  t2=ORDER_TYPE_SELL; }

  LogMsg(StringFormat("OpenPair SLOT=%d PAIR=%d (S1=%s, S2=%s)",
                      s+1, p,
                      (t1==ORDER_TYPE_BUY?"BUY":"SELL"),
                      (t2==ORDER_TYPE_BUY?"BUY":"SELL")));

  if(InpSymbolToTradeFirstWhenOpening==FIRST_SYMBOL1)
  {
    if(!OpenLeg(InpSymbol1,t1,InpInitialLot,MakeComment(s,p,"S1"))) return false;
    if(!OpenLeg(InpSymbol2,t2,InpInitialLot,MakeComment(s,p,"S2")))
    {
      LogMsg("Second leg failed -> rolling back first leg");
      trade.SetExpertMagicNumber(InpMagicNo);
      trade.PositionClose(FindTicket(s,p,"S1"));
      return false;
    }
  }
  else
  {
    if(!OpenLeg(InpSymbol2,t2,InpInitialLot,MakeComment(s,p,"S2"))) return false;
    if(!OpenLeg(InpSymbol1,t1,InpInitialLot,MakeComment(s,p,"S1")))
    {
      LogMsg("Second leg failed -> rolling back first leg");
      trade.SetExpertMagicNumber(InpMagicNo);
      trade.PositionClose(FindTicket(s,p,"S2"));
      return false;
    }
  }
  return true;
}

bool CanClose(int s,int p)
{
  if(InpMinHoldMinutes<=0) return true;

  ulong a=FindTicket(s,p,"S1"), b=FindTicket(s,p,"S2");
  if(a==0||b==0) return false;

  datetime now=TimeCurrent();

  if(!PositionSelectByTicket(a)) return false;
  datetime t1=(datetime)PositionGetInteger(POSITION_TIME);

  if(!PositionSelectByTicket(b)) return false;
  datetime t2=(datetime)PositionGetInteger(POSITION_TIME);

  long need=(long)InpMinHoldMinutes*60L;
  return ((now-t1)>=need && (now-t2)>=need);
}

void ClosePair(int s,int p)
{
  if(!CanClose(s,p)) return;

  ulong a=FindTicket(s,p,"S1"), b=FindTicket(s,p,"S2");
  if(a==0||b==0) return;

  LogMsg(StringFormat("ClosePair SLOT=%d PAIR=%d", s+1, p));

  trade.SetExpertMagicNumber(InpMagicNo);

  if(InpSymbolToCloseFirst==FIRST_SYMBOL1)
  {
    if(!trade.PositionClose(a))
      LogMsg(StringFormat("Close S1 failed ticket=%I64u ret=%d (%s)", a, (int)trade.ResultRetcode(), trade.ResultRetcodeDescription()));
    if(!trade.PositionClose(b))
      LogMsg(StringFormat("Close S2 failed ticket=%I64u ret=%d (%s)", b, (int)trade.ResultRetcode(), trade.ResultRetcodeDescription()));
  }
  else
  {
    if(!trade.PositionClose(b))
      LogMsg(StringFormat("Close S2 failed ticket=%I64u ret=%d (%s)", b, (int)trade.ResultRetcode(), trade.ResultRetcodeDescription()));
    if(!trade.PositionClose(a))
      LogMsg(StringFormat("Close S1 failed ticket=%I64u ret=%d (%s)", a, (int)trade.ResultRetcode(), trade.ResultRetcodeDescription()));
  }
}

//====================== LOAD SLOTS ======================//
void LoadSlots()
{
  slots[0].pairs=InpNumberOfPairs1; slots[0].trade_level=InpDifferenceToTrade1; slots[0].cut_level=InpDifferenceToCut1;
  slots[1].pairs=InpNumberOfPairs2; slots[1].trade_level=InpDifferenceToTrade2; slots[1].cut_level=InpDifferenceToCut2;
  slots[2].pairs=InpNumberOfPairs3; slots[2].trade_level=InpDifferenceToTrade3; slots[2].cut_level=InpDifferenceToCut3;
  slots[3].pairs=InpNumberOfPairs4; slots[3].trade_level=InpDifferenceToTrade4; slots[3].cut_level=InpDifferenceToCut4;
  slots[4].pairs=InpNumberOfPairs5; slots[4].trade_level=InpDifferenceToTrade5; slots[4].cut_level=InpDifferenceToCut5;
  slots[5].pairs=InpNumberOfPairs6; slots[5].trade_level=InpDifferenceToTrade6; slots[5].cut_level=InpDifferenceToCut6;
  slots[6].pairs=InpNumberOfPairs7; slots[6].trade_level=InpDifferenceToTrade7; slots[6].cut_level=InpDifferenceToCut7;
}

//====================== CHART DISPLAY (timer-driven) ======================//
void UpdateChartEveryNSeconds()
{
  if(!InpShowGapOnChart) return;

  double gap, p1, p2;
  if(!ComputeGap(gap, p1, p2))
  {
    Comment("PairGapEA\nWaiting for ticks / symbols...\nS1: ", InpSymbol1, "\nS2: ", InpSymbol2);
    return;
  }

  string dir = (InpOpenDirection==DIR_SELL_ONLY) ? "SELL_ONLY (SELL S1 / BUY S2)" : "BUY_ONLY (BUY S1 / SELL S2)";
  string txt;

  int d1 = SymDigitsSafe(InpSymbol1);
  int d2 = SymDigitsSafe(InpSymbol2);

  txt  = "PairGapEA v2.30\n";
  txt += "Dir: " + dir + "\n\n";
  txt += "S1: " + InpSymbol1 + "  Px=" + DoubleToString(p1, d1) + "\n";
  txt += "S2: " + InpSymbol2 + "  Px=" + DoubleToString(p2, d2) + "\n\n";
  txt += "GAP (S1-S2): " + DoubleToString(gap, 5) + "\n";
  txt += "PrevGap: " + DoubleToString(g_prevGap, 5) + "\n\n";

  for(int s=0; s<7; s++)
  {
    if(slots[s].pairs<=0) continue;
    int openFull = CountFullPairs(s);
    txt += StringFormat("Slot %d | Open %d/%d | Trade %.5f | Cut %.5f\n",
                        s+1, openFull, slots[s].pairs, slots[s].trade_level, slots[s].cut_level);
  }

  Comment(txt);
}

//====================== EVENTS ======================//
int OnInit()
{
  LoadSlots();

  int sec = (InpChartRefreshSec <= 0) ? 2 : InpChartRefreshSec;
  EventSetTimer(sec);

  double gap, p1, p2;
  if(ComputeGap(gap, p1, p2)) g_prevGap = gap;

  LogMsg("Initialized. Chart refresh every " + IntegerToString(sec) + " seconds.");
  LogMsg("Symbols: S1=" + InpSymbol1 + " | S2=" + InpSymbol2);

  UpdateChartEveryNSeconds();

  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  EventKillTimer();
  Comment("");
  LogMsg("Deinitialized.");
}

void OnTimer()
{
  UpdateChartEveryNSeconds();
}

void OnTick()
{
  double gap, p1, p2;
  if(!ComputeGap(gap, p1, p2)) return;

  for(int s=0;s<7;s++)
  {
    if(slots[s].pairs<=0) continue;

    HandleOrphans(s);

    int open=CountFullPairs(s);

    // CLOSE: gap <= cut_level
    if(open>0 && gap<=slots[s].cut_level)
    {
      LogMsg(StringFormat("CLOSE signal slot=%d gap=%.5f <= cut=%.5f", s+1, gap, slots[s].cut_level));
      for(int p=1;p<=slots[s].pairs;p++) ClosePair(s,p);
    }

    // OPEN: gap >= trade_level
    if(gap>=slots[s].trade_level && open<slots[s].pairs)
    {
      if(!InpEnableTradeOnSameLevel &&
         !(g_prevGap<slots[s].trade_level || gap>g_prevGap))
      {
        continue; // gated to avoid repeated opens at same level
      }

      int p=NextFreePair(s);
      if(p>0)
      {
        LogMsg(StringFormat("OPEN signal slot=%d pair=%d gap=%.5f >= trade=%.5f",
                            s+1, p, gap, slots[s].trade_level));
        OpenPair(s,p);
      }
    }
  }

  g_prevGap=gap;
}
//+------------------------------------------------------------------+
