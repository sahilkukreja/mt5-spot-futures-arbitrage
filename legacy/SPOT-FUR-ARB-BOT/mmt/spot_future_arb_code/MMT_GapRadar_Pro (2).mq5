//+------------------------------------------------------------------+
//|                                     GapRadar_PlanBuilder_Pro.mq5 |
//|                                     Advanced Statistical Engine  |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window

enum ENUM_OPEN_DIR { DIR_BUY_ONLY=1, DIR_SELL_ONLY=2 };

//====================== INPUTS ======================//
input string        InpSymbol1          = "GCJ26.ma";
input string        InpSymbol2          = "XAUUSD.pp";
input ENUM_OPEN_DIR InpDirection        = DIR_SELL_ONLY;
input int           InpTimerMs          = 200;
input int           InpMaxSamples       = 2000;
input int           InpMinSamplesToShow = 200;

// UI
input int           UI_X                = 10;
input int           UI_Y                = 10;
input int           UI_W                = 1200;
input int           UI_FontBase         = 12;
input string        UI_FontMono         = "Consolas";

// Colors
input color         ColPanelBG          = clrWhite;
input color         ColAccent           = clrBlue;
input color         ColDanger           = clrRed;

//====================== GLOBALS ======================//
string g_prefix = "GRPB_";
int    g_tab = 0; 

// Ring Buffers
double g_gap[], g_p1[], g_p2[];
long   g_ts_ms[];
int    g_head = 0, g_count = 0;
int    g_bodyLines = 22;

//====================== MATH ENGINE ======================//

// 1. Pearson Correlation
double CalculateCorrelation(const double &arr1[], const double &arr2[])
{
   int n = ArraySize(arr1);
   if(n < 10) return 0;
   double sum1=0, sum2=0, sum1_sq=0, sum2_sq=0, sum_p=0;
   for(int i=0; i<n; i++) {
      sum1 += arr1[i]; sum2 += arr2[i];
      sum1_sq += arr1[i]*arr1[i]; sum2_sq += arr2[i]*arr2[i];
      sum_p += arr1[i]*arr2[i];
   }
   double num = (n * sum_p) - (sum1 * sum2);
   double den = MathSqrt((n * sum1_sq - sum1 * sum1) * (n * sum2_sq - sum2 * sum2));
   return (MathAbs(den) < 1e-9) ? 0 : num / den;
}

// 2. Z-Score
double CalculateZScore(double val, double mu, double sd) {
   return (sd > 0.0000001) ? (val - mu) / sd : 0;
}

// 3. Linear Regression Slope
double CalculateSlope(const double &y[], const long &ts[], int n) {
   if(n < 10) return 0; // Not enough data
   
   double sx=0, sy=0, sxx=0, sxy=0;
   double t0 = (double)ts[0]; // Set relative start time
   
   for(int i=0; i<n; i++) {
      // Convert time to minutes relative to start to keep numbers small
      double x = ((double)ts[i] - t0) / 60000.0; 
      double yi = y[i];
      
      sx  += x;
      sy  += yi;
      sxx += x * x;
      sxy += x * yi;
   }
   
   // Denominator for linear regression: n*sum(x^2) - (sum x)^2
   double denom = (n * sxx) - (sx * sx);
   
   // Error Check: Prevent division by zero
   if(MathAbs(denom) < 1e-12) return 0; 
   
   return (n * sxy - sx * sy) / denom;
}

// 4. Optimized Quantile (Sorts once)
double GetQuantile(double &sorted_values[], double q) {
   int n = ArraySize(sorted_values);
   if(n==0) return 0;
   double pos = q * (n - 1);
   int i = (int)MathFloor(pos);
   int j = (int)MathCeil(pos);
   if(i == j) return sorted_values[i];
   return sorted_values[i] + (sorted_values[j] - sorted_values[i]) * (pos - i);
}

//====================== DATA CORE ======================//

void RingPush(long ts, double gap, double p1, double p2) {
   if(ArraySize(g_gap) != InpMaxSamples) {
      ArrayResize(g_gap, InpMaxSamples); ArrayResize(g_p1, InpMaxSamples);
      ArrayResize(g_p2, InpMaxSamples);  ArrayResize(g_ts_ms, InpMaxSamples);
   }
   g_gap[g_head] = gap; g_p1[g_head] = p1; g_p2[g_head] = p2; g_ts_ms[g_head] = ts;
   g_head = (g_head + 1) % InpMaxSamples;
   if(g_count < InpMaxSamples) g_count++;
}

bool RingGetByAge(int age, long &ts, double &gap, double &p1, double &p2) {
   if(age < 0 || age >= g_count) return false;
   int idx = (g_head - 1 - age + InpMaxSamples) % InpMaxSamples;
   ts = g_ts_ms[idx]; gap = g_gap[idx]; p1 = g_p1[idx]; p2 = g_p2[idx];
   return true;
}

//====================== UI SYSTEM ======================//

void BuildUI() {
   int x = UI_X, y = UI_Y;
   ObjectCreate(0,g_prefix+"BG", OBJ_RECTANGLE_LABEL, 0,0,0);
   ObjectSetInteger(0,g_prefix+"BG", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0,g_prefix+"BG", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0,g_prefix+"BG", OBJPROP_XSIZE, UI_W);
   ObjectSetInteger(0,g_prefix+"BG", OBJPROP_YSIZE, 500);
   ObjectSetInteger(0,g_prefix+"BG", OBJPROP_COLOR, ColPanelBG);

   ObjectCreate(0,g_prefix+"TITLE", OBJ_LABEL, 0,0,0);
   ObjectSetInteger(0,g_prefix+"TITLE", OBJPROP_XDISTANCE, x+10);
   ObjectSetInteger(0,g_prefix+"TITLE", OBJPROP_YDISTANCE, y+10);
   ObjectSetString(0,g_prefix+"TITLE", OBJPROP_TEXT, "GAP RADAR PRO | Stats & Pearson Correlation");
   ObjectSetInteger(0,g_prefix+"TITLE", OBJPROP_FONTSIZE, 14);

   for(int i=0; i<g_bodyLines; i++) {
      string nm = g_prefix+"L"+(string)i;
      ObjectCreate(0,nm, OBJ_LABEL, 0,0,0);
      ObjectSetInteger(0,nm, OBJPROP_XDISTANCE, x+20);
      ObjectSetInteger(0,nm, OBJPROP_YDISTANCE, y+80+(i*20));
      ObjectSetString(0,nm, OBJPROP_FONT, UI_FontMono);
      ObjectSetInteger(0,nm, OBJPROP_FONTSIZE, 10);
   }
}

void SetLine(int i, string txt, color clr=clrBlack) {
   string nm = g_prefix+"L"+(string)i;
   ObjectSetString(0,nm, OBJPROP_TEXT, txt);
   ObjectSetInteger(0,nm, OBJPROP_COLOR, clr);
}

//====================== MAIN RENDER ======================//

void RefreshLogic() {
   MqlTick t1, t2;
   if(!SymbolInfoTick(InpSymbol1, t1) || !SymbolInfoTick(InpSymbol2, t2)) return;
   
   double p1 = (InpDirection==DIR_SELL_ONLY) ? t1.bid : t1.ask;
   double p2 = (InpDirection==DIR_SELL_ONLY) ? t2.ask : t2.bid;
   double gap = p1 - p2;
   
   RingPush(GetTickCount64(), gap, p1, p2);

   // Extract Data for Stats
   int n = g_count;
   if(n < InpMinSamplesToShow) {
      SetLine(0, "Collecting Data... " + (string)n + "/" + (string)InpMinSamplesToShow);
      return;
   }

   double v_gap[], v_p1[], v_p2[]; long v_ts[];
   ArrayResize(v_gap, n); ArrayResize(v_p1, n); ArrayResize(v_p2, n); ArrayResize(v_ts, n);

   for(int i=0; i<n; i++) {
      int age = n - 1 - i; // Oldest to Newest
      RingGetByAge(age, v_ts[i], v_gap[i], v_p1[i], v_p2[i]);
   }

   // Calculations
   double corr = CalculateCorrelation(v_p1, v_p2);
   
   double sorted_gaps[]; ArrayCopy(sorted_gaps, v_gap);
   ArraySort(sorted_gaps);
   
   double mu=0; for(int i=0; i<n; i++) mu += v_gap[i]; mu /= n;
   double var=0; for(int i=0; i<n; i++) var += MathPow(v_gap[i]-mu, 2);
   double sd = MathSqrt(var/n);
   
   double z = CalculateZScore(gap, mu, sd);
   double slope = CalculateSlope(v_gap, v_ts, n);

   // UI Update
   SetLine(0, StringFormat("CURRENT GAP: %.2f | Z-SCORE: %.2f | CORR: %.3f", gap, z, corr), (MathAbs(z)>2 ? ColDanger : ColAccent));
   SetLine(1, "--------------------------------------------------------------------------------");
   SetLine(2, StringFormat("P10: %.2f | P50 (Med): %.2f | P90: %.2f", GetQuantile(sorted_gaps, 0.1), GetQuantile(sorted_gaps, 0.5), GetQuantile(sorted_gaps, 0.9)));
   SetLine(3, StringFormat("Slope: %.4f per min | Samples: %d", slope, n));
   
   string advice = (corr < 0.8) ? "WARNING: Low Correlation. Gap may drift." : "STATUS: High Correlation. Mean reversion likely.";
   SetLine(5, advice, (corr < 0.8 ? ColDanger : clrGreen));
}

//====================== MQL5 EVENTS ======================//

int OnInit() {
   EventSetMillisecondTimer(InpTimerMs);
   BuildUI();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int r) {
   EventKillTimer();
   ObjectsDeleteAll(0, g_prefix);
}

void OnTimer() {
   RefreshLogic();
   ChartRedraw();
}

int OnCalculate(const int r, const int p, const int b, const double &pr[]) { return r; }