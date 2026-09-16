//+------------------------------------------------------------------+
//| GapRadar_Pro.mq5 (Indicator)                                     |
//| v2.03 - Added Telegram Alerts for OAG/CAG                        |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property version "2.03"

//====================== INPUTS ======================//
input string InpSymbol1 = "GCJ26.ma";
input string InpSymbol2 = "XAUUSD.pp";

enum ENUM_GAP_DIR { GAP_SELL_ONLY=1, GAP_BUY_ONLY=2 };
input ENUM_GAP_DIR InpGapDir = GAP_SELL_ONLY;

input int  InpSampleMs       = 200;
input int  InpHistoryMinutes = 12*60;
input int  InpMaxSamples     = 8000;

input int    InpRenderMinMs      = 900;
input double InpGapDeltaToRender = 0.03;

//==================== TELEGRAM SETTINGS ====================//
input bool   InpTeleAlerts = false;           // Enable Telegram Alerts
input string InpTeleToken  = "8653099152:AAGi_1ZhUdglhVwyCk_8oOboWOdpoJMxb1o";    // Bot Token
input long   InpTeleChatID = 0;               // Chat ID (Numeric)
input double InpZThreshold = 2.0;             // Z-Score threshold for Alert

//==================== WINDOW CONFIG ====================//
enum ENUM_WIN_UNIT { UNIT_MINUTES=0, UNIT_HOURS=1 };

input bool          W1_Enable = true;
input ENUM_WIN_UNIT W1_Unit   = UNIT_HOURS;
input double        W1_Value  = 1.0;

input bool          W2_Enable = true;
input ENUM_WIN_UNIT W2_Unit   = UNIT_HOURS;
input double        W2_Value  = 1.5;

input bool          W3_Enable = true;
input ENUM_WIN_UNIT W3_Unit   = UNIT_HOURS;
input double        W3_Value  = 2.0;

input bool          W4_Enable = true;
input ENUM_WIN_UNIT W4_Unit   = UNIT_MINUTES;
input double        W4_Value  = 5.0;

input bool          W5_Enable = true;
input ENUM_WIN_UNIT W5_Unit   = UNIT_MINUTES;
input double        W5_Value  = 15.0;

input bool          W6_Enable = true;
input ENUM_WIN_UNIT W6_Unit   = UNIT_MINUTES;
input double        W6_Value  = 30.0;

// Which window index to use for headline & alerts (0..n-1)
input int    InpActiveWindowIx = 0;

// UI sizing
input bool UI_AutoSize  = true;
input int  UI_X          = 10;
input int  UI_Y          = 10;
input int  UI_W          = 1050;
input int  UI_H          = 540;
input int  UI_Pad        = 10;

input string UI_Font      = "Consolas";
input int    UI_FontTitle = 20;
input int    UI_FontBase  = 14;
input int    UI_FontSmall = 12;

// Colors
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
string g_prefix="GRP_";

enum ENUM_TAB { TAB_WINDOWS=0, TAB_STATS=1, TAB_QUANTS=2, TAB_PLAN=3 };
int g_tab = TAB_WINDOWS;

int    g_winMins[];
string g_winLabels[];
int g_activeWindowIx = 0;

long    g_ts[];
double g_gap[];
double g_mid1[];
double g_mid2[];
int    g_cap=0, g_head=0, g_count=0;

bool   g_dirty=true;
long   g_lastRenderMs=0;
double g_lastRenderedGap=0.0;
bool   g_hasRenderedGap=false;

double g_lastGap=0.0, g_lastP1=0.0, g_lastP2=0.0, g_lastM1=0.0, g_lastM2=0.0;
bool   g_haveTick=false;

// Alert state
datetime g_lastAlertTime = 0;
bool     g_isAlertActive = false;

// layout
int g_panelX=0, g_panelY=0, g_panelW=0, g_panelH=0;
int g_contentX=0, g_contentY=0, g_contentW=0, g_contentH=0;
int g_tableX=0, g_tableY=0, g_tableW=0, g_tableH=0;
int g_rowH=26;
int g_colW[];
int g_cols=0;
int g_rows=0;

//====================== UTILS ======================//
long NowMs(){ return (long)GetTickCount64(); }
int  IMin(int a,int b){ return (a<b?a:b); }
int  IMax(int a,int b){ return (a>b?a:b); }

string F2(double v){ return DoubleToString(v,2); }
string F3(double v){ return DoubleToString(v,3); }
string F4(double v){ return DoubleToString(v,4); }

string TrimStr(string s){ StringTrimLeft(s); StringTrimRight(s); return s; }

bool StartsWith(const string s, const string pref)
{
  return (StringLen(s)>=StringLen(pref) && StringSubstr(s,0,StringLen(pref))==pref);
}

bool GetTickSafe(const string sym, MqlTick &t)
{
  if(!SymbolSelect(sym,true)) return false;
  if(!SymbolInfoTick(sym,t))  return false;
  return (t.bid>0 && t.ask>0);
}

string UrlEncode(string text) 
{
   string out = "";
   uchar src[];
   StringToCharArray(text, src);
   for(int i=0; i<ArraySize(src)-1; i++) 
   {
      if(src[i] == ' ') out += "%20";
      else if(src[i] == '\n') out += "%0A";
      else out += CharToString(src[i]);
   }
   return out;
}

void SendTelegram(string message)
{
   if(!InpTeleAlerts || InpTeleChatID == 0 || InpTeleToken == "YOUR_TOKEN") return;
   
   string url = "https://api.telegram.org/bot" + InpTeleToken + "/sendMessage";
   // MQL5 WebRequest requires the parameters to be in the 'data' array for POST, 
   // or appended to the URL for GET. We will use the URL approach for simplicity.
   string full_url = url + "?chat_id=" + IntegerToString(InpTeleChatID) + "&text=" + UrlEncode(message);
   
   char data[];      // Empty data array for POST body
   char result[];    // Array to store the server response
   string headers;   // String to store response headers
   
   // Reset the error state before call
   ResetLastError();
   
   // Note: We use "GET" here to avoid complex byte array conversions for the message body
   int res = WebRequest("GET", full_url, headers, 1000, data, result, headers);
   
   if(res == -1) 
   {
      Print("GRP Telegram Error: ", GetLastError());
      // Common error 4060: You forgot to add https://api.telegram.org to the Allowed URLs list
   }
}


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

string DirText()
{
  return (InpGapDir==GAP_SELL_ONLY) ? "SELL_ONLY (Bid1-Ask2)" : "BUY_ONLY (Ask1-Bid2)";
}

//====================== WINDOWS ======================//
int UnitValueToMinutes(const ENUM_WIN_UNIT unit, double val)
{
  if(val<=0.0) val=1.0;
  double mins = (unit==UNIT_MINUTES) ? val : (val*60.0);
  int out = (int)MathRound(mins);
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
  if(unit==UNIT_HOURS)
    return NumToCleanStr(val) + "H";
  return IntegerToString(mins) + "m";
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
        int tm = mins[i];
        mins[i] = mins[j];
        mins[j] = tm;
        string ts = labels[i];
        labels[i] = labels[j];
        labels[j] = ts;
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

  AddWinMinutes(W1_Enable,  W1_Unit,  W1_Value,  tmpMins, tmpLabels);
  AddWinMinutes(W2_Enable,  W2_Unit,  W2_Value,  tmpMins, tmpLabels);
  AddWinMinutes(W3_Enable,  W3_Unit,  W3_Value,  tmpMins, tmpLabels);
  AddWinMinutes(W4_Enable,  W4_Unit,  W4_Value,  tmpMins, tmpLabels);
  AddWinMinutes(W5_Enable,  W5_Unit,  W5_Value,  tmpMins, tmpLabels);
  AddWinMinutes(W6_Enable,  W6_Unit,  W6_Value,  tmpMins, tmpLabels);

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

//====================== RING BUFFER ======================//
void RingInit()
{
  int maxWin = 60;
  if(ArraySize(g_winMins)>0)
    maxWin = MaxWindowMinutes();

  int histMins = MathMax(InpHistoryMinutes, maxWin + 5);
  double perMin = 60000.0 / (double)MathMax(InpSampleMs,50);
  int cap = (int)MathCeil((double)histMins * perMin) + 10;

  cap = MathMax(400, cap);
  cap = MathMin(InpMaxSamples, cap);

  g_cap=cap;
  ArrayResize(g_ts,  g_cap);
  ArrayResize(g_gap, g_cap);
  ArrayResize(g_mid1,g_cap);
  ArrayResize(g_mid2,g_cap);
  g_head=0;
  g_count=0;
}

void RingPush(const long ts_ms, const double gap, const double m1, const double m2)
{
  if(g_cap<=0) return;
  g_ts[g_head]=ts_ms;
  g_gap[g_head]=gap;
  g_mid1[g_head]=m1;
  g_mid2[g_head]=m2;
  g_head=(g_head+1)%g_cap;
  if(g_count<g_cap) g_count++;
}

bool RingGetByAge(const int age, long &ts_ms, double &gap, double &m1, double &m2)
{
  if(age<0 || age>=g_count || g_cap<=0) return false;
  int idx=g_head-1-age;
  while(idx<0) idx+=g_cap;
  idx%=g_cap;
  ts_ms=g_ts[idx];
  gap =g_gap[idx];
  m1  =g_mid1[idx];
  m2  =g_mid2[idx];
  return true;
}

bool CopyWindow_NewestToOldest(const int window_minutes, long &out_ts[], double &out_gap[], double &out_m1[], double &out_m2[])
{
  ArrayResize(out_ts,0);
  ArrayResize(out_gap,0);
  ArrayResize(out_m1,0);
  ArrayResize(out_m2,0);
  if(g_count<=0) return false;

  long now=NowMs();
  long cutoff=now-(long)window_minutes*60L*1000L;

  int cnt=0;
  for(int age=0; age<g_count; age++)
  {
    long ts; double gp,m1,m2;
    if(!RingGetByAge(age,ts,gp,m1,m2)) break;
    if(ts<cutoff) break;
    cnt++;
  }
  if(cnt<=1) return false;

  ArrayResize(out_ts,cnt);
  ArrayResize(out_gap,cnt);
  ArrayResize(out_m1,cnt);
  ArrayResize(out_m2,cnt);

  for(int i=0;i<cnt;i++)
  {
    long ts; double gp,m1,m2;
    RingGetByAge(i,ts,gp,m1,m2);
    out_ts[i]=ts; out_gap[i]=gp; out_m1[i]=m1; out_m2[i]=m2;
  }
  return true;
}

//====================== STATS ======================//
bool MinMax(const double &a[], double &mn, double &mx)
{
  int n=ArraySize(a);
  if(n<=0) return false;
  mn=a[0]; mx=a[0];
  for(int i=1;i<n;i++){ mn=MathMin(mn,a[i]); mx=MathMax(mx,a[i]); }
  return true;
}

bool MeanStd(const double &a[], double &mean, double &std)
{
  int n=ArraySize(a);
  if(n<=1) return false;
  double s=0;
  for(int i=0;i<n;i++) s+=a[i];
  mean=s/n;
  double v=0;
  for(int i=0;i<n;i++){ double d=a[i]-mean; v+=d*d; }
  std=MathSqrt(v/(n-1));
  return true;
}

bool Quantile(const double &a[], double q, double &out)
{
  int n=ArraySize(a);
  if(n<=0) return false;
  if(q<0) q=0; if(q>1) q=1;
  double values[];
  ArrayResize(values,n);
  for(int i=0;i<n;i++) values[i]=a[i];
  ArraySort(values);
  double pos=q*(n-1);
  int lo=(int)MathFloor(pos);
  int hi=(int)MathCeil(pos);
  if(lo<0) lo=0; if(hi>n-1) hi=n-1;
  if(lo==hi){ out=values[lo]; return true; }
  double w=pos-lo;
  out = values[lo]*(1.0-w) + values[hi]*w;
  return true;
}

bool PearsonCorr(const double &x[], const double &y[], double &corr)
{
  int n=ArraySize(x);
  if(n<=2 || ArraySize(y)!=n) return false;
  double mx=0,my=0;
  for(int i=0;i<n;i++){ mx+=x[i]; my+=y[i]; }
  mx/=n; my/=n;
  double sxx=0, syy=0, sxy=0;
  for(int i=0;i<n;i++)
  {
    double dx=x[i]-mx, dy=y[i]-my;
    sxx+=dx*dx; syy+=dy*dy; sxy+=dx*dy;
  }
  if(sxx<=0 || syy<=0) return false;
  corr = sxy / MathSqrt(sxx*syy);
  return true;
}

bool SlopePerMin(const long &ts_ms[], const double &gap[], double &slope)
{
  int n=ArraySize(gap);
  if(n<=2 || ArraySize(ts_ms)!=n) return false;
  long t0 = ts_ms[n-1];
  double sx=0, sy=0, sxx=0, sxy=0;
  for(int i=0;i<n;i++)
  {
    double x=(double)(ts_ms[i]-t0)/60000.0;
    double y=gap[i];
    sx+=x; sy+=y; sxx+=x*x; sxy+=x*y;
  }
  double denom=n*sxx - sx*sx;
  if(MathAbs(denom)<1e-12) return false;
  slope=(n*sxy - sx*sy)/denom;
  return true;
}

//====================== ALERT LOGIC ======================//
void CheckAlertLogic(double currentGap, double mean, double std, double p90, double p10, double corr)
{
   // Alert once per 5 minutes for same event
   if(TimeCurrent() < g_lastAlertTime + 300) return;

   double z = (std > 0) ? (currentGap - mean) / std : 0;
   
   // --- OAG CONDITION (Open Arbitrage Gap) ---
   bool isOAG = false;
   if(InpGapDir == GAP_SELL_ONLY && currentGap >= p90 && z >= InpZThreshold) isOAG = true;
   if(InpGapDir == GAP_BUY_ONLY  && currentGap <= p10 && z <= -InpZThreshold) isOAG = true;

   if(isOAG && !g_isAlertActive && MathAbs(corr) > 0.90)
   {
      string msg = "🚀 OAG ALERT (Entry Signal)\n" +
                   "Sym: " + InpSymbol1 + " / " + InpSymbol2 + "\n" +
                   "Gap: " + F2(currentGap) + " (Z: " + F2(z) + ")\n" +
                   "P90: " + F2(p90) + " | P10: " + F2(p10) + "\n" +
                   "Corr: " + F3(corr);
      SendTelegram(msg);
      g_isAlertActive = true;
      g_lastAlertTime = TimeCurrent();
   }

   // --- CAG CONDITION (Close Arbitrage Gap) ---
   if(g_isAlertActive)
   {
      bool isCAG = false;
      if(InpGapDir == GAP_SELL_ONLY && currentGap <= mean) isCAG = true;
      if(InpGapDir == GAP_BUY_ONLY  && currentGap >= mean) isCAG = true;

      if(isCAG)
      {
         string msg = "✅ CAG ALERT (Target Met)\n" +
                      "Gap reverted to Mean: " + F2(mean) + "\n" +
                      "Current Gap: " + F2(currentGap);
         SendTelegram(msg);
         g_isAlertActive = false; 
      }
   }
}

//====================== UI FUNCTIONS ======================//
void DeleteUI()
{
  int total=ObjectsTotal(0,0,-1);
  for(int i=total-1;i>=0;i--)
  {
    string n=ObjectName(0,i,0,-1);
    if(StartsWith(n,g_prefix)) ObjectDelete(0,n);
  }
}

bool CreateRect(const string n,int x,int y,int w,int h,color bg,color border)
{
  if(!ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0)) return false;
  ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
  ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
  ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
  ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
  ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
  ObjectSetInteger(0,n,OBJPROP_COLOR,border);
  ObjectSetInteger(0,n,OBJPROP_BACK,false);
  ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
  ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  return true;
}

bool CreateLabel(const string n,int x,int y,const string txt,int fsize,color col)
{
  if(!ObjectCreate(0,n,OBJ_LABEL,0,0,0)) return false;
  ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
  ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
  ObjectSetInteger(0,n,OBJPROP_COLOR,col);
  ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fsize);
  ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
  ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  ObjectSetString (0,n,OBJPROP_FONT,UI_Font);
  ObjectSetString (0,n,OBJPROP_TEXT,txt);
  return true;
}

bool CreateCellBG(const string n,int x,int y,int w,int h,color bg)
{
  if(!ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0)) return false;
  ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
  ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
  ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
  ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
  ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
  ObjectSetInteger(0,n,OBJPROP_COLOR,ColBorder);
  ObjectSetInteger(0,n,OBJPROP_BACK,false);
  ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
  ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  return true;
}

bool CreateButton(const string n,int x,int y,int w,int h,const string txt,color bg,int fsize)
{
  if(!ObjectCreate(0,n,OBJ_BUTTON,0,0,0)) return false;
  ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
  ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
  ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
  ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
  ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
  ObjectSetInteger(0,n,OBJPROP_COLOR,clrBlack);
  ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fsize);
  ObjectSetString (0,n,OBJPROP_TEXT,txt);
  ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  ObjectSetInteger(0,n,OBJPROP_STATE,false);
  ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
  return true;
}

void SetText(const string n,const string t)
{
  if(ObjectFind(0,n)>=0) ObjectSetString(0,n,OBJPROP_TEXT,t);
}
void SetBG(const string n,color bg)
{
  if(ObjectFind(0,n)>=0) ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
}
void ResetBtn(const string n)
{
  if(ObjectFind(0,n)>=0) ObjectSetInteger(0,n,OBJPROP_STATE,false);
}

//====================== LAYOUT / TABLE ======================//
void ComputePanelSize()
{
  int cw=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0);
  int ch=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);
  g_panelX=UI_X; g_panelY=UI_Y;

  if(UI_AutoSize)
  {
    g_panelW = IMax(760, cw - (UI_X*2));
    g_panelH = IMax(420, ch - (UI_Y*2));
  }
  else
  {
    g_panelW = IMin(UI_W, cw-10);
    g_panelH = IMin(UI_H, ch-10);
  }

  g_contentX = g_panelX + UI_Pad;
  g_contentY = g_panelY + UI_Pad;
  g_contentW = g_panelW - 2*UI_Pad;
  g_contentH = g_panelH - 2*UI_Pad;
}

void BuildTableGrid(int cols, int rows, const int &colW[])
{
  g_cols=cols; g_rows=rows;
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
      CreateCellBG(bgN,x,y,w,g_rowH,rowbg);
      CreateLabel(txN, x+8, y+4, "", UI_FontBase, (r==0?ColMuted:ColInfo));
      x+=w;
    }
    y += g_rowH;
  }
}

void ClearTableText()
{
  for(int r=0;r<g_rows;r++)
    for(int c=0;c<g_cols;c++)
      SetText(g_prefix+"TX_"+IntegerToString(r)+"_"+IntegerToString(c), "");
}

void SetCell(int r,int c,const string text,color col=clrNONE)
{
  string n=g_prefix+"TX_"+IntegerToString(r)+"_"+IntegerToString(c);
  if(ObjectFind(0,n)>=0)
  {
    ObjectSetString(0,n,OBJPROP_TEXT,text);
    if(col!=clrNONE) ObjectSetInteger(0,n,OBJPROP_COLOR,col);
  }
}

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

void BuildUI()
{
  ComputePanelSize();
  DeleteUI();

  CreateRect(g_prefix+"PANEL", g_panelX,g_panelY,g_panelW,g_panelH, ColPanelBG,ColBorder);
  CreateLabel(g_prefix+"TITLE", g_contentX, g_contentY, "GAP RADAR PRO v2.03", UI_FontTitle, ColTitle);

  int tabY=g_contentY+34, tabW=150, tabH=28, tabGap=10;
  CreateButton(g_prefix+"TAB0", g_contentX,                   tabY,tabW,tabH,"WINDOWS",    (g_tab==TAB_WINDOWS?ColTabOnBG:ColTabOffBG), UI_FontBase);
  CreateButton(g_prefix+"TAB1", g_contentX+(tabW+tabGap),     tabY,tabW,tabH,"STATS+CORR", (g_tab==TAB_STATS  ?ColTabOnBG:ColTabOffBG), UI_FontBase);
  CreateButton(g_prefix+"TAB2", g_contentX+2*(tabW+tabGap), tabY,tabW,tabH,"P10-P90",    (g_tab==TAB_QUANTS ?ColTabOnBG:ColTabOffBG), UI_FontBase);
  CreateButton(g_prefix+"TAB3", g_contentX+3*(tabW+tabGap), tabY,tabW,tabH,"PLAN",       (g_tab==TAB_PLAN   ?ColTabOnBG:ColTabOffBG), UI_FontBase);

  int hY=tabY+tabH+10;
  CreateLabel(g_prefix+"H1", g_contentX, hY,   "", UI_FontBase,  ColInfo);
  CreateLabel(g_prefix+"H2", g_contentX, hY+22,"", UI_FontBase,  ColMuted);
  CreateLabel(g_prefix+"H3", g_contentX, hY+44,"", UI_FontSmall, ColMuted);

  if(g_tab==TAB_WINDOWS)
  {
    int cols=5; ArrayResize(g_colW, cols);
    int w0=120; int rem=g_contentW-w0; int w=rem/4;
    g_colW[0]=w0; g_colW[1]=w; g_colW[2]=w; g_colW[3]=w; g_colW[4]=rem-3*w;
    BuildTableGrid(cols, 1+ArraySize(g_winMins), g_colW);
  }
  else if(g_tab==TAB_STATS)
  {
    int cols=7; ArrayResize(g_colW, cols);
    int w0=110,w1=110,wZ=90,wC=110,wS=140; int rem=g_contentW-(w0+w1+wZ+wC+wS);
    int wMean=rem/2; int wStd=rem-wMean;
    g_colW[0]=w0; g_colW[1]=w1; g_colW[2]=wMean; g_colW[3]=wStd; g_colW[4]=wZ; g_colW[5]=wC; g_colW[6]=wS;
    BuildTableGrid(cols, 1+ArraySize(g_winMins), g_colW);
  }
  else if(g_tab==TAB_QUANTS)
  {
    int cols=6; ArrayResize(g_colW, cols);
    int w0=110; int rem=g_contentW-w0; int w=rem/5;
    g_colW[0]=w0; g_colW[1]=w; g_colW[2]=w; g_colW[3]=w; g_colW[4]=w; g_colW[5]=rem-4*w;
    BuildTableGrid(cols, 1+ArraySize(g_winMins), g_colW);
  }
  else
  {
    int cols=2; ArrayResize(g_colW, cols);
    g_colW[0]=160; g_colW[1]=g_contentW-g_colW[0];
    BuildTableGrid(cols, 1+10, g_colW);
  }
  g_dirty=true;
}

//====================== RENDER FUNCTIONS ======================//
void RenderHeadline()
{
  if(!g_haveTick)
  {
    SetText(g_prefix+"H1","S1: "+InpSymbol1+"  |  S2: "+InpSymbol2+"  |  "+DirText());
    SetText(g_prefix+"H2","GAP: --   P1: --   P2: --");
    SetText(g_prefix+"H3","Waiting for ticks...");
    return;
  }
  int win=g_winMins[g_activeWindowIx];
  string winLabel=WindowLabelByIndex(g_activeWindowIx);
  SetText(g_prefix+"H1","S1: "+InpSymbol1+"  |  S2: "+InpSymbol2+"  |  "+DirText());
  SetText(g_prefix+"H2","CURRENT GAP: "+F2(g_lastGap)+"   |   P1: "+F2(g_lastP1)+"   P2: "+F2(g_lastP2));
  long ts[]; double gap[]; double m1[]; double m2[];
  if(!CopyWindow_NewestToOldest(win,ts,gap,m1,m2)) return;
  double mean=0,std=0,corr=0,slope=0;
  MeanStd(gap,mean,std);
  double z=(std>0 ? (g_lastGap-mean)/std : 0.0);
  bool okC=PearsonCorr(m1,m2,corr);
  bool okS=SlopePerMin(ts,gap,slope);
  string line="Window: "+winLabel+" | Z: "+F2(z)+" | Corr: "+(okC?F3(corr):"--")+" | Slope: "+(okS?F4(slope):"--")+" | Alert: "+(g_isAlertActive?"ACTIVE":"READY");
  SetText(g_prefix+"H3",line);
}

void RenderWindowsTab(){
  ClearTableText(); SetCell(0,0,"Window"); SetCell(0,1,"Max"); SetCell(0,2,"Min"); SetCell(0,3,"Median"); SetCell(0,4,"Mean");
  for(int i=0;i<ArraySize(g_winMins);i++){
    int r=1+i; long ts[]; double gap[],m1[],m2[];
    if(!CopyWindow_NewestToOldest(g_winMins[i],ts,gap,m1,m2)) continue;
    double mn,mx,med,mean,std; MinMax(gap,mn,mx); Quantile(gap,0.5,med); MeanStd(gap,mean,std);
    SetCell(r,0,g_winLabels[i]); SetCell(r,1,F2(mx)); SetCell(r,2,F2(mn)); SetCell(r,3,F2(med)); SetCell(r,4,F2(mean));
  }
}

void RenderStatsTab(){
  ClearTableText(); SetCell(0,0,"Window"); SetCell(0,1,"Samples"); SetCell(0,2,"Mean(G)"); SetCell(0,3,"Std(G)"); SetCell(0,4,"Z(now)"); SetCell(0,5,"Corr"); SetCell(0,6,"Slope");
  for(int i=0;i<ArraySize(g_winMins);i++){
    int r=1+i; long ts[]; double gap[],m1[],m2[];
    if(!CopyWindow_NewestToOldest(g_winMins[i],ts,gap,m1,m2)) continue;
    double mean,std,corr,slope; MeanStd(gap,mean,std); double z=(std>0?(g_lastGap-mean)/std:0); PearsonCorr(m1,m2,corr); SlopePerMin(ts,gap,slope);
    SetCell(r,0,g_winLabels[i]); SetCell(r,1,IntegerToString(ArraySize(gap))); SetCell(r,2,F2(mean)); SetCell(r,3,F2(std)); SetCell(r,4,F2(z),ZColor(z)); SetCell(r,5,F3(corr),CorrColor(corr)); SetCell(r,6,F4(slope));
  }
}

void RenderQuantsTab(){
  ClearTableText(); SetCell(0,0,"Window"); SetCell(0,1,"P10"); SetCell(0,2,"P25"); SetCell(0,3,"P50"); SetCell(0,4,"P75"); SetCell(0,5,"P90");
  for(int i=0;i<ArraySize(g_winMins);i++){
    int r=1+i; long ts[]; double gap[],m1[],m2[];
    if(!CopyWindow_NewestToOldest(g_winMins[i],ts,gap,m1,m2)) continue;
    double p10,p25,p50,p75,p90; Quantile(gap,0.1,p10); Quantile(gap,0.25,p25); Quantile(gap,0.5,p50); Quantile(gap,0.75,p75); Quantile(gap,0.9,p90);
    SetCell(r,0,g_winLabels[i]); SetCell(r,1,F2(p10)); SetCell(r,2,F2(p25)); SetCell(r,3,F2(p50)); SetCell(r,4,F2(p75)); SetCell(r,5,F2(p90));
  }
}

void RenderPlanTab(){
  ClearTableText(); SetCell(0,0,"Alert Mode"); SetCell(0,1,"Telegram Alerts Active: "+(InpTeleAlerts?"YES":"NO"));
  SetCell(1,0,"OAG Trigger"); SetCell(1,1,"Gap > P90 + Z-Score > "+F2(InpZThreshold));
  SetCell(2,0,"CAG Trigger"); SetCell(2,1,"Gap reverts to historical Mean (P50)");
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
void SampleAndMaybeRender()
{
  double gap,p1,p2,m1,m2;
  bool ok=ComputeGap(gap,p1,p2,m1,m2);
  if(ok)
  {
    g_haveTick=true;
    g_lastGap=gap; g_lastP1=p1; g_lastP2=p2; g_lastM1=m1; g_lastM2=m2;
    RingPush(NowMs(), gap, m1, m2);

    // Run Alert Logic
    int win = g_winMins[g_activeWindowIx];
    long ts[]; double gaps[], m_1[], m_2[];
    if(CopyWindow_NewestToOldest(win, ts, gaps, m_1, m_2))
    {
       double mean, std, p90, p10, corr;
       MeanStd(gaps, mean, std);
       Quantile(gaps, 0.90, p90);
       Quantile(gaps, 0.10, p10);
       PearsonCorr(m_1, m_2, corr);
       CheckAlertLogic(gap, mean, std, p90, p10, corr);
    }
  }

  long now=NowMs();
  bool time_ok = (now - g_lastRenderMs) >= (long)MathMax(InpRenderMinMs,200);
  bool delta_ok = (!g_hasRenderedGap && ok) || (ok && MathAbs(gap-g_lastRenderedGap)>=InpGapDeltaToRender);

  if(g_dirty || (ok && (time_ok || delta_ok)))
  {
    Render();
    g_lastRenderMs=now;
    if(ok){ g_lastRenderedGap=gap; g_hasRenderedGap=true; }
    g_dirty=false;
    ChartRedraw(0);
  }
}

//====================== EVENTS ======================//
int OnInit()
{
  BuildWindowsFromInputs(); RingInit(); BuildUI();
  int ms=InpSampleMs; if(ms<50) ms=50;
  EventSetMillisecondTimer(ms);
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){ EventKillTimer(); DeleteUI(); }

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[], const double &open[], const double &high[], const double &low[], const double &close[], const long &tick_volume[], const long &volume[], const int &spread[]){ return rates_total; }

void OnTimer(){ SampleAndMaybeRender(); }

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
  if(newtab!=g_tab){ g_tab=newtab; BuildUI(); g_dirty=true; }
}