//+------------------------------------------------------------------+
//| GapRadar_Pro_EA.mq5                                              |
//| v3.20 - PERFORMANCE REWORK                                       |
//| - Sample fast / compute stats slow (throttled)                   |
//| - No per-window array allocations (WinAgg scan)                  |
//| - Quantiles via ONE scratch array (no repeated allocs)           |
//| - Per-window cache (avoid recompute on every render)             |
//| - UI text caching (no ObjectGetString in hot loops)              |
//| - Telegram polling ms-throttle (skip JSON work unless due)       |
//+------------------------------------------------------------------+
#property strict
#property version   "3.20"

//====================== INPUTS ======================//
input string InpSymbol1 = "GCJ26.ma";
input string InpSymbol2 = "XAUUSD.pp";

enum ENUM_GAP_DIR { GAP_SELL_ONLY=1, GAP_BUY_ONLY=2 };
input ENUM_GAP_DIR InpGapDir = GAP_SELL_ONLY;

input int  InpSampleMs       = 250;
input int  InpHistoryMinutes = 12*60;
input int  InpMaxSamples     = 8000;

input int InpStatsMinMs = 900;     // compute stats at most once per this interval
input int InpTeleMinMs  = 1500;    // poll telegram at most once per this interval

input int    InpRenderMinMs      = 900;
input double InpGapDeltaToRender = 0.03;

//==================== TELEGRAM SETTINGS ====================//
input bool   InpTeleEnable         = true;
// IMPORTANT: don't hardcode real bot tokens in code you share.
// Rotate token in BotFather if this was ever exposed.
input string InpTeleToken          = "8653099152:AAGi_1ZhUdglhVwyCk_8oOboWOdpoJMxb1o";
input int    InpTelePollSec        = 5;
input double InpZThreshold         = 2.0;
input int    InpTeleCooldownSec    = 300;

input string InpTeleAllowedChatIDs  = "957548787;7771695878;5865942099";
input bool   InpTelePollCommands    = true;

//==================== TELEGRAM DEFAULTS ====================//
#define TELE_DEFAULT_ALERTS_ON   false
#define TELE_DEFAULT_WINDOW_IX   0
#define TELE_DEFAULT_ZTHRESH     2.0
#define TELE_DEFAULT_COOLDOWN    300

//==================== WINDOW CONFIG ====================//
enum ENUM_WIN_UNIT { UNIT_MINUTES=0, UNIT_HOURS=1 };

input bool          W1_Enable = true;
input ENUM_WIN_UNIT W1_Unit   = UNIT_MINUTES;
input double        W1_Value  = 1.0;

input bool          W2_Enable = true;
input ENUM_WIN_UNIT W2_Unit   = UNIT_HOURS;
input double        W2_Value  = 5.0;

input bool          W3_Enable = true;
input ENUM_WIN_UNIT W3_Unit   = UNIT_MINUTES;
input double        W3_Value  = 15.0;

input bool          W4_Enable = true;
input ENUM_WIN_UNIT W4_Unit   = UNIT_MINUTES;
input double        W4_Value  = 30.0;

input bool          W5_Enable = true;
input ENUM_WIN_UNIT W5_Unit   = UNIT_MINUTES;
input double        W5_Value  = 45.0;

input bool          W6_Enable = true;
input ENUM_WIN_UNIT W6_Unit   = UNIT_HOURS;
input double        W6_Value  = 1.0;

input bool          W7_Enable = true;
input ENUM_WIN_UNIT W7_Unit   = UNIT_HOURS;
input double        W7_Value  = 2.0;

input bool          W8_Enable = true;
input ENUM_WIN_UNIT W8_Unit   = UNIT_HOURS;
input double        W8_Value  = 4.0;

input bool          W9_Enable = false;
input ENUM_WIN_UNIT W9_Unit   = UNIT_HOURS;
input double        W9_Value  = 8.0;

input bool          W10_Enable = false;
input ENUM_WIN_UNIT W10_Unit   = UNIT_HOURS;
input double        W10_Value  = 12.0;

input bool          W11_Enable = false;
input ENUM_WIN_UNIT W11_Unit   = UNIT_HOURS;
input double        W11_Value  = 16.0;

input bool          W12_Enable = false;
input ENUM_WIN_UNIT W12_Unit   = UNIT_HOURS;
input double        W12_Value  = 20.0;

// Which window index to use for headline & alerts
input int InpActiveWindowIx = 0;

//==================== UI ====================//
input bool UI_AutoSize  = true;
input int  UI_X         = 10;
input int  UI_Y         = 10;
input int  UI_W         = 1050;
input int  UI_H         = 540;
input int  UI_Pad       = 10;

input string UI_Font      = "Consolas";
input int    UI_FontTitle = 20;
input int    UI_FontBase  = 14;
input int    UI_FontSmall = 12;

//==================== COLORS ====================//
input color  ColPanelBG     = clrWhite;
input color  ColBorder      = clrSilver;
input color  ColTitle       = clrRed;
input color  ColInfo        = clrBlack;
input color  ColMuted       = clrDimGray;
input color  ColHeaderBG    = clrGainsboro;
input color  ColRowAltBG    = (color)0xF2F2F2;
input color  ColTabOnBG     = (color)0xD8E9FF;
input color  ColTabOffBG    = clrGainsboro;
input color  ColGood        = clrGreen;
input color  ColWarn        = clrDarkOrange;
input color  ColBad         = clrCrimson;

//====================== GLOBALS ======================//
string g_prefix="GRPEA_";

enum ENUM_TAB { TAB_WINDOWS=0, TAB_STATS=1, TAB_QUANTS=2, TAB_PLAN=3 };
int g_tab = TAB_WINDOWS;

int    g_winMins[];
string g_winLabels[];
int    g_activeWindowIx = 0;

long   g_ts[];
double g_gap[];
double g_mid1[];
double g_mid2[];
int    g_cap=0, g_head=0, g_count=0;

bool   g_dirty=true;
ulong  g_lastRenderMs=0;
double g_lastRenderedGap=0.0;
bool   g_hasRenderedGap=false;

double g_lastGap=0.0, g_lastP1=0.0, g_lastP2=0.0, g_lastM1=0.0, g_lastM2=0.0;
bool   g_haveTick=false;

// stats throttles
ulong g_lastStatsMs = 0;

// telegram polling state
long     g_tgUpdateOffset = 0;
datetime g_lastTelePollTime = 0;
ulong    g_lastTeleMs = 0;

// alert state (global headline only; per-user is in TeleUser)
datetime g_lastAlertTime = 0;
bool     g_isAlertActive = false;
bool     g_alertsEnabled = true;
double   g_runtimeZThreshold = 0.0;

// layout
int g_gridColsBuilt = -1;
int g_gridRowsBuilt = -1;
int g_gridTabBuilt  = -1;
int g_gridContentWBuilt = -1;

bool g_needsRedraw = false;

int g_panelX=0, g_panelY=0, g_panelW=0, g_panelH=0;
int g_contentX=0, g_contentY=0, g_contentW=0, g_contentH=0;
int g_tableX=0, g_tableY=0, g_tableW=0, g_tableH=0;
int g_rowH=26;
int g_colW[];
int g_cols=0;
int g_rows=0;
int g_lastChartW=0, g_lastChartH=0;

//====================== UTILS ======================//
ulong NowMs(){ return GetTickCount64(); }
int  IMin(int a,int b){ return (a<b?a:b); }
int  IMax(int a,int b){ return (a>b?a:b); }

string F2(double v){ return DoubleToString(v,2); }
string F3(double v){ return DoubleToString(v,3); }
string F4(double v){ return DoubleToString(v,4); }

bool StartsWith(const string s, const string pref)
{
   return (StringLen(s)>=StringLen(pref) && StringSubstr(s,0,StringLen(pref))==pref);
}

void QuickSortD(double &a[], int left, int right)
{
   int i = left, j = right;
   double pivot = a[(left + right) >> 1];

   while(i <= j)
   {
      while(a[i] < pivot) i++;
      while(a[j] > pivot) j--;

      if(i <= j)
      {
         double tmp = a[i];
         a[i] = a[j];
         a[j] = tmp;
         i++; j--;
      }
   }
   if(left < j)  QuickSortD(a, left, j);
   if(i < right) QuickSortD(a, i, right);
}

string TrimStr(string s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
}

bool GetTickSafe(const string sym, MqlTick &t)
{
   if(!SymbolSelect(sym,true)) return false;
   if(!SymbolInfoTick(sym,t))  return false;
   return (t.bid>0 && t.ask>0);
}

string DirText()
{
   return (InpGapDir==GAP_SELL_ONLY) ? "SELL_ONLY (Bid1-Ask2)" : "BUY_ONLY (Ask1-Bid2)";
}

//====================== WINDOW HELPERS ======================//
struct WinAgg
{
   int    n;
   double minG, maxG;

   // for mean/std (Welford)
   double meanG, m2G;

   // for corr(m1,m2)
   double mean1, mean2, c11, c22, c12;

   // for slope (gap vs time in minutes)
   double sx, sy, sxx, sxy;
   double t0;
   bool   hasT0;
};

void WinAggInit(WinAgg &a)
{
   a.n=0;
   a.minG=0; a.maxG=0;
   a.meanG=0; a.m2G=0;
   a.mean1=0; a.mean2=0; a.c11=0; a.c22=0; a.c12=0;
   a.sx=0; a.sy=0; a.sxx=0; a.sxy=0;
   a.t0=0; a.hasT0=false;
}

void WinAggAdd(WinAgg &a, const long ts_ms, const double gap, const double m1, const double m2)
{
   if(a.n==0){ a.minG=gap; a.maxG=gap; }
   else      { a.minG=MathMin(a.minG,gap); a.maxG=MathMax(a.maxG,gap); }

   a.n++;
   // Welford for gap
   double d = gap - a.meanG;
   a.meanG += d / a.n;
   a.m2G   += d * (gap - a.meanG);

   // online covariance for corr
   double d1 = m1 - a.mean1; a.mean1 += d1 / a.n;
   double d2 = m2 - a.mean2; a.mean2 += d2 / a.n;
   a.c11 += d1 * (m1 - a.mean1);
   a.c22 += d2 * (m2 - a.mean2);
   a.c12 += d1 * (m2 - a.mean2);

   // slope sums: x minutes since first sample
   double tmin = (double)ts_ms / 60000.0;
   if(!a.hasT0){ a.t0=tmin; a.hasT0=true; }
   double x = tmin - a.t0;
   a.sx  += x;
   a.sy  += gap;
   a.sxx += x*x;
   a.sxy += x*gap;
}

bool RingGetByAge(const int age,long &ts_ms,double &gap,double &m1,double &m2); // forward

bool ScanWindowAgg(const int window_minutes, WinAgg &outAgg)
{
   WinAggInit(outAgg);
   if(g_count<=0 || g_cap<=0) return false;

   long now = (long)NowMs();
   long cutoff = now - (long)window_minutes*60L*1000L;

   for(int age=0; age<g_count; age++)
   {
      long ts; double gp,m1,m2;
      if(!RingGetByAge(age,ts,gp,m1,m2)) break;
      if(ts < cutoff) break;
      WinAggAdd(outAgg, ts, gp, m1, m2);
   }
   return (outAgg.n >= 3);
}

double WinAggStd(const WinAgg &a)
{
   if(a.n <= 1) return 0.0;
   return MathSqrt(a.m2G / (a.n - 1));
}

bool WinAggCorr(const WinAgg &a, double &corr)
{
   if(a.n <= 2) return false;
   if(a.c11<=0 || a.c22<=0) return false;
   corr = a.c12 / MathSqrt(a.c11 * a.c22);
   return true;
}

bool WinAggSlope(const WinAgg &a, double &slope)
{
   if(a.n <= 2) return false;
   double denom = a.n*a.sxx - a.sx*a.sx;
   if(MathAbs(denom) < 1e-12) return false;
   slope = (a.n*a.sxy - a.sx*a.sy) / denom;
   return true;
}

int UnitValueToMinutes(const ENUM_WIN_UNIT unit, double val)
{
   if(val<=0.0) val=1.0;
   double mins = (unit==UNIT_MINUTES) ? val : (val*60.0);
   int out=(int)MathRound(mins);
   if(out<1) out=1;
   return out;
}

string NumToCleanStr(double v)
{
   if(MathAbs(v - MathRound(v)) < 0.0000001)
      return IntegerToString((int)MathRound(v));

   string s = DoubleToString(v,2);
   while(StringLen(s)>0 && StringSubstr(s,StringLen(s)-1,1)=="0")
      s = StringSubstr(s,0,StringLen(s)-1);
   if(StringLen(s)>0 && StringSubstr(s,StringLen(s)-1,1)==".")
      s = StringSubstr(s,0,StringLen(s)-1);
   return s;
}

string BuildWindowLabel(const ENUM_WIN_UNIT unit, double val, int mins)
{
   if(unit==UNIT_HOURS) return NumToCleanStr(val)+"H";
   return IntegerToString(mins)+"m";
}

void AddWinMinutes(bool enable, ENUM_WIN_UNIT unit, double val, int &tmpMins[], string &tmpLabels[])
{
   if(!enable) return;
   int m = UnitValueToMinutes(unit,val);
   if(m<=0) return;

   for(int i=0;i<ArraySize(tmpMins);i++)
      if(tmpMins[i]==m) return;

   int n=ArraySize(tmpMins);
   ArrayResize(tmpMins,n+1);
   ArrayResize(tmpLabels,n+1);
   tmpMins[n]=m;
   tmpLabels[n]=BuildWindowLabel(unit,val,m);
}

void SortWindowsAscending(int &mins[], string &labels[])
{
   int n=ArraySize(mins);
   for(int i=0;i<n-1;i++)
   {
      for(int j=i+1;j<n;j++)
      {
         if(mins[j] < mins[i])
         {
            int tm=mins[i]; mins[i]=mins[j]; mins[j]=tm;
            string ts=labels[i]; labels[i]=labels[j]; labels[j]=ts;
         }
      }
   }
}

bool BuildWindowsFromInputs()
{
   int tmpMins[];
   string tmpLabels[];
   ArrayResize(tmpMins,0);
   ArrayResize(tmpLabels,0);

   AddWinMinutes(W1_Enable,W1_Unit,W1_Value,tmpMins,tmpLabels);
   AddWinMinutes(W2_Enable,W2_Unit,W2_Value,tmpMins,tmpLabels);
   AddWinMinutes(W3_Enable,W3_Unit,W3_Value,tmpMins,tmpLabels);
   AddWinMinutes(W4_Enable,W4_Unit,W4_Value,tmpMins,tmpLabels);
   AddWinMinutes(W5_Enable,W5_Unit,W5_Value,tmpMins,tmpLabels);
   AddWinMinutes(W6_Enable,W6_Unit,W6_Value,tmpMins,tmpLabels);
   AddWinMinutes(W7_Enable,W7_Unit,W7_Value,tmpMins,tmpLabels);
   AddWinMinutes(W8_Enable,W8_Unit,W8_Value,tmpMins,tmpLabels);
   AddWinMinutes(W9_Enable,W9_Unit,W9_Value,tmpMins,tmpLabels);
   AddWinMinutes(W10_Enable,W10_Unit,W10_Value,tmpMins,tmpLabels);
   AddWinMinutes(W11_Enable,W11_Unit,W11_Value,tmpMins,tmpLabels);
   AddWinMinutes(W12_Enable,W12_Unit,W12_Value,tmpMins,tmpLabels);

   if(ArraySize(tmpMins)<=0)
   {
      ArrayResize(g_winMins,1);
      ArrayResize(g_winLabels,1);
      g_winMins[0]=60;
      g_winLabels[0]="1H";
   }
   else
   {
      SortWindowsAscending(tmpMins,tmpLabels);
      ArrayResize(g_winMins,ArraySize(tmpMins));
      ArrayResize(g_winLabels,ArraySize(tmpLabels));
      for(int i=0;i<ArraySize(tmpMins);i++)
      {
         g_winMins[i]=tmpMins[i];
         g_winLabels[i]=tmpLabels[i];
      }
   }

   g_activeWindowIx = InpActiveWindowIx;
   if(g_activeWindowIx<0) g_activeWindowIx=0;
   if(g_activeWindowIx>=ArraySize(g_winMins)) g_activeWindowIx=ArraySize(g_winMins)-1;
   return true;
}

int MaxWindowMinutes()
{
   int mx=60;
   for(int i=0;i<ArraySize(g_winMins);i++)
      if(g_winMins[i]>mx) mx=g_winMins[i];
   return mx;
}

string WindowLabelByIndex(int ix)
{
   if(ix<0 || ix>=ArraySize(g_winLabels)) return "--";
   return g_winLabels[ix];
}

//====================== GAP CALC ======================//
bool ComputeGap(double &gap,double &p1,double &p2,double &m1,double &m2)
{
   MqlTick t1,t2;
   if(!GetTickSafe(InpSymbol1,t1)) return false;
   if(!GetTickSafe(InpSymbol2,t2)) return false;

   m1 = 0.5*(t1.bid+t1.ask);
   m2 = 0.5*(t2.bid+t2.ask);

   if(InpGapDir==GAP_SELL_ONLY){ p1=t1.bid; p2=t2.ask; }
   else                        { p1=t1.ask; p2=t2.bid; }

   gap = p1 - p2;
   return true;
}

//====================== RING BUFFER ======================//
void RingInit()
{
   int maxWin=60;
   if(ArraySize(g_winMins)>0) maxWin=MaxWindowMinutes();

   int histMins = MathMax(InpHistoryMinutes, maxWin+5);
   double perMin = 60000.0 / (double)MathMax(InpSampleMs,50);
   int cap = (int)MathCeil((double)histMins * perMin) + 10;

   cap = MathMax(400, cap);
   cap = MathMin(InpMaxSamples, cap);

   g_cap=cap;
   ArrayResize(g_ts,g_cap);
   ArrayResize(g_gap,g_cap);
   ArrayResize(g_mid1,g_cap);
   ArrayResize(g_mid2,g_cap);
   g_head=0;
   g_count=0;
}

void RingPush(const long ts_ms,const double gap,const double m1,const double m2)
{
   if(g_cap<=0) return;
   g_ts[g_head]=ts_ms;
   g_gap[g_head]=gap;
   g_mid1[g_head]=m1;
   g_mid2[g_head]=m2;
   g_head=(g_head+1)%g_cap;
   if(g_count<g_cap) g_count++;
}

bool RingGetByAge(const int age,long &ts_ms,double &gap,double &m1,double &m2)
{
   if(age<0 || age>=g_count || g_cap<=0) return false;
   int idx=g_head-1-age;
   while(idx<0) idx+=g_cap;
   idx%=g_cap;
   ts_ms=g_ts[idx];
   gap  =g_gap[idx];
   m1   =g_mid1[idx];
   m2   =g_mid2[idx];
   return true;
}

//====================== QUANTILES (ONE SCRATCH ARRAY) ======================//
double g_qScratch[]; // sized to g_cap once

int FillWindowGaps(const int window_minutes, double &out[])
{
   if(g_count<=0 || g_cap<=0) return 0;

   long now=(long)NowMs();
   long cutoff=now-(long)window_minutes*60L*1000L;

   int n=0;
   int capOut = ArraySize(out);
   for(int age=0; age<g_count; age++)
   {
      long ts; double gp,m1,m2;
      if(!RingGetByAge(age,ts,gp,m1,m2)) break;
      if(ts<cutoff) break;
      if(n>=capOut) break;
      out[n++] = gp;
   }
   return n;
}

double PercentileSorted(const double &a[], const int n, double q)
{
   if(n<=0) return 0.0;
   if(q<0) q=0;
   if(q>1) q=1;

   double pos=q*(n-1);
   int lo=(int)MathFloor(pos);
   int hi=(int)MathCeil(pos);
   if(lo<0) lo=0;
   if(hi>n-1) hi=n-1;

   if(lo==hi) return a[lo];
   double w=pos-lo;
   return a[lo]*(1.0-w) + a[hi]*w;
}

//====================== PER-WINDOW CACHE ======================//
struct WinCache
{
   ulong  statsMs;   // last computed stats time
   ulong  quantsMs;  // last computed quantiles time
   int    winMins;
   int    n;

   // stats
   double minG,maxG,meanG,stdG,corr,slope;

   // quantiles
   bool   hasQuants;
   double p10,p25,p50,p75,p90;
};

WinCache g_cache[];

// Ensure cache arrays match windows
void CacheInit()
{
   int n=ArraySize(g_winMins);
   ArrayResize(g_cache,n);
   for(int i=0;i<n;i++)
   {
      g_cache[i].statsMs=0;
      g_cache[i].quantsMs=0;
      g_cache[i].winMins=g_winMins[i];
      g_cache[i].n=0;

      g_cache[i].minG=0; g_cache[i].maxG=0;
      g_cache[i].meanG=0; g_cache[i].stdG=0;
      g_cache[i].corr=0; g_cache[i].slope=0;

      g_cache[i].hasQuants=false;
      g_cache[i].p10=g_cache[i].p25=g_cache[i].p50=g_cache[i].p75=g_cache[i].p90=0.0;
   }
}

// compute stats for one window if stale
bool EnsureStatsForWindow(const int ix, const bool force=false)
{
   if(ix<0 || ix>=ArraySize(g_cache)) return false;

   ulong now=NowMs();
   if(!force && g_cache[ix].statsMs>0 && (now - g_cache[ix].statsMs) < (ulong)MathMax(InpStatsMinMs,100))
      return (g_cache[ix].n>=3);

   // if window minutes changed (shouldn't, but safe)
   g_cache[ix].winMins = g_winMins[ix];

   WinAgg a;
   if(!ScanWindowAgg(g_cache[ix].winMins,a))
   {
      g_cache[ix].n=0;
      g_cache[ix].statsMs=now;
      // don't clear quants here; they might still be shown (but typically stale). keep as-is.
      return false;
   }

   g_cache[ix].n = a.n;
   g_cache[ix].minG = a.minG;
   g_cache[ix].maxG = a.maxG;
   g_cache[ix].meanG = a.meanG;
   g_cache[ix].stdG  = WinAggStd(a);

   double c=0,s=0;
   if(!WinAggCorr(a,c)) c=0;
   if(!WinAggSlope(a,s)) s=0;
   g_cache[ix].corr=c;
   g_cache[ix].slope=s;

   g_cache[ix].statsMs=now;
   return true;
}

// compute quantiles for one window if stale
bool EnsureQuantsForWindow(const int ix, const bool force=false)
{
   if(ix<0 || ix>=ArraySize(g_cache)) return false;

   ulong now=NowMs();
   if(!force && g_cache[ix].hasQuants && g_cache[ix].quantsMs>0 && (now - g_cache[ix].quantsMs) < (ulong)MathMax(InpStatsMinMs,100))
      return (g_cache[ix].n>=3);

   int winMins = g_winMins[ix];

   if(ArraySize(g_qScratch) != g_cap) ArrayResize(g_qScratch, g_cap);

   int n = FillWindowGaps(winMins, g_qScratch);
   if(n < 3)
   {
      g_cache[ix].hasQuants=false;
      g_cache[ix].quantsMs=now;
      return false;
   }

   if(n > 1)
   QuickSortD(g_qScratch, 0, n-1);

   g_cache[ix].p10 = PercentileSorted(g_qScratch,n,0.10);
   g_cache[ix].p25 = PercentileSorted(g_qScratch,n,0.25);
   g_cache[ix].p50 = PercentileSorted(g_qScratch,n,0.50);
   g_cache[ix].p75 = PercentileSorted(g_qScratch,n,0.75);
   g_cache[ix].p90 = PercentileSorted(g_qScratch,n,0.90);

   g_cache[ix].hasQuants=true;
   g_cache[ix].quantsMs=now;
   return true;
}

// bulk compute depending on current tab (still throttled)
void EnsureCachesForTab(const bool force=false)
{
   int n=ArraySize(g_cache);
   if(n<=0) return;

   for(int i=0;i<n;i++)
   {
      // Always ensure stats for any view that needs mean/std/corr/slope
      if(g_tab==TAB_STATS || g_tab==TAB_PLAN)
         EnsureStatsForWindow(i, force);

      // WINDOWS needs min/max/mean + median => quantiles for p50 only.
      // We'll compute quants only when WINDOWS tab is shown (still throttled).
      if(g_tab==TAB_WINDOWS)
      {
         EnsureStatsForWindow(i, force);
         EnsureQuantsForWindow(i, force); // gives p50 quickly with scratch array
      }

      // QUANTS needs full set
      if(g_tab==TAB_QUANTS)
      {
         EnsureStatsForWindow(i, force);
         EnsureQuantsForWindow(i, force);
      }
   }
}

//====================== COLORS ======================//
color CorrColor(double corr)
{
   double a=MathAbs(corr);
   if(a>=0.97) return ColGood;
   if(a>=0.90) return ColWarn;
   return ColBad;
}
color ZColor(double z)
{
   double a=MathAbs(z);
   if(a<=0.7) return ColGood;
   if(a<=1.5) return ColWarn;
   return ColBad;
}

//====================== SNAPSHOT (FROM CACHE) ======================//
bool GetSnapshotForWindowIx_Cached(
   const int windowIx,
   int &winMins,
   string &winLabel,
   int &samples,
   double &mean,
   double &std,
   double &z,
   double &corr,
   double &slope,
   double &p10,
   double &p50,
   double &p90,
   const bool needQuants)
{
   winMins=60; winLabel="1H"; samples=0;
   mean=std=z=corr=slope=p10=p50=p90=0.0;

   if(ArraySize(g_winMins)<=0) return false;
   if(windowIx<0 || windowIx>=ArraySize(g_winMins)) return false;

   winMins=g_winMins[windowIx];
   winLabel=WindowLabelByIndex(windowIx);

   if(!EnsureStatsForWindow(windowIx,false)) return false;

   samples = g_cache[windowIx].n;
   if(samples<3) return false;

   mean = g_cache[windowIx].meanG;
   std  = g_cache[windowIx].stdG;
   corr = g_cache[windowIx].corr;
   slope= g_cache[windowIx].slope;
   z    = (std>0 ? (g_lastGap-mean)/std : 0.0);

   if(needQuants)
   {
      if(!EnsureQuantsForWindow(windowIx,false)) return false;
      p10 = g_cache[windowIx].p10;
      p50 = g_cache[windowIx].p50;
      p90 = g_cache[windowIx].p90;
   }
   else
   {
      // if already computed, reuse
      if(g_cache[windowIx].hasQuants)
      {
         p10=g_cache[windowIx].p10;
         p50=g_cache[windowIx].p50;
         p90=g_cache[windowIx].p90;
      }
   }

   return true;
}

bool GetActiveSnapshot(
   int &winMins,
   string &winLabel,
   int &samples,
   double &mean,
   double &std,
   double &z,
   double &corr,
   double &slope,
   double &p10,
   double &p50,
   double &p90)
{
   int ix=g_activeWindowIx;
   if(ix<0) ix=0;
   if(ix>=ArraySize(g_winMins)) ix=ArraySize(g_winMins)-1;

   // For headline: need quants because alerts use p10/p90 and you show them in summary sometimes
   return GetSnapshotForWindowIx_Cached(ix,winMins,winLabel,samples,mean,std,z,corr,slope,p10,p50,p90,true);
}

//====================== TELEGRAM RUNTIME ======================//
struct TeleUser
{
   long     chatId;

   bool     hasEnabledOverride;
   bool     enabled;

   bool     hasWindowOverride;
   int      windowIx;

   bool     hasZOverride;
   double   zThreshold;

   bool     hasCooldownOverride;
   int      cooldownSec;

   bool     alertActive;
   datetime lastAlertTime;
};

TeleUser g_users[];

//====================== TELEGRAM HELPERS ======================//
int GetUserWindowIx(const TeleUser &u)
{
   if(u.hasWindowOverride) return u.windowIx;
   return TELE_DEFAULT_WINDOW_IX;
}
double GetUserZThreshold(const TeleUser &u)
{
   if(u.hasZOverride) return u.zThreshold;
   return TELE_DEFAULT_ZTHRESH;
}
int GetUserCooldownSec(const TeleUser &u)
{
   if(u.hasCooldownOverride) return u.cooldownSec;
   return TELE_DEFAULT_COOLDOWN;
}
bool GetUserAlertsEnabled(const TeleUser &u)
{
   if(u.hasEnabledOverride) return u.enabled;
   return TELE_DEFAULT_ALERTS_ON;
}

bool LoadTeleUsers()
{
   ArrayResize(g_users, 0);

   string s = InpTeleAllowedChatIDs;
   StringReplace(s, " ", "");
   if(StringLen(s) == 0) return false;

   string parts[];
   int n = StringSplit(s, ';', parts);
   if(n <= 0) return false;

   for(int i=0; i<n; i++)
   {
      long chatId = (long)StringToInteger(parts[i]);
      if(chatId == 0) continue;

      TeleUser u;
      u.chatId = chatId;

      u.hasEnabledOverride  = false;
      u.enabled             = true;

      u.hasWindowOverride   = false;
      u.windowIx            = 0;

      u.hasZOverride        = false;
      u.zThreshold          = 0.0;

      u.hasCooldownOverride = false;
      u.cooldownSec         = 0;

      u.alertActive         = false;
      u.lastAlertTime       = 0;

      int sz = ArraySize(g_users);
      ArrayResize(g_users, sz + 1);
      g_users[sz] = u;
   }
   return (ArraySize(g_users) > 0);
}

int FindUserIndexByChatId(const long chatId)
{
   for(int i=0; i<ArraySize(g_users); i++)
      if(g_users[i].chatId == chatId)
         return i;
   return -1;
}
bool IsAllowedChat(const long chatId)
{
   return (FindUserIndexByChatId(chatId) >= 0);
}

string BuildMySettingsText(const TeleUser &u)
{
   string s = "👤 <b>YOUR SETTINGS</b>\n";
   s += "Chat ID: <b>" + IntegerToString(u.chatId) + "</b>\n";
   s += "Alerts: <b>" + string(GetUserAlertsEnabled(u) ? "ON" : "OFF") + "</b>\n";
   s += "Window: <b>" + WindowLabelByIndex(GetUserWindowIx(u)) + "</b> (index " + IntegerToString(GetUserWindowIx(u)) + ")\n";
   s += "Z Threshold: <b>" + DoubleToString(GetUserZThreshold(u),2) + "</b>\n";
   s += "Cooldown: <b>" + IntegerToString(GetUserCooldownSec(u)) + " sec</b>\n\n";
   s += "Commands:\n";
   s += "/whoami\n";
   s += "/ping\n";
   s += "/mysettings\n";
   s += "/window\n";
   s += "/usewin N\n";
   s += "/setz 2.5\n";
   s += "/setcooldown 300\n";
   s += "/alerts_on\n";
   s += "/alerts_off\n";
   s += "/status\n";
   s += "/summary\n";
   s += "/tab_all";
   return s;
}

//====================== HTTP / JSON ======================//
string UrlEncodeForm(const string text)
{
   uchar src[];
   StringToCharArray(text, src, 0, WHOLE_ARRAY, CP_UTF8);

   string out="";
   for(int i=0;i<ArraySize(src)-1;i++)
   {
      uchar c=src[i];

      if((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') ||
         c=='-' || c=='_' || c=='.' || c=='~')
         out += CharToString(c);
      else if(c==' ')
         out += "+";
      else if(c=='\n')
         out += "%0A";
      else
         out += StringFormat("%%%02X", c);
   }
   return out;
}

string JsonGetString(const string json, const string key, const int start_pos=0)
{
   string pat="\""+key+"\":\"";
   int p=StringFind(json, pat, start_pos);
   if(p<0) return "";
   p += StringLen(pat);

   string out="";
   for(int i=p;i<StringLen(json);i++)
   {
      string ch=StringSubstr(json,i,1);
      if(ch=="\"" && i>0 && StringSubstr(json,i-1,1)!="\\")
         break;
      out += ch;
   }
   StringReplace(out,"\\n","\n");
   StringReplace(out,"\\\"","\"");
   return out;
}

long JsonGetLong(const string json, const string key, const int start_pos=0)
{
   string pat="\""+key+"\":";
   int p=StringFind(json, pat, start_pos);
   if(p<0) return 0;
   p += StringLen(pat);

   while(p<StringLen(json))
   {
      string ch=StringSubstr(json,p,1);
      if(ch==" " || ch=="\t" || ch=="\n" || ch=="\r") p++;
      else break;
   }

   string num="";
   for(int i=p;i<StringLen(json);i++)
   {
      string ch=StringSubstr(json,i,1);
      if((ch>="0" && ch<="9") || ch=="-") num += ch;
      else break;
   }

   if(StringLen(num)==0) return 0;
   return (long)StringToInteger(num);
}

bool HttpGET(const string url, string &resp, int &http_code)
{
   resp="";
   http_code=0;

   char data[];
   ArrayResize(data,0);

   char result[];
   string headers_out="";
   string headers_in="";
   ResetLastError();

   int res = WebRequest("GET", url, headers_in, 5000, data, result, headers_out);
   if(res==-1) return false;

   http_code = res;
   resp = CharArrayToString(result,0,ArraySize(result));
   return true;
}

bool HttpPOST(const string url, const string body, string &resp, int &http_code)
{
   resp="";
   http_code=0;

   ResetLastError();

   string headers_in = "Content-Type: application/x-www-form-urlencoded\r\n";
   char data[];
   StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);

   char result[];
   string headers_out="";

   int res = WebRequest("POST", url, headers_in, 5000, data, result, headers_out);
   if(res==-1) return false;

   http_code = res;
   resp = CharArrayToString(result,0,ArraySize(result));
   return true;
}

//====================== TELEGRAM SEND ======================//
void SendTelegramChunkToChat(const long chatId, const string msg)
{
   if(!InpTeleEnable) return;
   if(chatId==0) return;
   if(InpTeleToken=="PASTE_NEW_BOT_TOKEN_HERE" || StringLen(InpTeleToken)<20) return;

   string url = "https://api.telegram.org/bot" + InpTeleToken + "/sendMessage";
   string body = "chat_id=" + IntegerToString(chatId) +
                 "&parse_mode=HTML" +
                 "&text=" + UrlEncodeForm(msg);

   string resp;
   int code=0;
   HttpPOST(url, body, resp, code);
}

void SendTelegramToChat(const long chatId, const string message)
{
   const int MAX_CHUNK = 3500;

   string s = message;
   int n = StringLen(s);
   if(n<=0) return;

   int start=0;
   while(start<n)
   {
      int len = MathMin(MAX_CHUNK, n-start);
      string part = StringSubstr(s, start, len);

      if(start+len < n)
      {
         // split on last newline for nicer chunks
         int pos=-1;
         int cur=StringFind(part,"\n",0);
         while(cur>=0){ pos=cur; cur=StringFind(part,"\n",cur+1); }
         if(pos>1000) part = StringSubstr(s,start,pos);
      }

      SendTelegramChunkToChat(chatId, part);
      start += StringLen(part);
   }
}

bool GetSnapshotForWindowIx(
   const int windowIx,
   int &winMins,
   string &winLabel,
   int &samples,
   double &mean,
   double &std,
   double &z,
   double &corr,
   double &slope,
   double &p10,
   double &p50,
   double &p90)
{
   // Telegram user snapshot needs quantiles (alerts depend on p10/p90)
   return GetSnapshotForWindowIx_Cached(windowIx,winMins,winLabel,samples,mean,std,z,corr,slope,p10,p50,p90,true);
}

//====================== TELEGRAM TEXT BUILDERS ======================//
string BuildStatusTextForUser(const TeleUser &u)
{
   int winMins, samples;
   string winLabel;
   double mean, std, z, corr, slope, p10, p50, p90;

   int userWindowIx = GetUserWindowIx(u);

   string s = "💎 <b>GAP RADAR PRO</b>\n";
   s += "<code>────────────────────────</code>\n";
   s += "📈 Asset: <b>" + InpSymbol1 + " / " + InpSymbol2 + "</b>\n";
   s += "🛠 Mode: <code>" + DirText() + "</code>\n";
   s += "⚡ Gap: <b>" + (g_haveTick ? F2(g_lastGap) : "--") + "</b>\n";
   s += "🔗 P1/P2: <code>" + (g_haveTick ? (F2(g_lastP1) + " | " + F2(g_lastP2)) : "--") + "</code>\n";
   s += "<code>────────────────────────</code>\n";

   if(GetSnapshotForWindowIx(userWindowIx, winMins, winLabel, samples, mean, std, z, corr, slope, p10, p50, p90))
   {
      s += "📅 User Window: <b>" + winLabel + "</b> (index " + IntegerToString(userWindowIx) + ")\n";
      s += "🎯 Mean: <code>" + F2(mean) + "</code>\n";
      s += "📊 Z-Score: <b>" + F2(z) + "</b>\n";
      s += "🤝 Corr: <b>" + F3(corr) + "</b>\n";
      s += "🌊 Slope: <code>" + F4(slope) + "/min</code>\n";
   }
   else
   {
      s += "📅 User Window: <b>" + WindowLabelByIndex(userWindowIx) + "</b> (index " + IntegerToString(userWindowIx) + ")\n";
      s += "⚠️ <i>Insufficient history for stats.</i>\n";
   }
   return s;
}

string BuildWindowsText()
{
   string s = "🪟 <b>Windows</b>\n";
   for(int i=0; i<ArraySize(g_winLabels); i++)
   {
      string marker = (i==g_activeWindowIx ? " ⭐ UI" : "");
      s += IntegerToString(i) + ": <b>" + g_winLabels[i] + "</b>" + marker + "\n";
   }
   return s;
}

string BuildTabWindowsText()
{
   string s = "🪟 <b>WINDOWS TAB</b>\n";
   s += "Pair: <b>" + InpSymbol1 + " / " + InpSymbol2 + "</b>\n";
   s += "Mode: <b>" + DirText() + "</b>\n\n";

   for(int i=0; i<ArraySize(g_winLabels); i++)
   {
      string marker = (i==g_activeWindowIx ? " ⭐ UI" : "");
      s += "<b>" + IntegerToString(i) + ": " + g_winLabels[i] + "</b>" + marker;

      if(!EnsureStatsForWindow(i,false) || !EnsureQuantsForWindow(i,false))
      {
         s += " → no history\n";
         continue;
      }

      s += "\n  Max: " + F2(g_cache[i].maxG) +
           " | Min: " + F2(g_cache[i].minG) +
           " | Med: " + F2(g_cache[i].p50) +
           " | Mean: " + F2(g_cache[i].meanG) + "\n";
   }
   return s;
}

string BuildTabStatsText()
{
   string s = "📈 <b>STATS TAB</b>\n";
   s += "Pair: <b>" + InpSymbol1 + " / " + InpSymbol2 + "</b>\n\n";

   for(int i=0; i<ArraySize(g_winLabels); i++)
   {
      string marker = (i==g_activeWindowIx ? " ⭐ UI" : "");
      s += "<b>" + IntegerToString(i) + ": " + g_winLabels[i] + "</b>" + marker;

      if(!EnsureStatsForWindow(i,false))
      {
         s += " → no history\n";
         continue;
      }

      double mean=g_cache[i].meanG;
      double std =g_cache[i].stdG;
      double z   =(std>0?(g_lastGap-mean)/std:0.0);

      s += "\n  Samples: " + IntegerToString(g_cache[i].n) +
           "\n  Mean: " + F2(mean) +
           " | Std: " + F2(std) +
           "\n  Z: " + F2(z) +
           " | Corr: " + F3(g_cache[i].corr) +
           " | Slope: " + F4(g_cache[i].slope) + "\n";
   }
   return s;
}

string BuildTabQuantsText()
{
   string s = "📊 <b>QUANTILE DISTRIBUTION</b>\n";
   s += "<code>────────────────────────</code>\n";

   for(int i=0; i<ArraySize(g_winLabels); i++)
   {
      string marker = (i==g_activeWindowIx ? " ⭐ UI" : "");
      s += "🕒 <b>" + g_winLabels[i] + "</b>" + marker + "\n";

      if(!EnsureQuantsForWindow(i,false))
      {
         s += "<i>No data</i>\n\n";
         continue;
      }

      s += "<code>[P10] " + F2(g_cache[i].p10) + "</code>\n";
      s += "<code>[P50] " + F2(g_cache[i].p50) + "</code> (Median)\n";
      s += "<code>[P90] " + F2(g_cache[i].p90) + "</code>\n";
      s += "<code>────────────────────────</code>\n";
   }
   return s;
}

string BuildTabPlanText()
{
   string s = "🧠 <b>PLAN TAB</b>\n";
   s += "Telegram: <b>" + string(InpTeleEnable ? "ON" : "OFF") + "</b>\n";
   s += "Pair: <b>" + InpSymbol1 + " / " + InpSymbol2 + "</b>\n";
   s += "Mode: <b>" + DirText() + "</b>\n";
   s += "Allowed Users Loaded: <b>" + IntegerToString(ArraySize(g_users)) + "</b>\n";
   s += "UI Window: <b>" + WindowLabelByIndex(g_activeWindowIx) + "</b>\n\n";
   s += "Per-user commands:\n";
   s += "• /mysettings\n";
   s += "• /usewin N\n";
   s += "• /setz 2.5\n";
   s += "• /setcooldown 300\n";
   s += "• /alerts_on /alerts_off\n";
   return s;
}

string BuildSummaryTextForUser(const TeleUser &u)
{
   int winMins,samples;
   string winLabel;
   double mean,std,z,corr,slope,p10,p50,p90;

   int userWindowIx = GetUserWindowIx(u);

   string s = "🧾 <b>SUMMARY</b>\n";
   s += "Pair: <b>" + InpSymbol1 + " / " + InpSymbol2 + "</b>\n";
   s += "Mode: <b>" + DirText() + "</b>\n";
   s += "Current Gap: <b>" + (g_haveTick ? F2(g_lastGap) : "--") + "</b>\n";

   if(GetSnapshotForWindowIx(userWindowIx, winMins, winLabel, samples, mean, std, z, corr, slope, p10, p50, p90))
   {
      s += "User Window: <b>" + winLabel + "</b> (index " + IntegerToString(userWindowIx) + ")\n";
      s += "Samples: <b>" + IntegerToString(samples) + "</b>\n";
      s += "Mean/Std: <b>" + F2(mean) + " / " + F2(std) + "</b>\n";
      s += "Z/Corr: <b>" + F2(z) + " / " + F3(corr) + "</b>\n";
      s += "P10/P50/P90: <b>" + F2(p10) + " / " + F2(p50) + " / " + F2(p90) + "</b>\n";
      s += "Slope/min: <b>" + F4(slope) + "</b>\n";
   }
   else
   {
      s += "User Window: <b>" + WindowLabelByIndex(userWindowIx) + "</b> (index " + IntegerToString(userWindowIx) + ")\n";
      s += "Stats: <b>not enough history</b>\n";
   }

   return s;
}

//====================== TELEGRAM ALERTS ======================//
void CheckAlertLogicForUser(const int userIx, const double currentGap)
{
   if(userIx < 0 || userIx >= ArraySize(g_users)) return;

   TeleUser u = g_users[userIx];

   bool userEnabled = GetUserAlertsEnabled(u);
   if(!userEnabled) return;

   int userCooldown = GetUserCooldownSec(u);
   if(TimeCurrent() < u.lastAlertTime + userCooldown) return;

   int userWindowIx = GetUserWindowIx(u);
   if(userWindowIx < 0) userWindowIx = 0;
   if(userWindowIx >= ArraySize(g_winMins)) userWindowIx = ArraySize(g_winMins)-1;

   double userZ = GetUserZThreshold(u);

   // Ensure cache for this window (stats + quants) without allocating arrays
   EnsureStatsForWindow(userWindowIx,false);
   EnsureQuantsForWindow(userWindowIx,false);

   if(g_cache[userWindowIx].n < 3 || !g_cache[userWindowIx].hasQuants) return;

   double mean = g_cache[userWindowIx].meanG;
   double std  = g_cache[userWindowIx].stdG;
   double z    = (std>0 ? (currentGap-mean)/std : 0.0);
   double corr = g_cache[userWindowIx].corr;
   string winLabel = WindowLabelByIndex(userWindowIx);

   double p10 = g_cache[userWindowIx].p10;
   double p90 = g_cache[userWindowIx].p90;

   bool isOAG=false;
   if(InpGapDir==GAP_SELL_ONLY && currentGap>=p90 && z>=userZ) isOAG=true;
   if(InpGapDir==GAP_BUY_ONLY  && currentGap<=p10 && z<=-userZ) isOAG=true;

   if(isOAG && !u.alertActive && MathAbs(corr) > 0.90)
   {
      string msg = "🚀 <b>OAG ALERT: ENTRY SIGNAL</b>\n";
      msg += "<code>────────────────────────</code>\n";
      msg += "💎 Pair: <b>" + InpSymbol1 + " / " + InpSymbol2 + "</b>\n";
      msg += "📏 Window: <b>" + winLabel + "</b>\n";
      msg += "⚡ Gap: <code>" + DoubleToString(currentGap,2) + "</code>\n";
      msg += "📊 Z: <code>" + DoubleToString(z,2) + "</code> (Ref: " + DoubleToString(userZ,2) + ")\n";
      msg += "🤝 Corr: <b>" + DoubleToString(corr,3) + "</b>\n";
      msg += "⏱ Cooldown: <b>" + IntegerToString(userCooldown) + " sec</b>\n";
      msg += "<code>────────────────────────</code>\n";
      msg += "📥 <b>ACTION: CONSIDER ENTRY</b>";

      SendTelegramToChat(u.chatId, msg);
      u.alertActive = true;
      u.lastAlertTime = TimeCurrent();
      g_users[userIx] = u;
      return;
   }

   if(u.alertActive)
   {
      bool isCAG=false;
      if(InpGapDir==GAP_SELL_ONLY && currentGap<=mean) isCAG=true;
      if(InpGapDir==GAP_BUY_ONLY  && currentGap>=mean) isCAG=true;

      if(isCAG)
      {
         string msg = "✅ <b>CAG ALERT: TARGET MET</b>\n";
         msg += "<code>────────────────────────</code>\n";
         msg += "💎 Pair: <b>" + InpSymbol1 + " / " + InpSymbol2 + "</b>\n";
         msg += "📏 Window: <b>" + winLabel + "</b>\n";
         msg += "⚡ Gap Now: <code>" + DoubleToString(currentGap,2) + "</code>\n";
         msg += "🎯 Mean: <code>" + DoubleToString(mean,2) + "</code>\n";
         msg += "<code>────────────────────────</code>\n";
         msg += "💰 <b>ACTION: CONSIDER EXIT</b>";

         SendTelegramToChat(u.chatId, msg);
         u.alertActive = false;
         u.lastAlertTime = TimeCurrent();
         g_users[userIx] = u;
         return;
      }
   }
}

void CheckAllUserAlerts(const double currentGap)
{
   for(int i=0; i<ArraySize(g_users); i++)
      CheckAlertLogicForUser(i, currentGap);
}

//====================== TELEGRAM COMMANDS ======================//
void HandleTelegramCommand(const long chatId, const string text)
{
   string cmd = TrimStr(text);
   string low = cmd;
   StringToLower(low);

   if(low == "/whoami")
   {
      SendTelegramToChat(
         chatId,
         "👤 <b>Your Telegram Info</b>\n"
         "Chat ID: <b>" + IntegerToString(chatId) + "</b>"
      );
      return;
   }

   if(low == "/ping")
   {
      SendTelegramToChat(chatId, "🏓 <b>pong</b>\nChat ID: <b>" + IntegerToString(chatId) + "</b>");
      return;
   }

   int userIx = FindUserIndexByChatId(chatId);
   if(userIx < 0) return;

   TeleUser u = g_users[userIx];

   if(low=="/start" || low=="/help")
   {
      SendTelegramToChat(chatId,
         "🤖 <b>GapRadar Bot</b>\n"
         "Commands:\n"
         "/whoami\n"
         "/ping\n"
         "/mysettings\n"
         "/status\n"
         "/summary\n"
         "/window\n"
         "/usewin N\n"
         "/setz 2.5\n"
         "/setcooldown 300\n"
         "/alerts_on\n"
         "/alerts_off\n"
         "/tab\n"
         "/tab_windows\n"
         "/tab_stats\n"
         "/tab_quants\n"
         "/tab_plan\n"
         "/tab_all"
      );
      return;
   }

   if(low=="/mysettings")
   {
      SendTelegramToChat(chatId, BuildMySettingsText(u));
      return;
   }

   if(low=="/status" || low=="/stats")
   {
      SendTelegramToChat(chatId, BuildStatusTextForUser(u) + "\n\n" + BuildMySettingsText(u));
      return;
   }

   if(low=="/summary")
   {
      SendTelegramToChat(chatId, BuildSummaryTextForUser(u) + "\n\n" + BuildMySettingsText(u));
      return;
   }

   if(low=="/window")
   {
      SendTelegramToChat(chatId, BuildWindowsText());
      return;
   }

   if(low=="/alerts on" || low=="/alerts_on")
   {
      u.hasEnabledOverride = true;
      u.enabled = true;
      g_users[userIx] = u;
      SendTelegramToChat(chatId, "🔔 <b>Your alerts turned ON</b>");
      return;
   }

   if(low=="/alerts off" || low=="/alerts_off")
   {
      u.hasEnabledOverride = true;
      u.enabled = false;
      g_users[userIx] = u;
      SendTelegramToChat(chatId, "🔕 <b>Your alerts turned OFF</b>");
      return;
   }

   if(StringFind(low,"/setz ")==0)
   {
      string v = TrimStr(StringSubstr(low,6));
      double zval = StringToDouble(v);

      if(zval > 0.0)
      {
         u.hasZOverride = true;
         u.zThreshold = zval;
         g_users[userIx] = u;
         SendTelegramToChat(chatId, "⚙️ <b>Your Z threshold set to:</b> " + DoubleToString(u.zThreshold,2));
      }
      else
      {
         SendTelegramToChat(chatId, "❌ <b>Invalid Z value</b>\nUsage: /setz 2.5");
      }
      return;
   }

   if(StringFind(low,"/setcooldown ")==0)
   {
      string v = TrimStr(StringSubstr(low,13));
      int cd = (int)StringToInteger(v);

      if(cd > 0)
      {
         u.hasCooldownOverride = true;
         u.cooldownSec = cd;
         g_users[userIx] = u;
         SendTelegramToChat(chatId, "⏱ <b>Your cooldown set to:</b> " + IntegerToString(cd) + " sec");
      }
      else
      {
         SendTelegramToChat(chatId, "❌ <b>Invalid cooldown</b>\nUsage: /setcooldown 300");
      }
      return;
   }

   if(low=="/tab")
   {
      SendTelegramToChat(chatId,
         "🗂 <b>Tab Commands</b>\n"
         "/tab_windows\n"
         "/tab_stats\n"
         "/tab_quants\n"
         "/tab_plan\n"
         "/tab_all"
      );
      return;
   }

   if(low=="/tab windows" || low=="/tab_windows")
   {
      g_tab=TAB_WINDOWS;
      g_dirty=true;
      SendTelegramToChat(chatId, BuildTabWindowsText());
      return;
   }

   if(low=="/tab stats" || low=="/tab_stats")
   {
      g_tab=TAB_STATS;
      g_dirty=true;
      SendTelegramToChat(chatId, BuildTabStatsText());
      return;
   }

   if(low=="/tab quants" || low=="/tab_quants")
   {
      g_tab=TAB_QUANTS;
      g_dirty=true;
      SendTelegramToChat(chatId, BuildTabQuantsText());
      return;
   }

   if(low=="/tab plan" || low=="/tab_plan")
   {
      g_tab=TAB_PLAN;
      g_dirty=true;
      SendTelegramToChat(chatId, BuildTabPlanText());
      return;
   }

   if(low=="/tab all" || low=="/tab_all")
   {
      SendTelegramToChat(chatId, "🗂 <b>TAB ALL</b> (sending multiple messages)...");
      SendTelegramToChat(chatId, BuildTabWindowsText());
      SendTelegramToChat(chatId, BuildTabStatsText());
      SendTelegramToChat(chatId, BuildTabQuantsText());
      SendTelegramToChat(chatId, BuildTabPlanText());
      return;
   }

   if(low=="/usewin")
   {
      SendTelegramToChat(chatId, "⚙️ <b>Usage</b>\n/usewin N\n\n" + BuildWindowsText());
      return;
   }

   if(StringFind(low,"/usewin ")==0)
   {
      string idxs = TrimStr(StringSubstr(low,8));
      int ix = (int)StringToInteger(idxs);

      if(ix>=0 && ix<ArraySize(g_winMins))
      {
         u.hasWindowOverride = true;
         u.windowIx = ix;
         g_users[userIx] = u;
         SendTelegramToChat(chatId, "✅ <b>Your window set to:</b> " + WindowLabelByIndex(ix));
      }
      else
      {
         SendTelegramToChat(chatId, "❌ <b>Invalid window index</b>\n\n" + BuildWindowsText());
      }
      return;
   }

   SendTelegramToChat(
      chatId,
      "❓ <b>Unknown command</b>\n"
      "Try:\n"
      "/whoami\n"
      "/ping\n"
      "/mysettings\n"
      "/status\n"
      "/summary\n"
      "/alerts_on\n"
      "/alerts_off\n"
      "/setz 2.5\n"
      "/setcooldown 300\n"
      "/usewin 0"
   );
}

//====================== TELEGRAM POLLING (MS THROTTLED) ======================//
void PollTelegramUpdates()
{
   if(!InpTeleEnable || !InpTelePollCommands) return;
   if(InpTeleToken=="PASTE_NEW_BOT_TOKEN_HERE" || StringLen(InpTeleToken)<20) return;

   ulong nowMs = NowMs();
   if(nowMs - g_lastTeleMs < (ulong)MathMax(InpTeleMinMs,200)) return;
   g_lastTeleMs = nowMs;

   if(TimeCurrent() < g_lastTelePollTime + InpTelePollSec) return;
   g_lastTelePollTime = TimeCurrent();

   string url = "https://api.telegram.org/bot" + InpTeleToken + "/getUpdates?timeout=1";
   if(g_tgUpdateOffset > 0)
      url += "&offset=" + IntegerToString((int)g_tgUpdateOffset);

   string resp;
   int code = 0;
   if(!HttpGET(url, resp, code)) return;
   if(code < 200 || code >= 300) return;

   int scan = 0;
   while(true)
   {
      int pUpd = StringFind(resp, "\"update_id\":", scan);
      if(pUpd < 0) break;

      long updId = JsonGetLong(resp, "update_id", pUpd);
      if(updId > 0) g_tgUpdateOffset = updId + 1;

      int pMsg = StringFind(resp, "\"message\":", pUpd);
      if(pMsg < 0)
      {
         scan = pUpd + 11;
         continue;
      }

      int pChat = StringFind(resp, "\"chat\":", pMsg);
      int pText = StringFind(resp, "\"text\":", pMsg);

      long chatId = 0;
      string text = "";

      if(pChat >= 0)
         chatId = JsonGetLong(resp, "id", pChat);

      if(pText >= 0)
         text = JsonGetString(resp, "text", pMsg);

      if(StringLen(text) > 0)
      {
         string low = TrimStr(text);
         StringToLower(low);

         if(low == "/whoami" || low == "/ping")
            HandleTelegramCommand(chatId, text);
         else if(IsAllowedChat(chatId))
            HandleTelegramCommand(chatId, text);
      }

      scan = pUpd + 11;
   }
}

//====================== UI HELPERS ======================//
void DeleteUI()
{
   int total=ObjectsTotal(0,0,-1);
   for(int i=total-1;i>=0;i--)
   {
      string n=ObjectName(0,i,0,-1);
      if(StartsWith(n,g_prefix)) ObjectDelete(0,n);
   }
}

void DeleteTableOnly()
{
   int total=ObjectsTotal(0,0,-1);
   for(int i=total-1;i>=0;i--)
   {
      string n=ObjectName(0,i,0,-1);
      if(!StartsWith(n,g_prefix)) continue;

      if(StringFind(n, g_prefix+"BG_") == 0 || StringFind(n, g_prefix+"TX_") == 0)
         ObjectDelete(0,n);
   }
}

bool EnsureRect(const string n,int x,int y,int w,int h,color bg,color border)
{
   if(ObjectFind(0,n)<0)
   {
      if(!ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0)) return false;
      ObjectSetInteger(0,n,OBJPROP_BACK,false);
      ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,border);
   return true;
}

bool EnsureLabel(const string n,int x,int y,const string txt,int fsize,color col)
{
   if(ObjectFind(0,n)<0)
   {
      if(!ObjectCreate(0,n,OBJ_LABEL,0,0,0)) return false;
      ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
      ObjectSetString (0,n,OBJPROP_FONT,UI_Font);
   }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_COLOR,col);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fsize);
   ObjectSetString (0,n,OBJPROP_TEXT,txt);
   return true;
}

bool EnsureButton(const string n,int x,int y,int w,int h,const string txt,color bg,int fsize)
{
   if(ObjectFind(0,n)<0)
   {
      if(!ObjectCreate(0,n,OBJ_BUTTON,0,0,0)) return false;
      ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,clrBlack);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fsize);
   ObjectSetString (0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_STATE,false);
   return true;
}

void ResetBtn(const string n)
{
   if(ObjectFind(0,n)>=0) ObjectSetInteger(0,n,OBJPROP_STATE,false);
}

//====================== UI TEXT CACHES (NO ObjectGetString in hot loop) ======================//
string g_h1Last="", g_h2Last="", g_h3Last="";

void SetHeadlineText(const string objName, string &cache, const string t)
{
   if(cache==t) return;
   cache=t;
   if(ObjectFind(0,objName)>=0)
   {
      ObjectSetString(0,objName,OBJPROP_TEXT,t);
      g_needsRedraw=true;
   }
}

// table cell caches
string g_cellLastText[];
color  g_cellLastColor[];

int CellIndex(const int r,const int c){ return r*g_cols + c; }

void EnsureCellCaches()
{
   int need = g_rows * g_cols;
   if(need<=0) return;

   if(ArraySize(g_cellLastText)!=need)
   {
      ArrayResize(g_cellLastText,need);
      for(int i=0;i<need;i++) g_cellLastText[i]="";
   }
   if(ArraySize(g_cellLastColor)!=need)
   {
      ArrayResize(g_cellLastColor,need);
      for(int i=0;i<need;i++) g_cellLastColor[i]=clrNONE;
   }
}

void SetCell(int r,int c,const string text,color col=clrNONE)
{
   if(r<0||c<0||r>=g_rows||c>=g_cols) return;
   int idx=CellIndex(r,c);

   string n=g_prefix+"TX_"+IntegerToString(r)+"_"+IntegerToString(c);
   if(ObjectFind(0,n)<0) return;

   if(g_cellLastText[idx]!=text)
   {
      g_cellLastText[idx]=text;
      ObjectSetString(0,n,OBJPROP_TEXT,text);
      g_needsRedraw=true;
   }

   if(col!=clrNONE && g_cellLastColor[idx]!=col)
   {
      g_cellLastColor[idx]=col;
      ObjectSetInteger(0,n,OBJPROP_COLOR,col);
      g_needsRedraw=true;
   }
}

void ClearTableText()
{
   for(int r=0;r<g_rows;r++)
      for(int c=0;c<g_cols;c++)
         SetCell(r,c,"");
}

//====================== LAYOUT ======================//
void ComputePanelSize()
{
   int cw=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0);
   int ch=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);

   g_panelX=UI_X;
   g_panelY=UI_Y;

   if(UI_AutoSize)
   {
      g_panelW = IMax(760, cw - (UI_X*2));
      g_panelH = IMax(420, ch - (UI_Y*2));
      g_panelW = IMin(g_panelW, cw-10);
      g_panelH = IMin(g_panelH, ch-10);
   }
   else
   {
      g_panelW = IMin(UI_W, cw-10);
      g_panelH = IMin(UI_H, ch-10);
      g_panelW = IMax(600, g_panelW);
      g_panelH = IMax(360, g_panelH);
   }

   g_contentX = g_panelX + UI_Pad;
   g_contentY = g_panelY + UI_Pad;
   g_contentW = g_panelW - 2*UI_Pad;
   g_contentH = g_panelH - 2*UI_Pad;
}

void BuildTableGrid(int cols, int rows, const int &colW[])
{
   g_cols=cols;
   g_rows=rows;

   g_tableX = g_contentX;
   g_tableY = g_contentY + 96;
   g_tableW = g_contentW;

   int availableH = (g_panelY+g_panelH) - g_tableY - UI_Pad;
   g_rowH = availableH / IMax(1,rows);
   g_rowH = IMax(18, IMin(30, g_rowH));

   int y=g_tableY;
   for(int r=0;r<rows;r++)
   {
      int x=g_tableX;
      color rowbg = (r==0 ? ColHeaderBG : ((r%2==0)?ColRowAltBG:ColPanelBG));
      for(int c=0;c<cols;c++)
      {
         int w=colW[c];
         string bgN=g_prefix+"BG_"+IntegerToString(r)+"_"+IntegerToString(c);
         string txN=g_prefix+"TX_"+IntegerToString(r)+"_"+IntegerToString(c);

         EnsureRect(bgN,x,y,w,g_rowH,rowbg,ColBorder);
         EnsureLabel(txN,x+8,y+4,"",UI_FontBase,(r==0?ColMuted:ColInfo));
         x+=w;
      }
      y += g_rowH;
   }

   EnsureCellCaches();
}

//====================== BUILD / RENDER ======================//
void BuildUI()
{
   ComputePanelSize();

   EnsureRect(g_prefix+"PANEL", g_panelX, g_panelY, g_panelW, g_panelH, ColPanelBG, ColBorder);
   EnsureLabel(g_prefix+"TITLE", g_contentX, g_contentY, "GAP RADAR PRO EA", UI_FontTitle, ColTitle);

   int tabY   = g_contentY + 34;
   int tabW   = 150;
   int tabH   = 28;
   int tabGap = 10;

   EnsureButton(g_prefix+"TAB0", g_contentX,                 tabY, tabW, tabH, "WINDOWS",    (g_tab==TAB_WINDOWS ? ColTabOnBG : ColTabOffBG), UI_FontBase);
   EnsureButton(g_prefix+"TAB1", g_contentX+(tabW+tabGap),   tabY, tabW, tabH, "STATS+CORR", (g_tab==TAB_STATS   ? ColTabOnBG : ColTabOffBG), UI_FontBase);
   EnsureButton(g_prefix+"TAB2", g_contentX+2*(tabW+tabGap), tabY, tabW, tabH, "P10-P90",    (g_tab==TAB_QUANTS  ? ColTabOnBG : ColTabOffBG), UI_FontBase);
   EnsureButton(g_prefix+"TAB3", g_contentX+3*(tabW+tabGap), tabY, tabW, tabH, "PLAN",       (g_tab==TAB_PLAN    ? ColTabOnBG : ColTabOffBG), UI_FontBase);

   int hY = g_contentY + 34 + 28 + 10;
   EnsureLabel(g_prefix+"H1", g_contentX, hY,      "", UI_FontBase,  ColInfo);
   EnsureLabel(g_prefix+"H2", g_contentX, hY + 22, "", UI_FontBase,  ColMuted);
   EnsureLabel(g_prefix+"H3", g_contentX, hY + 44, "", UI_FontSmall, ColMuted);

   int cols = 0;
   int rows = 0;

   if(g_tab == TAB_WINDOWS)
   {
      cols = 5;
      rows = 1 + ArraySize(g_winMins);

      ArrayResize(g_colW, cols);

      int w0  = 120;
      int rem = g_contentW - w0;
      int w   = rem / 4;

      g_colW[0] = w0;
      g_colW[1] = w;
      g_colW[2] = w;
      g_colW[3] = w;
      g_colW[4] = rem - 3*w;
   }
   else if(g_tab == TAB_STATS)
   {
      cols = 7;
      rows = 1 + ArraySize(g_winMins);

      ArrayResize(g_colW, cols);

      int w0   = 110;
      int w1   = 110;
      int wZ   = 90;
      int wC   = 110;
      int wS   = 140;
      int rem  = g_contentW - (w0 + w1 + wZ + wC + wS);
      int wMean= rem / 2;
      int wStd = rem - wMean;

      g_colW[0] = w0;
      g_colW[1] = w1;
      g_colW[2] = wMean;
      g_colW[3] = wStd;
      g_colW[4] = wZ;
      g_colW[5] = wC;
      g_colW[6] = wS;
   }
   else if(g_tab == TAB_QUANTS)
   {
      cols = 6;
      rows = 1 + ArraySize(g_winMins);

      ArrayResize(g_colW, cols);

      int w0  = 110;
      int rem = g_contentW - w0;
      int w   = rem / 5;

      g_colW[0] = w0;
      g_colW[1] = w;
      g_colW[2] = w;
      g_colW[3] = w;
      g_colW[4] = w;
      g_colW[5] = rem - 4*w;
   }
   else // TAB_PLAN
   {
      cols = 2;
      rows = 11;

      ArrayResize(g_colW, cols);

      g_colW[0] = 160;
      g_colW[1] = g_contentW - g_colW[0];
   }

   bool needGridRebuild = (
      g_gridTabBuilt      != g_tab     ||
      g_gridColsBuilt     != cols      ||
      g_gridRowsBuilt     != rows      ||
      g_gridContentWBuilt != g_contentW
   );

   if(needGridRebuild)
   {
      DeleteTableOnly();
      BuildTableGrid(cols, rows, g_colW);

      g_gridTabBuilt      = g_tab;
      g_gridColsBuilt     = cols;
      g_gridRowsBuilt     = rows;
      g_gridContentWBuilt = g_contentW;

      // reset caches to force draw
      g_h1Last=""; g_h2Last=""; g_h3Last="";
      for(int i=0;i<ArraySize(g_cellLastText);i++) g_cellLastText[i]="";
      for(int i=0;i<ArraySize(g_cellLastColor);i++) g_cellLastColor[i]=clrNONE;
   }

   g_dirty = true;
}

void RenderHeadline()
{
   SetHeadlineText(g_prefix+"H1", g_h1Last, "S1: "+InpSymbol1+"  |  S2: "+InpSymbol2+"  |  "+DirText());

   if(!g_haveTick)
   {
      SetHeadlineText(g_prefix+"H2", g_h2Last, "GAP: --   P1: --   P2: --");
      SetHeadlineText(g_prefix+"H3", g_h3Last, "Waiting for ticks...");
      return;
   }

   SetHeadlineText(g_prefix+"H2", g_h2Last, "CURRENT GAP: "+F2(g_lastGap)+"   |   P1: "+F2(g_lastP1)+"   P2: "+F2(g_lastP2));

   int winMins,samples;
   string winLabel;
   double mean,std,z,corr,slope,p10,p50,p90;

   if(!GetActiveSnapshot(winMins,winLabel,samples,mean,std,z,corr,slope,p10,p50,p90))
   {
      SetHeadlineText(g_prefix+"H3", g_h3Last, "Window: "+WindowLabelByIndex(g_activeWindowIx)+" | Not enough history");
      return;
   }

   string line="Window: "+winLabel
      +" | Z: "+F2(z)
      +" | Corr: "+F3(corr)
      +" | Slope: "+F4(slope)
      +" | Alert: "+string(g_isAlertActive?"ACTIVE":"READY")
      +" | Alerts: "+string(g_alertsEnabled?"ON":"OFF");
   SetHeadlineText(g_prefix+"H3", g_h3Last, line);
}

void RenderWindowsTab()
{
   ClearTableText();
   SetCell(0,0,"Window",ColMuted);
   SetCell(0,1,"Max",ColMuted);
   SetCell(0,2,"Min",ColMuted);
   SetCell(0,3,"Median",ColMuted);
   SetCell(0,4,"Mean",ColMuted);

   for(int i=0;i<ArraySize(g_winMins);i++)
   {
      int r=1+i;

      if(!EnsureStatsForWindow(i,false) || !EnsureQuantsForWindow(i,false))
      {
         SetCell(r,0,g_winLabels[i]);
         SetCell(r,1,"--",ColMuted);
         SetCell(r,2,"--",ColMuted);
         SetCell(r,3,"--",ColMuted);
         SetCell(r,4,"--",ColMuted);
         continue;
      }

      SetCell(r,0,g_winLabels[i]);
      SetCell(r,1,F2(g_cache[i].maxG));
      SetCell(r,2,F2(g_cache[i].minG));
      SetCell(r,3,F2(g_cache[i].p50));
      SetCell(r,4,F2(g_cache[i].meanG));
   }
}

void RenderStatsTab()
{
   ClearTableText();
   SetCell(0,0,"Window",ColMuted);
   SetCell(0,1,"Samples",ColMuted);
   SetCell(0,2,"Mean(G)",ColMuted);
   SetCell(0,3,"Std(G)",ColMuted);
   SetCell(0,4,"Z(now)",ColMuted);
   SetCell(0,5,"Corr",ColMuted);
   SetCell(0,6,"Slope",ColMuted);

   for(int i=0;i<ArraySize(g_winMins);i++)
   {
      int r=1+i;

      if(!EnsureStatsForWindow(i,false))
      {
         SetCell(r,0,g_winLabels[i]);
         for(int c=1;c<=6;c++) SetCell(r,c,"--",ColMuted);
         continue;
      }

      double mean=g_cache[i].meanG;
      double std =g_cache[i].stdG;
      double z   =(std>0?(g_lastGap-mean)/std:0.0);

      SetCell(r,0,g_winLabels[i]);
      SetCell(r,1,IntegerToString(g_cache[i].n));
      SetCell(r,2,F2(mean));
      SetCell(r,3,F2(std));
      SetCell(r,4,F2(z),ZColor(z));
      SetCell(r,5,F3(g_cache[i].corr),CorrColor(g_cache[i].corr));
      SetCell(r,6,F4(g_cache[i].slope));
   }
}

void RenderQuantsTab()
{
   ClearTableText();
   SetCell(0,0,"Window",ColMuted);
   SetCell(0,1,"P10",ColMuted);
   SetCell(0,2,"P25",ColMuted);
   SetCell(0,3,"P50",ColMuted);
   SetCell(0,4,"P75",ColMuted);
   SetCell(0,5,"P90",ColMuted);

   for(int i=0;i<ArraySize(g_winMins);i++)
   {
      int r=1+i;

      if(!EnsureQuantsForWindow(i,false))
      {
         SetCell(r,0,g_winLabels[i]);
         for(int c=1;c<=5;c++) SetCell(r,c,"--",ColMuted);
         continue;
      }

      SetCell(r,0,g_winLabels[i]);
      SetCell(r,1,F2(g_cache[i].p10));
      SetCell(r,2,F2(g_cache[i].p25));
      SetCell(r,3,F2(g_cache[i].p50));
      SetCell(r,4,F2(g_cache[i].p75));
      SetCell(r,5,F2(g_cache[i].p90));
   }
}

void RenderPlanTab()
{
   ClearTableText();
   SetCell(0,0,"Item",ColMuted);         SetCell(0,1,"Notes",ColMuted);
   SetCell(1,0,"Telegram");              SetCell(1,1,"Enabled: "+string(InpTeleEnable?"YES":"NO"));
   SetCell(2,0,"OAG Trigger");           SetCell(2,1,"SELL: Gap >= P90 and Z >= threshold. BUY: Gap <= P10 and Z <= -threshold.");
   SetCell(3,0,"CAG Trigger");           SetCell(3,1,"SELL: Gap <= Mean. BUY: Gap >= Mean.");
   SetCell(4,0,"Commands");              SetCell(4,1,"/status /summary /window /usewin N /tab ... /alerts on|off /setz X /ping");
   SetCell(5,0,"Active Window");         SetCell(5,1,WindowLabelByIndex(g_activeWindowIx));
   SetCell(6,0,"Z Threshold");           SetCell(6,1,F2(g_runtimeZThreshold));
   SetCell(7,0,"Cooldown Sec");          SetCell(7,1,IntegerToString(InpTeleCooldownSec));
   SetCell(8,0,"Pair");                  SetCell(8,1,InpSymbol1+" / "+InpSymbol2);
   SetCell(9,0,"Mode");                  SetCell(9,1,DirText());
   SetCell(10,0,"Notes");                SetCell(10,1,"Add https://api.telegram.org to Tools > Options > Expert Advisors > Allow WebRequest.");
}

void Render()
{
   RenderHeadline();
   if(g_tab==TAB_WINDOWS) RenderWindowsTab();
   else if(g_tab==TAB_STATS) RenderStatsTab();
   else if(g_tab==TAB_QUANTS) RenderQuantsTab();
   else RenderPlanTab();
}

//====================== MAIN LOOP ======================//
void CheckChartResize()
{
   int cw=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0);
   int ch=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);
   if(cw!=g_lastChartW || ch!=g_lastChartH)
   {
      g_lastChartW=cw;
      g_lastChartH=ch;
      BuildUI();
   }
}

void SampleAndMaybeRender()
{
   CheckChartResize();

   // 1) SAMPLE FAST
   double gap=0,p1=0,p2=0,m1=0,m2=0;
   bool ok=ComputeGap(gap,p1,p2,m1,m2);

   if(ok)
   {
      g_haveTick=true;
      g_lastGap=gap;
      g_lastP1=p1;
      g_lastP2=p2;
      g_lastM1=m1;
      g_lastM2=m2;

      RingPush((long)NowMs(), gap, m1, m2);
   }

   // 2) COMPUTE STATS SLOW (THROTTLED)
   ulong now=NowMs();
   bool stats_due = (now - g_lastStatsMs) >= (ulong)MathMax(InpStatsMinMs,100);
   if(stats_due || g_dirty)
   {
      EnsureCachesForTab(false);
      g_lastStatsMs = now;
   }

   // 3) ALERTS: compute only per user window needed (uses cache + scratch)
   // run only if we have at least some history; and only when stats due (prevents rapid spam checks)
   if(ok && stats_due)
      CheckAllUserAlerts(gap);

   // 4) TELEGRAM POLL (MS THROTTLED)
   PollTelegramUpdates();

   // 5) RENDER THROTTLED
   bool time_ok  = (now - g_lastRenderMs) >= (ulong)MathMax(InpRenderMinMs,200);
   bool delta_ok = (!g_hasRenderedGap && ok) || (ok && MathAbs(gap-g_lastRenderedGap)>=InpGapDeltaToRender);
   bool shouldUpdate = (g_dirty || (ok && (time_ok || delta_ok)));

   if(shouldUpdate)
   {
      if(g_dirty)
         BuildUI();

      // ensure caches required for current tab just before drawing (cheap if already fresh)
      EnsureCachesForTab(false);

      Render();

      g_lastRenderMs = now;
      if(ok)
      {
         g_lastRenderedGap = gap;
         g_hasRenderedGap  = true;
      }
      g_dirty = false;
   }

   if(g_needsRedraw)
   {
      ChartRedraw(0);
      g_needsRedraw = false;
   }
}

//====================== EVENTS ======================//
int OnInit()
{
   BuildWindowsFromInputs();
   RingInit();
   LoadTeleUsers();

   CacheInit();
   ArrayResize(g_qScratch, g_cap);

   g_alertsEnabled = true;
   g_runtimeZThreshold = InpZThreshold;

   int ms=InpSampleMs;
   if(ms<50) ms=50;
   EventSetMillisecondTimer(ms);

   g_lastChartW=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0);
   g_lastChartH=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);

   BuildUI();
   EnsureCachesForTab(true);
   Render();

   Print("GapRadar_Pro_EA initialized. Allowed Telegram users loaded: ", ArraySize(g_users));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteUI();
}

void OnTick()
{
   // sampling is timer-driven; leave empty
}

void OnTimer()
{
   SampleAndMaybeRender();
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id!=CHARTEVENT_OBJECT_CLICK) return;
   if(!StartsWith(sparam,g_prefix)) return;

   ResetBtn(sparam);

   int newtab=g_tab;
   if(sparam==g_prefix+"TAB0") newtab=TAB_WINDOWS;
   if(sparam==g_prefix+"TAB1") newtab=TAB_STATS;
   if(sparam==g_prefix+"TAB2") newtab=TAB_QUANTS;
   if(sparam==g_prefix+"TAB3") newtab=TAB_PLAN;

   if(newtab!=g_tab)
   {
      g_tab=newtab;
      g_dirty=true;

      // force cache refresh for new tab on next tick
      g_lastStatsMs = 0;

      BuildUI();
      EnsureCachesForTab(true);
      Render();
      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+