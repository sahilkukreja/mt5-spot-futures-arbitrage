//+------------------------------------------------------------------+
//| GapRadarTableEA.mq5                                              |
//| v2.20 - REAL UI rendering (pair/live gap + per-window stats)      |
//+------------------------------------------------------------------+
#property strict
#property version "2.20"

input string InpSymbol1 = "GCJ26.ma";
input string InpSymbol2 = "XAUUSD.pp";

enum ENUM_GAP_DIR { GAP_SELL_ONLY=1, GAP_BUY_ONLY=2 };
input ENUM_GAP_DIR InpGapDir = GAP_SELL_ONLY;

input int  InpSampleMs       = 200;
input int  InpHistoryMinutes = 12*60;
input int  InpMaxSamples     = 8000;

input int    InpRenderMinMs      = 800;
input double InpGapDeltaToRender = 0.02;

// ===== WINDOW SIZE INPUT =====
// examples: "60" or "60,240,720"
input string InpWindowsMinutes = "60,240,720";
// which window index to use for OAG/CAG (0..n-1)
input int    InpActiveWindowIx = 0;

// Quantiles for OAG and CAG target
input double InpOAG_Quantile = 0.90;  // entry threshold (e.g., p90)
input double InpCAG_Quantile = 0.50;  // exit target (e.g., p50)

// ===== UI =====
input int    UI_X = 10;
input int    UI_Y = 10;
input double UI_Scale = 1.25;
input string UI_Font  = "Consolas";

input int UI_FontHeader = 16;
input int UI_FontRow    = 16;
input int UI_RowH       = 26;
input int UI_Pad        = 10;

input color ColBG     = clrWhite;
input color ColBorder = clrSilver;
input color ColHdr    = clrDimGray;

input color ColGood   = clrDarkGreen;
input color ColWarn   = clrOrange;
input color ColBad    = clrRed;
input color ColText   = clrBlack;
input color ColSubtle = clrGray;

// Columns widths (scaled)
input int COL_A = 280;  // left column
input int COL_B = 140;
input int COL_C = 140;
input int COL_D = 140;
input int COL_GAP = 18;

// ===== internal =====
string g_prefix="GRT_";

long   g_ts[];
double g_gap[];
int    g_cap=0, g_head=0, g_count=0;

bool   g_dirty=true;
long   g_lastRenderMs=0;
double g_lastRenderedGap=0.0;
bool   g_hasRenderedGap=false;

double g_lastGap=0.0, g_lastP1=0.0, g_lastP2=0.0;
bool   g_haveGap=false;

int g_windows[]; // parsed from input

// ---------- helpers ----------
int  S(const int v){ return (int)MathRound((double)v * UI_Scale); }
long NowMs(){ return (long)GetTickCount64(); }
string F2(const double v){ return DoubleToString(v,2); }

bool GetTickSafe(const string sym, MqlTick &t)
{
  if(!SymbolSelect(sym,true)) return false;
  if(!SymbolInfoTick(sym,t))  return false;
  return (t.bid>0 && t.ask>0);
}

bool ComputeGap(double &gap,double &p1,double &p2)
{
  MqlTick t1,t2;
  if(!GetTickSafe(InpSymbol1,t1)) return false;
  if(!GetTickSafe(InpSymbol2,t2)) return false;

  if(InpGapDir==GAP_SELL_ONLY){ p1=t1.bid; p2=t2.ask; }
  else                        { p1=t1.ask; p2=t2.bid; }

  gap = p1 - p2;
  return true;
}

// ---------- ring ----------
void RingInit()
{
  double perMin = 60000.0 / (double)MathMax(InpSampleMs,50);
  int cap = (int)MathCeil((double)InpHistoryMinutes * perMin) + 10;
  cap = MathMax(300, cap);
  cap = MathMin(InpMaxSamples, cap);

  g_cap=cap;
  ArrayResize(g_ts,g_cap);
  ArrayResize(g_gap,g_cap);
  g_head=0;
  g_count=0;
}

void RingPush(const long ts_ms, const double gap)
{
  if(g_cap<=0) return;
  g_ts[g_head]=ts_ms;
  g_gap[g_head]=gap;
  g_head=(g_head+1)%g_cap;
  if(g_count<g_cap) g_count++;
}

bool RingGetByAge(const int age, long &ts_ms, double &gap)
{
  if(age<0 || age>=g_count || g_cap<=0) return false;
  int idx=g_head-1-age;
  while(idx<0) idx+=g_cap;
  idx%=g_cap;
  ts_ms=g_ts[idx];
  gap=g_gap[idx];
  return true;
}

bool CopyWindow_NewestToOldest(const int window_minutes, double &out[])
{
  ArrayResize(out,0);
  if(g_count<=0) return false;

  long now=NowMs();
  long cutoff=now-(long)window_minutes*60L*1000L;

  int cnt=0;
  for(int age=0; age<g_count; age++)
  {
    long ts; double gp;
    if(!RingGetByAge(age,ts,gp)) break;
    if(ts<cutoff) break;
    cnt++;
  }
  if(cnt<=0) return false;

  ArrayResize(out,cnt);
  for(int i=0;i<cnt;i++)
  {
    long ts; double gp;
    RingGetByAge(i,ts,gp);
    out[i]=gp;
  }
  return true;
}

// ---------- stats ----------
void SortAsc(double &arr[])
{
  int n=ArraySize(arr);
  if(n<=1) return;
  for(int i=1;i<n;i++)
  {
    double key=arr[i];
    int j=i-1;
    while(j>=0 && arr[j]>key){ arr[j+1]=arr[j]; j--; }
    arr[j+1]=key;
  }
}

bool Quantile(const double &a[], double q, double &out)
{
  int n=ArraySize(a);
  if(n<=0) return false;
  if(q<0) q=0; if(q>1) q=1;

  double v[];
  ArrayResize(v,n);
  for(int i=0;i<n;i++) v[i]=a[i];
  SortAsc(v);

  double pos=q*(n-1);
  int lo=(int)MathFloor(pos), hi=(int)MathCeil(pos);
  if(lo<0) lo=0; if(hi>n-1) hi=n-1;
  if(lo==hi){ out=v[lo]; return true; }
  double w=pos-lo;
  out=v[lo]*(1.0-w)+v[hi]*w;
  return true;
}

// ---------- parse windows ----------
void ParseWindows()
{
  ArrayResize(g_windows,0);

  string s=InpWindowsMinutes;
  StringReplace(s," ","");

  if(StringLen(s)<=0)
  {
    ArrayResize(g_windows,1);
    g_windows[0]=60;
    return;
  }

  string parts[];
  int n=StringSplit(s,',',parts);
  if(n<=0)
  {
    ArrayResize(g_windows,1);
    g_windows[0]=60;
    return;
  }

  int tmp[];
  ArrayResize(tmp,0);

  for(int i=0;i<n;i++)
  {
    int w=(int)StringToInteger(parts[i]);
    if(w<=0) continue;
    int old=ArraySize(tmp);
    ArrayResize(tmp,old+1);
    tmp[old]=w;
  }

  if(ArraySize(tmp)<=0)
  {
    ArrayResize(g_windows,1);
    g_windows[0]=60;
    return;
  }

  ArrayResize(g_windows, ArraySize(tmp));
  ArrayCopy(g_windows, tmp, 0, 0, WHOLE_ARRAY);
}

// ---------- UI primitives ----------
void CreateOrUpdateRect(const string n,int x,int y,int w,int h,color bg,color border)
{
  if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
  ObjectSetInteger(0,n,OBJPROP_CORNER, CORNER_LEFT_UPPER);
  ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
  ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
  ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
  ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
  ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
  ObjectSetInteger(0,n,OBJPROP_COLOR,border);
  ObjectSetInteger(0,n,OBJPROP_WIDTH,1);
  ObjectSetInteger(0,n,OBJPROP_BACK,false);
  ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
  ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}

void CreateOrUpdateLabel(const string n,int x,int y,const string txt,int fs,color col,bool bold=false)
{
  if(ObjectFind(0,n)<0)
  {
    ObjectCreate(0,n,OBJ_LABEL,0,0,0);
    ObjectSetString (0,n,OBJPROP_FONT,UI_Font);
    ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
    ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
    ObjectSetInteger(0,n,OBJPROP_BACK,false);
  }
  ObjectSetInteger(0,n,OBJPROP_CORNER, CORNER_LEFT_UPPER);
  ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
  ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
  ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
  ObjectSetInteger(0,n,OBJPROP_COLOR,col);
  ObjectSetString (0,n,OBJPROP_TEXT,(txt==""?" ":txt));
}

void DeleteAllUI()
{
  int total=ObjectsTotal(0,0,-1);
  for(int i=total-1;i>=0;i--)
  {
    string name=ObjectName(0,i,0,-1);
    if(StringFind(name,g_prefix)==0)
      ObjectDelete(0,name);
  }
}

// ---------- REAL table render ----------
void RenderTable()
{
  int pad=S(UI_Pad), rowH=S(UI_RowH);
  int fsH=S(UI_FontHeader), fsR=S(UI_FontRow);

  int wA=S(COL_A), wB=S(COL_B), wC=S(COL_C), wD=S(COL_D), gap=S(COL_GAP);
  int tableW = wA+wB+wC+wD + 3*gap;

  int wcount = ArraySize(g_windows);
  if(wcount<=0) wcount=1;

  // Layout:
  // Block 1: Pair summary (Header + 2 rows)
  // Block 2: Windows table (Header + wcount rows)
  int rows_block1 = 2;
  int rows_block2 = wcount;

  int panelH = rowH*(1 + rows_block1 + 1 + rows_block2) + 2*pad + rowH; // + one spacer row
  int panelW = tableW + 2*pad;

  CreateOrUpdateRect(g_prefix+"PANEL", UI_X, UI_Y, panelW, panelH, ColBG, ColBorder);

  int x0 = UI_X + pad;
  int y  = UI_Y + pad;

  // ===== Block 1 header
  CreateOrUpdateLabel(g_prefix+"B1H_A", x0, y, "PAIR", fsH, ColHdr, true);
  CreateOrUpdateLabel(g_prefix+"B1H_B", x0+(wA+gap), y, "LIVE_GAP", fsH, ColHdr, true);
  CreateOrUpdateLabel(g_prefix+"B1H_C", x0+(wA+gap)+(wB+gap), y, "OAG(p"+(string)((int)MathRound(InpOAG_Quantile*100))+")", fsH, ColHdr, true);
  CreateOrUpdateLabel(g_prefix+"B1H_D", x0+(wA+gap)+(wB+gap)+(wC+gap), y, "CAG(p"+(string)((int)MathRound(InpCAG_Quantile*100))+")", fsH, ColHdr, true);
  y += rowH;

  // Active window
  int useIx = (ArraySize(g_windows)>0 ? MathMax(0, MathMin(InpActiveWindowIx, ArraySize(g_windows)-1)) : 0);
  int winMin = (ArraySize(g_windows)>0 ? g_windows[useIx] : 60);

  double oag=0, cag=0;
  bool has_plan=false;
  double w[];
  int wn=0;
  if(CopyWindow_NewestToOldest(winMin, w))
  {
    wn = ArraySize(w);
    double qo,qc;
    if(Quantile(w, InpOAG_Quantile, qo) && Quantile(w, InpCAG_Quantile, qc))
    {
      oag=qo; cag=qc;
      has_plan=true;
    }
  }

  string pairName = InpSymbol1 + " / " + InpSymbol2 + "  (" + (InpGapDir==GAP_SELL_ONLY ? "SELL" : "BUY") + ")";
  string liveGap  = (g_haveGap ? F2(g_lastGap) : "--");
  color  gapCol   = (g_haveGap ? ColText : ColSubtle);

  CreateOrUpdateLabel(g_prefix+"B1R0_A", x0, y, pairName, fsR, ColText);
  CreateOrUpdateLabel(g_prefix+"B1R0_B", x0+(wA+gap), y, liveGap, fsR, gapCol, true);
  CreateOrUpdateLabel(g_prefix+"B1R0_C", x0+(wA+gap)+(wB+gap), y, has_plan?F2(oag):"--", fsR, has_plan?ColGood:ColSubtle);
  CreateOrUpdateLabel(g_prefix+"B1R0_D", x0+(wA+gap)+(wB+gap)+(wC+gap), y, has_plan?F2(cag):"--", fsR, has_plan?ColWarn:ColSubtle);
  y += rowH;

  string meta = "Active WIN: " + (string)winMin + "m" + " | Samples: " + (string)wn + " | Timer: " + (string)MathMax(InpSampleMs,50) + "ms";
  CreateOrUpdateLabel(g_prefix+"B1R1_A", x0, y, meta, fsR, ColSubtle);
  CreateOrUpdateLabel(g_prefix+"B1R1_B", x0+(wA+gap), y, "", fsR, ColSubtle);
  CreateOrUpdateLabel(g_prefix+"B1R1_C", x0+(wA+gap)+(wB+gap), y, "", fsR, ColSubtle);
  CreateOrUpdateLabel(g_prefix+"B1R1_D", x0+(wA+gap)+(wB+gap)+(wC+gap), y, "", fsR, ColSubtle);
  y += rowH;

  // spacer
  y += (rowH/2);

  // ===== Block 2 header
  CreateOrUpdateLabel(g_prefix+"B2H_A", x0, y, "WINDOW", fsH, ColHdr, true);
  CreateOrUpdateLabel(g_prefix+"B2H_B", x0+(wA+gap), y, "N", fsH, ColHdr, true);
  CreateOrUpdateLabel(g_prefix+"B2H_C", x0+(wA+gap)+(wB+gap), y, "OAG", fsH, ColHdr, true);
  CreateOrUpdateLabel(g_prefix+"B2H_D", x0+(wA+gap)+(wB+gap)+(wC+gap), y, "CAG", fsH, ColHdr, true);
  y += rowH;

  // ===== Block 2 rows: each window
  int realWcount = ArraySize(g_windows);
  for(int i=0;i<MathMax(1,realWcount);i++)
  {
    int wm = (realWcount>0 ? g_windows[i] : 60);

    double ww[];
    int nn=0;
    double oo=0, cc=0;
    bool ok=false;

    if(CopyWindow_NewestToOldest(wm, ww))
    {
      nn = ArraySize(ww);
      double qo,qc;
      if(Quantile(ww, InpOAG_Quantile, qo) && Quantile(ww, InpCAG_Quantile, qc))
      { oo=qo; cc=qc; ok=true; }
    }

    color rowCol = (i==useIx ? ColText : ColSubtle);
    string r = (i==useIx ? (string)wm+"m  *" : (string)wm+"m");

    CreateOrUpdateLabel(g_prefix+"B2R_A_"+(string)i, x0, y, r, fsR, rowCol, (i==useIx));
    CreateOrUpdateLabel(g_prefix+"B2R_B_"+(string)i, x0+(wA+gap), y, (nn>0?(string)nn:"--"), fsR, (nn>0?ColText:ColSubtle));
    CreateOrUpdateLabel(g_prefix+"B2R_C_"+(string)i, x0+(wA+gap)+(wB+gap), y, ok?F2(oo):"--", fsR, ok?ColGood:ColSubtle);
    CreateOrUpdateLabel(g_prefix+"B2R_D_"+(string)i, x0+(wA+gap)+(wB+gap)+(wC+gap), y, ok?F2(cc):"--", fsR, ok?ColWarn:ColSubtle);

    y += rowH;
  }
}

// ---------- runtime ----------
void SampleAndMaybeRender()
{
  double gap,p1,p2;
  bool ok=ComputeGap(gap,p1,p2);
  if(ok)
  {
    g_haveGap=true;
    g_lastGap=gap; g_lastP1=p1; g_lastP2=p2;
    RingPush(NowMs(), gap);
  }

  long now=NowMs();
  bool time_ok = (now - g_lastRenderMs) >= (long)MathMax(InpRenderMinMs,200);

  bool delta_ok=false;
  if(!g_hasRenderedGap && ok) delta_ok=true;
  else if(ok) delta_ok = (MathAbs(gap - g_lastRenderedGap) >= InpGapDeltaToRender);

  if(g_dirty || (ok && (time_ok || delta_ok)))
  {
    RenderTable();
    g_lastRenderMs = now;
    if(ok){ g_lastRenderedGap=gap; g_hasRenderedGap=true; }
    g_dirty=false;
    ChartRedraw(0);
  }
}

// ---------- EA events ----------
int OnInit()
{
  ParseWindows();
  RingInit();
  DeleteAllUI();

  int ms=InpSampleMs;
  if(ms<50) ms=50;
  EventSetMillisecondTimer(ms);

  g_dirty=true;
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  EventKillTimer();
  DeleteAllUI();
}

void OnTimer()
{
  SampleAndMaybeRender();
}

void OnTick()
{
  long now=NowMs();
  if((now - g_lastRenderMs) >= (long)MathMax(InpRenderMinMs,200))
    SampleAndMaybeRender();
}
//+------------------------------------------------------------------+