//+------------------------------------------------------------------+
//|                                       HarnessStage2_SelfTest.mq5 |
//|                                                                  |
//| Exhaustive test of every PURE function in HarnessStage2_Guards.mqh
//| -- the decision logic HarnessStage2_LivePilot.mq5 uses for its
//| account whitelist, live-mode, expiry, spread, margin, and budget
//| guards, plus the retry whitelist and the loss-only P&L semantics
//| R-011 depends on.
//|
//| WHAT THIS IS NOT: this file contains NO call to OrderSend,
//| OrderSendAsync, OrderCheck, CTrade, PositionOpen, AccountInfo*, or
//| SymbolInfoTick -- checkable by grep, the same guarantee
//| HarnessStage0_DryRun.mq5 makes. It cannot place an order, and it
//| cannot even READ a real account, by construction.
//|
//| WHAT THIS DOES NOT COVER: HarnessStage2_LivePilot.mq5's thin
//| wrapper functions (GuardSpread(), GuardMarginLevel(), etc.) that
//| gather real values via AccountInfoInteger/SymbolInfoTick/
//| OrderCalcMargin, and the real order-sending path itself
//| (ExecuteLeg(), CloseLegByTicket()). Those can only be tested by an
//| actual pair run against a broker -- this file tests everything
//| that CAN be verified for free, and is explicit about the boundary
//| rather than implying more coverage than it has.
//|
//| Quarantine: see measurement_harness/README.md. Never a source for
//| src/, the same way legacy/ never is.
//+------------------------------------------------------------------+
#property copyright "MT5 Spot-Futures Arbitrage -- research project"
#property version   "0.100"
#property strict

#include "HarnessStage2_Guards.mqh"

//====================================================================
// Result reporting -- same shape as HarnessStage0_DryRun.mq5's.
//====================================================================
#define RESULTS_FILE "arb_harness_stage2_selftest_results.csv"

int g_pass_count = 0;
int g_fail_count = 0;
int g_results_handle = INVALID_HANDLE;

void ReportResult(const string test_id, const string description, bool pass, const string notes)
  {
   if(pass) g_pass_count++; else g_fail_count++;
   string line = StringFormat("%s,%s,%s,%s", test_id, description, pass ? "PASS" : "FAIL", notes);
   Print(pass ? "PASS " : "!!!! FAIL ", test_id, " -- ", description,
         (StringLen(notes) > 0 ? (" (" + notes + ")") : ""));
   if(g_results_handle != INVALID_HANDLE)
     {
      FileWriteString(g_results_handle, line + "\r\n");
      FileFlush(g_results_handle);
     }
  }

//--------------------------------------------------------------------
// G1 -- retry whitelist. Every transient code true, a representative
// set of non-transient codes false, and one arbitrary/unknown value
// to confirm the default:false path (mirrors ShouldRetry()'s pattern
// from MMT_TradePannel_Pro_v284.cpp -- explicit allow-list, fail
// closed on anything not named).
//--------------------------------------------------------------------
void Test_G1_RetryWhitelist()
  {
   int transient[] = {TRADE_RETCODE_REQUOTE, TRADE_RETCODE_PRICE_CHANGED, TRADE_RETCODE_PRICE_OFF,
                      TRADE_RETCODE_TIMEOUT, TRADE_RETCODE_CONNECTION, TRADE_RETCODE_TOO_MANY_REQUESTS};
   bool all_transient_ok = true;
   for(int i = 0; i < ArraySize(transient); i++)
      if(!IsTransientRetcode(transient[i]))
         all_transient_ok = false;

   int nontransient[] = {TRADE_RETCODE_REJECT, TRADE_RETCODE_INVALID, TRADE_RETCODE_NO_MONEY,
                         TRADE_RETCODE_MARKET_CLOSED, TRADE_RETCODE_DONE, TRADE_RETCODE_DONE_PARTIAL,
                         TRADE_RETCODE_TRADE_DISABLED, TRADE_RETCODE_INVALID_VOLUME};
   bool all_nontransient_ok = true;
   for(int i = 0; i < ArraySize(nontransient); i++)
      if(IsTransientRetcode(nontransient[i]))
         all_nontransient_ok = false;

   bool unknown_ok = !IsTransientRetcode(999999); // arbitrary, unmapped -- must default to false

   bool pass = all_transient_ok && all_nontransient_ok && unknown_ok;
   ReportResult("G1", "Retry whitelist: transient=true, non-transient=false, unknown defaults false", pass,
                StringFormat("transient_ok=%s nontransient_ok=%s unknown_ok=%s",
                             all_transient_ok?"T":"F", all_nontransient_ok?"T":"F", unknown_ok?"T":"F"));
  }

void Test_G2_RetcodeDescriptionMapping()
  {
   bool known_ok = (RetcodeDescription(TRADE_RETCODE_DONE) == "DONE") &&
                   (RetcodeDescription(TRADE_RETCODE_REQUOTE) == "REQUOTE") &&
                   (RetcodeDescription(TRADE_RETCODE_NO_MONEY) == "NO_MONEY");
   string unmapped = RetcodeDescription(777777);
   bool unmapped_ok = (StringFind(unmapped, "UNMAPPED_777777") == 0);
   bool pass = known_ok && unmapped_ok;
   ReportResult("G2", "Retcode description: known codes map correctly, unknown codes flagged not guessed",
                pass, StringFormat("known_ok=%s unmapped='%s'", known_ok?"T":"F", unmapped));
  }

void Test_G3_MakeIdemKeyFormat()
  {
   string key = MakeIdemKey("RUN1", 3, 2, 1);
   bool pass = (key == "HRUN1-P3-L2-A1");
   ReportResult("G3", "Idempotency key format: H{run}-P{pair}-L{leg}-A{attempt}", pass, key);
  }

//--------------------------------------------------------------------
// G4 -- account whitelist guard.
//--------------------------------------------------------------------
void Test_G4_AccountWhitelist()
  {
   bool match       = GuardAccountWhitelistedLogic(8572793, 8572793);
   bool mismatch     = !GuardAccountWhitelistedLogic(8572793, 1234567);
   bool unset_fails  = !GuardAccountWhitelistedLogic(8572793, 0);   // no whitelist loaded
   bool negative_fails = !GuardAccountWhitelistedLogic(8572793, -1);
   bool pass = match && mismatch && unset_fails && negative_fails;
   ReportResult("G4", "Account whitelist: exact match passes, any mismatch or unset fails closed", pass,
                StringFormat("match=%s mismatch=%s unset=%s negative=%s",
                             match?"T":"F", mismatch?"T":"F", unset_fails?"T":"F", negative_fails?"T":"F"));
  }

//--------------------------------------------------------------------
// G5 -- live-account-only guard.
//--------------------------------------------------------------------
void Test_G5_AccountIsReal()
  {
   bool real_ok    = GuardAccountIsRealLogic(ACCOUNT_TRADE_MODE_REAL);
   bool demo_fails = !GuardAccountIsRealLogic(ACCOUNT_TRADE_MODE_DEMO);
   bool contest_fails = !GuardAccountIsRealLogic(ACCOUNT_TRADE_MODE_CONTEST);
   bool pass = real_ok && demo_fails && contest_fails;
   ReportResult("G5", "Live-account guard: only ACCOUNT_TRADE_MODE_REAL passes", pass,
                StringFormat("real=%s demo_fails=%s contest_fails=%s",
                             real_ok?"T":"F", demo_fails?"T":"F", contest_fails?"T":"F"));
  }

//--------------------------------------------------------------------
// G6 -- expiry hard-stop guard.
//--------------------------------------------------------------------
void Test_G6_ExpiryGuard()
  {
   datetime expiry = D'2026.11.25 00:00:00';
   long buffer_days = 14;
   datetime cutoff = (datetime)((long)expiry - buffer_days * 86400); // 2026.11.11

   bool well_before = GuardExpiryLogic(D'2026.09.17 00:00:00', expiry, buffer_days);   // far from cutoff
   bool well_after  = !GuardExpiryLogic(D'2026.11.20 00:00:00', expiry, buffer_days);  // past cutoff
   bool one_sec_before_cutoff = GuardExpiryLogic(cutoff - 1, expiry, buffer_days);
   bool exactly_at_cutoff     = !GuardExpiryLogic(cutoff, expiry, buffer_days); // now<cutoff is strict
   bool unparseable_fails = !GuardExpiryLogic(D'2026.09.17', 0, buffer_days);

   bool pass = well_before && well_after && one_sec_before_cutoff && exactly_at_cutoff && unparseable_fails;
   ReportResult("G6", "Expiry guard: allows well before cutoff, blocks at/after cutoff, fails closed if unparseable",
                pass, StringFormat("well_before=%s well_after=%s boundary_before=%s boundary_at=%s unparseable=%s",
                      well_before?"T":"F", well_after?"T":"F", one_sec_before_cutoff?"T":"F",
                      exactly_at_cutoff?"T":"F", unparseable_fails?"T":"F"));
  }

//--------------------------------------------------------------------
// G7 -- spread circuit breaker (D-H1: a breaker, not a filter).
//--------------------------------------------------------------------
void Test_G7_SpreadGuard()
  {
   bool normal_ok    = GuardSpreadLogic(0.24, 0.15, 3.00);   // measured typical spreads
   bool futures_wide = !GuardSpreadLogic(3.50, 0.15, 3.00);  // futures leg blows the breaker
   bool spot_wide    = !GuardSpreadLogic(0.24, 5.00, 3.00);  // spot leg blows the breaker
   bool both_wide    = !GuardSpreadLogic(4.00, 4.00, 3.00);
   bool boundary_at_max = !GuardSpreadLogic(3.00, 0.15, 3.00); // strictly less-than required
   bool pass = normal_ok && futures_wide && spot_wide && both_wide && boundary_at_max;
   ReportResult("G7", "Spread circuit breaker: normal passes, either leg wide blocks, boundary is strict",
                pass, StringFormat("normal=%s fut_wide=%s spot_wide=%s both=%s boundary=%s",
                      normal_ok?"T":"F", futures_wide?"T":"F", spot_wide?"T":"F", both_wide?"T":"F",
                      boundary_at_max?"T":"F"));
  }

//--------------------------------------------------------------------
// G8 -- margin level guard, including the projected_margin<=0 edge
// case (guard does not apply -- e.g. a broker that reports zero
// margin requirement for some reason should not block on a divide
// artifact).
//--------------------------------------------------------------------
void Test_G8_MarginLevelGuard()
  {
   double level;
   bool healthy = GuardMarginLevelLogic(1000, 0, 42.96, 86.71, 300, level);      // ~771% level, matches R-001 finding
   bool healthy_level_ok = (level > 700 && level < 800);

   bool unhealthy = !GuardMarginLevelLogic(1000, 850, 42.96, 86.71, 300, level); // margin already consumed
   bool zero_margin_edge = GuardMarginLevelLogic(1000, 0, 0, 0, 300, level);     // projected_margin<=0
   bool zero_margin_level_is_zero = (level == 0);

   bool pass = healthy && healthy_level_ok && unhealthy && zero_margin_edge && zero_margin_level_is_zero;
   ReportResult("G8", "Margin level guard: healthy passes with correct %, consumed margin blocks, zero-margin edge case handled",
                pass, StringFormat("healthy=%s level_ok=%s unhealthy_blocks=%s zero_edge=%s zero_level=%s",
                      healthy?"T":"F", healthy_level_ok?"T":"F", unhealthy?"T":"F",
                      zero_margin_edge?"T":"F", zero_margin_level_is_zero?"T":"F"));
  }

//--------------------------------------------------------------------
// G9 -- budget guard, every one of its six outcomes individually,
// plus the priority ordering (kill switch checked first).
//--------------------------------------------------------------------
void Test_G9_BudgetGuard()
  {
   ENUM_BUDGET_BLOCK ok        = GuardBudgetsLogic(false, 0, 1, 0, 50, 0, 15, 40, 0, 250);
   ENUM_BUDGET_BLOCK killsw    = GuardBudgetsLogic(true,  0, 1, 0, 50, 0, 15, 40, 0, 250);
   ENUM_BUDGET_BLOCK maxpairs  = GuardBudgetsLogic(false, 1, 1, 0, 50, 0, 15, 40, 0, 250);
   ENUM_BUDGET_BLOCK maxperday = GuardBudgetsLogic(false, 0, 300, 50, 50, 0, 15, 40, 0, 250);
   ENUM_BUDGET_BLOCK dailyloss = GuardBudgetsLogic(false, 0, 300, 0, 50, 30, 15, 40, 0, 250); // 30+15>40
   ENUM_BUDGET_BLOCK cumloss   = GuardBudgetsLogic(false, 0, 300, 0, 50, 0, 15, 40, 240, 250); // 240+15>250
   // Priority: kill switch AND max-pairs both true -- kill switch must win (checked first).
   ENUM_BUDGET_BLOCK priority  = GuardBudgetsLogic(true, 1, 1, 0, 50, 0, 15, 40, 0, 250);

   bool pass = (ok == BUDGET_OK) && (killsw == BUDGET_KILL_SWITCH) && (maxpairs == BUDGET_MAX_PAIRS) &&
               (maxperday == BUDGET_MAX_PAIRS_PER_DAY) && (dailyloss == BUDGET_DAILY_LOSS) &&
               (cumloss == BUDGET_CUMULATIVE_LOSS) && (priority == BUDGET_KILL_SWITCH);
   ReportResult("G9", "Budget guard: all six outcomes correct, kill switch has priority over other blocks",
                pass, StringFormat("ok=%s killsw=%s maxpairs=%s maxperday=%s dailyloss=%s cumloss=%s priority=%s",
                      BudgetBlockName(ok), BudgetBlockName(killsw), BudgetBlockName(maxpairs),
                      BudgetBlockName(maxperday), BudgetBlockName(dailyloss), BudgetBlockName(cumloss),
                      BudgetBlockName(priority)));
  }

//--------------------------------------------------------------------
// G10 -- loss-only P&L accumulation (R-011's core safety property:
// profits must never offset losses, to avoid a loss-recovery/
// martingale-adjacent pattern PROJECT_MANDATE.md prohibits).
//--------------------------------------------------------------------
void Test_G10_LossPortionAsymmetry()
  {
   bool profit_gives_zero   = (LossPortion(12.50) == 0.0);
   bool loss_gives_positive = (LossPortion(-8.25) == 8.25);
   bool zero_gives_zero     = (LossPortion(0.0) == 0.0);
   bool pass = profit_gives_zero && loss_gives_positive && zero_gives_zero;
   ReportResult("G10", "Loss-only accumulation: profit contributes 0, loss contributes its absolute value",
                pass, StringFormat("profit=%s loss=%s zero=%s",
                      profit_gives_zero?"T":"F", loss_gives_positive?"T":"F", zero_gives_zero?"T":"F"));
  }

void Test_G11_DealPnLArithmetic()
  {
   double pnl = DealPnLFromComponents(10.50, -0.60, -0.10); // profit, swap (usually 0 or negative), commission
   bool pass = (MathAbs(pnl - 9.80) < 0.00001);
   ReportResult("G11", "Deal P&L = profit + swap + commission, signs preserved", pass,
                StringFormat("result=%.5f expect=9.80", pnl));
  }

//--------------------------------------------------------------------
// G12 -- file round-trip. Not part of the .mqh (file I/O is real I/O,
// deliberately not abstracted into pure logic), but safe to test here
// since it never touches a broker -- only the local filesystem, and
// only files this project's own tooling reads.
//--------------------------------------------------------------------
void Test_G12_FileRoundTrip()
  {
   string test_file = "arb_harness_stage2_selftest_scratch.txt";
   int h = FileOpen(test_file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   bool wrote = (h != INVALID_HANDLE);
   if(wrote)
     {
      FileWriteString(h, "roundtrip_check=42\r\n");
      FileClose(h);
     }
   string read_back = "";
   int h2 = FileOpen(test_file, FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   bool reopened = (h2 != INVALID_HANDLE);
   if(reopened)
     {
      read_back = FileReadString(h2);
      FileClose(h2);
     }
   bool pass = wrote && reopened && (read_back == "roundtrip_check=42");
   ReportResult("G12", "File round-trip: write then read back matches exactly (no broker involved)",
                pass, "read_back='" + read_back + "'");
   FileDelete(test_file); // leave no trace
  }

//--------------------------------------------------------------------
// G13-G17 -- the fast-market/stale-quote guard (R-004), added
// 2026-09-18. G17 is the load-bearing one: it replays the ACTUAL
// recorded prices and timestamps from the 2026-09-11 13:30 UTC
// anomaly (docs/02_quant/13_BASIS_MODEL.md's own row-level table)
// through GuardFastMarketLogic() and proves it would have blocked
// that specific, real, historical event -- not a synthetic case
// invented to make the guard look good.
//--------------------------------------------------------------------
void Test_G13_TickVelocityArithmetic()
  {
   // The documented maximum-velocity tick in the entire 7-day dataset:
   // futures mid moved 34.25 points in 212ms, 2026-09-11 13:30:01.369
   // to 13:30:01.581 UTC (13_BASIS_MODEL.md). ~161.6 pts/sec expected.
   double v = TickVelocityPtsPerSec(4394.805, 0, 4360.555, 212);
   bool matches_documented_extreme = (v > 160.0 && v < 163.0);

   // Normal case: near the documented median (0.25 pts/sec) over a
   // typical ~500ms interval.
   double v_normal = TickVelocityPtsPerSec(4360.00, 0, 4360.13, 500);
   bool normal_reasonable = (v_normal > 0.2 && v_normal < 0.3);

   // Edge case: duplicate/out-of-order timestamp (dt<=0) must return
   // -1, never silently read as "zero movement, safe."
   bool dt_zero_is_sentinel = (TickVelocityPtsPerSec(4360.00, 100, 4360.00, 100) == -1);
   bool dt_negative_is_sentinel = (TickVelocityPtsPerSec(4360.00, 200, 4360.00, 100) == -1);

   bool pass = matches_documented_extreme && normal_reasonable && dt_zero_is_sentinel && dt_negative_is_sentinel;
   ReportResult("G13", "Tick velocity arithmetic matches the documented 161.6 pts/sec extreme; dt<=0 returns sentinel -1",
                pass, StringFormat("extreme_v=%.2f normal_v=%.4f dt_zero=%s dt_neg=%s",
                      v, v_normal, dt_zero_is_sentinel?"T":"F", dt_negative_is_sentinel?"T":"F"));
  }

void Test_G14_QuoteAgeArithmetic()
  {
   bool normal    = (QuoteAgeMs(10000, 9500) == 500);
   bool zero_age  = (QuoteAgeMs(10000, 10000) == 0);
   bool future_tick_floors_at_zero = (QuoteAgeMs(10000, 10500) == 0); // clock skew, not staleness -- not this guard's job
   bool pass = normal && zero_age && future_tick_floors_at_zero;
   ReportResult("G14", "Quote age arithmetic: normal case correct, a from-the-future tick floors at 0 rather than going negative",
                pass, StringFormat("normal=%s zero=%s future_floors=%s", normal?"T":"F", zero_age?"T":"F", future_tick_floors_at_zero?"T":"F"));
  }

void Test_G15_CrossLegSkewArithmetic()
  {
   // The R-004 anomaly row's own documented quote_skew_ms: 238.
   bool matches_documented = (CrossLegSkewMs(11218, 10980) == 238);
   bool symmetric = (CrossLegSkewMs(10980, 11218) == 238); // magnitude only, order-independent
   bool zero_skew = (CrossLegSkewMs(5000, 5000) == 0);
   bool pass = matches_documented && symmetric && zero_skew;
   ReportResult("G15", "Cross-leg skew arithmetic matches the R-004 row's documented 238ms, magnitude only",
                pass, StringFormat("matches=%s symmetric=%s zero=%s", matches_documented?"T":"F", symmetric?"T":"F", zero_skew?"T":"F"));
  }

void Test_G16_FastMarketGuardBoundaries()
  {
   // Candidate thresholds, matching HarnessStage2_LivePilot.mq5's own
   // input defaults -- kept in sync manually since this is a self-test,
   // not a shared constant (deliberate: a silent shared-constant drift
   // would be worse than a caught mismatch on the next review).
   double max_v = 20.0; long max_age = 2000; long max_skew = 400;

   bool normal_passes = GuardFastMarketLogic(0.30, 0.25, max_v, 100, 150, max_age, 50, max_skew);
   bool futures_velocity_blocks = !GuardFastMarketLogic(161.6, 0.25, max_v, 100, 150, max_age, 50, max_skew);
   bool spot_velocity_blocks    = !GuardFastMarketLogic(0.30, 161.6, max_v, 100, 150, max_age, 50, max_skew);
   bool stale_futures_blocks    = !GuardFastMarketLogic(0.30, 0.25, max_v, 5000, 150, max_age, 50, max_skew);
   bool wide_skew_blocks        = !GuardFastMarketLogic(0.30, 0.25, max_v, 100, 150, max_age, 500, max_skew);
   bool invalid_velocity_blocks = !GuardFastMarketLogic(-1, 0.25, max_v, 100, 150, max_age, 50, max_skew); // dt<=0 sentinel

   bool pass = normal_passes && futures_velocity_blocks && spot_velocity_blocks && stale_futures_blocks
               && wide_skew_blocks && invalid_velocity_blocks;
   ReportResult("G16", "Fast-market guard: normal passes; velocity/age/skew breach on either leg blocks; invalid velocity fails closed",
                pass, StringFormat("normal=%s fut_v=%s spot_v=%s stale=%s skew=%s invalid=%s",
                      normal_passes?"T":"F", futures_velocity_blocks?"T":"F", spot_velocity_blocks?"T":"F",
                      stale_futures_blocks?"T":"F", wide_skew_blocks?"T":"F", invalid_velocity_blocks?"T":"F"));
  }

// THE LOAD-BEARING TEST. Replays the actual recorded prices and
// timestamps from docs/02_quant/13_BASIS_MODEL.md's row-level table
// for the 2026-09-11 13:30 UTC anomaly -- the event both
// /arb-risk-review and /arb-hostile-review used to reject
// 35_1000_USD_LIVE_TEST_PLAN.md section 8.2. This is not a synthetic
// case chosen to flatter the guard; these are the real recorded rows.
void Test_G17_ReplayR004Anomaly()
  {
   // Row 13:30:01.369 UTC: fut_bid=4393.18 fut_ask=4396.43 -> mid=4394.805
   // Row 13:30:01.581 UTC: fut_bid=4360.33 fut_ask=4360.78 -> mid=4360.555
   // (the documented 161.6 pts/sec maximum-velocity tick of the whole dataset)
   double fut_mid_t1 = (4393.18 + 4396.43) / 2.0;
   double fut_mid_t2 = (4360.33 + 4360.78) / 2.0;
   double velocity_futures = TickVelocityPtsPerSec(fut_mid_t1, 0, fut_mid_t2, 212);

   // Spot over the same 212ms window (both legs were still moving together
   // at this point -- the freeze happens in the NEXT window, see below).
   double spot_mid_t1 = (4352.04 + 4352.39) / 2.0;
   double spot_mid_t2 = (4322.16 + 4334.31) / 2.0;
   double velocity_spot = TickVelocityPtsPerSec(spot_mid_t1, 0, spot_mid_t2, 212);

   // Candidate thresholds -- same as G16, matching the live file's inputs.
   double max_v = 20.0; long max_age = 2000; long max_skew = 400;

   // At the anomaly row itself (13:30:11.218), quote_skew_ms=238 as
   // documented directly in 13_BASIS_MODEL.md -- confirming the
   // project's own prior finding that skew ALONE (238 < candidate 400)
   // would NOT have blocked this event; quote age assumed fresh (0) for
   // this specific check, isolating the skew term.
   bool skew_alone_insufficient = GuardFastMarketLogic(0, 0, max_v, 0, 0, max_age, 238, max_skew);

   // The actual guard, with the real recorded velocity on both legs:
   // must block, via the velocity term, exactly as 13_BASIS_MODEL.md's
   // own conclusion states ("per-leg price velocity would have caught
   // it, with a large margin").
   bool guard_blocks_the_real_event = !GuardFastMarketLogic(velocity_futures, velocity_spot, max_v,
                                                              0, 0, max_age, 238, max_skew);

   bool pass = skew_alone_insufficient && guard_blocks_the_real_event;
   ReportResult("G17", "REPLAY of the real 2026-09-11 13:30 UTC anomaly: skew alone (238ms) would NOT have "
                "blocked it (confirms prior finding); velocity DOES block it",
                pass, StringFormat("velocity_futures=%.2f velocity_spot=%.2f skew_alone_insufficient=%s guard_blocks=%s",
                      velocity_futures, velocity_spot, skew_alone_insufficient?"T":"F", guard_blocks_the_real_event?"T":"F"));
  }

//====================================================================
// Entry point.
//====================================================================
int OnInit()
  {
   Print("=====================================================================");
   Print("HarnessStage2_SelfTest -- pure-logic self-test. No broker/account API");
   Print("is called anywhere in this file. Tests HarnessStage2_Guards.mqh only --");
   Print("HarnessStage2_LivePilot.mq5's real-API wrappers and its OrderSend/");
   Print("PositionSelectByTicket paths are NOT covered here. Only a real pair");
   Print("run can validate those.");
   Print("=====================================================================");

   g_results_handle = FileOpen(RESULTS_FILE, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(g_results_handle != INVALID_HANDLE)
      FileWriteString(g_results_handle, "test_id,description,result,notes\r\n");

   g_pass_count = 0; g_fail_count = 0;

   Test_G1_RetryWhitelist();
   Test_G2_RetcodeDescriptionMapping();
   Test_G3_MakeIdemKeyFormat();
   Test_G4_AccountWhitelist();
   Test_G5_AccountIsReal();
   Test_G6_ExpiryGuard();
   Test_G7_SpreadGuard();
   Test_G8_MarginLevelGuard();
   Test_G9_BudgetGuard();
   Test_G10_LossPortionAsymmetry();
   Test_G11_DealPnLArithmetic();
   Test_G12_FileRoundTrip();
   Test_G13_TickVelocityArithmetic();
   Test_G14_QuoteAgeArithmetic();
   Test_G15_CrossLegSkewArithmetic();
   Test_G16_FastMarketGuardBoundaries();
   Test_G17_ReplayR004Anomaly();

   Print("=====================================================================");
   Print(StringFormat("STAGE 2 GUARDS SELF-TEST RESULT: %d PASS, %d FAIL", g_pass_count, g_fail_count));
   if(g_fail_count > 0)
      Print("!!! At least one guard test FAILED. Do not trust HarnessStage2_LivePilot.mq5's guards. !!!");
   Print("Reminder: this covers pure logic only. It does NOT test OrderSend, CloseLegByTicket,");
   Print("or any real-API wrapper. A clean result here is necessary, not sufficient.");
   Print("Results: ", TerminalInfoString(TERMINAL_DATA_PATH), "\\MQL5\\Files\\", RESULTS_FILE);
   Print("=====================================================================");

   Comment(StringFormat("Stage 2 guards self-test: %d PASS / %d FAIL -- see Experts log", g_pass_count, g_fail_count));

   if(g_results_handle != INVALID_HANDLE)
      FileClose(g_results_handle);

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_results_handle != INVALID_HANDLE)
      FileClose(g_results_handle);
  }

// Required by the EA model; deliberately empty -- all testing happens
// once, synchronously, in OnInit.
void OnTick()
  {
  }
