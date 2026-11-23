//+------------------------------------------------------------------+
//|                                        GoldApexInstitutional.mq5 |
//|   ATR-Adaptive Asian Compression, Judas Sweep & Trend Runner EA  |
//|   Version 3.00 - Built for Exness XAUUSDc (M15 Execution / H1)   |
//+------------------------------------------------------------------+
#property copyright "Gold Apex Institutional 3.0"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

//--- 1. Risk & Account Protection
input group "=== 1. Risk & Account Protection ==="
input double   InpRiskPercent          = 1.25;     // Risk Per Trade (% of Balance)
input double   InpMaxDailyLossPct      = 3.5;      // Daily Loss Circuit Breaker (%)
input int      InpMaxTradesPerDay      = 3;        // Max Trades Per Day
input int      InpMaxSpreadATR_Pct     = 18;       // Max Spread (% of M15 ATR)
input ulong    InpMagicNumber          = 2026999;  // Unique Magic Number

//--- 2. Session & Kill-Zone Timing (Server Time)
input group "=== 2. Session & Kill-Zone Timing ==="
input int      InpAsiaStartHour        = 0;        // Asian Range Start Hour
input int      InpAsiaEndHour          = 6;        // Asian Range End Hour (Inclusive)
input int      InpTradeStartHour       = 7;        // London Kill-Zone Start Hour
input int      InpTradeEndHour         = 15;       // Last Entry Hour (15 = Cutoff 15:59)
input int      InpHardCloseHour        = 20;       // Pre-Rollover Hard Close Hour
input int      InpHardCloseMinute      = 45;       // Pre-Rollover Hard Close Minute

//--- 3. ATR-Self-Calibrating Compression & Engines
input group "=== 3. ATR-Adaptive Regime & Setup Engines ==="
input bool     InpEnableJudasSweep     = true;     // Enable Engine A: Asian Liquidity Sweep
input bool     InpEnableCleanBreakout  = true;     // Enable Engine B: Tight-Box Breakout
input int      InpH1_EMA_Period        = 50;       // H1 Institutional Trend Filter EMA
input double   InpMinAsiaD1_ATR        = 0.14;     // Min Asian Range (Fraction of D1 ATR)
input double   InpMaxAsiaD1_ATR        = 0.65;     // Max Asian Range (Fraction of D1 ATR)
input double   InpMaxBreakoutD1_ATR    = 0.42;     // Max Asian Range for Clean Breakout
input double   InpMinSweepATR          = 0.10;     // Min Wick Sweep Beyond Asia (x M15 ATR)
input double   InpMaxSweepATR          = 0.85;     // Max Overshoot Beyond Asia (x M15 ATR)
input double   InpMinADX_Breakout      = 22.0;     // Min M15 ADX(14) for Breakout Mode
input double   InpMinVolMult           = 1.15;     // Min Volume Multiplier vs 20-Bar Avg

//--- 4. ATR Stop-Loss, Partial Bank & Runner Trail
input group "=== 4. ATR Stops, Partial Banking & Runner ==="
input double   InpSL_ATR_Mult          = 0.65;     // Stop Buffer Beyond Structure (x M15 ATR)
input double   InpMinSL_ATR_Mult       = 1.10;     // Minimum Stop Floor (x M15 ATR)
input double   InpBELockRR             = 1.00;     // Move SL to Breakeven at +R
input double   InpPartialCloseRR       = 1.50;     // Bank 50% Partial Profit at +R
input double   InpFinalTargetRR        = 3.20;     // Runner Take-Profit Target (+R)
input double   InpTrail_ATR_Mult       = 1.35;     // Runner Chandelier Trail (x M15 ATR)

//--- Indicator Handles
int hATR_M15 = INVALID_HANDLE;
int hATR_D1  = INVALID_HANDLE;
int hADX_M15 = INVALID_HANDLE;
int hEMA_H1  = INVALID_HANDLE;

//--- Daily State
datetime g_CurrentDay      = 0;
double   g_DayStartBalance = 0.0;
int      g_TradesToday     = 0;
datetime g_LastM15Bar      = 0;

double   g_AsiaHigh        = 0.0;
double   g_AsiaLow         = 0.0;
bool     g_AsiaLocked      = false;
bool     g_HighSweptUsed   = false;
bool     g_LowSweptUsed    = false;

//--- Position Tracking Arrays
ulong    g_PartialDone[];
ulong    g_RiskTickets[];
double   g_RiskValues[];

//+------------------------------------------------------------------+
//| Safe Single-Value Indicator Reader                               |
//+------------------------------------------------------------------+
double GetInd(int handle, int buffer, int shift)
{
   double buf[1];
   if(CopyBuffer(handle, buffer, shift, 1, buf) < 1)
      return(0.0);
   return(buf[0]);
}

//+------------------------------------------------------------------+
//| Ticket Tracking Helpers                                          |
//+------------------------------------------------------------------+
bool IsPartialCompleted(ulong ticket)
{
   for(int i = ArraySize(g_PartialDone) - 1; i >= 0; i--)
      if(g_PartialDone[i] == ticket) return(true);
   return(false);
}

void SetPartialCompleted(ulong ticket)
{
   if(IsPartialCompleted(ticket)) return;
   int n = ArraySize(g_PartialDone);
   ArrayResize(g_PartialDone, n + 1);
   g_PartialDone[n] = ticket;
}

void StoreInitialRisk(ulong ticket, double riskDist)
{
   for(int i = ArraySize(g_RiskTickets) - 1; i >= 0; i--)
   {
      if(g_RiskTickets[i] == ticket)
      {
         g_RiskValues[i] = riskDist;
         return;
      }
   }
   int n = ArraySize(g_RiskTickets);
   ArrayResize(g_RiskTickets, n + 1);
   ArrayResize(g_RiskValues, n + 1);
   g_RiskTickets[n] = ticket;
   g_RiskValues[n]  = riskDist;
}

double FetchInitialRisk(ulong ticket, double fallback)
{
   for(int i = ArraySize(g_RiskTickets) - 1; i >= 0; i--)
      if(g_RiskTickets[i] == ticket && g_RiskValues[i] > 0.0)
         return(g_RiskValues[i]);
   return(fallback);
}

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!symInfo.Name(_Symbol))
      return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   hATR_M15 = iATR(_Symbol, PERIOD_M15, 14);
   hATR_D1  = iATR(_Symbol, PERIOD_D1, 14);
   hADX_M15 = iADX(_Symbol, PERIOD_M15, 14);
   hEMA_H1  = iMA(_Symbol, PERIOD_H1, InpH1_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(hATR_M15 == INVALID_HANDLE || hATR_D1 == INVALID_HANDLE ||
      hADX_M15 == INVALID_HANDLE || hEMA_H1 == INVALID_HANDLE)
      return(INIT_FAILED);

   g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(hATR_M15 != INVALID_HANDLE) IndicatorRelease(hATR_M15);
   if(hATR_D1  != INVALID_HANDLE) IndicatorRelease(hATR_D1);
   if(hADX_M15 != INVALID_HANDLE) IndicatorRelease(hADX_M15);
   if(hEMA_H1  != INVALID_HANDLE) IndicatorRelease(hEMA_H1);
}

//+------------------------------------------------------------------+
//| Main Tick Handler                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!symInfo.RefreshRates()) return;

   MqlDateTime dt;
   TimeCurrent(dt);

   //--- Daily Reset
   datetime dayStart = StructToTime(dt) - (dt.hour * 3600 + dt.min * 60 + dt.sec);
   if(dayStart != g_CurrentDay)
   {
      g_CurrentDay      = dayStart;
      g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_TradesToday     = 0;
      g_AsiaHigh        = 0.0;
      g_AsiaLow         = 0.0;
      g_AsiaLocked      = false;
      g_HighSweptUsed   = false;
      g_LowSweptUsed    = false;
      ArrayResize(g_PartialDone, 0);
      ArrayResize(g_RiskTickets, 0);
      ArrayResize(g_RiskValues, 0);
   }

   //--- Manage Active Trades Every Tick
   ManagePositions(dt);

   //--- Evaluate Setups on Closed M15 Bar
   datetime barTime = iTime(_Symbol, PERIOD_M15, 0);
   if(barTime == g_LastM15Bar) return;
   g_LastM15Bar = barTime;

   //--- Build Asian Range from Closed M15 Bars
   MqlDateTime barDt;
   TimeToStruct(iTime(_Symbol, PERIOD_M15, 1), barDt);
   double h1 = iHigh(_Symbol, PERIOD_M15, 1);
   double l1 = iLow(_Symbol, PERIOD_M15, 1);

   if(barDt.hour >= InpAsiaStartHour && barDt.hour <= InpAsiaEndHour)
   {
      if(g_AsiaHigh == 0.0 || h1 > g_AsiaHigh) g_AsiaHigh = h1;
      if(g_AsiaLow  == 0.0 || l1 < g_AsiaLow)  g_AsiaLow  = l1;
      return;
   }

   if(g_AsiaHigh > 0.0 && g_AsiaLow > 0.0 && g_AsiaHigh > g_AsiaLow)
      g_AsiaLocked = true;

   if(!g_AsiaLocked) return;

   //--- Session, Daily Cap & Drawdown Guards
   if(dt.hour < InpTradeStartHour || dt.hour > InpTradeEndHour) return;
   if(g_TradesToday >= InpMaxTradesPerDay) return;
   if(CountActivePositions() > 0) return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(((g_DayStartBalance - equity) / g_DayStartBalance) * 100.0 >= InpMaxDailyLossPct)
      return;

   //--- ATR Volatility & Spread Calibration
   double atrM15 = GetInd(hATR_M15, 0, 1);
   double atrD1  = GetInd(hATR_D1,  0, 1);
   if(atrM15 <= 0.0 || atrD1 <= 0.0) return;

   double spreadDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * symInfo.Point();
   if(spreadDist > atrM15 * (InpMaxSpreadATR_Pct / 100.0)) return;

   double asiaWidth = g_AsiaHigh - g_AsiaLow;
   if(asiaWidth < atrD1 * InpMinAsiaD1_ATR || asiaWidth > atrD1 * InpMaxAsiaD1_ATR)
      return;

   //--- Relative Volume Filter
   long vol1 = iVolume(_Symbol, PERIOD_M15, 1);
   double avgVol = 0.0;
   for(int i = 2; i <= 21; i++)
      avgVol += (double)iVolume(_Symbol, PERIOD_M15, i);
   avgVol /= 20.0;
   if(avgVol > 0.0 && (double)vol1 < avgVol * InpMinVolMult) return;

   //--- H1 Institutional Trend Bias
   double emaH1_1 = GetInd(hEMA_H1, 0, 1);
   double emaH1_3 = GetInd(hEMA_H1, 0, 3);
   double closeH1 = iClose(_Symbol, PERIOD_H1, 1);
   if(emaH1_1 <= 0.0) return;

   bool h1Bull = (closeH1 > emaH1_1 && emaH1_1 >= emaH1_3);
   bool h1Bear = (closeH1 < emaH1_1 && emaH1_1 <= emaH1_3);

   double o1 = iOpen(_Symbol, PERIOD_M15, 1);
   double c1 = iClose(_Symbol, PERIOD_M15, 1);
   double minSweep = atrM15 * InpMinSweepATR;
   double maxSweep = atrM15 * InpMaxSweepATR;
double minSL    = atrM15 * InpMinSL_ATR_Mult;
int    digits   = symInfo.Digits();
//==================================================================
// ENGINE A: Judas Liquidity Sweep & Rejection Reversal
//==================================================================
if(InpEnableJudasSweep)
{
//--- Bullish Sweep of Asian Low (Aligned with H1 Uptrend)
if(h1Bull && !g_LowSweptUsed && l1 < (g_AsiaLow - minSweep) && (g_AsiaLow - l1) <= maxSweep && c1 > g_AsiaLow && c1 > o1)
{
double entry  = symInfo.Ask();
double slDist = MathMax(entry - (l1 - atrM15 * InpSL_ATR_Mult), minSL);
double sl     = NormalizeDouble(entry - slDist, digits);
double tp     = NormalizeDouble(entry + slDist * InpFinalTargetRR, digits);
double lots   = CalcLots(slDist);
if(lots >= symInfo.LotsMin() && trade.Buy(lots, _Symbol, entry, sl, tp, "Apex_Sweep_Buy"))
{
g_TradesToday++;
g_LowSweptUsed = true;
return;
}
}
//--- Bearish Sweep of Asian High (Aligned with H1 Downtrend)
if(h1Bear && !g_HighSweptUsed && h1 > (g_AsiaHigh + minSweep) && (h1 - g_AsiaHigh) <= maxSweep && c1 < g_AsiaHigh && c1 < o1)
{
double entry  = symInfo.Bid();
double slDist = MathMax((h1 + atrM15 * InpSL_ATR_Mult) - entry, minSL);
double sl     = NormalizeDouble(entry + slDist, digits);
double tp     = NormalizeDouble(entry - slDist * InpFinalTargetRR, digits);
double lots   = CalcLots(slDist);
if(lots >= symInfo.LotsMin() && trade.Sell(lots, _Symbol, entry, sl, tp, "Apex_Sweep_Sell"))
{
g_TradesToday++;
g_HighSweptUsed = true;
return;
}
}
}
//==================================================================
// ENGINE B: Tight Asian Box Momentum Breakout
//==================================================================
if(InpEnableCleanBreakout && asiaWidth <= atrD1 * InpMaxBreakoutD1_ATR)
{
double adx15 = GetInd(hADX_M15, 0, 1);
double c2    = iClose(_Symbol, PERIOD_M15, 2);
double body1 = MathAbs(c1 - o1);
if(adx15 >= InpMinADX_Breakout && body1 >= atrM15 * 0.45)
{
//--- Bullish Breakout Above Asian High
if(h1Bull && !g_HighSweptUsed && c1 > g_AsiaHigh + minSweep && c2 <= g_AsiaHigh)
{
double entry  = symInfo.Ask();
double slDist = MathMax(entry - (l1 - atrM15 * InpSL_ATR_Mult), minSL);
double sl     = NormalizeDouble(entry - slDist, digits);
double tp     = NormalizeDouble(entry + slDist * InpFinalTargetRR, digits);
double lots   = CalcLots(slDist);
if(lots >= symInfo.LotsMin() && trade.Buy(lots, _Symbol, entry, sl, tp, "Apex_Break_Buy"))
{
g_TradesToday++;
g_HighSweptUsed = true;
return;
}
}
//--- Bearish Breakout Below Asian Low
if(h1Bear && !g_LowSweptUsed && c1 < g_AsiaLow - minSweep && c2 >= g_AsiaLow)
{
double entry  = symInfo.Bid();
double slDist = MathMax((h1 + atrM15 * InpSL_ATR_Mult) - entry, minSL);
double sl     = NormalizeDouble(entry + slDist, digits);
double tp     = NormalizeDouble(entry - slDist * InpFinalTargetRR, digits);
double lots   = CalcLots(slDist);
if(lots >= symInfo.LotsMin() && trade.Sell(lots, _Symbol, entry, sl, tp, "Apex_Break_Sell"))
{
g_TradesToday++;
g_LowSweptUsed = true;
return;
}
}
}
}
}
//+------------------------------------------------------------------+
//| Position Management: Breakeven + Single 50% Partial + ATR Trail  |
//+------------------------------------------------------------------+
void ManagePositions(const MqlDateTime &dt)
{
double atrM15 = GetInd(hATR_M15, 0, 1);
double point  = symInfo.Point();
int    digits = symInfo.Digits();
for(int i = PositionsTotal() - 1; i >= 0; i--)
{
if(!posInfo.SelectByIndex(i)) continue;
if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;
ulong  ticket  = posInfo.Ticket();
double openPrc = posInfo.PriceOpen();
double sl      = posInfo.StopLoss();
double tp      = posInfo.TakeProfit();
double vol     = posInfo.Volume();
long   type    = posInfo.PositionType();
if(dt.hour > InpHardCloseHour || (dt.hour == InpHardCloseHour && dt.min >= InpHardCloseMinute))
{
trade.PositionClose(ticket);
continue;
}
if((type == POSITION_TYPE_BUY && sl > 0.0 && sl < openPrc) ||
(type == POSITION_TYPE_SELL && sl > openPrc))
{
StoreInitialRisk(ticket, MathAbs(openPrc - sl));
}
double fallbackRisk = (tp > 0.0) ? (MathAbs(tp - openPrc) / InpFinalTargetRR) : (atrM15 * InpMinSL_ATR_Mult);
double initRisk     = FetchInitialRisk(ticket, fallbackRisk);
if(initRisk <= 0.0) continue;
bool partialDone = IsPartialCompleted(ticket);
if(type == POSITION_TYPE_BUY)
{
double bid    = symInfo.Bid();
double gain   = bid - openPrc;
if(gain >= initRisk * InpBELockRR && sl < openPrc)
{
double beSL = NormalizeDouble(openPrc + 30 * point, digits);
trade.PositionModify(ticket, beSL, tp);
sl = beSL;
}
if(!partialDone && gain >= initRisk * InpPartialCloseRR && vol >= symInfo.LotsMin() * 2.0)
{
double part = NormLot(vol * 0.50);
if(part >= symInfo.LotsMin() && (vol - part) >= symInfo.LotsMin())
if(trade.PositionClosePartial(ticket, part))
SetPartialCompleted(ticket);
}
if(gain >= initRisk * InpPartialCloseRR && atrM15 > 0.0)
{
double newSL = NormalizeDouble(bid - atrM15 * InpTrail_ATR_Mult, digits);
if(newSL > sl + 25 * point)
trade.PositionModify(ticket, newSL, tp);
}
}
else if(type == POSITION_TYPE_SELL)
{
double ask    = symInfo.Ask();
double gain   = openPrc - ask;
if(gain >= initRisk * InpBELockRR && (sl > openPrc || sl == 0.0))
{
double beSL = NormalizeDouble(openPrc - 30 * point, digits);
trade.PositionModify(ticket, beSL, tp);
sl = beSL;
}
if(!partialDone && gain >= initRisk * InpPartialCloseRR && vol >= symInfo.LotsMin() * 2.0)
{
double part = NormLot(vol * 0.50);
if(part >= symInfo.LotsMin() && (vol - part) >= symInfo.LotsMin())
if(trade.PositionClosePartial(ticket, part))
SetPartialCompleted(ticket);
}
if(gain >= initRisk * InpPartialCloseRR && atrM15 > 0.0)
{
double newSL = NormalizeDouble(ask + atrM15 * InpTrail_ATR_Mult, digits);
if(newSL < sl - 25 * point)
trade.PositionModify(ticket, newSL, tp);
}
}
}
}
int CountActivePositions()
{
int c = 0;
for(int i = PositionsTotal() - 1; i >= 0; i--)
if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
c++;
return(c);
}
double CalcLots(double slDist)
{
double riskCash = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
double tickVal  = symInfo.TickValue();
double tickSize = symInfo.TickSize();
if(tickVal <= 0.0 || tickSize <= 0.0 || slDist <= 0.0) return(symInfo.LotsMin());
double lossPerLot = (slDist / tickSize) * tickVal;
return(lossPerLot > 0.0 ? NormLot(riskCash / lossPerLot) : symInfo.LotsMin());
}
double NormLot(double lots)
{
double minL = symInfo.LotsMin(), maxL = symInfo.LotsMax(), stepL = symInfo.LotsStep();
lots = MathFloor(lots / stepL) * stepL;
return(NormalizeDouble(MathMax(minL, MathMin(maxL, lots)), 2));
}
//+------------------------------------------------------------------+
//| Custom Fitness Function (Rewards Profit Factor, Recovery & R^2)  |
//+------------------------------------------------------------------+
double OnTester()
{
double profit = TesterStatistics(STAT_PROFIT);
double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
double rf     = TesterStatistics(STAT_RECOVERY_FACTOR);
double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
double trades = TesterStatistics(STAT_TRADES);
if(profit <= 0.0 || trades < 40 || dd > 14.0)
return(0.0);
return(pf * rf * MathSqrt(trades));
}
//+------------------------------------------------------------------+