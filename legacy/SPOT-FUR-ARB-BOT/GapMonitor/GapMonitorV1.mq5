//+------------------------------------------------------------------+
//|                                       GapMonitorEA_TableUI.mq5    |
//|  PRICE GAP Window Monitor (MT5)                                   |
//|  GAP = Symbol1 - Symbol2 (PRICE BASED)  [NO MID]                   |
//|                                                                    |
//|  Execution-aware GAP (recommended):                                |
//|   - SELL_ONLY (SELL S1 / BUY S2):  GAP = Bid1 - Ask2               |
//|   - BUY_ONLY  (BUY S1 / SELL S2):  GAP = Ask1 - Bid2               |
//|                                                                    |
//|  UI: Fixed top-left bordered table panel                           |
//|   - True table: labels + cell backgrounds                          |
//|   - Border + grid lines + zebra rows                               |
//|   - Uses ARGB backgrounds (ColorToARGB)                            |
//|   - Updates every N seconds (OnTimer)                              |
//+------------------------------------------------------------------+
#property strict
#property version "3.10"

//==================== SYMBOLS ====================//
input string InpSymbol1 = "GC-J26";
input string InpSymbol2 = "XAUUSD";

//==================== GAP DIRECTION ====================//
enum ENUM_OPEN_DIR { DIR_BUY_ONLY=1, DIR_SELL_ONLY=2 };
input ENUM_OPEN_DIR InpOpenDirection = DIR_SELL_ONLY;

//==================== UPDATE / LOG ====================//
input int    InpRefreshSec = 2;
input bool   InpEnableLogs = false;

//==================== WINDOW CONFIG ====================//
enum ENUM_WIN_UNIT { UNIT_MINUTES=0, UNIT_HOURS=1 };

input bool          W1_Enable = true;
input ENUM_WIN_UNIT W1_Unit   = UNIT_HOURS;
input int           W1_Value  = 1;

input bool          W2_Enable = true;
input ENUM_WIN_UNIT W2_Unit   = UNIT_HOURS;
input int           W2_Value  = 2;

input bool          W3_Enable = true;
input ENUM_WIN_UNIT W3_Unit   = UNIT_HOURS;
input int           W3_Value  = 4;

input bool          W4_Enable = false;
input ENUM_WIN_UNIT W4_Unit   = UNIT_MINUTES;
input int           W4_Value  = 30;

input bool          W5_Enable = false;
input ENUM_WIN_UNIT W5_Unit   = UNIT_MINUTES;
input int           W5_Value  = 15;

input bool          W6_Enable = false;
input ENUM_WIN_UNIT W6_Unit   = UNIT_HOURS;
input int           W6_Value  = 6;

input bool          W7_Enable = false;
input ENUM_WIN_UNIT W7_Unit   = UNIT_HOURS;
input int           W7_Value  = 12;

input bool          W8_Enable = false;
input ENUM_WIN_UNIT W8_Unit   = UNIT_HOURS;
input int           W8_Value  = 24;

input bool          W9_Enable = false;
input ENUM_WIN_UNIT W9_Unit   = UNIT_MINUTES;
input int           W9_Value  = 5;

input bool          W10_Enable = false;
input ENUM_WIN_UNIT W10_Unit   = UNIT_MINUTES;
input int           W10_Value  = 10;

//==================== TABLE UI SETTINGS ====================//
input bool   UI_EnablePanel     = true;
input int    UI_XOffset         = 10;
input int    UI_YOffset         = 25;

input int    UI_Width           = 520;
input bool   UI_AutoHeight      = true;
input int    UI_HeightFixed     = 240;

input string UI_FontName        = "Consolas";
input int    UI_FontSize        = 10;

input color  UI_BgColor         = clrBlack;
input int    UI_BgAlpha         = 170;

input color  UI_TextColor       = clrWhite;
input color  UI_HeaderTextColor = clrAqua;

input color  UI_BorderColor     = clrSilver;
input int    UI_BorderAlpha     = 220;

input color  UI_GridColor       = clrDimGray;
input int    UI_GridAlpha       = 180;

input color  UI_HeaderBg        = clrBlack;
input int    UI_HeaderBgAlpha   = 210;

input color  UI_RowAltBg        = clrBlack;
input int    UI_RowAltBgAlpha   = 110;

input bool   UI_ShowSymbols      = true;
input bool   UI_ShowMidPrices    = false;  // kept for compatibility; now shows Px1/Px2 (NO MID)
input bool   UI_ShowCurrentHour  = true;
input int    UI_PrecisionDigits  = 2;

//====================== INTERNAL STRUCTS ======================//
struct GapSample { datetime ts; double gap; };
struct WinCfg    { bool enable; int seconds; string label; };

GapSample samples[];
WinCfg     windows[];
int        g_maxWindowSeconds = 60;

// current hour tracking
int      g_currHourKey = -1;
double   g_currHourMax = -DBL_MAX;
double   g_currHourMin =  DBL_MAX;

// latest values
double   g_lastGap = 0.0;
double   g_px1=0.0, g_px2=0.0;

//====================== LOG ======================//
void LogMsg(const string s){ if(InpEnableLogs) Print("[GapMonitorEA_TableUI] ", s); }

//====================== SYMBOL / GAP ======================//
bool EnsureSymbol(const string sym){ return SymbolSelect(sym,true); }

bool GetTickSafe(const string sym, MqlTick &t)
{
  if(!EnsureSymbol(sym)) return false;
  if(!SymbolInfoTick(sym,t)) return false;
  return (t.bid>0 && t.ask>0);
}

// Execution-aware gap (NO MID)
// SELL_ONLY => SELL S1 at Bid1, BUY S2 at Ask2 => gap = Bid1 - Ask2
// BUY_ONLY  => BUY  S1 at Ask1, SELL S2 at Bid2 => gap = Ask1 - Bid2
bool ComputeGap(double &gap, double &px1, double &px2)
{
  MqlTick t1,t2;
  if(!GetTickSafe(InpSymbol1,t1)) return false;
  if(!GetTickSafe(InpSymbol2,t2)) return false;

  if(InpOpenDirection==DIR_SELL_ONLY)
  {
    px1 = t1.bid;
    px2 = t2.ask;
  }
  else
  {
    px1 = t1.ask;
    px2 = t2.bid;
  }

  gap = px1 - px2;
  return true;
}

//====================== WINDOWS ======================//
int UnitValueToSeconds(const ENUM_WIN_UNIT unit, int val)
{
  if(val<=0) val=1;
  return (unit==UNIT_MINUTES) ? val*60 : val*3600;
}

string MakeLabel(const ENUM_WIN_UNIT unit, int val)
{
  if(val<=0) val=1;
  return (unit==UNIT_MINUTES) ? StringFormat("%dm", val) : StringFormat("%dh", val);
}

void AddWindow(const bool enable, const ENUM_WIN_UNIT unit, const int val)
{
  WinCfg w;
  w.enable  = enable;
  w.seconds = UnitValueToSeconds(unit,val);
  w.label   = MakeLabel(unit,val);

  int n=ArraySize(windows);
  ArrayResize(windows,n+1);
  windows[n]=w;

  if(enable && w.seconds>g_maxWindowSeconds)
    g_maxWindowSeconds=w.seconds;
}

void BuildWindows()
{
  ArrayResize(windows,0);
  g_maxWindowSeconds = 60;

  AddWindow(W1_Enable,  W1_Unit,  W1_Value);
  AddWindow(W2_Enable,  W2_Unit,  W2_Value);
  AddWindow(W3_Enable,  W3_Unit,  W3_Value);
  AddWindow(W4_Enable,  W4_Unit,  W4_Value);
  AddWindow(W5_Enable,  W5_Unit,  W5_Value);
  AddWindow(W6_Enable,  W6_Unit,  W6_Value);
  AddWindow(W7_Enable,  W7_Unit,  W7_Value);
  AddWindow(W8_Enable,  W8_Unit,  W8_Value);
  AddWindow(W9_Enable,  W9_Unit,  W9_Value);
  AddWindow(W10_Enable, W10_Unit, W10_Value);

  LogMsg("Windows built. MaxWindowSeconds=" + IntegerToString(g_maxWindowSeconds));
}

//====================== SAMPLES ======================//
void AddSample(datetime ts, double gap)
{
  int n=ArraySize(samples);
  ArrayResize(samples,n+1);
  samples[n].ts  = ts;
  samples[n].gap = gap;
}

void PruneOld(datetime now)
{
  datetime cutoff = now - g_maxWindowSeconds;
  int n=ArraySize(samples);
  if(n<=0) return;

  int start=0;
  while(start<n && samples[start].ts < cutoff) start++;

  if(start>0)
  {
    int newN = n-start;
    GapSample tmp[];
    ArrayResize(tmp,newN);
    for(int i=0;i<newN;i++) tmp[i]=samples[start+i];
    ArrayResize(samples,newN);
    for(int i=0;i<newN;i++) samples[i]=tmp[i];
  }
}

bool WindowStats(datetime now, int seconds, double &maxGap, double &minGap)
{
  datetime cutoff = now - seconds;
  maxGap = -DBL_MAX;
  minGap =  DBL_MAX;

  bool found=false;
  int n=ArraySize(samples);
  for(int i=n-1;i>=0;i--)
  {
    if(samples[i].ts < cutoff) break;
    double g = samples[i].gap;
    if(g>maxGap) maxGap=g;
    if(g<minGap) minGap=g;
    found=true;
  }
  return found;
}

//====================== CURRENT HOUR ======================//
int HourKey(datetime t)
{
  MqlDateTime dt; TimeToStruct(t,dt);
  return (dt.year*1000000 + dt.mon*10000 + dt.day*100 + dt.hour);
}

void UpdateCurrentHour(datetime now, double gap)
{
  int hk = HourKey(now);
  if(hk != g_currHourKey)
  {
    g_currHourKey = hk;
    g_currHourMax = gap;
    g_currHourMin = gap;
  }
  else
  {
    if(gap > g_currHourMax) g_currHourMax = gap;
    if(gap < g_currHourMin) g_currHourMin = gap;
  }
}

//====================== UI HELPERS (BORDERED TABLE) ======================//
string UI_PREFIX = "GM_";

void RemoveUI_All()
{
  int total = ObjectsTotal(0,0,-1);
  for(int i=total-1;i>=0;i--)
  {
    string name = ObjectName(0,i,0,-1);
    if(StringFind(name, UI_PREFIX) == 0)
      ObjectDelete(0,name);
  }
}

color ARGB(color c, int a)
{
  if(a<0) a=0; if(a>255) a=255;
  return ColorToARGB(c,(uchar)a);
}

bool EnsureRect(const string name, int x, int y, int w, int h, color fill, bool back=false)
{
  if(ObjectFind(0,name)<0)
  {
    if(!ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0))
      return false;
  }
  ObjectSetInteger(0,name,OBJPROP_CORNER, CORNER_LEFT_UPPER);
  ObjectSetInteger(0,name,OBJPROP_XDISTANCE, x);
  ObjectSetInteger(0,name,OBJPROP_YDISTANCE, y);
  ObjectSetInteger(0,name,OBJPROP_XSIZE, w);
  ObjectSetInteger(0,name,OBJPROP_YSIZE, h);
  ObjectSetInteger(0,name,OBJPROP_COLOR, fill);
  ObjectSetInteger(0,name,OBJPROP_BACK, back);
  ObjectSetInteger(0,name,OBJPROP_SELECTABLE, false);
  ObjectSetInteger(0,name,OBJPROP_HIDDEN, false);
  return true;
}

bool EnsureLabel(const string name, int x, int y, string text, color txtColor, int fontSize=-1, string fontName="")
{
  if(ObjectFind(0,name)<0)
  {
    if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0))
      return false;
  }
  ObjectSetInteger(0,name,OBJPROP_CORNER, CORNER_LEFT_UPPER);
  ObjectSetInteger(0,name,OBJPROP_XDISTANCE, x);
  ObjectSetInteger(0,name,OBJPROP_YDISTANCE, y);

  ObjectSetString(0,name,OBJPROP_TEXT, text);
  ObjectSetInteger(0,name,OBJPROP_COLOR, txtColor);

  ObjectSetString(0,name,OBJPROP_FONT, (fontName=="")?UI_FontName:fontName);
  ObjectSetInteger(0,name,OBJPROP_FONTSIZE, (fontSize>0)?fontSize:UI_FontSize);

  ObjectSetInteger(0,name,OBJPROP_SELECTABLE, false);
  ObjectSetInteger(0,name,OBJPROP_HIDDEN, false);
  return true;
}

string Fmt(double v){ return DoubleToString(v, UI_PrecisionDigits); }

int EnabledWindowCount()
{
  int c=0;
  for(int i=0;i<ArraySize(windows);i++) if(windows[i].enable) c++;
  return c;
}

int CalcPanelHeight_PX()
{
  int lineH = UI_FontSize + 8;
  int lines = 0;

  lines += 1; // title
  if(UI_ShowSymbols)     lines += 1;
  if(UI_ShowMidPrices)   lines += 1; // now prices row
  lines += 1; // gap
  if(UI_ShowCurrentHour) lines += 1;

  lines += 1; // spacing
  lines += 1; // header row
  lines += MathMax(1, EnabledWindowCount());

  int padding = 18 + 16;
  int h = lines*lineH + padding;
  if(h < 170) h = 170;
  return h;
}

bool RenderPanel(datetime now)
{
  if(!UI_EnablePanel) return true;

  int panelX = UI_XOffset;
  int panelY = UI_YOffset;
  int panelW = UI_Width;
  int panelH = UI_AutoHeight ? CalcPanelHeight_PX() : UI_HeightFixed;

  if(!EnsureRect(UI_PREFIX+"PANEL_BG", panelX, panelY, panelW, panelH, ARGB(UI_BgColor, UI_BgAlpha), false))
    return false;

  int b = 1;
  color border = ARGB(UI_BorderColor, UI_BorderAlpha);
  EnsureRect(UI_PREFIX+"B_TOP", panelX, panelY, panelW, b, border, false);
  EnsureRect(UI_PREFIX+"B_BOT", panelX, panelY+panelH-b, panelW, b, border, false);
  EnsureRect(UI_PREFIX+"B_LFT", panelX, panelY, b, panelH, border, false);
  EnsureRect(UI_PREFIX+"B_RGT", panelX+panelW-b, panelY, b, panelH, border, false);

  int padL = 12;
  int padT = 10;
  int lineH = UI_FontSize + 8;

  int x = panelX + padL;
  int y = panelY + padT;

  string dirTxt = (InpOpenDirection==DIR_SELL_ONLY) ? "SELL_ONLY (Bid1-Ask2)" : "BUY_ONLY (Ask1-Bid2)";
  EnsureLabel(UI_PREFIX+"TITLE", x, y, "GAP MONITOR (Price)  " + dirTxt, UI_HeaderTextColor, UI_FontSize+1);
  y += lineH;

  if(UI_ShowSymbols)
  {
    EnsureLabel(UI_PREFIX+"SYM", x, y, StringFormat("S1: %s   |   S2: %s", InpSymbol1, InpSymbol2), UI_TextColor);
    y += lineH;
  }

  if(UI_ShowMidPrices)
  {
    EnsureLabel(UI_PREFIX+"MID", x, y, StringFormat("Px1: %s   |   Px2: %s", Fmt(g_px1), Fmt(g_px2)), UI_TextColor);
    y += lineH;
  }

  EnsureLabel(UI_PREFIX+"GAP", x, y, StringFormat("Gap:  %s", Fmt(g_lastGap)), UI_TextColor);
  y += lineH;

  if(UI_ShowCurrentHour)
  {
    EnsureLabel(UI_PREFIX+"HOUR", x, y, StringFormat("Hour Max: %s   |   Hour Min: %s", Fmt(g_currHourMax), Fmt(g_currHourMin)), UI_TextColor);
    y += lineH;
  }

  y += 6;

  int tableX = panelX + 10;
  int tableY = y;
  int tableW = panelW - 20;

  int col0 = 90;
  int col1 = (tableW - col0) / 2;
  int col2 = tableW - col0 - col1;

  int rowH = lineH;

  EnsureRect(UI_PREFIX+"TH_BG", tableX, tableY, tableW, rowH, ARGB(UI_HeaderBg, UI_HeaderBgAlpha), false);
  EnsureLabel(UI_PREFIX+"TH0", tableX + 8,               tableY + 2, "Window", UI_HeaderTextColor);
  EnsureLabel(UI_PREFIX+"TH1", tableX + col0 + 8,        tableY + 2, "Max",    UI_HeaderTextColor);
  EnsureLabel(UI_PREFIX+"TH2", tableX + col0 + col1 + 8, tableY + 2, "Min",    UI_HeaderTextColor);

  color grid = ARGB(UI_GridColor, UI_GridAlpha);
  int bodyRows = rowH * MathMax(1, EnabledWindowCount());
  EnsureRect(UI_PREFIX+"V1", tableX + col0,          tableY, 1, rowH + bodyRows, grid, false);
  EnsureRect(UI_PREFIX+"V2", tableX + col0 + col1,   tableY, 1, rowH + bodyRows, grid, false);
  EnsureRect(UI_PREFIX+"H0", tableX, tableY + rowH, tableW, 1, grid, false);

  int wn = ArraySize(windows);

  int visibleRows = 0;
  for(int i=0;i<wn;i++) if(windows[i].enable) visibleRows++;

  if(visibleRows <= 0)
  {
    int ry = tableY + rowH;
    EnsureRect(UI_PREFIX+"RBG_0", tableX, ry, tableW, rowH, ARGB(UI_RowAltBg, UI_RowAltBgAlpha), false);
    EnsureLabel(UI_PREFIX+"R0C0", tableX+8, ry+2, "-", UI_TextColor);
    EnsureLabel(UI_PREFIX+"R0C1", tableX+col0+8, ry+2, "-", UI_TextColor);
    EnsureLabel(UI_PREFIX+"R0C2", tableX+col0+col1+8, ry+2, "-", UI_TextColor);
    EnsureRect(UI_PREFIX+"HROW_0", tableX, ry + rowH, tableW, 1, grid, false);
    return true;
  }

  int rIndex = 0;
  for(int i=0;i<wn;i++)
  {
    if(!windows[i].enable) continue;

    int ry = tableY + rowH*(1 + rIndex);

    bool alt = ((rIndex % 2)==1);
    color rowBg = alt ? ARGB(UI_RowAltBg, UI_RowAltBgAlpha) : ARGB(UI_BgColor, UI_BgAlpha);
    EnsureRect(UI_PREFIX+StringFormat("RBG_%d", rIndex), tableX, ry, tableW, rowH, rowBg, false);

    double maxG,minG;
    bool ok = WindowStats(now, windows[i].seconds, maxG, minG);

    string sW   = windows[i].label;
    string sMax = ok ? Fmt(maxG) : "-";
    string sMin = ok ? Fmt(minG) : "-";

    EnsureLabel(UI_PREFIX+StringFormat("R%dC0", rIndex), tableX + 8, ry + 2, sW, UI_TextColor);

    int cellChars = 14;
    string pMax = (StringLen(sMax) < cellChars) ? StringFormat("%*s", cellChars, sMax) : sMax;
    string pMin = (StringLen(sMin) < cellChars) ? StringFormat("%*s", cellChars, sMin) : sMin;

    EnsureLabel(UI_PREFIX+StringFormat("R%dC1", rIndex), tableX + col0 + 8,        ry + 2, pMax, UI_TextColor);
    EnsureLabel(UI_PREFIX+StringFormat("R%dC2", rIndex), tableX + col0 + col1 + 8, ry + 2, pMin, UI_TextColor);

    EnsureRect(UI_PREFIX+StringFormat("HROW_%d", rIndex), tableX, ry + rowH, tableW, 1, grid, false);

    rIndex++;
  }

  // delete leftovers if rows reduced
  for(int k=rIndex;k<10;k++)
  {
    ObjectDelete(0, UI_PREFIX+StringFormat("RBG_%d", k));
    ObjectDelete(0, UI_PREFIX+StringFormat("R%dC0", k));
    ObjectDelete(0, UI_PREFIX+StringFormat("R%dC1", k));
    ObjectDelete(0, UI_PREFIX+StringFormat("R%dC2", k));
    ObjectDelete(0, UI_PREFIX+StringFormat("HROW_%d", k));
  }

  return true;
}

//====================== UPDATE LOOP ======================//
void UpdateAll()
{
  if(!UI_EnablePanel) return;

  datetime now = TimeCurrent();
  double gap,px1,px2;

  if(!ComputeGap(gap,px1,px2))
  {
    g_lastGap = 0; g_px1=0; g_px2=0;
    RenderPanel(now);
    EnsureLabel(UI_PREFIX+"WARN", UI_XOffset+12, UI_YOffset+40, "Waiting for ticks... Check Market Watch symbols.", clrTomato);
    return;
  }

  ObjectDelete(0, UI_PREFIX+"WARN");

  g_lastGap = gap; g_px1=px1; g_px2=px2;

  AddSample(now, gap);
  PruneOld(now);
  UpdateCurrentHour(now, gap);

  RenderPanel(now);
}

//====================== EVENTS ======================//
int OnInit()
{
  if(!EnsureSymbol(InpSymbol1) || !EnsureSymbol(InpSymbol2))
  {
    Print("ERROR: Symbol not available in Market Watch. Check exact names.");
    return INIT_FAILED;
  }

  BuildWindows();

  int sec = (InpRefreshSec<=0) ? 2 : InpRefreshSec;
  EventSetTimer(sec);

  UpdateAll();
  Print("GapMonitorEA_TableUI initialized.");
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  EventKillTimer();
  RemoveUI_All();
}

void OnTimer()
{
  UpdateAll();
}

void OnTick()
{
  // add extra samples on tick for better high/low accuracy
  datetime now = TimeCurrent();
  double gap,px1,px2;
  if(!ComputeGap(gap,px1,px2)) return;

  g_lastGap = gap; g_px1=px1; g_px2=px2;
  AddSample(now, gap);
  PruneOld(now);
  UpdateCurrentHour(now, gap);
}
//+------------------------------------------------------------------+
