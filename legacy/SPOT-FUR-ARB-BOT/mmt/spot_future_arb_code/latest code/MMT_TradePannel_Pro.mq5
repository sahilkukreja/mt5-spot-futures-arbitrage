#property strict
#property version "3.26"

#include <Trade/Trade.mqh>
CTrade trade;

// ============================================================
//  GROUP 1 — INSTRUMENT & IDENTITY
//  Defines which symbols are traded and how this EA is
//  identified in the terminal (magic number).
// ============================================================
input long   InpMagicNo  = 123;           // Magic Number: unique ID stamped on every order; prevents conflict with other EAs
input string InpSymbol1  = "GCM26.u";     // Symbol 1 (S1): futures leg — always SELL when direction = SELL_ONLY
input string InpSymbol2  = "XAUUSD.u";    // Symbol 2 (S2): spot leg   — always BUY  when direction = SELL_ONLY

enum ENUM_OPEN_DIR { DIR_BUY_ONLY=1, DIR_SELL_ONLY=2 };
input ENUM_OPEN_DIR InpOpenDirection = DIR_SELL_ONLY; // Trade Direction: SELL_ONLY = sell S1 / buy S2; BUY_ONLY = reverse

enum ENUM_FIRST_SYMBOL { FIRST_SYMBOL1=0, FIRST_SYMBOL2=1 };
input ENUM_FIRST_SYMBOL InpSymbolToTradeFirstWhenOpening = FIRST_SYMBOL1; // Open Leg Order: which leg gets its order sent first (affects partial-fill risk)
input ENUM_FIRST_SYMBOL InpSymbolToCloseFirst            = FIRST_SYMBOL1; // Close Leg Order: which leg gets its close order sent first

// ============================================================
//  GROUP 2 — SYSTEM & PERFORMANCE
//  Controls EA refresh rate, logging, and execution concurrency.
// ============================================================
input int    InpMaxPairs              = 20;    // Max Pair Slots: total number of simultaneous pair positions the EA can manage
input int    InpRefreshMs             = 100;   // Tick Timer (ms): how often OnTimer fires to check gaps and manage positions
input int    InpSlippagePips          = 1;     // Max Slippage (pips): order rejection threshold if fill is worse than this
input bool   InpEnableLogs            = true;  // Enable File Logs: write detailed trade and event logs to disk
input int    InpMaxConcurrentOpening  = 3;     // Max Simultaneous Opens: caps how many pairs can be in the opening phase at once
input int    InpMaxConcurrentClosing  = 10;    // Max Simultaneous Closes: caps how many pairs can be in the closing phase at once
input int    InpExecGraceMs           = 200;   // Execution Grace (ms): extra time allowed after order dispatch before declaring a timeout
input int    InpCloseWatchdogMs       = 60000; // Close Watchdog (ms): if a closing pair is stuck for this long, EA force-cancels and alerts

// ============================================================
//  GROUP 3 — SPREAD FILTER
//  Prevents OAG/CAG triggers when bid-ask spreads are
//  abnormally wide (e.g. during news, thin liquidity).
//  Set to 0.0 to disable per symbol.
// ============================================================
input double InpMaxSpreadS1 = 1.20; // Max Spread S1 (pts): block OAG+CAG if GCM26 spread exceeds this  (0 = disabled)
input double InpMaxSpreadS2 = 0.90; // Max Spread S2 (pts): block OAG+CAG if XAUUSD spread exceeds this (0 = disabled)

// ============================================================
//  GROUP 4 — OAG  (Open At Gap)
//  OAG fires when the live gap (S1.bid - S2.ask) reaches
//  your configured threshold and stays there long enough.
// ============================================================
input double InpOagTolerance          = 0.25; // OAG Tolerance (pts): how far gap can be below OAG level and still count as "hit"
input double InpOagMaxDrift           = 1.00; // OAG Max Drift (pts): if gap rises this far above OAG during confirm window, order is cancelled and pair is blocked until gap resets
input int    InpOagConfirmMs          = 150;  // OAG Confirm Window (ms): gap must stay at/above OAG for this duration before orders fire
input int    InpOagExitToleranceMs    = 0;  // OAG Exit Grace (ms): gap can dip below OAG briefly for this long before the hit timer resets

// ============================================================
//  GROUP 5 — CAG  (Close At Gap)
//  CAG fires when the live gap compresses back to your
//  target level, locking in the pairs-trade profit.
// ============================================================
input double InpCagOverrunTol         = 1.00; // CAG Overrun Tolerance (pts): if gap moves THIS far past target (over-compressed), skip the close to avoid chasing a reversal
input bool   InpEnableCagOverrunSkip  = false; // Enable CAG Overrun Skip: when true, gaps that blow past target by InpCagOverrunTol are ignored
input int    InpCagConfirmMs          = 100;  // CAG Confirm Window (ms): gap must stay at/below target for this duration before close orders fire (100ms = fast but protected by pre-send check)
input int    InpCagExitToleranceMs    = 200;  // CAG Exit Grace (ms): gap can pop above target briefly for this long before the CAG hit timer resets
input double InpCagTolerance          = 0.25; // CAG Tolerance (pts): DISABLED — retained for parameter compatibility only; not used in close logic

// ============================================================
//  GROUP 6 — OPEN EXECUTION QUALITY
//  Controls how orders are sent at open and what happens
//  when fill quality is worse than expected.
// ============================================================
input bool   InpUseSyncOpenExecution       = true;  // Sync Open Execution: true = wait for S1 fill confirmation before sending S2 (safer); false = send both simultaneously
input int    InpOpenSyncSecondLegMaxWaitMs = 1000;  // Sync Second Leg Timeout (ms): if S1 fill not confirmed within this time, abort and flatten
input double InpPreSendTolerance           = 0.30;  // Open Pre-Send Tolerance (pts): gap must still be within this many pts of OAG at the moment orders are dispatched, or open is aborted
input double InpOpenFillTolerance          = 0.40;  // Open Fill Tolerance (pts): if actual fill gap is more than this below OAG, position is flagged as a bad fill (triggers AutoFlatten if enabled)
input bool   InpAutoFlattenOpenReject      = false;  // Auto-Flatten Bad Open Fills: when true, immediately close both legs if fill gap is below OAG - OpenFillTolerance; when false, keep live and log OPEN_REJECT_KEPT

// ============================================================
//  GROUP 7 — CLOSE EXECUTION QUALITY
//  Controls what happens between CAG confirmation and
//  the moment close orders are actually dispatched.
// ============================================================
input double InpClosePreSendTolerance = 0.30; // Close Pre-Send Tolerance (pts): abort the close if the gap has snapped back more than this above target between CAG confirm and order dispatch (0 = disabled)

// ============================================================
//  GROUP 8 — POSITION MANAGEMENT
//  Rules that govern whether a live position is eligible
//  to be closed at a given moment.
// ============================================================
input int    InpMinHoldMinutes           = 0;     // Min Hold Time (min): position must be open for at least this many minutes before CAG close is allowed (0 = no minimum)
input bool   InpTargetCloseRequireProfit = false; // Require Profit to Close: when true, CAG close is only allowed if current floating P&L is positive
input double InpMinProfitToClose         = 0.0;   // Minimum Profit to Close ($): used only when InpTargetCloseRequireProfit=true; position must show at least this P&L

// ============================================================
//  GROUP 9 — UI LAYOUT
//  Panel position, size, and font settings.
// ============================================================
input int    UI_X          = 10;        // Panel X Position (px): distance from left edge of chart
input int    UI_Y          = 10;        // Panel Y Position (px): distance from top edge of chart
input int    UI_W          = 1400;      // Panel Width (px)
input int    UI_H_Min      = 220;       // Panel Min Height (px): minimum height when auto-sizing
input bool   UI_AutoHeight = true;      // Auto Height: expand panel height to fit all pair rows
input int    UI_FontBase   = 10;        // Base Font Size (pt)
input string UI_MonoFont   = "Consolas"; // Monospace Font: font used for all panel text

// ============================================================
//  GROUP 10 — UI COLORS
//  All color settings for the trade panel.
// ============================================================
input color  InpColPanelBG        = clrAliceBlue;   // Panel Background Color
input color  InpColTitleText      = clrBlack;        // Title Text Color
input color  InpColInfoText       = clrDimGray;      // Info / Label Text Color
input color  InpColGapText        = clrDodgerBlue;   // Live Gap Value Color
input color  InpColOpenText       = clrDarkGreen;    // Open Price Text Color

input color  InpColStatusProfit   = clrBlueViolet;   // Status Color — Profitable Position
input color  InpColStatusLoss     = clrRed;           // Status Color — Loss Position
input color  InpColStatusIdle     = clrSilver;        // Status Color — Idle / No Position
input color  InpColStatusSched    = clrOrange;        // Status Color — Scheduled (waiting for OAG)
input color  InpColStatusOpening  = clrGold;          // Status Color — Opening Orders In Flight
input color  InpColStatusClosing  = clrDodgerBlue;    // Status Color — Closing Orders In Flight

input color  InpColBtnOpenBG      = clrPink;          // Open Button Background Color
input color  InpColBtnCloseAllBG  = (color)0xB71C1C;  // Close All Button Background Color
input color  InpColBtnUpdateBG    = (color)0x1B5E20;  // Update Button Background Color
input color  InpColBtnText        = clrWhite;          // Button Text Color
input color  InpColBtnBorder      = clrBlack;          // Button Border Color

input color  InpColEditText       = clrBlack;          // Input Field Text Color
input color  InpColEditBG         = clrWhite;          // Input Field Background Color
input color  InpColEditBorder     = clrGray;           // Input Field Border Color

#define PSTATUS_IDLE       0
#define PSTATUS_LIVE       1
#define PSTATUS_SCHED      2
#define PSTATUS_BROKEN     3
#define PSTATUS_OPENING    4
#define PSTATUS_CLOSING    5

#define UI_MAX_ROWS 64
#define UI_COLS 9

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
   bool   isOpening;
   bool   isClosing;
};

struct CellCache
{
   string text;
   color  col;
   bool   visible;
};

string       g_prefix   = "PGUI_";
int          g_maxPairs = 20;

int          g_visiblePairs[64];
int          g_visibleN = 0;

PairRuntime  g_rt[64];
CellCache    g_cache[UI_MAX_ROWS][UI_COLS];
bool         g_uiBuilt = false;

double       g_gap   = 0.0;
double       g_p1    = 0.0;
double       g_p2    = 0.0;
bool         g_gapOk = false;

bool         g_s1OpenAllowed  = false;
bool         g_s2OpenAllowed  = false;
bool         g_s1CloseAllowed = false;
bool         g_s2CloseAllowed = false;

// Set true during ClosePairsInBatch send loops.
// Suppresses RefreshPairRuntime inside OnTradeTransaction so synchronous
// fill callbacks don't stall the send loop with expensive position scans.
bool         g_inBatchClose   = false;

int g_btnUpdX[UI_MAX_ROWS];
int g_btnUpdY[UI_MAX_ROWS];
int g_btnClsX[UI_MAX_ROWS];
int g_btnClsY[UI_MAX_ROWS];

double       g_eps = 0.00001;

string F2(double v){ return DoubleToString(v,2); }

void LogMsg(const string s) { if(InpEnableLogs) Print("[PGUI] ", s); }
void LogPair(const int p, const string action, const string detail="")
{
   if(!InpEnableLogs) return;
   string msg = StringFormat("[PGUI] Pair %d | %s", p, action);
   if(detail != "") msg += " | " + detail;
   Print(msg);
}

void FinalizeCloseLog(int p);

ulong NowMs()
{
#ifdef __MQL5__
   return (ulong)GetTickCount64();
#else
   return (ulong)GetTickCount();
#endif
}

int PipToPoints(string sym, int pips)
{
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   return pips * ((d==5||d==3) ? 10 : 1);
}

bool GetTickSafe(string sym, MqlTick &t)
{
   if(!SymbolInfoTick(sym, t)) return false;
   return (t.bid > 0 && t.ask > 0);
}

bool IsSpreadOk()
{
   // If both are 0, the filter is disabled
   if(InpMaxSpreadS1 <= 0.0 && InpMaxSpreadS2 <= 0.0) return true;

   MqlTick t1, t2;
   if(!GetTickSafe(InpSymbol1, t1) || !GetTickSafe(InpSymbol2, t2)) return false;

   // Check if the actual Bid-Ask spread exceeds your allowed limit
   if(InpMaxSpreadS1 > 0.0 && (t1.ask - t1.bid) > InpMaxSpreadS1 + g_eps) return false;
   if(InpMaxSpreadS2 > 0.0 && (t2.ask - t2.bid) > InpMaxSpreadS2 + g_eps) return false;

   return true;
}


bool ComputeGap(double &gap, double &p1, double &p2)
{
   MqlTick t1, t2;
   if(!GetTickSafe(InpSymbol1, t1)) return false;
   if(!GetTickSafe(InpSymbol2, t2)) return false;

   if(InpOpenDirection==DIR_SELL_ONLY) { p1=t1.bid; p2=t2.ask; }
   else                                { p1=t1.ask; p2=t2.bid; }

   gap = p1 - p2;
   return true;
}




bool TargetHit_Abs(const double current_gap, const double target_gap)
{
   if(target_gap == 0.0) return false;
   if(InpOpenDirection==DIR_SELL_ONLY) return (current_gap <= target_gap);
   return (current_gap >= target_gap);
}

bool CanOpenSymbol(const string sym)
{
   long mode = (long)SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   return (mode != SYMBOL_TRADE_MODE_DISABLED &&
           mode != SYMBOL_TRADE_MODE_CLOSEONLY);
}

bool CanCloseSymbol(const string sym)
{
   long mode = (long)SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   return (mode != SYMBOL_TRADE_MODE_DISABLED);
}

void RefreshTradeableState()
{
   bool o1 = CanOpenSymbol(InpSymbol1);
   bool o2 = CanOpenSymbol(InpSymbol2);
   bool c1 = CanCloseSymbol(InpSymbol1);
   bool c2 = CanCloseSymbol(InpSymbol2);

   if(o1 != g_s1OpenAllowed)
   {
      g_s1OpenAllowed = o1;
      LogMsg(StringFormat("OPEN_STATE_CHANGE | %s => %s", InpSymbol1, o1 ? "OPEN_ALLOWED" : "OPEN_BLOCKED"));
   }
   if(o2 != g_s2OpenAllowed)
   {
      g_s2OpenAllowed = o2;
      LogMsg(StringFormat("OPEN_STATE_CHANGE | %s => %s", InpSymbol2, o2 ? "OPEN_ALLOWED" : "OPEN_BLOCKED"));
   }
   if(c1 != g_s1CloseAllowed)
   {
      g_s1CloseAllowed = c1;
      LogMsg(StringFormat("CLOSE_STATE_CHANGE | %s => %s", InpSymbol1, c1 ? "CLOSE_ALLOWED" : "CLOSE_BLOCKED"));
   }
   if(c2 != g_s2CloseAllowed)
   {
      g_s2CloseAllowed = c2;
      LogMsg(StringFormat("CLOSE_STATE_CHANGE | %s => %s", InpSymbol2, c2 ? "CLOSE_ALLOWED" : "CLOSE_BLOCKED"));
   }
}

bool CanOpenTrades()  { return g_s1OpenAllowed  && g_s2OpenAllowed;  }
bool CanCloseTrades() { return g_s1CloseAllowed && g_s2CloseAllowed; }

string SanitizeNumberString(const string raw)
{
   string s = raw;
   while(StringLen(s)>0){ int c=StringGetCharacter(s,0); if(c==' '||c=='\t') s=StringSubstr(s,1); else break; }
   while(StringLen(s)>0){ int last=StringLen(s)-1; int c=StringGetCharacter(s,last); if(c==' '||c=='\t') s=StringSubstr(s,0,last); else break; }

   bool hasDot=false;
   string out="";
   for(int i=0; i<StringLen(s); i++)
   {
      int c=StringGetCharacter(s,i);
      if(c==',') continue;
      if(c=='-' && StringLen(out)==0) { out+="-"; continue; }
      if(c>='0' && c<='9') { out+=(string)CharToString((uchar)c); continue; }
      if(c=='.' && !hasDot)
      {
         hasDot=true;
         if(out==""||out=="-") out+="0";
         out+=".";
         continue;
      }
   }
   if(out==""||out=="-") return "0";
   if(out=="-0."||out=="0.") return "0";
   return out;
}

double ReadEditNumber(const string objName, string &sanitized_out)
{
   sanitized_out="0";
   if(ObjectFind(0,objName)<0) return 0.0;
   string raw=ObjectGetString(0,objName,OBJPROP_TEXT);
   sanitized_out=SanitizeNumberString(raw);
   return StringToDouble(sanitized_out);
}

void WriteEditSanitized(const string objName, const string sanitized)
{
   if(ObjectFind(0,objName)>=0) ObjectSetString(0,objName,OBJPROP_TEXT,sanitized);
}

string GvKeyBase()
{
   return StringFormat("PGUI|%I64d|%s|%s|DIR=%d|",
                       InpMagicNo, InpSymbol1, InpSymbol2, (int)InpOpenDirection);
}
string GvKey(int pairIdx, string field) { return GvKeyBase()+StringFormat("P=%d|%s",pairIdx,field); }

double GvGetD(int pairIdx, string field, double def=0.0)
{
   string k=GvKey(pairIdx,field);
   if(!GlobalVariableCheck(k)) return def;
   return GlobalVariableGet(k);
}
void GvSetD(int pairIdx, string field, double v) { GlobalVariableSet(GvKey(pairIdx,field),v); }

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

bool IsOpeningLocked(int p, int maxLockMs=8000)
{
   if(GvGetD(p,"OPENING",0.0)<0.5) return false;
   ulong age=NowMs()-(ulong)GvGetD(p,"OPENING_SINCE_MS",0.0);
   if((int)age>maxLockMs)
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
      GvSetD(p,"CLOSING_START_MS",0.0);
      GvSetD(p,"CLOSING_DISPATCH_MS",0.0);
   }
}

bool IsClosingLocked(int p)
{
   return (GvGetD(p,"CLOSING",0.0) >= 0.5);
}

void ResetOagHit(const int p)
{
   GvSetD(p,"OAG_HIT_ACTIVE",0.0);
   GvSetD(p,"OAG_HIT_SINCE_MS",0.0);
   GvSetD(p,"OAG_EXIT_SINCE_MS",0.0);
}

void ResetCagHit(const int p)
{
   GvSetD(p,"CAG_HIT_ACTIVE",0.0);
   GvSetD(p,"CAG_HIT_SINCE_MS",0.0);
   GvSetD(p,"CAG_EXIT_SINCE_MS",0.0);
}

void ResetOagDriftBlock(const int p)
{
   GvSetD(p,"OAG_DRIFT_BLOCK",0.0);
   GvSetD(p,"OAG_DRIFT_BLOCK_SINCE",0.0);
}

void ResetHitTimers(const int p) { ResetOagHit(p); ResetCagHit(p); }

void ClearScheduleState(const int p, const bool clearTarget)
{
   GvSetD(p,"STATUS",0.0);
   GvSetD(p,"OAG",0.0);
   GvSetD(p,"SCHED_LOT",0.0);
   if(clearTarget) GvSetD(p,"TARGET",0.0);
   ResetOagHit(p);
}

void CancelSchedule(int p)
{
   ClearScheduleState(p,true);
   ResetCagHit(p);
   ResetOagDriftBlock(p);
   SetOpeningLock(p,false);
   LogPair(p,"SCHEDULE_CANCELLED");
}

void ClearLiveMeta(const int p, const bool clearTarget)
{
   GvSetD(p,"OPENGAP",0.0);
   GvSetD(p,"OAG_AT_OPEN",0.0);
   GvSetD(p,"OPENING_DISPATCH_MS",0.0);
   GvSetD(p,"CLOSING_DISPATCH_MS",0.0);
   GvSetD(p,"CLOSING_START_MS",0.0);
   GvSetD(p,"OPEN_TIME_SEC",0.0);
   GvSetD(p,"CLOSE_TK_S1",0.0);
   GvSetD(p,"CLOSE_TK_S2",0.0);
   GvSetD(p,"CLOSE_FILL_S1",0.0);
   GvSetD(p,"CLOSE_FILL_S2",0.0);
   GvSetD(p,"OPEN_TRIGGER_GAP",0.0);

   GvSetD(p,"OPEN_DISPATCH_GAP",0.0);
   GvSetD(p,"OPEN_FILL_S1",0.0);
   GvSetD(p,"OPEN_FILL_S2",0.0);
   GvSetD(p,"OPEN_FILL_GAP",0.0);

   GvSetD(p,"CLOSE_TRIGGER_GAP",0.0);
   GvSetD(p,"CLOSE_FILL_GAP",0.0);

   if(clearTarget) GvSetD(p,"TARGET",0.0);
   ResetCagHit(p);
   SetOpeningLock(p,false);
   SetClosingLock(p,false);
}

void ClearPairState(const int p)
{
   ClearScheduleState(p,true);
   ClearLiveMeta(p,true);
   ResetOagDriftBlock(p);
   GvSetD(p,"BROKEN_LOGGED",0.0);
}

void ReconcilePairState(const int p)
{
   bool s1=g_rt[p].hasS1, s2=g_rt[p].hasS2;
   double st=GvGetD(p,"STATUS",0.0);

   if(!s1 && !s2)
   {
      if(IsClosingLocked(p)) return;
      if(IsOpeningLocked(p)) return;

      if(st==2.0)
      {
         double oag=GvGetD(p,"OAG",0.0), lot=GvGetD(p,"SCHED_LOT",0.0);
         if(oag!=0.0 && lot>0.0)
         {
            GvSetD(p,"OPENGAP",0.0);
            GvSetD(p,"OPEN_TIME_SEC",0.0);
            SetOpeningLock(p,false);
            ResetCagHit(p);
            return;
         }
         CancelSchedule(p);
         return;
      }
      ClearPairState(p);
      return;
   }

   if(IsOpeningLocked(p)) return;
   if(IsClosingLocked(p)) return;

   GvSetD(p,"STATUS",0.0);
   GvSetD(p,"OAG",0.0);
   GvSetD(p,"SCHED_LOT",0.0);
   ResetOagHit(p);

   if(s1 && s2)
   {
      GvSetD(p,"BROKEN_LOGGED",0.0);
      if(GvGetD(p,"OPEN_TIME_SEC",0.0)<=0.0)
         GvSetD(p,"OPEN_TIME_SEC",(double)TimeCurrent());
   }
   else
   {
      ResetCagHit(p);
      if(GvGetD(p,"BROKEN_LOGGED",0.0) < 0.5)
      {
         LogPair(p,"BROKEN_STATE","manual intervention required");
         GvSetD(p,"BROKEN_LOGGED",1.0);
      }
   }
}

void ReconcileAllPairStates()
{
   for(int p=1; p<=g_maxPairs; p++) ReconcilePairState(p);
}

void ResetSessionStateOnInit()
{
   for(int p=1; p<=g_maxPairs; p++)
   {
      ResetHitTimers(p);
      ResetOagDriftBlock(p);
      SetOpeningLock(p,false);
      SetClosingLock(p,false);
   }
}

void RefreshLockCache()
{
   for(int p=1; p<=g_maxPairs; p++)
   {
      g_rt[p].isOpening = IsOpeningLocked(p);
      g_rt[p].isClosing = IsClosingLocked(p);
   }
}

string MakeCloseTag() { return StringFormat("%03d", (int)(InpMagicNo % 1000)); }

string MakeComment(int pairIdx, string leg)
{
   return StringFormat("%02d%c%03d", (int)(InpMagicNo % 100), (leg=="S1"?'a':'b'), pairIdx);
}

bool ParseComment(string c, int &pairIdx, string &leg)
{
   if(StringLen(c) != 6) return false;

   string expPfx = StringFormat("%02d", (int)(InpMagicNo % 100));
   if(StringSubstr(c,0,2) != expPfx) return false;

   int legChar = StringGetCharacter(c,2);
   if(legChar != 'a' && legChar != 'b') return false;

   leg = (legChar == 'a') ? "S1" : "S2";
   pairIdx = (int)StringToInteger(StringSubstr(c,3));
   return (pairIdx >= 1 && pairIdx <= 50);
}

ulong FindTicket(int pairIdx, string leg)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
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

bool PairHasAnyLeg(int pairIdx) { return (g_rt[pairIdx].hasS1 || g_rt[pairIdx].hasS2); }

int GetPairStatus(int p)
{
   if(IsOpeningLocked(p)) return PSTATUS_OPENING;
   if(IsClosingLocked(p)) return PSTATUS_CLOSING;

   bool s1=g_rt[p].hasS1, s2=g_rt[p].hasS2;
   if(s1 && s2) return PSTATUS_LIVE;
   if(s1 || s2) return PSTATUS_BROKEN;
   if(GvGetD(p,"STATUS",0.0)==2.0) return PSTATUS_SCHED;
   return PSTATUS_IDLE;
}

int NextFreePairSlot()
{
   for(int p=1; p<=g_maxPairs; p++)
      if(!g_rt[p].hasS1 && !g_rt[p].hasS2
         && GvGetD(p,"STATUS",0.0)!=2.0
         && !IsOpeningLocked(p)
         && !IsClosingLocked(p))
         return p;
   return -1;
}

double GetPairPL_ProfitOnly(int p) { return g_rt[p].pl; }

double GetPairLot_PairSize(int p)
{
   double v1=g_rt[p].volS1, v2=g_rt[p].volS2;
   if(v1>0.0&&v2>0.0) return MathMin(v1,v2);
   if(v1>0.0) return v1;
   return v2;
}

double GetPairOpenGap_FromFills(const int p, bool &ok)
{
   ok=(g_rt[p].hasS1&&g_rt[p].hasS2&&g_rt[p].openS1>0.0&&g_rt[p].openS2>0.0);
   return ok?(g_rt[p].openS1-g_rt[p].openS2):0.0;
}

ENUM_ORDER_TYPE_FILLING GetBestFilling(const string sym)
{
   long fm=(long)SymbolInfoInteger(sym,SYMBOL_FILLING_MODE);
   if((fm&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((fm&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

bool SendRawOrder(const string sym, ENUM_ORDER_TYPE type, double lot,
                  const string cmt, MqlTradeResult &res)
{
   ZeroMemory(res);
   MqlTick tk;
   if(!GetTickSafe(sym,tk)) { LogMsg("SendRawOrder: no tick "+sym); return false; }

   MqlTradeRequest req; ZeroMemory(req);
   req.action=TRADE_ACTION_DEAL;
   req.symbol=sym;
   req.magic=InpMagicNo;
   req.volume=lot;
   req.deviation=PipToPoints(sym,InpSlippagePips);
   req.type_filling=GetBestFilling(sym);
   req.type=type;
   req.price=(type==ORDER_TYPE_BUY?tk.ask:tk.bid);
   req.comment=cmt;

   ResetLastError();
   bool ok=OrderSend(req,res);
   bool accepted=(res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_PLACED);

   if(accepted)
      LogMsg(StringFormat("OpenLeg OK | sym=%s ok=%d ret=%d (done at %s) | type=%s lot=%.2f",
             sym,(int)ok,(int)res.retcode,F2(res.price),
             (type==ORDER_TYPE_BUY?"BUY":"SELL"),lot));
   else
      LogMsg(StringFormat("OpenLeg FAIL | sym=%s ok=%d ret=%d | type=%s lot=%.2f",
             sym,(int)ok,(int)res.retcode,
             (type==ORDER_TYPE_BUY?"BUY":"SELL"),lot));
   return ok&&accepted;
}

bool SendCloseRequest(const int pairIdx, const string leg, ulong ticket, MqlTradeResult &res_out)
{
   ZeroMemory(res_out);
   if(ticket==0) return true;
   if(!PositionSelectByTicket(ticket)) return true;

   string sym=PositionGetString(POSITION_SYMBOL);
   long   ptype=PositionGetInteger(POSITION_TYPE);
   double vol=PositionGetDouble(POSITION_VOLUME);

   MqlTick tk;
   if(!GetTickSafe(sym,tk)) { LogMsg("SendCloseRequest: no tick "+sym); return false; }

   MqlTradeRequest req; ZeroMemory(req);
   req.action=TRADE_ACTION_DEAL;
   req.position=ticket;
   req.symbol=sym;
   req.magic=InpMagicNo;
   req.volume=vol;
   req.deviation=PipToPoints(sym,InpSlippagePips);
   req.type_filling=GetBestFilling(sym);
   req.type=(ptype==POSITION_TYPE_BUY?ORDER_TYPE_SELL:ORDER_TYPE_BUY);
   req.price=(req.type==ORDER_TYPE_SELL?tk.bid:tk.ask);
   req.comment=MakeComment(pairIdx, leg);

   ResetLastError();
   bool ok=OrderSendAsync(req,res_out);
   bool accepted=(res_out.retcode==TRADE_RETCODE_PLACED || res_out.retcode==TRADE_RETCODE_DONE);

   if(accepted)
      LogMsg(StringFormat("CloseLeg SENT | pair=%d leg=%s ticket=%I64u sym=%s | closeType=%s vol=%.2f reqId=%I64u",
             pairIdx,leg,ticket,sym,(req.type==ORDER_TYPE_BUY?"BUY":"SELL"),vol,res_out.request_id));
   else
      LogMsg(StringFormat("CloseLeg FAIL | pair=%d leg=%s ticket=%I64u sym=%s ok=%d ret=%d ext=%d",
             pairIdx,leg,ticket,sym,(int)ok,(int)res_out.retcode,(int)res_out.retcode_external));

   return ok&&accepted;
}

bool CloseTicketAndConfirm(const int pairIdx, const string leg, ulong ticket)
{
   if(ticket==0) return true;
   if(!PositionSelectByTicket(ticket)) return true;

   string sym=PositionGetString(POSITION_SYMBOL);
   long   ptype=PositionGetInteger(POSITION_TYPE);
   double vol=PositionGetDouble(POSITION_VOLUME);

   MqlTick tk;
   if(!GetTickSafe(sym,tk)) return false;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action=TRADE_ACTION_DEAL;
   req.position=ticket;
   req.symbol=sym;
   req.magic=InpMagicNo;
   req.volume=vol;
   req.deviation=PipToPoints(sym,InpSlippagePips);
   req.type_filling=GetBestFilling(sym);
   req.type=(ptype==POSITION_TYPE_BUY?ORDER_TYPE_SELL:ORDER_TYPE_BUY);
   req.price=(req.type==ORDER_TYPE_SELL?tk.bid:tk.ask);
   req.comment=MakeComment(pairIdx, leg);

   ResetLastError();
   bool ok = OrderSend(req,res);
   bool accepted = (res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_PLACED);

   if(!ok || !accepted) return false;
   return !PositionSelectByTicket(ticket);
}

bool SendRawOrderAsync(const string sym, ENUM_ORDER_TYPE type, double lot,
                       const string cmt, MqlTradeResult &res)
{
   ZeroMemory(res);

   MqlTick tk;
   if(!GetTickSafe(sym, tk)) { LogMsg("SendRawOrder: no tick " + sym); return false; }

   MqlTradeRequest req; ZeroMemory(req);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = sym;
   req.magic        = InpMagicNo;
   req.volume       = lot;
   req.deviation    = PipToPoints(sym, InpSlippagePips);
   req.type_filling = GetBestFilling(sym);
   req.type         = type;
   req.price        = (type == ORDER_TYPE_BUY ? tk.ask : tk.bid);
   req.comment      = cmt;

   ResetLastError();

   bool ok = OrderSendAsync(req, res);
   bool accepted = (res.retcode == TRADE_RETCODE_PLACED || res.retcode == TRADE_RETCODE_DONE);

   if(accepted)
      LogMsg(StringFormat("OpenLeg SENT | sym=%s | type=%s lot=%.2f reqId=%I64u",
             sym, (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lot, res.request_id));
   else
      LogMsg(StringFormat("OpenLeg FAIL | sym=%s ok=%d ret=%d", sym, (int)ok, (int)res.retcode));

   return ok && accepted;
}

bool RecheckOpenGapBeforeSend(const int pairIdx, const double oag, double &cg_now)
{
   if(!IsSpreadOk())
   {
      LogPair(pairIdx,"OPEN_ABORT_PRESEND","Spread exceeds MaxSpread limit");
      return false;
   }

   double p1_now=0.0, p2_now=0.0;
   if(!ComputeGap(cg_now, p1_now, p2_now))
   {
      LogPair(pairIdx,"OPEN_ABORT_PRESEND","ComputeGap failed");
      return false;
   }

   bool still_ok = (InpOpenDirection==DIR_SELL_ONLY)
      ? (cg_now >= oag - InpPreSendTolerance - g_eps)
      : (cg_now <= oag + InpPreSendTolerance + g_eps);

   if(!still_ok)
   {
      LogPair(pairIdx,"OPEN_ABORT_PRESEND",
              StringFormat("cgNow=%s oag=%s tol=%.2f",
                           F2(cg_now),F2(oag),InpPreSendTolerance));
      return false;
   }

   return true;
}

// Returns false and logs if gap has moved back above target by more than InpClosePreSendTolerance.
// Also blocks if spread is currently too wide.
bool RecheckCloseGapBeforeSend(const int pairIdx, const double target)
{
   if(InpClosePreSendTolerance <= 0.0) return true; // disabled

   if(!IsSpreadOk())
   {
      LogPair(pairIdx,"CLOSE_ABORT_PRESEND","Spread exceeds MaxSpread limit");
      return false;
   }

   double cg_now=0.0, p1_now=0.0, p2_now=0.0;
   if(!ComputeGap(cg_now, p1_now, p2_now))
   {
      LogPair(pairIdx,"CLOSE_ABORT_PRESEND","ComputeGap failed");
      return false;
   }

   // If target is 0 (no schedule set — e.g. auto-flatten path), skip the gap direction check.
   // Spread check above is sufficient; we have no reference point to evaluate gap position.
   if(target <= 0.0) return true;

   // For SELL_ONLY: gap should be <= target to close profitably.
   // If gap has snapped back above target + tolerance, the profit window is gone — abort.
   bool still_ok = (InpOpenDirection == DIR_SELL_ONLY)
      ? (cg_now <= target + InpClosePreSendTolerance + g_eps)
      : (cg_now >= target - InpClosePreSendTolerance - g_eps);

   if(!still_ok)
   {
      LogPair(pairIdx,"CLOSE_ABORT_PRESEND",
              StringFormat("cgNow=%s target=%s tol=%.2f => gap moved back, aborting close",
                           F2(cg_now), F2(target), InpClosePreSendTolerance));
      return false;
   }

   return true;
}

bool OpenPair(int pairIdx, double lot, double oag, double trigP1=0.0, double trigP2=0.0)
{
   if(pairIdx < 1 || pairIdx > g_maxPairs) return false;
   if(!CanOpenTrades()) { LogPair(pairIdx, "OPEN_BLOCKED", "symbols not openable"); return false; }
   if(PairHasAnyLeg(pairIdx)) { LogPair(pairIdx, "OPEN_BLOCKED", "slot has leg"); return false; }
   if(IsOpeningLocked(pairIdx)) { LogPair(pairIdx, "OPEN_BLOCKED", "opening lock"); return false; }

   double cg_now = 0.0;
   if(!RecheckOpenGapBeforeSend(pairIdx, oag, cg_now))
      return false;

   SetOpeningLock(pairIdx, true);
   GvSetD(pairIdx, "STATUS", 0.0);
   GvSetD(pairIdx, "OPEN_TIME_SEC", 0.0);
   GvSetD(pairIdx, "OAG_AT_OPEN", oag);
   GvSetD(pairIdx, "OPEN_TRIGGER_GAP", cg_now);
   GvSetD(pairIdx, "OPEN_DISPATCH_GAP", cg_now);
   GvSetD(pairIdx, "OPENING_DISPATCH_MS", (double)NowMs());
   GvSetD(pairIdx, "OPEN_FILL_S1", 0.0);
   GvSetD(pairIdx, "OPEN_FILL_S2", 0.0);
   GvSetD(pairIdx, "OPEN_FILL_GAP", 0.0);
   ResetHitTimers(pairIdx);

   ENUM_ORDER_TYPE t1 = (InpOpenDirection == DIR_SELL_ONLY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   ENUM_ORDER_TYPE t2 = (InpOpenDirection == DIR_SELL_ONLY) ? ORDER_TYPE_BUY  : ORDER_TYPE_SELL;

   MqlTradeResult r1, r2;
   bool okS1 = false, okS2 = false;

   if(InpUseSyncOpenExecution)
   {
      LogPair(pairIdx, "OPEN_DISPATCH_SYNC",
              StringFormat("lot=%s oag=%s dispatchGap=%s", F2(lot), F2(oag), F2(cg_now)));

      if(InpSymbolToTradeFirstWhenOpening == FIRST_SYMBOL1)
      {
         okS1 = SendRawOrder(InpSymbol1, t1, lot, MakeComment(pairIdx, "S1"), r1);
         if(okS1) okS2 = SendRawOrder(InpSymbol2, t2, lot, MakeComment(pairIdx, "S2"), r2);
      }
      else
      {
         okS2 = SendRawOrder(InpSymbol2, t2, lot, MakeComment(pairIdx, "S2"), r2);
         if(okS2) okS1 = SendRawOrder(InpSymbol1, t1, lot, MakeComment(pairIdx, "S1"), r1);
      }
   }
   else
   {
      LogPair(pairIdx, "OPEN_DISPATCH_ASYNC",
              StringFormat("lot=%s oag=%s", F2(lot), F2(oag)));

      if(InpSymbolToTradeFirstWhenOpening == FIRST_SYMBOL1)
      {
         okS1 = SendRawOrderAsync(InpSymbol1, t1, lot, MakeComment(pairIdx, "S1"), r1);
         okS2 = SendRawOrderAsync(InpSymbol2, t2, lot, MakeComment(pairIdx, "S2"), r2);
      }
      else
      {
         okS2 = SendRawOrderAsync(InpSymbol2, t2, lot, MakeComment(pairIdx, "S2"), r1);
         okS1 = SendRawOrderAsync(InpSymbol1, t1, lot, MakeComment(pairIdx, "S1"), r2);
      }
   }

   if(!okS1 && !okS2)
   {
      SetOpeningLock(pairIdx, false);
      GvSetD(pairIdx, "OPENING_DISPATCH_MS", 0.0);
      GvSetD(pairIdx, "OAG_AT_OPEN", 0.0);
      GvSetD(pairIdx, "OPEN_TRIGGER_GAP", 0.0);
      GvSetD(pairIdx, "OPEN_DISPATCH_GAP", 0.0);
      LogPair(pairIdx, "OPEN_FAIL", "both requests rejected");
      return false;
   }

   if(InpUseSyncOpenExecution && (okS1 != okS2))
   {
      LogPair(pairIdx, "OPEN_PARTIAL_SYNC", "flattening partial immediately");
      Sleep(150);
      RefreshPairRuntime();

      ulong tk1 = FindTicket(pairIdx,"S1");
      ulong tk2 = FindTicket(pairIdx,"S2");
      if(tk1!=0) CloseTicketAndConfirm(pairIdx,"S1",tk1);
      if(tk2!=0) CloseTicketAndConfirm(pairIdx,"S2",tk2);

      SetOpeningLock(pairIdx,false);
      ClearPairState(pairIdx);
      return false;
   }

   return true;
}




void ClosePair(int pairIdx, bool manual=false)
{
   if(!CanCloseTrades()) { LogPair(pairIdx,"CLOSE_BLOCKED","symbols not closable"); return; }
   if(IsClosingLocked(pairIdx)||IsOpeningLocked(pairIdx))
   {
      LogPair(pairIdx,"CLOSE_BLOCKED","lock active");
      return;
   }

   ulong a=g_rt[pairIdx].tkS1, b=g_rt[pairIdx].tkS2;
   if(a==0&&b==0) return;

   if(!manual)
   {
      double tg = GvGetD(pairIdx,"TARGET",0.0);
      if(!RecheckCloseGapBeforeSend(pairIdx, tg)) { ResetCagHit(pairIdx); return; }
   }

   SetClosingLock(pairIdx,true);
   GvSetD(pairIdx,"CLOSING_START_MS",(double)NowMs());
   GvSetD(pairIdx,"CLOSING_DISPATCH_MS",(double)NowMs());
   GvSetD(pairIdx,"CLOSE_TK_S1",(double)a);
   GvSetD(pairIdx,"CLOSE_TK_S2",(double)b);
   GvSetD(pairIdx,"CLOSE_FILL_S1",0.0);
   GvSetD(pairIdx,"CLOSE_FILL_S2",0.0);
   GvSetD(pairIdx,"CLOSE_TRIGGER_GAP", g_gapOk ? g_gap : 0.0);
   GvSetD(pairIdx,"CLOSE_FILL_GAP", 0.0);

   LogPair(pairIdx,"CLOSE_START");

   MqlTradeResult ra,rb; ZeroMemory(ra); ZeroMemory(rb);
   if(InpSymbolToCloseFirst==FIRST_SYMBOL1)
   {
      if(a!=0) SendCloseRequest(pairIdx,"S1",a,ra);
      if(b!=0) SendCloseRequest(pairIdx,"S2",b,rb);
   }
   else
   {
      if(b!=0) SendCloseRequest(pairIdx,"S2",b,rb);
      if(a!=0) SendCloseRequest(pairIdx,"S1",a,ra);
   }
}

void ClosePairsInBatch(const int &pairs[], const int n)
{
   if(n<=0) return;
   if(!CanCloseTrades()) { LogMsg("CLOSE_BATCH_BLOCKED | symbols not closable"); return; }

   // ── Pre-compute gap + spread once for the whole batch ──────────────────────
   // Avoids N separate ComputeGap calls inside the validation loop.
   if(!IsSpreadOk()) { LogMsg("CLOSE_BATCH_BLOCKED | spread too wide"); return; }

   double batchCg=0.0, batchP1=0.0, batchP2=0.0;
   bool   batchGapOk = ComputeGap(batchCg, batchP1, batchP2);

   ulong  batchNow = NowMs();

   // ── Phase 1: validate + lock + snapshot tickets ─────────────────────────────
   int    validPairs[64];
   ulong  snap1[64];    // first-leg ticket snapshot
   ulong  snap2[64];    // second-leg ticket snapshot
   int    validN = 0;

   for(int i=0; i<n; i++)
   {
      int p=pairs[i];
      if(IsClosingLocked(p)||IsOpeningLocked(p)) continue;

      ulong a=g_rt[p].tkS1, b=g_rt[p].tkS2;
      if(a==0&&b==0) continue;

      // Inline pre-send gap check using the single pre-computed gap
      if(batchGapOk && InpClosePreSendTolerance > 0.0)
      {
         double tg = GvGetD(p,"TARGET",0.0);
         if(tg > 0.0)
         {
            bool still_ok = (InpOpenDirection==DIR_SELL_ONLY)
               ? (batchCg <= tg + InpClosePreSendTolerance + g_eps)
               : (batchCg >= tg - InpClosePreSendTolerance - g_eps);
            if(!still_ok)
            {
               LogPair(p,"CLOSE_ABORT_PRESEND",
                       StringFormat("cgNow=%s target=%s tol=%.2f",
                                    F2(batchCg),F2(tg),InpClosePreSendTolerance));
               ResetCagHit(p);
               continue;
            }
         }
      }

      SetClosingLock(p,true);
      GvSetD(p,"CLOSING_START_MS",  (double)batchNow);
      GvSetD(p,"CLOSING_DISPATCH_MS",(double)batchNow);
      GvSetD(p,"CLOSE_TK_S1",  (double)a);
      GvSetD(p,"CLOSE_TK_S2",  (double)b);
      GvSetD(p,"CLOSE_FILL_S1",0.0);
      GvSetD(p,"CLOSE_FILL_S2",0.0);
      GvSetD(p,"CLOSE_TRIGGER_GAP", batchGapOk ? batchCg : 0.0);
      GvSetD(p,"CLOSE_FILL_GAP",    0.0);
      LogPair(p,"CLOSE_START");

      snap1[validN] = a;
      snap2[validN] = b;
      validPairs[validN++] = p;
   }

   if(validN == 0) return;

   // ── Phase 2: fire all orders as fast as possible ────────────────────────────
   // g_inBatchClose suppresses RefreshPairRuntime inside OnTradeTransaction so
   // synchronous fill callbacks don't stall the send loop with position scans.
   g_inBatchClose = true;

   // First leg for all pairs
   for(int i=0; i<validN; i++)
   {
      int p = validPairs[i];
      MqlTradeResult r; ZeroMemory(r);
      ulong tk = (InpSymbolToCloseFirst==FIRST_SYMBOL1) ? snap1[i] : snap2[i];
      string leg = (InpSymbolToCloseFirst==FIRST_SYMBOL1) ? "S1" : "S2";
      if(tk!=0) SendCloseRequest(p, leg, tk, r);
   }

   // Second leg for all pairs
   for(int i=0; i<validN; i++)
   {
      int p = validPairs[i];
      MqlTradeResult r; ZeroMemory(r);
      ulong tk = (InpSymbolToCloseFirst==FIRST_SYMBOL1) ? snap2[i] : snap1[i];
      string leg = (InpSymbolToCloseFirst==FIRST_SYMBOL1) ? "S2" : "S1";
      if(tk!=0) SendCloseRequest(p, leg, tk, r);
   }

   g_inBatchClose = false;
}

// Looks up the closing deal price for a position ticket from MT5 deal history.
// Used to recover fill prices when OnTradeTransaction callbacks arrive late.
bool FetchFillFromHistory(ulong posTicket, double &fillPrice)
{
   if(posTicket == 0) return false;
   if(!HistorySelectByPosition(posTicket)) return false;
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong dk = HistoryDealGetTicket(i);
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dk, DEAL_ENTRY) == DEAL_ENTRY_OUT)
      {
         double px = HistoryDealGetDouble(dk, DEAL_PRICE);
         if(px > 0.0) { fillPrice = px; return true; }
      }
   }
   return false;
}

// Called before FinalizeCloseLog when positions are detected as gone.
// Fills in any missing CLOSE_FILL_S1/S2 prices from deal history so the
// final report is complete even if OnTradeTransaction callbacks are delayed.
void TryFetchMissingCloseFills(int p)
{
   ulong tk1 = (ulong)GvGetD(p,"CLOSE_TK_S1",0.0);
   ulong tk2 = (ulong)GvGetD(p,"CLOSE_TK_S2",0.0);

   if(GvGetD(p,"CLOSE_FILL_S1",0.0) <= 0.0 && tk1 > 0)
   {
      double px = 0.0;
      if(FetchFillFromHistory(tk1, px))
      {
         GvSetD(p,"CLOSE_FILL_S1",px);
         LogPair(p,"FILL_CLOSE_HISTORY",StringFormat("leg=S1 price=%s (recovered from history)", F2(px)));
      }
   }

   if(GvGetD(p,"CLOSE_FILL_S2",0.0) <= 0.0 && tk2 > 0)
   {
      double px = 0.0;
      if(FetchFillFromHistory(tk2, px))
      {
         GvSetD(p,"CLOSE_FILL_S2",px);
         LogPair(p,"FILL_CLOSE_HISTORY",StringFormat("leg=S2 price=%s (recovered from history)", F2(px)));
      }
   }

   double c1 = GvGetD(p,"CLOSE_FILL_S1",0.0);
   double c2 = GvGetD(p,"CLOSE_FILL_S2",0.0);
   if(c1 > 0.0 && c2 > 0.0)
      GvSetD(p,"CLOSE_FILL_GAP",c1 - c2);
}

void ProcessClosingPairs()
{
   ulong now=NowMs();

   for(int p=1; p<=g_maxPairs; p++)
   {
      if(!IsClosingLocked(p)) continue;

      ulong startMs    = (ulong)GvGetD(p,"CLOSING_START_MS",0.0);
      ulong lastSendMs = (ulong)GvGetD(p,"CLOSING_DISPATCH_MS",0.0);

      ulong totalAge = (now>=startMs    ? now-startMs    : 0);
      ulong sendAge  = (now>=lastSendMs ? now-lastSendMs : 0);

      bool stillA=g_rt[p].hasS1;
      bool stillB=g_rt[p].hasS2;

      if(!stillA && !stillB)
      {
         TryFetchMissingCloseFills(p); // recover fill prices from history before callbacks arrive

         double f1 = GvGetD(p,"CLOSE_FILL_S1",0.0);
         double f2 = GvGetD(p,"CLOSE_FILL_S2",0.0);

         if(f1 > 0.0 && f2 > 0.0)
         {
            // Both fills confirmed — produce complete report
            FinalizeCloseLog(p);
         }
         else if((int)totalAge > 5000)
         {
            // Fills never arrived after 5s — force release the slot (callbacks lost)
            LogPair(p,"CLOSE_FILL_TIMEOUT",
                    StringFormat("f1=%s f2=%s ageMs=%d — releasing slot without fill data",
                                 F2(f1),F2(f2),(int)totalAge));
            ClearPairState(p);
            SetClosingLock(p,false);
            LogPair(p,"SLOT_RELEASED");
         }
         // else: both positions gone but fills not yet in GVs or history —
         // wait another tick for OnTradeTransaction callbacks to deliver them
         continue;
      }

      if((int)totalAge >= InpCloseWatchdogMs)
      {
         LogPair(p,"CLOSE_TIMEOUT",
                 StringFormat("stillA=%d stillB=%d ageMs=%I64u — force releasing slot",
                              (int)stillA,(int)stillB,totalAge));
         ClearPairState(p);
         SetClosingLock(p,false);
         LogPair(p,"SLOT_RELEASED","watchdog forced");
         continue;
      }

      if((int)sendAge < InpExecGraceMs) continue;

      LogPair(p,"CLOSE_PARTIAL",
              StringFormat("stillA=%d stillB=%d totalAgeMs=%I64u retryAgeMs=%I64u",
                           (int)stillA,(int)stillB,totalAge,sendAge));

      ulong a=g_rt[p].tkS1, b=g_rt[p].tkS2;
      MqlTradeResult ra,rb; ZeroMemory(ra); ZeroMemory(rb);
      if(stillA&&a!=0) SendCloseRequest(p,"S1",a,ra);
      if(stillB&&b!=0) SendCloseRequest(p,"S2",b,rb);

      GvSetD(p,"CLOSING_DISPATCH_MS",(double)NowMs());
      LogPair(p,"CLOSE_PARTIAL","retry sent, lock held until flat confirmation");
   }
}

void QueueOpen(int p, double lot, double oag, double cg, double p1, double p2,
               const string label,
               int &openBatch[], double &openLots[], double &openOags[], double &openP1s[], double &openP2s[], int &openN)
{
   LogPair(p, label, StringFormat("cg=%s oag=%s p1=%s p2=%s", F2(cg),F2(oag),F2(p1),F2(p2)));
   openBatch[openN]=p;
   openLots[openN]=lot;
   openOags[openN]=oag;
   openP1s[openN]=p1;
   openP2s[openN]=p2;
   openN++;
}

void QueueClose(int p, double pl, double cg, double tg, double p1, double p2,
                const string label,
                int &closeBatch[], int &closeN)
{
   LogPair(p, label, StringFormat("pl=%s cg=%s tgt=%s p1=%s p2=%s", F2(pl),F2(cg),F2(tg),F2(p1),F2(p2)));
   closeBatch[closeN++]=p;
}

bool ClosePositionByTicket(ulong ticket)
{
   if(ticket==0) return false;
   if(!PositionSelectByTicket(ticket)) return false;

   string sym = PositionGetString(POSITION_SYMBOL);
   double vol = PositionGetDouble(POSITION_VOLUME);
   long type  = PositionGetInteger(POSITION_TYPE);

   MqlTick tk;
   if(!GetTickSafe(sym,tk)) return false;

   ENUM_ORDER_TYPE closeType = (type==POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action       = TRADE_ACTION_DEAL;
   req.position     = ticket;
   req.symbol       = sym;
   req.volume       = vol;
   req.type         = closeType;
   req.price        = (closeType==ORDER_TYPE_SELL ? tk.bid : tk.ask);
   req.deviation    = PipToPoints(sym,InpSlippagePips);
   req.type_filling = GetBestFilling(sym);
   req.magic        = InpMagicNo;

   ResetLastError();
   bool ok = OrderSend(req,res);
   return (ok && (res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_DONE_PARTIAL || res.retcode==TRADE_RETCODE_PLACED));
}

void CloseSingleOpenLeg(int p, const string reason)
{
   bool hasS1 = g_rt[p].hasS1;
   bool hasS2 = g_rt[p].hasS2;

   if(hasS1 && !hasS2)
   {
      if(ClosePositionByTicket(g_rt[p].tkS1))
      {
         LogPair(p,"OPEN_RECOVERY_CLOSE_S1",
                 StringFormat("closed leg1 ticket=%I64u | %s", g_rt[p].tkS1, reason));
      }
      else
      {
         LogPair(p,"OPEN_RECOVERY_CLOSE_S1_FAIL",
                 StringFormat("failed to close leg1 ticket=%I64u | %s", g_rt[p].tkS1, reason));
      }
   }
   else if(!hasS1 && hasS2)
   {
      if(ClosePositionByTicket(g_rt[p].tkS2))
      {
         LogPair(p,"OPEN_RECOVERY_CLOSE_S2",
                 StringFormat("closed leg2 ticket=%I64u | %s", g_rt[p].tkS2, reason));
      }
      else
      {
         LogPair(p,"OPEN_RECOVERY_CLOSE_S2_FAIL",
                 StringFormat("failed to close leg2 ticket=%I64u | %s", g_rt[p].tkS2, reason));
      }
   }
}

void ProcessOpeningPairs()
{
   ulong now = NowMs();

   for(int p=1; p<=g_maxPairs; p++)
   {
      if(!IsOpeningLocked(p)) continue;

      ulong dispatchMs = (ulong)GvGetD(p,"OPENING_DISPATCH_MS",0.0);
      ulong age = (now>=dispatchMs ? now-dispatchMs : 0);

      if((int)age < InpExecGraceMs) continue;

      double oag   = GvGetD(p,"OAG_AT_OPEN",0.0);
      bool hasS1   = g_rt[p].hasS1;
      bool hasS2   = g_rt[p].hasS2;

      // both legs opened
      if(hasS1 && hasS2)
      {
         double filledGap = GvGetD(p,"OPEN_FILL_GAP",0.0);
         if(filledGap == 0.0)
            filledGap = g_rt[p].openS1 - g_rt[p].openS2;

         if(oag > 0.0)
         {
            bool fills_ok = true;
            if(InpOpenDirection==DIR_SELL_ONLY)
               fills_ok = (filledGap >= oag - InpOpenFillTolerance - g_eps);
            else
               fills_ok = (filledGap <= oag + InpOpenFillTolerance + g_eps);

            if(!fills_ok)
            {
               SetOpeningLock(p,false);
               GvSetD(p,"OAG",0.0);
               GvSetD(p,"SCHED_LOT",0.0);

               if(InpAutoFlattenOpenReject)
               {
                  LogPair(p,"OPEN_REJECT_FLATTEN",
                          StringFormat("fillGap=%s oag=%s fillTol=%.2f => closing both legs",
                                       F2(filledGap),F2(oag),InpOpenFillTolerance));
                  ClosePair(p);
               }
               else
               {
                  GvSetD(p,"OPENGAP",filledGap);
                  GvSetD(p,"OPEN_TIME_SEC",(double)TimeCurrent());
                  LogPair(p,"OPEN_REJECT_KEPT",
                          StringFormat("fillGap=%s oag=%s fillTol=%.2f => kept live",
                                       F2(filledGap),F2(oag),InpOpenFillTolerance));
               }
               continue;
            }
         }

         GvSetD(p,"OPENGAP",filledGap);
         GvSetD(p,"OAG",0.0);
         GvSetD(p,"SCHED_LOT",0.0);
         GvSetD(p,"OPEN_TIME_SEC",(double)TimeCurrent());
         SetOpeningLock(p,false);

         LogPair(p,"OPEN_OK",
                 StringFormat("triggerGap=%s dispatchGap=%s fillGap=%s ageMs=%I64u",
                              F2(GvGetD(p,"OPEN_TRIGGER_GAP",0.0)),
                              F2(GvGetD(p,"OPEN_DISPATCH_GAP",0.0)),
                              F2(filledGap), age));
      }
      // neither leg opened -> full abort
      else if(!hasS1 && !hasS2)
      {
         SetOpeningLock(p,false);
         GvSetD(p,"OAG",0.0);
         GvSetD(p,"SCHED_LOT",0.0);

         LogPair(p,"OPEN_ABORT","no legs found after grace window");
      }
      // leg1 opened but leg2 failed -> close leg1
      else if(hasS1 && !hasS2)
      {
         SetOpeningLock(p,false);
         GvSetD(p,"OAG",0.0);
         GvSetD(p,"SCHED_LOT",0.0);

         LogPair(p,"OPEN_PARTIAL_RECOVER",
                 StringFormat("leg1 open, leg2 missing after %I64ums => closing leg1", age));

         CloseSingleOpenLeg(p,"leg2 failed during pair opening");
      }
      // leg2 opened but leg1 failed -> abort / close leg2 too for symmetry safety
      else if(!hasS1 && hasS2)
      {
         SetOpeningLock(p,false);
         GvSetD(p,"OAG",0.0);
         GvSetD(p,"SCHED_LOT",0.0);

         LogPair(p,"OPEN_PARTIAL_RECOVER",
                 StringFormat("leg2 open, leg1 missing after %I64ums => closing leg2", age));

         CloseSingleOpenLeg(p,"leg1 failed during pair opening");
      }
   }
}

void ApplyAutoRules()
{
   if(!g_gapOk) return;
   bool spreadOk = IsSpreadOk(); // <-- NEW: Check spread health
   double cg=g_gap, p1=g_p1, p2=g_p2;
   ulong now = NowMs();

   int    openBatch[64];
   double openLots[64];
   double openOags[64];
   double openP1s[64];
   double openP2s[64];
   int    openN = 0;

   int closeBatch[64];
   int closeN = 0;

   int currentOpening = 0, currentClosing = 0;
   for(int p = 1; p <= g_maxPairs; p++)
   {
      if(g_rt[p].isOpening) currentOpening++;
      if(g_rt[p].isClosing) currentClosing++;
   }

   for(int p = 1; p <= g_maxPairs; p++)
   {
      if(g_rt[p].isOpening || g_rt[p].isClosing)
      {
         ResetHitTimers(p);
         continue;
      }

      int status = GetPairStatus(p);

      if(status == PSTATUS_BROKEN)
      {
         ResetHitTimers(p);
         continue;
      }

      if(status == PSTATUS_SCHED)
      {
         double oag = GvGetD(p, "OAG", 0.0);
         double lot = GvGetD(p, "SCHED_LOT", 0.01);
         if(oag == 0.0 || lot <= 0.0) { CancelSchedule(p); continue; }

         if(!CanOpenTrades()) { ResetOagHit(p); continue; }

         bool hit_oag = (InpOpenDirection == DIR_SELL_ONLY) ? (cg >= oag)
                                                            : (cg <= oag);

         if(!spreadOk) hit_oag = false; // <-- NEW: Treat bad spread as 'miss'                                                   
         bool drift_blocked = (GvGetD(p, "OAG_DRIFT_BLOCK", 0.0) >= 0.5);

         if(drift_blocked)
         {
            bool left_trigger_zone = (InpOpenDirection == DIR_SELL_ONLY) ? (cg < oag - g_eps)
                                                                         : (cg > oag + g_eps);

            if(left_trigger_zone)
            {
               ResetOagDriftBlock(p);
               LogPair(p,"OAG_REARMED",StringFormat("cg=%s oag=%s",F2(cg),F2(oag)));
            }
            else
            {
               continue;
            }
         }

         if(InpOagConfirmMs <= 0)
         {
            if(hit_oag && (openN + currentOpening) < InpMaxConcurrentOpening)
               QueueOpen(p, lot, oag, cg, p1, p2, "OAG_TRIGGER_NOW",
                         openBatch, openLots, openOags, openP1s, openP2s, openN);
            continue;
         }

         bool  active_oag = (GvGetD(p, "OAG_HIT_ACTIVE", 0.0) >= 0.5);
         ulong since_oag  = (ulong)GvGetD(p, "OAG_HIT_SINCE_MS", 0.0);

         if(hit_oag)
         {
            GvSetD(p, "OAG_EXIT_SINCE_MS", 0.0);

            if(!active_oag)
            {
               GvSetD(p, "OAG_HIT_ACTIVE", 1.0);
               GvSetD(p, "OAG_HIT_SINCE_MS", (double)now);
            }
            else
            {
               ulong elapsed = (now >= since_oag ? now - since_oag : 0);

               bool drift_ok = (InpOagMaxDrift <= 0.0) ||
                               ((InpOpenDirection == DIR_SELL_ONLY)
                                 ? (cg >= oag - InpOagMaxDrift - g_eps)
                                 : (cg <= oag + InpOagMaxDrift + g_eps));

               if(!drift_ok)
               {
                  ResetOagHit(p);
                  GvSetD(p,"OAG_DRIFT_BLOCK",1.0);
                  GvSetD(p,"OAG_DRIFT_BLOCK_SINCE",(double)now);

                  LogPair(p,"OAG_CANCEL_DRIFT",
                          StringFormat("cg=%s oag=%s maxDrift=%.2f BLOCKED",
                                       F2(cg),F2(oag),InpOagMaxDrift));
               }
               else if((int)elapsed >= InpOagConfirmMs &&
                       (openN + currentOpening) < InpMaxConcurrentOpening)
               {
                  QueueOpen(p, lot, oag, cg, p1, p2,
                            StringFormat("OAG_CONFIRMED_%dms", (int)elapsed),
                            openBatch, openLots, openOags, openP1s, openP2s, openN);
               }
            }
         }
         else if(active_oag)
         {
            ulong exit_since = (ulong)GvGetD(p, "OAG_EXIT_SINCE_MS", 0.0);
            if(exit_since == 0)
               GvSetD(p, "OAG_EXIT_SINCE_MS", (double)now);
            else
            {
               ulong ea = (now >= exit_since ? now - exit_since : 0);
               if((int)ea >= InpOagExitToleranceMs)
                  ResetOagHit(p);
            }
         }

         continue;
      }

      if(status == PSTATUS_LIVE)
      {
         double tg = GvGetD(p, "TARGET", 0.0);
         if(tg == 0.0)
         {
            if(GvGetD(p, "CAG_HIT_ACTIVE", 0.0) >= 0.5) ResetCagHit(p);
            continue;
         }

         if(!CanCloseTrades()) { ResetCagHit(p); continue; }

         if(InpMinHoldMinutes > 0)
         {
            long open_sec = (long)GvGetD(p, "OPEN_TIME_SEC", 0.0);
            if(open_sec > 0 && (long)TimeCurrent() - open_sec < (long)InpMinHoldMinutes * 60)
            {
               ResetCagHit(p);
               continue;
            }
         }

         bool hit_cag = (InpOpenDirection == DIR_SELL_ONLY) ? (cg <= tg)
                                                            : (cg >= tg);
         
         if(!spreadOk) hit_cag = false; // <-- NEW: Treat bad spread as 'miss'

         bool overrun = (InpOpenDirection == DIR_SELL_ONLY) ? (cg < tg - InpCagOverrunTol - g_eps)
                                                   : (cg > tg + InpCagOverrunTol + g_eps);

            if(InpEnableCagOverrunSkip && hit_cag && overrun)
            {
               ResetCagHit(p);
               LogPair(p, "CAG_SKIP_OVERRUN",
                     StringFormat("cg=%s tgt=%s (Market moved too fast)", F2(cg), F2(tg)));
               continue;
            }

         if(InpCagConfirmMs <= 0)
         {
            if(hit_cag)
            {
               double pl = GetPairPL_ProfitOnly(p);
               bool profit_ok = !InpTargetCloseRequireProfit || (pl > InpMinProfitToClose);
               if(profit_ok && (closeN + currentClosing) < InpMaxConcurrentClosing)
                  QueueClose(p, pl, cg, tg, p1, p2, "CAG_TRIGGER_NOW", closeBatch, closeN);
            }
            continue;
         }

         bool  active_cag = (GvGetD(p, "CAG_HIT_ACTIVE", 0.0) >= 0.5);
         ulong since_cag  = (ulong)GvGetD(p, "CAG_HIT_SINCE_MS", 0.0);

         if(hit_cag)
         {
            GvSetD(p, "CAG_EXIT_SINCE_MS", 0.0);

            if(!active_cag)
            {
               GvSetD(p, "CAG_HIT_ACTIVE", 1.0);
               GvSetD(p, "CAG_HIT_SINCE_MS", (double)now);
            }
            else
            {
               ulong elapsed = (now >= since_cag ? now - since_cag : 0);

               if((int)elapsed >= InpCagConfirmMs)
               {
                  double pl = GetPairPL_ProfitOnly(p);
                  bool profit_ok = !InpTargetCloseRequireProfit || (pl > InpMinProfitToClose);

                  if(profit_ok && (closeN + currentClosing) < InpMaxConcurrentClosing)
                     QueueClose(p, pl, cg, tg, p1, p2,
                                StringFormat("CAG_CONFIRMED_%dms", (int)elapsed),
                                closeBatch, closeN);
                  else if(!profit_ok)
                     ResetCagHit(p);
               }
            }
         }
         else if(active_cag)
         {
            ulong exit_since = (ulong)GvGetD(p, "CAG_EXIT_SINCE_MS", 0.0);
            if(exit_since == 0)
               GvSetD(p, "CAG_EXIT_SINCE_MS", (double)now);
            else
            {
               ulong ea = (now >= exit_since ? now - exit_since : 0);
               if((int)ea >= InpCagExitToleranceMs)
                  ResetCagHit(p);
            }
         }
      }
   }

   for(int i = 0; i < openN; i++)
      OpenPair(openBatch[i], openLots[i], openOags[i], openP1s[i], openP2s[i]);

   if(closeN > 0) ClosePairsInBatch(closeBatch, closeN);
}

int Pad()     { return 18; }
int LineH()   { return UI_FontBase+12; }
int TopH()    { return UI_FontBase+26; }
int TopEditW(){ return 120; }
int TopBtnW() { return 220; }
int TopGap()  { return 18; }
int RowH()    { return UI_FontBase+22; }
int RowBtnW() { return 110; }
int RowGap()  { return 14; }

void ObjDel(const string name){ ObjectDelete(0,name); }

bool CreateRect(string name,int x,int y,int w,int h,color bg)
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

bool CreateLabel(string name,int x,int y,string txt,int fsize,color col)
{
   if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0)) return false;
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fsize);
   ObjectSetInteger(0,name,OBJPROP_COLOR,col);
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
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
   ObjectSetString(0,name,OBJPROP_FONT,font);
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
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
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
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
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   return true;
}

bool CreateStateStrip(string name,int x,int y,int w,int h,color bg)
{
   if(!ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0)) return false;
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   return true;
}

void SetText(const string name,const string txt)
{
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
}

void ResetBtn(const string name)
{
   if(ObjectFind(0,name)>=0) ObjectSetInteger(0,name,OBJPROP_STATE,false);
}

void SetButtonVisible(const string name, const bool visible, const int x_show, const int y_show)
{
   if(ObjectFind(0,name) < 0) return;

   if(visible)
   {
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x_show);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y_show);
      ObjectSetInteger(0,name,OBJPROP_XSIZE,RowBtnW());
      ObjectSetInteger(0,name,OBJPROP_YSIZE,RowH());
      ObjectSetInteger(0,name,OBJPROP_STATE,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,true);
   }
   else
   {
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,-2000);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,-2000);
      ObjectSetInteger(0,name,OBJPROP_XSIZE,1);
      ObjectSetInteger(0,name,OBJPROP_YSIZE,1);
      ObjectSetInteger(0,name,OBJPROP_STATE,false);
   }
}

void SetObjVisible(const string name, const bool visible)
{
   if(ObjectFind(0,name) < 0) return;
   ObjectSetInteger(0,name,OBJPROP_TIMEFRAMES, visible ? OBJ_ALL_PERIODS : 0);
}

void CacheReset()
{
   for(int r=0; r<UI_MAX_ROWS; r++)
   {
      for(int c=0; c<UI_COLS; c++)
      {
         g_cache[r][c].text    = "__INIT__";
         g_cache[r][c].col     = clrNONE;
         g_cache[r][c].visible = false;
      }
   }
}

void UpdateLabelCached(const int row, const int col, const string name,
                       const string newTxt, const color newCol, const bool isVisible)
{
   if(ObjectFind(0,name) < 0) return;

   if(g_cache[row][col].text != newTxt)
   {
      ObjectSetString(0,name,OBJPROP_TEXT,newTxt);
      g_cache[row][col].text = newTxt;
   }

   if(g_cache[row][col].col != newCol)
   {
      ObjectSetInteger(0,name,OBJPROP_COLOR,newCol);
      g_cache[row][col].col = newCol;
   }

   if(g_cache[row][col].visible != isVisible)
   {
      SetObjVisible(name,isVisible);
      g_cache[row][col].visible = isVisible;
   }
}
void UpdateButtonCached(const int row, const int col, const string name,
                        const string newTxt, const bool isVisible)
{
   if(ObjectFind(0,name) < 0) return;

   if(g_cache[row][col].text != newTxt)
   {
      ObjectSetString(0,name,OBJPROP_TEXT,newTxt);
      g_cache[row][col].text = newTxt;
   }

   bool isUpdate = (StringFind(name,"BTN_UPDATE_") >= 0);

   if(isUpdate)
      SetButtonVisible(name, isVisible, g_btnUpdX[row], g_btnUpdY[row]);
   else
      SetButtonVisible(name, isVisible, g_btnClsX[row], g_btnClsY[row]);

   g_cache[row][col].visible = isVisible;
}
void UpdateRectCached(const int row, const int col, const string name,
                      const color newCol, const bool isVisible)
{
   if(ObjectFind(0,name) < 0) return;

   if(g_cache[row][col].col != newCol)
   {
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,newCol);
      g_cache[row][col].col = newCol;
   }

   if(g_cache[row][col].visible != isVisible)
   {
      SetObjVisible(name,isVisible);
      g_cache[row][col].visible = isVisible;
   }
}

void BuildVisiblePairs()
{
   g_visibleN=0;
   for(int p=1; p<=g_maxPairs; p++)
   {
      int st=GetPairStatus(p);
      if(st!=PSTATUS_IDLE)
         if(g_visibleN<(int)ArraySize(g_visiblePairs)) g_visiblePairs[g_visibleN++]=p;
   }
}

int CalcPanelH(int rows)
{
   int h=0;
   h+=10+LineH();
   h+=LineH();
   h+=LineH();
   h+=LineH()+10;
   h+=LineH();
   h+=LineH()+10;
   // 4 insight lines
   h+=LineH()+3;
   h+=LineH()+3;
   h+=LineH()+3;
   h+=LineH()+8;
   h+=TopH()+16;
   h+=LineH()+10;
   h+=(rows<=0?LineH()+10:rows*(RowH()+8));
   h+=Pad()+20;
   if(h<UI_H_Min) h=UI_H_Min;
   return h;
}

void DeleteUI()
{
   ObjDel(g_prefix+"PANEL"); ObjDel(g_prefix+"TITLE"); ObjDel(g_prefix+"SYMS");
   ObjDel(g_prefix+"DIR");   ObjDel(g_prefix+"GAP");   ObjDel(g_prefix+"PRICES");
   ObjDel(g_prefix+"TOTALS");
   ObjDel(g_prefix+"INS1"); ObjDel(g_prefix+"INS2");
   ObjDel(g_prefix+"INS3"); ObjDel(g_prefix+"INS4");
   ObjDel(g_prefix+"LOT_LBL"); ObjDel(g_prefix+"LOT_EDIT");
   ObjDel(g_prefix+"OAG_LBL"); ObjDel(g_prefix+"OAG_EDIT");
   ObjDel(g_prefix+"CAG_LBL"); ObjDel(g_prefix+"CAG_EDIT");
   ObjDel(g_prefix+"BTN_OPEN_SCHED"); ObjDel(g_prefix+"BTN_CLOSE_ALL");
   ObjDel(g_prefix+"COL_HDR0"); ObjDel(g_prefix+"COL_HDR1"); ObjDel(g_prefix+"COL_HDR2");
   ObjDel(g_prefix+"COL_HDR3"); ObjDel(g_prefix+"COL_HDR4"); ObjDel(g_prefix+"COL_HDR5");

   for(int r=0; r<UI_MAX_ROWS; r++)
   {
      ObjDel(g_prefix+"R_STRIP_"+IntegerToString(r));
      ObjDel(g_prefix+"R_PAIR_"+IntegerToString(r));
      ObjDel(g_prefix+"R_LOT_"+IntegerToString(r));
      ObjDel(g_prefix+"R_OG_"+IntegerToString(r));
      ObjDel(g_prefix+"R_OAG_"+IntegerToString(r));
      ObjDel(g_prefix+"R_TG_"+IntegerToString(r));
      ObjDel(g_prefix+"R_PL_"+IntegerToString(r));
      ObjDel(g_prefix+"BTN_UPDATE_"+IntegerToString(r));
      ObjDel(g_prefix+"BTN_CLOSE_"+IntegerToString(r));
   }

   g_uiBuilt = false;   // important fix
}

void BuildUIOnce()
{
   if(g_uiBuilt) return;

   int pad=Pad();
   int panelH=UI_AutoHeight?CalcPanelH(UI_MAX_ROWS):UI_H_Min + UI_MAX_ROWS*(RowH()+8);

   CreateRect(g_prefix+"PANEL",UI_X,UI_Y,UI_W,panelH,InpColPanelBG);

   int x0=UI_X+pad, y=UI_Y+6;

   CreateLabel(g_prefix+"TITLE",x0,y,"",UI_FontBase-3,InpColTitleText);
   y+=LineH()+6;

   CreateLabel(g_prefix+"SYMS",x0,y,"",UI_FontBase,InpColInfoText); y+=LineH()+5;
   CreateLabel(g_prefix+"DIR",x0,y,"",UI_FontBase,InpColInfoText); y+=LineH()+8;
   CreateLabel(g_prefix+"GAP",x0,y,"GAP: --",UI_FontBase+6,InpColGapText); y+=LineH()+14;
   CreateLabel(g_prefix+"PRICES",x0,y,"P1: --   P2: --",UI_FontBase,InpColInfoText); y+=LineH()+8;
   CreateLabel(g_prefix+"TOTALS",x0,y,"Terminal P/L: -- | List P/L: -- | List Lot: --",UI_FontBase,InpColOpenText); y+=LineH()+6;

   // ---- 4 Insight Lines ----
   CreateLabel(g_prefix+"INS1",x0,y,"",UI_FontBase,clrDodgerBlue);  y+=LineH()+3;
   CreateLabel(g_prefix+"INS2",x0,y,"",UI_FontBase,clrSilver);      y+=LineH()+3;
   CreateLabel(g_prefix+"INS3",x0,y,"",UI_FontBase,clrSilver);      y+=LineH()+3;
   CreateLabel(g_prefix+"INS4",x0,y,"",UI_FontBase,clrGold);        y+=LineH()+8;

   int topH=TopH();
   CreateLabel(g_prefix+"LOT_LBL",x0,y+6,"Lot:",UI_FontBase,InpColInfoText);
   CreateEdit(g_prefix+"LOT_EDIT",x0+55,y,TopEditW(),topH,"0.01",UI_FontBase+3);

   int x=x0+60+TopEditW()+TopGap();
   CreateLabel(g_prefix+"OAG_LBL",x-4,y+6,"OAG:",UI_FontBase,InpColInfoText);
   CreateEdit(g_prefix+"OAG_EDIT",x+60,y,TopEditW(),topH,"0",UI_FontBase+3);

   x=x+70+TopEditW()+TopGap();
   CreateLabel(g_prefix+"CAG_LBL",x-4,y+6,"CAG:",UI_FontBase,InpColInfoText);
   CreateEdit(g_prefix+"CAG_EDIT",x+60,y,TopEditW(),topH,"0",UI_FontBase+3);

   x=x+80+TopEditW()+TopGap();
   CreateButton(g_prefix+"BTN_OPEN_SCHED",x,y,TopBtnW(),topH,"OPEN / SCHEDULE",InpColBtnOpenBG,UI_FontBase-2);
   x+=TopBtnW()+TopGap();
   CreateButton(g_prefix+"BTN_CLOSE_ALL",x,y,170,topH,"CLOSE ALL",InpColBtnCloseAllBG,UI_FontBase-2);
   y+=topH+14;

   int cStrip=x0;
   int c0=x0+12, c1=c0+180, c2=c1+110, c3=c2+110, c4=c3+110, c5=c4+110, c6=c5+340;

   CreateLabelMono(g_prefix+"COL_HDR0",c0,y,"PAIR",    UI_FontBase,InpColInfoText,UI_MonoFont);
   CreateLabelMono(g_prefix+"COL_HDR1",c1,y,"LOT",     UI_FontBase,InpColInfoText,UI_MonoFont);
   CreateLabelMono(g_prefix+"COL_HDR2",c2,y,"OPEN_GAP",UI_FontBase,InpColInfoText,UI_MonoFont);
   CreateLabelMono(g_prefix+"COL_HDR3",c3,y,"OAG",     UI_FontBase,InpColInfoText,UI_MonoFont);
   CreateLabelMono(g_prefix+"COL_HDR4",c4,y,"CAG(TGT)",UI_FontBase,InpColInfoText,UI_MonoFont);
   CreateLabelMono(g_prefix+"COL_HDR5",c5,y,"P/L",     UI_FontBase,InpColInfoText,UI_MonoFont);
   y+=LineH()+8;

   for(int r=0; r<UI_MAX_ROWS; r++)
   {
      int ry=y+r*(RowH()+8);

      CreateStateStrip(g_prefix+"R_STRIP_"+IntegerToString(r), cStrip, ry-1, 4, RowH()+2, clrSilver);

      CreateLabelMono(g_prefix+"R_PAIR_"+IntegerToString(r),c0,ry,"",UI_FontBase,InpColInfoText,UI_MonoFont);
      CreateLabelMono(g_prefix+"R_LOT_" +IntegerToString(r),c1,ry,"",UI_FontBase,InpColInfoText,UI_MonoFont);
      CreateLabelMono(g_prefix+"R_OG_"  +IntegerToString(r),c2,ry,"",UI_FontBase,InpColInfoText,UI_MonoFont);
      CreateLabelMono(g_prefix+"R_OAG_" +IntegerToString(r),c3,ry,"",UI_FontBase,InpColInfoText,UI_MonoFont);
      CreateLabelMono(g_prefix+"R_TG_"  +IntegerToString(r),c4,ry,"",UI_FontBase,InpColInfoText,UI_MonoFont);
      CreateLabelMono(g_prefix+"R_PL_"  +IntegerToString(r),c5,ry,"",UI_FontBase,InpColInfoText,UI_MonoFont);

      int bx=c6-(RowBtnW()+RowGap()+RowBtnW());
      g_btnUpdX[r] = bx;
      g_btnUpdY[r] = ry-2;
      g_btnClsX[r] = bx+RowBtnW()+RowGap();
      g_btnClsY[r] = ry-2;

      CreateButton(g_prefix+"BTN_UPDATE_"+IntegerToString(r),g_btnUpdX[r],g_btnUpdY[r],RowBtnW(),RowH(),"UPDATE",InpColBtnUpdateBG,UI_FontBase-2);
      CreateButton(g_prefix+"BTN_CLOSE_" +IntegerToString(r),g_btnClsX[r],g_btnClsY[r],RowBtnW(),RowH(),"CLOSE",InpColBtnCloseAllBG,UI_FontBase-2);

      SetButtonVisible(g_prefix+"BTN_UPDATE_"+IntegerToString(r), false, g_btnUpdX[r], g_btnUpdY[r]);
      SetButtonVisible(g_prefix+"BTN_CLOSE_" +IntegerToString(r), false, g_btnClsX[r], g_btnClsY[r]);

      SetObjVisible(g_prefix+"R_STRIP_"+IntegerToString(r), false);
      SetObjVisible(g_prefix+"R_PAIR_" +IntegerToString(r), false);
      SetObjVisible(g_prefix+"R_LOT_"  +IntegerToString(r), false);
      SetObjVisible(g_prefix+"R_OG_"   +IntegerToString(r), false);
      SetObjVisible(g_prefix+"R_OAG_"  +IntegerToString(r), false);
      SetObjVisible(g_prefix+"R_TG_"   +IntegerToString(r), false);
      SetObjVisible(g_prefix+"R_PL_"   +IntegerToString(r), false);
   }

   g_uiBuilt = true;
}

double GetTerminalTotalPL()
{
   double t=0.0;
   for(int p=1;p<=g_maxPairs;p++) t+=g_rt[p].pl;
   return t;
}

double GetVisibleListSumPL()
{
   double s=0.0;
   for(int i=0;i<g_visibleN;i++)
   {
      int p=g_visiblePairs[i],st=GetPairStatus(p);
      if(st==PSTATUS_LIVE||st==PSTATUS_BROKEN||st==PSTATUS_CLOSING) s+=g_rt[p].pl;
   }
   return s;
}

double GetVisibleListSumLots()
{
   double s=0.0;
   for(int i=0;i<g_visibleN;i++)
   {
      int p=g_visiblePairs[i],st=GetPairStatus(p);
      if(st==PSTATUS_LIVE||st==PSTATUS_BROKEN||st==PSTATUS_OPENING||st==PSTATUS_CLOSING)
      {
         double v1=g_rt[p].volS1,v2=g_rt[p].volS2;
         if(v1>0.0&&v2>0.0) s+=MathMin(v1,v2);
         else if(v1>0.0) s+=v1;
         else s+=v2;
      }
      else if(st==PSTATUS_SCHED) s+=GvGetD(p,"SCHED_LOT",0.0);
   }
   return s;
}

void RefreshPairRuntime()
{
   for(int i=0;i<ArraySize(g_rt);i++) ZeroMemory(g_rt[i]);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNo) continue;

      int p; string leg;
      if(!ParseComment(PositionGetString(POSITION_COMMENT),p,leg)) continue;
      if(p<1||p>g_maxPairs) continue;

      g_rt[p].pl+=PositionGetDouble(POSITION_PROFIT);

      if(leg=="S1")
      {
         g_rt[p].hasS1=true;
         g_rt[p].tkS1=tk;
         g_rt[p].volS1=PositionGetDouble(POSITION_VOLUME);
         g_rt[p].openS1=PositionGetDouble(POSITION_PRICE_OPEN);
      }
      else if(leg=="S2")
      {
         g_rt[p].hasS2=true;
         g_rt[p].tkS2=tk;
         g_rt[p].volS2=PositionGetDouble(POSITION_VOLUME);
         g_rt[p].openS2=PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
}

void RefreshHeaderLight()
{
   bool ok=g_gapOk;
   double gap=g_gap, p1=g_p1, p2=g_p2;
   if(!ok) ok=ComputeGap(gap,p1,p2);

   string dir=(InpOpenDirection==DIR_SELL_ONLY)?"SELL_ONLY (Bid1-Ask2)":"BUY_ONLY (Ask1-Bid2)";

   SetText(g_prefix+"TITLE",
      "LOT | OAG | CAG -> OPEN/SCHEDULE  |  OagTol="+F2(InpOagTolerance)+
      "  OagDrift="+F2(InpOagMaxDrift)+
      "  CagTol(DISABLED)="+F2(InpCagTolerance)+
      "  CagOverrun="+F2(InpCagOverrunTol)+
      "  Grace="+IntegerToString(InpExecGraceMs)+
      "ms  OAGconf="+IntegerToString(InpOagConfirmMs)+
      "ms  CAGconf="+IntegerToString(InpCagConfirmMs)+
      "ms  CloseWatchdog="+IntegerToString(InpCloseWatchdogMs)+"ms"
   );

   SetText(g_prefix+"SYMS","S1: "+InpSymbol1+"  |  S2: "+InpSymbol2);
   SetText(g_prefix+"DIR","Dir: "+dir);
   SetText(g_prefix+"GAP", ok?"GAP: "+F2(gap):"GAP: --");
   SetText(g_prefix+"PRICES", ok?"P1: "+F2(p1)+"   P2: "+F2(p2):"P1: --   P2: --");
   SetText(g_prefix+"TOTALS", StringFormat("Terminal P/L: %s | List P/L: %s | List Lot: %s",
      F2(GetTerminalTotalPL()),F2(GetVisibleListSumPL()),F2(GetVisibleListSumLots())));

   // ---- Insight 1: Spread health + entry gate ----
   {
      MqlTick t1, t2;
      bool gotT = GetTickSafe(InpSymbol1,t1) && GetTickSafe(InpSymbol2,t2);
      bool spOk = IsSpreadOk();
      if(gotT)
      {
         double sp1=t1.ask-t1.bid, sp2=t2.ask-t2.bid;
         bool ok1=(InpMaxSpreadS1<=0.0||sp1<=InpMaxSpreadS1+g_eps);
         bool ok2=(InpMaxSpreadS2<=0.0||sp2<=InpMaxSpreadS2+g_eps);
         ObjectSetInteger(0,g_prefix+"INS1",OBJPROP_COLOR,spOk?clrMediumSeaGreen:clrRed);
         SetText(g_prefix+"INS1",
            StringFormat("Spread  %s: %.2f %s (lim %.2f)   |   %s: %.2f %s (lim %.2f)   |   Entry Gate: %s",
               InpSymbol1, sp1, ok1?"[OK]":"[WIDE!]", InpMaxSpreadS1,
               InpSymbol2, sp2, ok2?"[OK]":"[WIDE!]", InpMaxSpreadS2,
               spOk?"OPEN":"*** BLOCKED — SPREAD TOO WIDE ***"));
      }
      else
         SetText(g_prefix+"INS1","Spread: no tick data");
   }

   // ---- Insight 2: Position summary ----
   {
      int nLive=0,nSched=0,nOpening=0,nClosing=0,nBroken=0;
      for(int p=1;p<=g_maxPairs;p++)
      {
         int st=GetPairStatus(p);
         if(st==PSTATUS_LIVE)         nLive++;
         else if(st==PSTATUS_SCHED)   nSched++;
         else if(st==PSTATUS_OPENING) nOpening++;
         else if(st==PSTATUS_CLOSING) nClosing++;
         else if(st==PSTATUS_BROKEN)  nBroken++;
      }
      string brokenNote = (nBroken>0) ? StringFormat("  |  %d BROKEN — manual check needed!",nBroken) : "";
      SetText(g_prefix+"INS2",
         StringFormat("Positions: %d Live  |  %d Scheduled (waiting OAG)  |  %d Opening  |  %d Closing%s",
                      nLive, nSched, nOpening, nClosing, brokenNote));
      ObjectSetInteger(0,g_prefix+"INS2",OBJPROP_COLOR,nBroken>0?clrRed:clrSilver);
   }

   // ---- Insight 3: Gap vs active OAG/CAG levels ----
   {
      string ins3 = "Gap vs Levels: --";
      if(ok)
      {
         // Find first scheduled pair's OAG
         for(int p=1;p<=g_maxPairs;p++)
         {
            if(GetPairStatus(p)==PSTATUS_SCHED)
            {
               double oag=GvGetD(p,"OAG",0.0);
               if(oag>0.0)
               {
                  double delta = (InpOpenDirection==DIR_SELL_ONLY) ? gap - oag : oag - gap;
                  string pos   = (delta >= 0) ? StringFormat("+%.2f ABOVE OAG — IN ENTRY ZONE",delta)
                                              : StringFormat("%.2f below OAG — waiting",delta);
                  ins3 = StringFormat("Gap vs OAG(P%d): gap=%.2f  OAG=%.2f  %s", p, gap, oag, pos);
               }
               break;
            }
         }
         // If no scheduled, show gap vs first live pair's CAG target
         if(ins3=="Gap vs Levels: --")
         {
            for(int p=1;p<=g_maxPairs;p++)
            {
               if(GetPairStatus(p)==PSTATUS_LIVE)
               {
                  double tg=GvGetD(p,"TARGET",0.0);
                  double og=GvGetD(p,"OPENGAP",0.0);
                  if(tg>0.0)
                  {
                     double delta=(InpOpenDirection==DIR_SELL_ONLY)?gap-tg:tg-gap;
                     string pos=(delta<=0)?StringFormat("%.2f — AT/PAST CAG",delta)
                                          :StringFormat("+%.2f above CAG — %.2f pts to close",delta,MathAbs(delta));
                     ins3=StringFormat("Gap vs CAG(P%d): gap=%.2f  OpenGap=%.2f  CAG=%.2f  %s",
                                       p, gap, og, tg, pos);
                  }
                  break;
               }
            }
         }
         if(ins3=="Gap vs Levels: --") ins3="Gap vs Levels: no active schedules or targets — idle";
      }
      SetText(g_prefix+"INS3", ins3);
   }

   // ---- Insight 4: Recommended next action ----
   {
      string ins4 = "Next Action: --";
      color  ins4col = clrGold;

      int nLive=0,nSched=0;
      for(int p=1;p<=g_maxPairs;p++)
      {
         int st=GetPairStatus(p);
         if(st==PSTATUS_LIVE)       nLive++;
         else if(st==PSTATUS_SCHED) nSched++;
      }

      if(!IsSpreadOk())
      {
         ins4    = "Next Action: WAIT — spread too wide, all OAG/CAG triggers are paused until spread normalizes";
         ins4col = clrRed;
      }
      else if(nSched==0 && nLive==0)
      {
         ins4    = "Next Action: IDLE — enter Lot + OAG + CAG then click  OPEN / SCHEDULE  to queue a pair";
         ins4col = clrGold;
      }
      else if(nSched>0 && nLive==0)
      {
         ins4    = StringFormat("Next Action: MONITORING — %d pair(s) waiting for OAG trigger; EA will auto-open when gap reaches target",nSched);
         ins4col = clrDodgerBlue;
      }
      else if(nLive>0 && nSched==0)
      {
         bool anyTarget=false;
         for(int p=1;p<=g_maxPairs;p++)
            if(GetPairStatus(p)==PSTATUS_LIVE && GvGetD(p,"TARGET",0.0)!=0.0) { anyTarget=true; break; }
         if(anyTarget)
         {
            ins4    = StringFormat("Next Action: HOLDING %d live pair(s) — EA will auto-close when gap hits CAG target",nLive);
            ins4col = clrMediumSeaGreen;
         }
         else
         {
            ins4    = StringFormat("Next Action: %d live pair(s) with NO CAG set — enter CAG value and click UPDATE row button to activate auto-close",nLive);
            ins4col = clrOrange;
         }
      }
      else
      {
         ins4    = StringFormat("Next Action: ACTIVE — %d live + %d scheduled; EA managing both open and close triggers",nLive,nSched);
         ins4col = clrMediumSeaGreen;
      }

      SetText(g_prefix+"INS4", ins4);
      ObjectSetInteger(0,g_prefix+"INS4",OBJPROP_COLOR,ins4col);
   }
}

void RefreshUITextOnly()
{
   
   if(!g_uiBuilt) return;
   if(ObjectFind(0, g_prefix+"PANEL") < 0) return;

   RefreshHeaderLight();

   for(int r=0; r<UI_MAX_ROWS; r++)
   {
      bool isVisible = (r < g_visibleN);

      string nStrip = g_prefix+"R_STRIP_"+IntegerToString(r);
      string nPair  = g_prefix+"R_PAIR_"+IntegerToString(r);
      string nLot   = g_prefix+"R_LOT_" +IntegerToString(r);
      string nOG    = g_prefix+"R_OG_"  +IntegerToString(r);
      string nOAG   = g_prefix+"R_OAG_" +IntegerToString(r);
      string nTG    = g_prefix+"R_TG_"  +IntegerToString(r);
      string nPL    = g_prefix+"R_PL_"  +IntegerToString(r);
      string bUpd   = g_prefix+"BTN_UPDATE_"+IntegerToString(r);
      string bCls   = g_prefix+"BTN_CLOSE_"+IntegerToString(r);

      if(!isVisible)
      {
         UpdateRectCached (r,6,nStrip,clrSilver,false);
         UpdateLabelCached(r,0,nPair,"",InpColInfoText,false);
         UpdateLabelCached(r,1,nLot ,"",InpColInfoText,false);
         UpdateLabelCached(r,2,nOG  ,"",InpColInfoText,false);
         UpdateLabelCached(r,3,nOAG ,"",InpColInfoText,false);
         UpdateLabelCached(r,4,nTG  ,"",InpColInfoText,false);
         UpdateLabelCached(r,5,nPL  ,"",InpColInfoText,false);
         UpdateButtonCached(r,0,bUpd,"",false);
         UpdateButtonCached(r,1,bCls,"",false);
         continue;
      }

      int p = g_visiblePairs[r];
      int st = GetPairStatus(p);

      color rc = InpColInfoText;
      color stripCol = InpColStatusIdle;
      string stLabel = "";

      if(st==PSTATUS_OPENING)     { rc=InpColStatusOpening; stripCol=InpColStatusOpening; stLabel="OPENING"; }
      else if(st==PSTATUS_CLOSING){ rc=InpColStatusClosing; stripCol=InpColStatusClosing; stLabel="CLOSING"; }
      else if(st==PSTATUS_BROKEN) { rc=InpColStatusLoss;    stripCol=InpColStatusLoss;    stLabel="BROKEN"; }
      else if(st==PSTATUS_SCHED)  { rc=InpColStatusSched;   stripCol=InpColStatusSched;   stLabel="SCHED"; }
      else
      {
         double pl=GetPairPL_ProfitOnly(p);
         rc=(pl>=0.0?InpColStatusProfit:InpColStatusLoss);
         stripCol=(pl>=0.0?clrLimeGreen:InpColStatusLoss);
         stLabel="LIVE";
      }

      string pairTxt = "PAIR "+IntegerToString(p)+" ("+stLabel+")";
      string lotTxt  = "--";
      string ogTxt   = "--";
      string oagTxt  = "--";
      string tgTxt   = "--";
      string plTxt   = "--";
      string updTxt  = "UPDATE";
      string clsTxt  = "CLOSE";

      if(st==PSTATUS_SCHED)
      {
         lotTxt = F2(GvGetD(p,"SCHED_LOT",0.01));
         oagTxt = F2(GvGetD(p,"OAG",0.0));
         tgTxt  = F2(GvGetD(p,"TARGET",0.0));
         plTxt  = "PENDING";
         clsTxt = "CANCEL";
      }
      else if(st==PSTATUS_OPENING)
      {
         ulong age=NowMs()-(ulong)GvGetD(p,"OPENING_DISPATCH_MS",0.0);
         lotTxt = F2(GetPairLot_PairSize(p));
         oagTxt = F2(GvGetD(p,"OAG_AT_OPEN",0.0));
         tgTxt  = F2(GvGetD(p,"TARGET",0.0));
         plTxt  = StringFormat("wait %I64ums",age);
         updTxt = "--";
         clsTxt = "--";
      }
      else if(st==PSTATUS_CLOSING)
      {
         ulong age=NowMs()-(ulong)GvGetD(p,"CLOSING_START_MS",0.0);
         lotTxt = F2(GetPairLot_PairSize(p));
         tgTxt  = F2(GvGetD(p,"TARGET",0.0));
         plTxt  = StringFormat("closing %I64ums",age);
         updTxt = "--";
         clsTxt = "--";
      }
      else if(st==PSTATUS_BROKEN)
      {
         lotTxt = F2(GetPairLot_PairSize(p));
         plTxt  = F2(GetPairPL_ProfitOnly(p))+" [BROKEN]";
      }
      else
      {
         double lot=GetPairLot_PairSize(p), pl=GetPairPL_ProfitOnly(p);
         bool ok2=false;
         double og=GetPairOpenGap_FromFills(p,ok2);
         if(ok2) GvSetD(p,"OPENGAP",og); else og=GvGetD(p,"OPENGAP",0.0);

         lotTxt = F2(lot);
         ogTxt  = (og==0.0?"--":F2(og));
         tgTxt  = F2(GvGetD(p,"TARGET",0.0));
         plTxt  = F2(pl);
      }

      UpdateRectCached (r,6,nStrip,stripCol,true);
      UpdateLabelCached(r,0,nPair,pairTxt,rc,true);
      UpdateLabelCached(r,1,nLot ,lotTxt ,rc,true);
      UpdateLabelCached(r,2,nOG  ,ogTxt  ,rc,true);
      UpdateLabelCached(r,3,nOAG ,oagTxt ,rc,true);
      UpdateLabelCached(r,4,nTG  ,tgTxt  ,rc,true);
      UpdateLabelCached(r,5,nPL  ,plTxt  ,rc,true);
      UpdateButtonCached(r,7,bUpd,updTxt,true);
      UpdateButtonCached(r,8,bCls,clsTxt,true);
   }

   ChartRedraw(0);
}

void EnsureGVInit()
{
   for(int p=1;p<=g_maxPairs;p++)
   {
      if(!GlobalVariableCheck(GvKey(p,"STATUS")))                GvSetD(p,"STATUS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OAG")))                   GvSetD(p,"OAG",0.0);
      if(!GlobalVariableCheck(GvKey(p,"SCHED_LOT")))             GvSetD(p,"SCHED_LOT",0.0);
      if(!GlobalVariableCheck(GvKey(p,"TARGET")))                GvSetD(p,"TARGET",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPENGAP")))               GvSetD(p,"OPENGAP",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OAG_AT_OPEN")))           GvSetD(p,"OAG_AT_OPEN",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPENING")))               GvSetD(p,"OPENING",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPENING_SINCE_MS")))      GvSetD(p,"OPENING_SINCE_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPENING_DISPATCH_MS")))   GvSetD(p,"OPENING_DISPATCH_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSING")))               GvSetD(p,"CLOSING",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSING_SINCE_MS")))      GvSetD(p,"CLOSING_SINCE_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSING_START_MS")))      GvSetD(p,"CLOSING_START_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSING_DISPATCH_MS")))   GvSetD(p,"CLOSING_DISPATCH_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPEN_TIME_SEC")))         GvSetD(p,"OPEN_TIME_SEC",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OAG_HIT_ACTIVE")))        GvSetD(p,"OAG_HIT_ACTIVE",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OAG_HIT_SINCE_MS")))      GvSetD(p,"OAG_HIT_SINCE_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OAG_EXIT_SINCE_MS")))     GvSetD(p,"OAG_EXIT_SINCE_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OAG_DRIFT_BLOCK")))       GvSetD(p,"OAG_DRIFT_BLOCK",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OAG_DRIFT_BLOCK_SINCE"))) GvSetD(p,"OAG_DRIFT_BLOCK_SINCE",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CAG_HIT_ACTIVE")))        GvSetD(p,"CAG_HIT_ACTIVE",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CAG_HIT_SINCE_MS")))      GvSetD(p,"CAG_HIT_SINCE_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CAG_EXIT_SINCE_MS")))     GvSetD(p,"CAG_EXIT_SINCE_MS",0.0);
      if(!GlobalVariableCheck(GvKey(p,"BROKEN_LOGGED")))         GvSetD(p,"BROKEN_LOGGED",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSE_TK_S1")))           GvSetD(p,"CLOSE_TK_S1",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSE_TK_S2")))           GvSetD(p,"CLOSE_TK_S2",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSE_FILL_S1")))         GvSetD(p,"CLOSE_FILL_S1",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSE_FILL_S2")))         GvSetD(p,"CLOSE_FILL_S2",0.0);

      if(!GlobalVariableCheck(GvKey(p,"OPEN_TRIGGER_GAP")))    GvSetD(p,"OPEN_TRIGGER_GAP",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPEN_DISPATCH_GAP")))   GvSetD(p,"OPEN_DISPATCH_GAP",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPEN_FILL_S1")))        GvSetD(p,"OPEN_FILL_S1",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPEN_FILL_S2")))        GvSetD(p,"OPEN_FILL_S2",0.0);
      if(!GlobalVariableCheck(GvKey(p,"OPEN_FILL_GAP")))       GvSetD(p,"OPEN_FILL_GAP",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSE_TRIGGER_GAP")))   GvSetD(p,"CLOSE_TRIGGER_GAP",0.0);
      if(!GlobalVariableCheck(GvKey(p,"CLOSE_FILL_GAP")))      GvSetD(p,"CLOSE_FILL_GAP",0.0);

   }
}

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
   g_uiBuilt = false;   // force rebuild after reinit/property change

   g_maxPairs=InpMaxPairs;
   if(g_maxPairs<1) g_maxPairs=1;
   if(g_maxPairs>50) g_maxPairs=50;

   int mx=DetectMaxPairIdxFromPositions();
   if(mx>g_maxPairs) g_maxPairs=MathMin(mx,50);

   SymbolSelect(InpSymbol1, true);
   SymbolSelect(InpSymbol2, true);

   EnsureGVInit();
   ResetSessionStateOnInit();
   RefreshTradeableState();
   RefreshPairRuntime();
   ReconcileAllPairStates();

   CacheReset();
   BuildVisiblePairs();
   BuildUIOnce();
   RefreshUITextOnly();
   ChartRedraw();

   int ms=InpRefreshMs;
   if(ms<50) ms=50;
   EventSetMillisecondTimer(ms);

   LogMsg(StringFormat("v%s | MaxPairs=%d | OAGtol=%.2f | OAGmaxDrift=%.2f | CAGtol(DISABLED)=%.2f | CAGoverrun=%.2f | Grace=%dms | OAGconf=%dms | CAGconf=%dms | CloseWatchdog=%dms",
          "3.26",
          g_maxPairs,InpOagTolerance,InpOagMaxDrift,InpCagTolerance,InpCagOverrunTol,InpExecGraceMs,InpOagConfirmMs,InpCagConfirmMs,InpCloseWatchdogMs));
   return INIT_SUCCEEDED;
}



void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteUI();
   ChartRedraw();
   LogMsg("Deinitialized.");
}

void OnTick()
{
   static bool inExec=false;
   if(inExec) return;
   inExec=true;

   ResetLastError();

   RefreshTradeableState();
   g_gapOk = ComputeGap(g_gap, g_p1, g_p2);
   RefreshPairRuntime();
   ReconcileAllPairStates();
   ProcessOpeningPairs();
   ProcessClosingPairs();
   RefreshLockCache();
   ApplyAutoRules();

   inExec=false;
}

void OnTimer()
{
   static bool inUi=false;
   if(inUi) return;
   inUi=true;

   RefreshPairRuntime();
   BuildVisiblePairs();

   if(!g_uiBuilt)
      BuildUIOnce();

   RefreshUITextOnly();
   ChartRedraw();

   inUi=false;
}




void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(!HistoryDealSelect(dealTicket)) return;
   if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagicNo) return;

   long   entry   = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   string comment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
   double price   = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   string sym     = HistoryDealGetString(dealTicket, DEAL_SYMBOL);

   int pairIdx; string leg;

   if(ParseComment(comment, pairIdx, leg))
   {
      if(entry == DEAL_ENTRY_IN)
      {
         LogPair(pairIdx, "FILL_OPEN", StringFormat("leg=%s sym=%s price=%s", leg, sym, F2(price)));

         if(leg == "S1") GvSetD(pairIdx, "OPEN_FILL_S1", price);
         else            GvSetD(pairIdx, "OPEN_FILL_S2", price);

         double f1 = GvGetD(pairIdx, "OPEN_FILL_S1", 0.0);
         double f2 = GvGetD(pairIdx, "OPEN_FILL_S2", 0.0);

         if(f1 > 0.0 && f2 > 0.0)
         {
            double filledGap = f1 - f2;
            GvSetD(pairIdx, "OPEN_FILL_GAP", filledGap);

            LogPair(pairIdx, "OPEN_FILL_REPORT",
                    StringFormat("triggerGap=%s dispatchGap=%s fillGap=%s driftVsTrigger=%s",
                                 F2(GvGetD(pairIdx,"OPEN_TRIGGER_GAP",0.0)),
                                 F2(GvGetD(pairIdx,"OPEN_DISPATCH_GAP",0.0)),
                                 F2(filledGap),
                                 F2(filledGap - GvGetD(pairIdx,"OPEN_TRIGGER_GAP",0.0))));
         }

         RefreshPairRuntime();
         return;
      }

      if(entry == DEAL_ENTRY_OUT)
      {
         LogPair(pairIdx, "FILL_CLOSE", StringFormat("leg=%s sym=%s price=%s", leg, sym, F2(price)));

         if(leg == "S1") GvSetD(pairIdx, "CLOSE_FILL_S1", price);
         else            GvSetD(pairIdx, "CLOSE_FILL_S2", price);

         double c1 = GvGetD(pairIdx, "CLOSE_FILL_S1", 0.0);
         double c2 = GvGetD(pairIdx, "CLOSE_FILL_S2", 0.0);
         if(c1 > 0.0 && c2 > 0.0)
         {
            GvSetD(pairIdx, "CLOSE_FILL_GAP", c1 - c2);
            if(!g_inBatchClose)
            {
               // Not in batch-send hot path: refresh positions and finalize immediately.
               RefreshPairRuntime();
               if(!g_rt[pairIdx].hasS1 && !g_rt[pairIdx].hasS2)
                  FinalizeCloseLog(pairIdx);
            }
            // During g_inBatchClose: fill prices stored above; finalization deferred
            // to the next ProcessClosingPairs tick to keep the send loop unblocked.
         }
         // else: only one leg filled so far — wait for the second callback
         return;
      }
   }

   if(entry == DEAL_ENTRY_OUT && StringFind(comment, MakeCloseTag()) >= 0)
   {
      ulong posId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      double px   = price;

      for(int p=1; p<=g_maxPairs; p++)
      {
         ulong tk1 = (ulong)GvGetD(p, "CLOSE_TK_S1", 0.0);
         ulong tk2 = (ulong)GvGetD(p, "CLOSE_TK_S2", 0.0);

         if(posId == tk1 && tk1 != 0)
         {
            GvSetD(p, "CLOSE_FILL_S1", px);
            LogPair(p, "FILL_CLOSE", StringFormat("leg=S1 sym=%s price=%s (fallback)", sym, F2(px)));
         }
         else if(posId == tk2 && tk2 != 0)
         {
            GvSetD(p, "CLOSE_FILL_S2", px);
            LogPair(p, "FILL_CLOSE", StringFormat("leg=S2 sym=%s price=%s (fallback)", sym, F2(px)));
         }

         double c1 = GvGetD(p, "CLOSE_FILL_S1", 0.0);
         double c2 = GvGetD(p, "CLOSE_FILL_S2", 0.0);
         if(c1 > 0.0 && c2 > 0.0)
         {
            GvSetD(p, "CLOSE_FILL_GAP", c1 - c2);
            if(!g_inBatchClose)
            {
               RefreshPairRuntime();
               if(!g_rt[p].hasS1 && !g_rt[p].hasS2 &&
                  ((ulong)GvGetD(p, "CLOSE_TK_S1", 0.0) != 0 || (ulong)GvGetD(p, "CLOSE_TK_S2", 0.0) != 0))
               {
                  FinalizeCloseLog(p);
               }
            }
         }
         // else: only one leg filled so far — wait for the second callback
      }
   }
}


void FinalizeCloseLog(int p)
{
   if(!IsClosingLocked(p)) return;

   double fS1   = GvGetD(p,"CLOSE_FILL_S1",0.0);
   double fS2   = GvGetD(p,"CLOSE_FILL_S2",0.0);

   // Do not finalize until both fill prices are confirmed.
   // ProcessClosingPairs will retry until fills arrive (or timeout forces it).
   if(fS1 <= 0.0 || fS2 <= 0.0) return;

   double closeGap = GvGetD(p,"CLOSE_FILL_GAP",0.0);
   double trg   = GvGetD(p,"TARGET",0.0);
   double trigG = GvGetD(p,"CLOSE_TRIGGER_GAP",0.0);

   if(closeGap == 0.0) closeGap = fS1 - fS2;

   double openGap = GvGetD(p,"OPEN_FILL_GAP",0.0);
   double edgePts = (openGap > 0.0) ? (openGap - closeGap) : 0.0;
   string outcome = (openGap > 0.0)
                      ? ((closeGap < openGap - g_eps) ? "PROFIT" : "LOSS")
                      : "UNKNOWN";
   LogPair(p,"CAG_FINAL_REPORT",
           StringFormat("outcome=%s triggerGap=%s target=%s closeFillGap=%s openFillGap=%s edgePts=%s driftVsTrigger=%s driftVsTarget=%s",
                        outcome, F2(trigG), F2(trg), F2(closeGap), F2(openGap), F2(edgePts),
                        F2(closeGap - trigG), F2(closeGap - trg)));

   ClearPairState(p);
   SetClosingLock(p,false);
   LogPair(p,"SLOT_RELEASED");
}

double ReadTopLot()
{
   string s;
   double v=ReadEditNumber(g_prefix+"LOT_EDIT",s);
   WriteEditSanitized(g_prefix+"LOT_EDIT",s);
   if(v<=0) v=0.01;
   return v;
}

double ReadTopOAG()
{
   string s;
   double v=ReadEditNumber(g_prefix+"OAG_EDIT",s);
   WriteEditSanitized(g_prefix+"OAG_EDIT",s);
   return v;
}

double ReadTopCAG()
{
   string s;
   double v=ReadEditNumber(g_prefix+"CAG_EDIT",s);
   WriteEditSanitized(g_prefix+"CAG_EDIT",s);
   return v;
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id!=CHARTEVENT_OBJECT_CLICK) return;
   if(StringFind(sparam,g_prefix)!=0) return;

   RefreshPairRuntime();
   ResetBtn(sparam);

   if(sparam==g_prefix+"BTN_OPEN_SCHED")
   {
      double lot=ReadTopLot(), oag=ReadTopOAG(), cag=ReadTopCAG();
      int p=NextFreePairSlot();
      if(p<0){ LogMsg("No free slot."); return; }

      GvSetD(p,"TARGET",cag);
      ResetHitTimers(p);
      ResetOagDriftBlock(p);

      if(oag==0.0)
      {
         GvSetD(p,"STATUS",0.0);
         GvSetD(p,"OAG",0.0);
         GvSetD(p,"SCHED_LOT",0.0);
         LogPair(p,"OPEN_NOW",StringFormat("lot=%s cag=%s",F2(lot),F2(cag)));
         OpenPair(p,lot,0.0);
      }
      else
      {
         GvSetD(p,"OAG",oag);
         GvSetD(p,"SCHED_LOT",lot);
         GvSetD(p,"STATUS",2.0);
         LogPair(p,"SCHEDULE_SET",StringFormat("lot=%s oag=%s cag=%s confirm=%dms",F2(lot),F2(oag),F2(cag),InpOagConfirmMs));
      }
      return;
   }

   if(sparam==g_prefix+"BTN_CLOSE_ALL")
   {
      int batch[64]; int n=0;
      for(int p=1;p<=g_maxPairs;p++)
      {
         int st=GetPairStatus(p);
         if(st==PSTATUS_LIVE||st==PSTATUS_BROKEN||st==PSTATUS_CLOSING) batch[n++]=p;
      }
      if(n>0) ClosePairsInBatch(batch,n);
      return;
   }

   for(int r=0;r<g_visibleN;r++)
   {
      int p=g_visiblePairs[r];
      string upd=g_prefix+"BTN_UPDATE_"+IntegerToString(r);
      string cls=g_prefix+"BTN_CLOSE_"+IntegerToString(r);

      if(sparam==upd)
      {
         double cag=ReadTopCAG();
         GvSetD(p,"TARGET",cag);
         ResetCagHit(p);
         LogPair(p,"TARGET_UPDATED",StringFormat("newCAG=%s",F2(cag)));
         return;
      }

      if(sparam==cls)
      {
         int st=GetPairStatus(p);
         if(st==PSTATUS_SCHED)
         {
            CancelSchedule(p);
            LogPair(p,"ROW_CANCEL");
         }
         else if(st==PSTATUS_LIVE||st==PSTATUS_BROKEN||st==PSTATUS_CLOSING)
         {
            ClosePair(p, true); // manual=true: bypass gap/spread pre-send checks
         }
         return;
      }
   }
}