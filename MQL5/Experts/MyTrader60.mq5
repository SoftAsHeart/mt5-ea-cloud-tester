//+------------------------------------------------------------------+
//|                                                   MyTrader60.mq5 |
//|     Regime-Gated Institutional Liquidity Sweep & FVG EA          |
//|     Version 6.00 - Walk-Forward Production Build (XAUUSDc - M1)  |
//+------------------------------------------------------------------+
#property copyright "My Trader 6.0 Institutional"
#property version   "6.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

//--- Input Parameters
input group "=== 1. Compounding, Daily Guardrails & Performance Gate ==="
input double   InpRiskPercent          = 1.25;     // Risk per Trade (% of Current Balance)
input double   InpMaxDailyLossPct      = 2.50;     // Hard Daily Drawdown Circuit Breaker (%)
input int      InpBaseMaxTradesPerDay  = 1;        // Base Daily Trade Limit
input int      InpMaxUnlockedTrades    = 2;        // Hard Cap When Performance Gate Unlocked
input bool     InpEnablePerfScaling    = true;     // Allow 2nd Trade When Rolling Stats Strong
input int      InpPerfLookbackTrades   = 12;       // Rolling Closed Trades Window
input double   InpMinWinRateToUnlock   = 58.0;     // Min Rolling Win Rate (%) to Unlock 2nd Trade
input double   InpMinPFToUnlock        = 1.35;     // Min Rolling Profit Factor to Unlock 2nd Trade
input int      InpCooldownMinutes      = 25;       // Min Minutes Between Trades
input int      InpMaxSpreadPoints      = 350;      // Max Allowed Spread in Points ($0.35 on Cent)
input ulong    InpMagicNumber          = 2026060;  // EA Magic Number

input group "=== 2. Killzone & Rollover Protection (Server Time) ==="
input int      InpAsianStartHour       = 0;        // Asian Range Start Hour
input int      InpAsianEndHour         = 6;        // Asian Range End Hour
input int      InpMinAsianRangePts     = 3200;     // Min Asian Range Width (3200 pts = $3.20 Gold)
input int      InpTradeStartHour       = 7;        // London Killzone Start Hour
input int      InpTradeEndHour         = 15;       // Last Hour for New Entries
input bool     InpSkipHour10Transition = true;     // Skip Hour 10 London-to-NY Transition Chop
input int      InpHardCloseHour        = 20;       // Hard Pre-Rollover Close Hour
input int      InpHardCloseMinute      = 45;       // Hard Pre-Rollover Close Minute

input group "=== 3. HTF Regime Filter (Prevents Fading Runaway Trends) ==="
input bool     InpUseHTFRegimeFilter   = true;     // Enable H1 EMA + ADX Counter-Trend Block
input int      InpH1_FastEMA           = 50;       // H1 Fast Trend EMA Period
input int      InpH1_SlowEMA           = 200;      // H1 Slow Macro EMA Period
input int      InpH1_ADX_Period        = 14;       // H1 ADX Period
input double   InpH1_MaxCounterTrendADX= 24.0;     // Max H1 ADX Allowed to Fade Against H1 Trend

input group "=== 4. Adaptive Sweep & Displacement Engine ==="
input bool     InpEnableIntradayPools  = true;     // Sweep Fresh M15 Swing Pools When Unlocked
input int      InpSwingLookbackM15     = 16;       // M15 Bars for Rolling Intraday Liquidity Pools
input double   InpMaxPreSweepKER       = 0.46;     // Max Pre-Sweep KER (Anti-Chop Filter)
input int      InpSweepMinPoints       = 250;      // Min Sweep Beyond Liquidity Pool (Points)
input int      InpSweepMaxPoints       = 14000;    // Max Sweep Overshoot Allowed ($14.00)
input int      InpSweepMaxBars         = 45;       // Max M1 Bars After Sweep to Trigger Entry
input double   InpBaseDisplacementATR  = 0.85;     // Normal-Regime Displacement Candle (x M1 ATR)
input double   InpHighVolDispATR       = 1.25;     // High-Vol Regime Displacement Candle (x M1 ATR)
input int      InpHighVolD1ATRPoints   = 45000;    // Daily ATR Threshold for High-Vol Mode ($45)
input double   InpMinBodyRatio         = 0.52;     // Min Displacement Body-to-Range Ratio
input double   InpMinFVG_ATR_Mult      = 0.12;     // Min Micro-FVG Gap Size (x M1 ATR)

input group "=== 5. MFE-Calibrated SL, Early Shield & M15 Runner Trail ==="
input double   InpSL_ATR_Mult          = 1.15;     // Stop Loss Buffer Beyond Sweep Extreme (x M1 ATR)
input int      InpMinSLPoints          = 2800;     // Minimum Structural SL Floor (2800 pts = $2.80)
input int      InpMaxSLPoints          = 12000;    // Maximum Structural SL Cap (12000 pts = $12.00)
input double   InpBreakevenRR          = 0.50;     // Move SL to +0.08R at +0.50R (MFE Shield)
input double   InpPartialCloseRR       = 1.15;     // Bank 50% Profit at +1.15R
input double   InpRunnerLockRR         = 0.55;     // Lock Runner SL at +0.55R After Partial Bank
input double   InpFinalTargetRR        = 3.40;     // Runner Take Profit R:R Target
input double   InpTrail_M15_ATR_Mult   = 1.65;     // Runner Trailing Stop Multiplier (x M15 ATR)

//--- Indicator Handles
int hATR_M1   = INVALID_HANDLE;
int hATR_M15  = INVALID_HANDLE;
int hATR_D1   = INVALID_HANDLE;
int hEMA_Fast = INVALID_HANDLE;
int hEMA_Slow = INVALID_HANDLE;
int hADX_H1   = INVALID_HANDLE;

//--- Session & Liquidity Pool State
double   g_AsianHigh        = 0.0, g_AsianLow        = 0.0;
bool     g_AsianReady       = false;
bool     g_AsianHighSwept   = false;
bool     g_AsianLowSwept    = false;
double   g_LastTradedHigh   = 0.0;
double   g_LastTradedLow    = 0.0;

datetime g_SweepHighTime    = 0;
double   g_SweepHighExtreme = 0.0;

datetime g_SweepLowTime     = 0;
double   g_SweepLowExtreme  = 0.0;

datetime g_CurrentDay       = 0;
double   g_DayStartBalance  = 0.0;
int      g_TradesToday      = 0;
datetime g_LastTradeTime    = 0;
datetime g_LastBarTime      = 0;

//+------------------------------------------------------------------+
//| Safe Single-Value Indicator Buffer Reader                        |
//+------------------------------------------------------------------+
double GetBufferVal(int handle, int bufferNum, int shift)
{
   double tmp[];
   ArraySetAsSeries(tmp, true);
   if(CopyBuffer(handle, bufferNum, shift, 1, tmp) < 1)
      return(0.0);
   return(tmp[0]);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!symInfo.Name(_Symbol)) return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   hATR_M1   = iATR(_Symbol, PERIOD_M1, 14);
   hATR_M15  = iATR(_Symbol, PERIOD_M15, 14);
   hATR_D1   = iATR(_Symbol, PERIOD_D1, 14);
   hEMA_Fast = iMA(_Symbol, PERIOD_H1, InpH1_FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow = iMA(_Symbol, PERIOD_H1, InpH1_SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hADX_H1   = iADX(_Symbol, PERIOD_H1, InpH1_ADX_Period);

   if(hATR_M1 == INVALID_HANDLE || hATR_M15 == INVALID_HANDLE || hATR_D1 == INVALID_HANDLE ||
      hEMA_Fast == INVALID_HANDLE || hEMA_Slow == INVALID_HANDLE || hADX_H1 == INVALID_HANDLE)
      return(INIT_FAILED);

   g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hATR_M1);
   IndicatorRelease(hATR_M15);
   IndicatorRelease(hATR_D1);
   IndicatorRelease(hEMA_Fast);
   IndicatorRelease(hEMA_Slow);
   IndicatorRelease(hADX_H1);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!symInfo.RefreshRates()) return;

   MqlDateTime dt;
   TimeCurrent(dt);

   datetime dayStart = StructToTime(dt) - (dt.hour * 3600 + dt.min * 60 + dt.sec);
   if(dayStart != g_CurrentDay)
   {
      g_CurrentDay       = dayStart;
      g_DayStartBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
      g_TradesToday      = 0;
      g_AsianHigh        = 0.0;
      g_AsianLow         = 0.0;
      g_AsianReady       = false;
      g_AsianHighSwept   = false;
      g_AsianLowSwept    = false;
      g_LastTradedHigh   = 0.0;
      g_LastTradedLow    = 0.0;
      g_SweepHighTime    = 0;
      g_SweepHighExtreme = 0.0;
      g_SweepLowTime     = 0;
      g_SweepLowExtreme  = 0.0;
   }

   ManageOpenPositions(dt);

   datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
   if(barTime == g_LastBarTime) return;
   g_LastBarTime = barTime;

   //--- Build Asian Session Liquidity Range (00:00 - 06:00)
   if(dt.hour >= InpAsianStartHour && dt.hour < InpAsianEndHour)
   {
      double h1 = iHigh(_Symbol, PERIOD_M1, 1);
      double l1 = iLow(_Symbol, PERIOD_M1, 1);
      if(g_AsianHigh == 0.0 || h1 > g_AsianHigh) g_AsianHigh = h1;
      if(g_AsianLow  == 0.0 || l1 < g_AsianLow)  g_AsianLow  = l1;
      return;
   }

   if(dt.hour >= InpAsianEndHour && g_AsianHigh > 0.0 && g_AsianLow > 0.0)
   {
      double asianWidthPts = (g_AsianHigh - g_AsianLow) / symInfo.Point();
      if(asianWidthPts >= InpMinAsianRangePts)
         g_AsianReady = true;
   }

   if(!g_AsianReady) return;

   //--- Killzone, Transition Hour & Daily Risk Guardrails
   if(dt.hour < InpTradeStartHour || dt.hour >= InpTradeEndHour) return;
   if(InpSkipHour10Transition && dt.hour == 10) return;
   if(HasOpenPosition()) return;
   if(g_LastTradeTime > 0 && (TimeCurrent() - g_LastTradeTime) < InpCooldownMinutes * 60) return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyLossPct = ((g_DayStartBalance - equity) / g_DayStartBalance) * 100.0;
   if(dailyLossPct >= InpMaxDailyLossPct) return;

   //--- Strict Performance Gate (AND logic + Hard Daily Cap)
   bool perfUnlocked = (InpEnablePerfScaling && IsPerformanceStrictlyGood());
int allowedTrades = perfUnlocked ? InpMaxUnlockedTrades : InpBaseMaxTradesPerDay;
if(g_TradesToday >= allowedTrades)
return;
if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints) return;
CheckRegimeFilteredSweepSetup(perfUnlocked);
}
//+------------------------------------------------------------------+
//| Strict Rolling Performance Evaluator (AND Logic, No Same-Day Cheat)|
//+------------------------------------------------------------------+
bool IsPerformanceStrictlyGood()
{
if(!HistorySelect(0, TimeCurrent()))
return(false);
int totalDeals     = HistoryDealsTotal();
int counted        = 0;
int wins           = 0;
double grossProfit = 0.0;
double grossLoss   = 0.0;
for(int i = totalDeals - 1; i >= 0 && counted < InpPerfLookbackTrades; i--)
{
ulong ticket = HistoryDealGetTicket(i);
if(ticket == 0) continue;
if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)InpMagicNumber) continue;
long entryType = HistoryDealGetInteger(ticket, DEAL_ENTRY);
if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_INOUT) continue;
double netProfit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
+ HistoryDealGetDouble(ticket, DEAL_SWAP)
+ HistoryDealGetDouble(ticket, DEAL_COMMISSION);
counted++;
if(netProfit > 0.0)
{
wins++;
grossProfit += netProfit;
}
else if(netProfit < 0.0)
{
grossLoss += MathAbs(netProfit);
}
}
if(counted < InpPerfLookbackTrades)
return(false);
double winRate      = ((double)wins / (double)counted) * 100.0;
double profitFactor = (grossLoss > 0.0) ? (grossProfit / grossLoss) : (grossProfit > 0.0 ? 99.0 : 0.0);
return (winRate >= InpMinWinRateToUnlock && profitFactor >= InpMinPFToUnlock);
}
//+------------------------------------------------------------------+
//| Higher-Timeframe Regime Filter (H1 EMA Alignment + ADX Strength) |
//+------------------------------------------------------------------+
bool IsDirectionAllowedByRegime(bool isBuy)
{
if(!InpUseHTFRegimeFilter)
return(true);
double emaFast = GetBufferVal(hEMA_Fast, 0, 1);
double emaSlow = GetBufferVal(hEMA_Slow, 0, 1);
double adxH1   = GetBufferVal(hADX_H1, 0, 1);
double h1Close = iClose(_Symbol, PERIOD_H1, 1);
if(emaFast <= 0.0 || emaSlow <= 0.0 || adxH1 <= 0.0)
return(true);
bool strongH1Uptrend   = (emaFast > emaSlow && h1Close > emaFast && adxH1 > InpH1_MaxCounterTrendADX);
bool strongH1Downtrend = (emaFast < emaSlow && h1Close < emaFast && adxH1 > InpH1_MaxCounterTrendADX);
// Block fading against a strong H1 directional trend
if(!isBuy && strongH1Uptrend)
return(false);
if(isBuy && strongH1Downtrend)
return(false);
return(true);
}
//+------------------------------------------------------------------+
//| Regime-Filtered Liquidity Sweep + 2-Bar Displacement & FVG       |
//+------------------------------------------------------------------+
void CheckRegimeFilteredSweepSetup(bool perfUnlocked)
{
double point     = symInfo.Point();
double sweepDist = InpSweepMinPoints * point;
double maxSweep  = InpSweepMaxPoints * point;
double o1 = iOpen(_Symbol, PERIOD_M1, 1),  c1 = iClose(_Symbol, PERIOD_M1, 1);
double h1 = iHigh(_Symbol, PERIOD_M1, 1),  l1 = iLow(_Symbol, PERIOD_M1, 1);
datetime t1 = iTime(_Symbol, PERIOD_M1, 1);
double o2 = iOpen(_Symbol, PERIOD_M1, 2),  c2 = iClose(_Symbol, PERIOD_M1, 2);
double h2 = iHigh(_Symbol, PERIOD_M1, 2),  l2 = iLow(_Symbol, PERIOD_M1, 2);
double h3 = iHigh(_Symbol, PERIOD_M1, 3),  l3 = iLow(_Symbol, PERIOD_M1, 3);
double recentHigh = MathMax(h1, h2);
double recentLow  = MathMin(l1, l2);
//--- Primary Asian Pool, then Fresh M15 Swing Pool When Unlocked
double targetHighPool = g_AsianHigh;
double targetLowPool  = g_AsianLow;
if(g_AsianHighSwept)
{
if(!InpEnableIntradayPools || !perfUnlocked)
targetHighPool = 0.0;
else
{
int highestIdx = iHighest(_Symbol, PERIOD_M15, MODE_HIGH, InpSwingLookbackM15, 3);
if(highestIdx > 0)
{
double swingH = iHigh(_Symbol, PERIOD_M15, highestIdx);
targetHighPool = (MathAbs(swingH - g_LastTradedHigh) > 1000 * point) ? swingH : 0.0;
}
}
}
if(g_AsianLowSwept)
{
if(!InpEnableIntradayPools || !perfUnlocked)
targetLowPool = 0.0;
else
{
int lowestIdx = iLowest(_Symbol, PERIOD_M15, MODE_LOW, InpSwingLookbackM15, 3);
if(lowestIdx > 0)
{
double swingL = iLow(_Symbol, PERIOD_M15, lowestIdx);
targetLowPool = (MathAbs(swingL - g_LastTradedLow) > 1000 * point) ? swingL : 0.0;
}
}
}
//--- Record Sweep Extremes
if(targetHighPool > 0.0 && recentHigh >= targetHighPool + sweepDist && recentHigh <= targetHighPool + maxSweep)
{
if(g_SweepHighTime == 0 || (t1 - g_SweepHighTime) > InpSweepMaxBars * 60 || recentHigh > g_SweepHighExtreme)
{
g_SweepHighTime    = t1;
g_SweepHighExtreme = recentHigh;
}
}
if(targetLowPool > 0.0 && recentLow <= targetLowPool - sweepDist && recentLow >= targetLowPool - maxSweep)
{
if(g_SweepLowTime == 0 || (t1 - g_SweepLowTime) > InpSweepMaxBars * 60 || recentLow < g_SweepLowExtreme)
{
g_SweepLowTime    = t1;
g_SweepLowExtreme = recentLow;
}
}
int maxSweepSeconds = InpSweepMaxBars * 60;
bool freshHighSweep = (targetHighPool > 0.0 && g_SweepHighTime > 0 && (t1 - g_SweepHighTime) <= maxSweepSeconds);
bool freshLowSweep  = (targetLowPool  > 0.0 && g_SweepLowTime  > 0 && (t1 - g_SweepLowTime)  <= maxSweepSeconds);
if(!freshHighSweep && !freshLowSweep) return;
if(CalculatePreSweepKER(14, 3) > InpMaxPreSweepKER) return;
double atrM1 = GetBufferVal(hATR_M1, 0, 1);
if(atrM1 <= 0.0) return;
double reqDispMult = InpBaseDisplacementATR;
double atrD1 = GetBufferVal(hATR_D1, 0, 1);
if(atrD1 > 0.0 && (atrD1 / point) >= InpHighVolD1ATRPoints)
reqDispMult = InpHighVolDispATR;
double range1 = h1 - l1;
double range2 = h2 - l2;
if(range1 <= 0.0 || range2 <= 0.0) return;
//--- 2-Bar Displacement Impulse (Avoids Late Chasing at Bottom of Move)
double impulseRange = MathMax(range1, range2);
if(impulseRange < atrM1 * reqDispMult) return;
double bodyRatio1 = MathAbs(c1 - o1) / range1;
double bodyRatio2 = MathAbs(c2 - o2) / range2;
if(MathMax(bodyRatio1, bodyRatio2) < InpMinBodyRatio) return;
double minFVGSize = atrM1 * InpMinFVG_ATR_Mult;
double minSLDist  = InpMinSLPoints * point;
double maxSLDist  = InpMaxSLPoints * point;
//--- 1. Bearish Sweep Reversal (Regime-Checked)
bool bearishClose    = ((c1 - l1) / range1) <= 0.35;
bool validBearishFVG = ((l3 - h1) >= minFVGSize) || ((l2 - MathMin(l1, c1)) >= minFVGSize && c2 < o2);
if(freshHighSweep && IsDirectionAllowedByRegime(false) &&
c1 < o1 && bearishClose && c1 < targetHighPool && validBearishFVG)
{
double entry  = symInfo.Bid();
double rawSL  = g_SweepHighExtreme + (atrM1 * InpSL_ATR_Mult);
double slDist = MathMax(rawSL - entry, minSLDist);
if(slDist <= maxSLDist)
{
double sl   = NormalizeDouble(entry + slDist, symInfo.Digits());
double tp   = NormalizeDouble(entry - (slDist * InpFinalTargetRR), symInfo.Digits());
double lots = CalculateLotSize(slDist);
if(lots >= symInfo.LotsMin() && trade.Sell(lots, _Symbol, entry, sl, tp, "MT60_SweepSell"))
{
g_TradesToday++;
g_LastTradeTime    = TimeCurrent();
g_AsianHighSwept   = true;
g_LastTradedHigh   = targetHighPool;
g_SweepHighTime    = 0;
g_SweepHighExtreme = 0.0;
}
}
}
//--- 2. Bullish Sweep Reversal (Regime-Checked)
bool bullishClose    = ((h1 - c1) / range1) <= 0.35;
bool validBullishFVG = ((l1 - h3) >= minFVGSize) || ((MathMax(h1, c1) - h2) >= minFVGSize && c2 > o2);
if(freshLowSweep && IsDirectionAllowedByRegime(true) &&
c1 > o1 && bullishClose && c1 > targetLowPool && validBullishFVG)
{
double entry  = symInfo.Ask();
double rawSL  = g_SweepLowExtreme - (atrM1 * InpSL_ATR_Mult);
double slDist = MathMax(entry - rawSL, minSLDist);
if(slDist <= maxSLDist)
{
double sl   = NormalizeDouble(entry - slDist, symInfo.Digits());
double tp   = NormalizeDouble(entry + (slDist * InpFinalTargetRR), symInfo.Digits());
double lots = CalculateLotSize(slDist);
if(lots >= symInfo.LotsMin() && trade.Buy(lots, _Symbol, entry, sl, tp, "MT60_SweepBuy"))
{
g_TradesToday++;
g_LastTradeTime   = TimeCurrent();
g_AsianLowSwept   = true;
g_LastTradedLow   = targetLowPool;
g_SweepLowTime    = 0;
g_SweepLowExtreme = 0.0;
}
}
}
}
//+------------------------------------------------------------------+
//| Manage Open Positions: +0.50R MFE Shield, +1.15R Bank, M15 Trail |
//+------------------------------------------------------------------+
void ManageOpenPositions(const MqlDateTime &dt)
{
double atrM15 = GetBufferVal(hATR_M15, 0, 1);
for(int i = PositionsTotal() - 1; i >= 0; i--)
{
if(!posInfo.SelectByIndex(i)) continue;
if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;
ulong  ticket  = posInfo.Ticket();
double openPrc = posInfo.PriceOpen();
double sl      = posInfo.StopLoss();
double tp      = posInfo.TakeProfit();
double vol     = posInfo.Volume();
long   posType = posInfo.PositionType();
if(dt.hour > InpHardCloseHour || (dt.hour == InpHardCloseHour && dt.min >= InpHardCloseMinute))
{
trade.PositionClose(ticket);
continue;
}
double initialRisk = (tp > 0.0 && InpFinalTargetRR > 0.0) ? MathAbs(tp - openPrc) / InpFinalTargetRR : 0.0;
if(initialRisk <= 0.0) continue;
if(posType == POSITION_TYPE_BUY)
{
double bid        = symInfo.Bid();
double profitDist = bid - openPrc;
double lockSL     = NormalizeDouble(openPrc + (initialRisk * InpRunnerLockRR), symInfo.Digits());
double beSL       = NormalizeDouble(openPrc + (initialRisk * 0.08), symInfo.Digits());
// Priority 1: Partial Close 50% at +1.15R & Lock +0.55R
if(profitDist >= initialRisk * InpPartialCloseRR && sl < lockSL)
{
double closeVol = NormalizeLot(vol * 0.5);
if(closeVol >= symInfo.LotsMin() && (vol - closeVol) >= symInfo.LotsMin())
trade.PositionClosePartial(ticket, closeVol);
trade.PositionModify(ticket, lockSL, tp);
}
// Priority 2: Early MFE Shield at +0.50R
else if(profitDist >= initialRisk * InpBreakevenRR && sl < beSL)
{
trade.PositionModify(ticket, beSL, tp);
}
// Priority 3: M15 ATR Runner Trail (Avoids M5 Choking)
else if(sl >= lockSL && atrM15 > 0.0)
{
double newSL = NormalizeDouble(bid - (atrM15 * InpTrail_M15_ATR_Mult), symInfo.Digits());
if(newSL > sl + 80 * symInfo.Point())
trade.PositionModify(ticket, newSL, tp);
}
}
else if(posType == POSITION_TYPE_SELL)
{
double ask        = symInfo.Ask();
double profitDist = openPrc - ask;
double lockSL     = NormalizeDouble(openPrc - (initialRisk * InpRunnerLockRR), symInfo.Digits());
double beSL       = NormalizeDouble(openPrc - (initialRisk * 0.08), symInfo.Digits());
// Priority 1: Partial Close 50% at +1.15R & Lock +0.55R
if(profitDist >= initialRisk * InpPartialCloseRR && (sl > lockSL || sl == 0.0))
{
double closeVol = NormalizeLot(vol * 0.5);
if(closeVol >= symInfo.LotsMin() && (vol - closeVol) >= symInfo.LotsMin())
trade.PositionClosePartial(ticket, closeVol);
trade.PositionModify(ticket, lockSL, tp);
}
// Priority 2: Early MFE Shield at +0.50R
else if(profitDist >= initialRisk * InpBreakevenRR && (sl > beSL || sl == 0.0))
{
trade.PositionModify(ticket, beSL, tp);
}
// Priority 3: M15 ATR Runner Trail
else if(sl <= lockSL && sl > 0.0 && atrM15 > 0.0)
{
double newSL = NormalizeDouble(ask + (atrM15 * InpTrail_M15_ATR_Mult), symInfo.Digits());
if(newSL < sl - 80 * symInfo.Point())
trade.PositionModify(ticket, newSL, tp);
}
}
}
}
//+------------------------------------------------------------------+
//| Helper Functions                                                 |
//+------------------------------------------------------------------+
double CalculatePreSweepKER(int period, int startShift)
{
double cNow  = iClose(_Symbol, PERIOD_M1, startShift);
double cPast = iClose(_Symbol, PERIOD_M1, startShift + period);
double netChange = MathAbs(cNow - cPast);
double sumVolatility = 0.0;
for(int i = startShift; i < startShift + period; i++)
sumVolatility += MathAbs(iClose(_Symbol, PERIOD_M1, i) - iClose(_Symbol, PERIOD_M1, i + 1));
if(sumVolatility <= 0.0) return(1.0);
return(netChange / sumVolatility);
}
bool HasOpenPosition()
{
for(int i = PositionsTotal() - 1; i >= 0; i--)
{
if(posInfo.SelectByIndex(i))
{
if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
return(true);
}
}
return(false);
}
double CalculateLotSize(double slDistance)
{
double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
double riskCash = balance * (InpRiskPercent / 100.0);
double tickVal  = symInfo.TickValue();
double tickSize = symInfo.TickSize();
if(tickVal <= 0.0 || tickSize <= 0.0 || slDistance <= 0.0) return(symInfo.LotsMin());
double lossPerLot = (slDistance / tickSize) * tickVal;
if(lossPerLot <= 0.0) return(symInfo.LotsMin());
return(NormalizeLot(riskCash / lossPerLot));
}
double NormalizeLot(double lots)
{
double minLot = symInfo.LotsMin(), maxLot = symInfo.LotsMax(), stepLot = symInfo.LotsStep();
lots = MathFloor(lots / stepLot) * stepLot;
if(lots < minLot) lots = minLot;
if(lots > maxLot) lots = maxLot;
return(NormalizeDouble(lots, 2));
}
double OnTester()
{
double profit  = TesterStatistics(STAT_PROFIT);
double pf      = TesterStatistics(STAT_PROFIT_FACTOR);
double rf      = TesterStatistics(STAT_RECOVERY_FACTOR);
double ddPct   = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
double trades  = TesterStatistics(STAT_TRADES);
double wins    = TesterStatistics(STAT_PROFIT_TRADES);
if(profit <= 0.0 || trades < 85 || ddPct > 14.0 || pf < 1.15)
return(0.0);
double winRate = wins / trades;
return(pf * rf * winRate * MathSqrt(trades));
}
//+------------------------------------------------------------------+