//+------------------------------------------------------------------+
//|                                      PairGapEA_UITradePanel.mq5   |
//|  UI panel to OPEN/CLOSE pair trades (max 5) + show GAP (NO MID)   |
//|  - Execution-aware GAP (NO MID):                                  |
//|      SELL_ONLY: Bid1 - Ask2                                       |
//|      BUY_ONLY : Ask1 - Bid2                                       |
//|  - UI: lot input, OPEN NEXT, CLOSE ALL, CLOSE 1..N                |
//|  - Pair status table: Pair | Lot | S1 | S2 | P/L                  |
//|  - Dynamic layout + millisecond refresh                           |
//+------------------------------------------------------------------+
#property strict
#property version "1.20"

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

input int    InpMaxPairs       = 5;      // hard-capped to 5
input int    InpRefreshMs      = 200;    // UI refresh in milliseconds (e.g. 50..500)
input int    InpSlippagePips   = 1;

input bool   InpEnableLogs     = true;

//====================== UI CONFIG ======================//
input int    UI_X = 10;
input int    UI_Y = 10;
input int    UI_W = 420;
input int    UI_H = 280;

//====================== UI COLORS (INPUT) ======================//
// Panel / text
input color  InpColPanelBG       = (color)0x202020;
input color  InpColTitleText     = clrWhite;
input color  InpColInfoText      = clrWhite;
input color  InpColGapText       = clrAqua;
input color  InpColOpenText      = clrWhite;

// Buttons
input color  InpColBtnOpenBG     = (color)0x2E7D32;
input color  InpColBtnCloseAllBG = (color)0xB71C1C;
input color  InpColBtnPairBG     = (color)0x455A64;
input color  InpColBtnText       = clrWhite;
input color  InpColBtnBorder     = clrBlack;

// Edit
input color  InpColEditText      = clrBlack;
input color  InpColEditBG        = clrWhite;
input color  InpColEditBorder    = clrGray;

// Status
input color  InpColStatusProfit  = clrLime;
input color  InpColStatusLoss    = clrRed;
input color  InpColStatusIdle    = clrSilver;

//====================== GLOBALS ======================//
int    g_maxPairs = 5;
string g_prefix   = "PGUI_";
double g_lastGap  = 0.0;

//====================== LOG ======================//
void LogMsg(const string s){ if(InpEnableLogs) Print("[PGUI] ", s); }

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

int SymDigitsSafe(string sym)
{
  int d=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
  if(d<=0) d=5;
  return d;
}

// execution-aware GAP (NO MID)
bool ComputeGap(double &gap, double &p1, double &p2)
{
  MqlTick t1,t2;
  if(!GetTickSafe(InpSymbol1,t1)) return false;
  if(!GetTickSafe(InpSymbol2,t2)) return false;

  if(InpOpenDirection==DIR_SELL_ONLY)
  {
    p1 = t1.bid; // SELL S1 @ Bid
    p2 = t2.ask; // BUY  S2 @ Ask
  }
  else
  {
    p1 = t1.ask; // BUY  S1 @ Ask
    p2 = t2.bid; // SELL S2 @ Bid
  }
  gap = p1 - p2;
  return true;
}

//====================== PAIR TRACKING ======================//
string MakeComment(int pairIdx,string leg)
{
  return StringFormat("PAIR|IDX=%d|LEG=%s", pairIdx, leg);
}

bool ParseComment(string c,int &pairIdx,string &leg)
{
  if(StringFind(c,"PAIR|IDX=")!=0) return false;

  int a=StringFind(c,"IDX=");
  int b=StringFind(c,"|LEG=");
  if(a<0||b<0) return false;

  pairIdx=(int)StringToInteger(StringSubstr(c,a+4,b-(a+4)));
  leg=StringSubstr(c,b+5);
  return (pairIdx>=1 && pairIdx<=g_maxPairs);
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

bool PairIsFull(int pairIdx)
{
  return (FindTicket(pairIdx,"S1")!=0 && FindTicket(pairIdx,"S2")!=0);
}

int CountFullPairs()
{
  int c=0;
  for(int p=1;p<=g_maxPairs;p++) if(PairIsFull(p)) c++;
  return c;
}

int NextFreePair()
{
  for(int p=1;p<=g_maxPairs;p++)
    if(FindTicket(p,"S1")==0 && FindTicket(p,"S2")==0) return p;
  return -1;
}

// pair status helpers
double GetPairProfit(int pairIdx)
{
  double pl = 0.0;
  for(int i=PositionsTotal()-1;i>=0;i--)
  {
    ulong tk=PositionGetTicket(i);
    if(!PositionSelectByTicket(tk)) continue;
    if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNo) continue;

    int p; string lg;
    if(ParseComment(PositionGetString(POSITION_COMMENT),p,lg))
      if(p==pairIdx)
        pl += PositionGetDouble(POSITION_PROFIT);
  }
  return pl;
}

double GetPairLot(int pairIdx)
{
  ulong a = FindTicket(pairIdx,"S1");
  if(a==0) return 0.0;
  if(!PositionSelectByTicket(a)) return 0.0;
  return PositionGetDouble(POSITION_VOLUME);
}

//====================== TRADING ======================//
bool OpenLeg(string sym,ENUM_ORDER_TYPE type,double lot,string cmt)
{
  MqlTick t; if(!GetTickSafe(sym,t)) { LogMsg("Tick missing for "+sym); return false; }

  trade.SetExpertMagicNumber(InpMagicNo);
  trade.SetDeviationInPoints(PipToPoints(sym,InpSlippagePips));
  trade.SetTypeFillingBySymbol(sym);

  bool ok = (type==ORDER_TYPE_BUY) ? trade.Buy(lot,sym,t.ask,0,0,cmt)
                                  : trade.Sell(lot,sym,t.bid,0,0,cmt);

  if(!ok)
    LogMsg(StringFormat("OpenLeg FAIL %s %s lot=%.2f ret=%d (%s)",
                        sym,(type==ORDER_TYPE_BUY?"BUY":"SELL"),lot,
                        (int)trade.ResultRetcode(),trade.ResultRetcodeDescription()));
  return ok;
}

bool OpenPair(int pairIdx,double lot)
{
  if(pairIdx<1 || pairIdx>g_maxPairs) return false;
  if(PairIsFull(pairIdx)) { LogMsg("Pair already open: "+IntegerToString(pairIdx)); return false; }

  ENUM_ORDER_TYPE t1,t2;
  if(InpOpenDirection==DIR_SELL_ONLY) { t1=ORDER_TYPE_SELL; t2=ORDER_TYPE_BUY; }
  else                                { t1=ORDER_TYPE_BUY;  t2=ORDER_TYPE_SELL; }

  LogMsg(StringFormat("OPEN Pair #%d lot=%.2f", pairIdx, lot));

  if(InpSymbolToTradeFirstWhenOpening==FIRST_SYMBOL1)
  {
    if(!OpenLeg(InpSymbol1,t1,lot,MakeComment(pairIdx,"S1"))) return false;
    if(!OpenLeg(InpSymbol2,t2,lot,MakeComment(pairIdx,"S2")))
    {
      LogMsg("Second leg failed -> rollback first leg");
      trade.SetExpertMagicNumber(InpMagicNo);
      ulong a=FindTicket(pairIdx,"S1");
      if(a!=0) trade.PositionClose(a);
      return false;
    }
  }
  else
  {
    if(!OpenLeg(InpSymbol2,t2,lot,MakeComment(pairIdx,"S2"))) return false;
    if(!OpenLeg(InpSymbol1,t1,lot,MakeComment(pairIdx,"S1")))
    {
      LogMsg("Second leg failed -> rollback first leg");
      trade.SetExpertMagicNumber(InpMagicNo);
      ulong b=FindTicket(pairIdx,"S2");
      if(b!=0) trade.PositionClose(b);
      return false;
    }
  }
  return true;
}

void ClosePair(int pairIdx)
{
  ulong a=FindTicket(pairIdx,"S1");
  ulong b=FindTicket(pairIdx,"S2");
  if(a==0 && b==0) return;

  trade.SetExpertMagicNumber(InpMagicNo);
  LogMsg(StringFormat("CLOSE Pair #%d", pairIdx));

  if(InpSymbolToCloseFirst==FIRST_SYMBOL1)
  {
    if(a!=0) trade.PositionClose(a);
    if(b!=0) trade.PositionClose(b);
  }
  else
  {
    if(b!=0) trade.PositionClose(b);
    if(a!=0) trade.PositionClose(a);
  }
}

void CloseAllPairs()
{
  for(int p=1;p<=g_maxPairs;p++) ClosePair(p);
}

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

bool CreateButton(string name,int x,int y,int w,int h,string txt,color bg)
{
  if(!ObjectCreate(0,name,OBJ_BUTTON,0,0,0)) return false;
  ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
  ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
  ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
  ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
  ObjectSetInteger(0,name,OBJPROP_COLOR,InpColBtnText);
  ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
  ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,InpColBtnBorder);
  ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
  ObjectSetString (0,name,OBJPROP_TEXT,txt);
  ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  return true;
}

bool CreateEdit(string name,int x,int y,int w,int h,string txt)
{
  if(!ObjectCreate(0,name,OBJ_EDIT,0,0,0)) return false;
  ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
  ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
  ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
  ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
  ObjectSetInteger(0,name,OBJPROP_COLOR,InpColEditText);
  ObjectSetInteger(0,name,OBJPROP_BGCOLOR,InpColEditBG);
  ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,InpColEditBorder);
  ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
  ObjectSetString (0,name,OBJPROP_TEXT,txt);
  ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  return true;
}

void SetText(const string name,const string txt){ ObjectSetString(0,name,OBJPROP_TEXT,txt); }

double GetLotFromUI()
{
  string n = g_prefix + "LOT_EDIT";
  string s = ObjectGetString(0,n,OBJPROP_TEXT);
  double lot = StringToDouble(s);
  if(lot<=0) lot = 0.01;
  return lot;
}

//====================== UI LAYOUT ======================//
int PADDING(){ return 10; }

void BuildUI()
{
  int pad = PADDING();

  // dynamic heights based on rows
  // rows: header+symbols+dir+gap+prices+controls+closeButtons+statusHeader+statusRows
  // We'll rely on UI_H input, but layout is calculated and won't overlap.

  CreateRect(g_prefix+"PANEL", UI_X, UI_Y, UI_W, UI_H, InpColPanelBG);

  int x0 = UI_X + pad;
  int y  = UI_Y + 6;

  CreateLabel(g_prefix+"TITLE", x0, y, "PairGap UI (max 5 pairs) - NO MID", 11, InpColTitleText);
  y += 20;

  CreateLabel(g_prefix+"SYMS", x0, y, "S1: "+InpSymbol1+"  |  S2: "+InpSymbol2, 10, InpColInfoText);
  y += 16;

  string dir = (InpOpenDirection==DIR_SELL_ONLY) ? "SELL_ONLY (Bid1-Ask2)" : "BUY_ONLY (Ask1-Bid2)";
  CreateLabel(g_prefix+"DIR", x0, y, "Dir: "+dir, 10, InpColInfoText);
  y += 22;

  CreateLabel(g_prefix+"GAP", x0, y, "GAP: --", 14, InpColGapText);
  y += 22;

  CreateLabel(g_prefix+"PRICES", x0, y, "P1: --   P2: --", 10, InpColInfoText);

  // Open count on same line (right side)
  CreateLabel(g_prefix+"OPEN", UI_X + UI_W - pad - 120, y, "Open: 0/5", 10, InpColOpenText);
  y += 26;

  // Controls row
  CreateLabel(g_prefix+"LOT_LBL", x0, y+4, "Lot:", 10, InpColInfoText);
  CreateEdit (g_prefix+"LOT_EDIT", x0+40, y, 70, 22, DoubleToString(0.01,2));

  int btnH = 26;
  int btnW = 95;
  int btnY = y - 2;

  CreateButton(g_prefix+"BTN_OPEN_NEXT", x0+130, btnY, btnW, btnH, "OPEN NEXT", InpColBtnOpenBG);
  CreateButton(g_prefix+"BTN_CLOSE_ALL", x0+130+btnW+10, btnY, btnW, btnH, "CLOSE ALL", InpColBtnCloseAllBG);

  y += 40;

  // Close buttons row (dynamic sizing to avoid overflow)
  int gap = 6;
  int totalGap = gap * (g_maxPairs-1);
  int availW = UI_W - 2*pad - totalGap;
  int bw = (g_maxPairs>0) ? (availW / g_maxPairs) : 60;
  if(bw < 60) bw = 60;
  int bh = 26;

  for(int i=1;i<=g_maxPairs;i++)
  {
    int bx = x0 + (i-1)*(bw+gap);
    CreateButton(g_prefix+"BTN_CLOSE_P"+IntegerToString(i), bx, y, bw, bh, "CLOSE "+IntegerToString(i), InpColBtnPairBG);
  }

  y += bh + 16;

  // Status header + rows
  CreateLabel(g_prefix+"STAT_HDR", x0, y, "PAIR STATUS (Open Positions)", 10, InpColInfoText);
  y += 16;

  for(int i=1;i<=g_maxPairs;i++)
  {
    CreateLabel(g_prefix+"STAT_"+IntegerToString(i),
                x0,
                y + (i-1)*16,
                "PAIR "+IntegerToString(i)+" | --",
                9,
                InpColStatusIdle);
  }
}

void DeleteUI()
{
  ObjDel(g_prefix+"PANEL");
  ObjDel(g_prefix+"TITLE");
  ObjDel(g_prefix+"SYMS");
  ObjDel(g_prefix+"DIR");
  ObjDel(g_prefix+"GAP");
  ObjDel(g_prefix+"PRICES");
  ObjDel(g_prefix+"OPEN");
  ObjDel(g_prefix+"LOT_LBL");
  ObjDel(g_prefix+"LOT_EDIT");
  ObjDel(g_prefix+"BTN_OPEN_NEXT");
  ObjDel(g_prefix+"BTN_CLOSE_ALL");
  ObjDel(g_prefix+"STAT_HDR");

  for(int i=1;i<=5;i++)
  {
    ObjDel(g_prefix+"BTN_CLOSE_P"+IntegerToString(i));
    ObjDel(g_prefix+"STAT_"+IntegerToString(i));
  }
}

//====================== UI REFRESH ======================//
void RefreshUI()
{
  // GAP/Prices
  double gap,p1,p2;
  if(!ComputeGap(gap,p1,p2))
  {
    SetText(g_prefix+"GAP","GAP: waiting ticks...");
    SetText(g_prefix+"PRICES","P1: --   P2: --");
  }
  else
  {
    int d1=SymDigitsSafe(InpSymbol1);
    int d2=SymDigitsSafe(InpSymbol2);

    SetText(g_prefix+"GAP","GAP: "+DoubleToString(gap,5));
    SetText(g_prefix+"PRICES",
            "P1: "+DoubleToString(p1,d1)+"   P2: "+DoubleToString(p2,d2));

    g_lastGap = gap;
  }

  // Open count
  int open=CountFullPairs();
  SetText(g_prefix+"OPEN", StringFormat("Open: %d/%d", open, g_maxPairs));

  // Pair status rows
  for(int i=1;i<=g_maxPairs;i++)
  {
    string nm = g_prefix+"STAT_"+IntegerToString(i);

    if(!PairIsFull(i))
    {
      SetText(nm, "PAIR "+IntegerToString(i)+" | --");
      ObjectSetInteger(0,nm,OBJPROP_COLOR,InpColStatusIdle);
      continue;
    }

    double lot = GetPairLot(i);
    double pl  = GetPairProfit(i);

    string row = StringFormat("PAIR %d | LOT %.2f | %s | %s | P/L: %.2f",
                              i, lot, InpSymbol1, InpSymbol2, pl);

    SetText(nm, row);
    ObjectSetInteger(0,nm,OBJPROP_COLOR, (pl>=0.0)?InpColStatusProfit:InpColStatusLoss);
  }

  ChartRedraw(0);
}

//====================== EVENTS ======================//
int OnInit()
{
  g_maxPairs = InpMaxPairs;
  if(g_maxPairs > 5) g_maxPairs = 5;
  if(g_maxPairs < 1) g_maxPairs = 1;

  trade.SetExpertMagicNumber(InpMagicNo);

  DeleteUI();     // safety if reattached
  BuildUI();

  int ms = InpRefreshMs;
  if(ms < 20) ms = 20;        // safety (too fast can lag terminal)
  EventSetMillisecondTimer(ms);

  RefreshUI();

  LogMsg("Initialized UI. MaxPairs=" + IntegerToString(g_maxPairs) +
         " RefreshMs=" + IntegerToString(ms));
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  EventKillTimer();
  DeleteUI();
  Comment("");
  LogMsg("Deinitialized.");
}

void OnTimer()
{
  RefreshUI();
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
  if(id!=CHARTEVENT_OBJECT_CLICK) return;
  if(StringFind(sparam,g_prefix)!=0) return;

  double lot = GetLotFromUI();

  if(sparam == g_prefix+"BTN_OPEN_NEXT")
  {
    int p = NextFreePair();
    if(p<0) { LogMsg("No free pair slot available (max reached)."); return; }
    OpenPair(p, lot);
    RefreshUI();
    return;
  }

  if(sparam == g_prefix+"BTN_CLOSE_ALL")
  {
    CloseAllPairs();
    RefreshUI();
    return;
  }

  for(int i=1;i<=g_maxPairs;i++)
  {
    if(sparam == g_prefix+"BTN_CLOSE_P"+IntegerToString(i))
    {
      ClosePair(i);
      RefreshUI();
      return;
    }
  }
}
//+------------------------------------------------------------------+
