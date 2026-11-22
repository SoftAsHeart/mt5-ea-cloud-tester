//+------------------------------------------------------------------+
//|                                                My Trader 3.2.mq5 |
//|                    Institutional Liquidity Sweep & Micro-FVG EA  |
//|                    Tailored for Exness Cent (XAUUSDc) - M1       |
//+------------------------------------------------------------------+
#property copyright "My Trader 3.2"
#property version   "3.20"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

//--- Input Parameters
input group "=== Risk & Account Management ==="
input double   InpRiskPercent          = 1.0;      // Risk per trade (% of Balance)
input double   InpMaxDailyLossPct      = 3.5;      // Max Daily Drawdown Limit (%)
input int      InpMaxTradesPerDay      = 3;        // Max Trades per Day
input int      InpMaxSpreadPoints      = 350;      // Max Allowed Spread in Points (350 pts = $0.35 on Cent)
input ulong    InpMagicNumber          = 2026032;  // EA Magic Number

input group "=== Session & Intraday Time-Stop (Broker Server Time) ==="
input int      InpAsianStartHour       = 0;        // Asian Range Start Hour
input int      InpAsianEndHour         = 6;        // Asian Range End Hour
input int      InpTradeStartHour       = 7;        // London/NY Killzone Start Hour
input int      InpTradeEndHour         = 15;       // Last Hour for New Entries (15:00 Server)
input int      InpMaxHoldMinutes       = 240;      // Max Trade Duration in Minutes (4 Hours)
input int      InpHardCloseHour        = 20;       // Hard Daily Close Hour (Before Rollover)
input int      InpHardCloseMinute      = 45;       // Hard Daily Close Minute

input group "=== Strategy & Liquidity Sweep Filters ==="
input int      InpKERPeriod            = 14;       // Kaufman Efficiency Ratio Period (M1)
input double   InpMaxKERForReversal    = 0.45;     // Max KER Allowed (0.40 - 0.55)
input int      InpSweepMinPoints       = 300;      // Min Sweep Beyond Asian High/Low (Points)
input int      InpSweepMaxPoints       = 1200;     // Max Sweep Overshoot Allowed (Points - Filters Breakouts)
input int      InpSweepMaxBars         = 15;       // Max M1 Bars After Sweep to Trigger Entry
input int      InpMinAsianRangePts     = 400;      // Min Asian Range Width (Points)
input int      InpMaxAsianRangePts     = 2500;     // Max Asian Range Width (Points)
input double   InpMinDisplacementBody  = 0.55;     // Min Displacement Candle Body Ratio (0.0-1.0)
input bool     InpRequireFVG           = true;     // Require Micro-FVG on Displacement
input bool     InpUseH1TrendFilter     = true;     // Strict H1 EMA 200 + Slope Trend Filter
input int      InpH1EMAPeriod          = 200;      // H1 Macro Trend EMA Period

input group "=== Stop Loss, Partial TP & Trailing ==="
input int      InpATRPeriod            = 14;       // M1 ATR Period
input double   InpSL_ATR_Mult          = 0.90;     // Stop Loss ATR Buffer Multiplier
input double   InpPartialCloseRR       = 1.0;      // R:R to Close 50% & Move SL to Breakeven
input double   InpFinalTargetRR        = 2.2;      // Final Take Profit R:R Target
input bool     InpUseATRTrailing       = true;     // Trail Runner After Partial Close
input double   InpTrail_ATR_Mult       = 0.80;     // Trailing Stop ATR Multiplier

//--- Global Variables
int      hATR_M1     = INVALID_HANDLE;
int      hEMA_H1     = INVALID_HANDLE;

double   g_AsianHigh        = 0.0;
double   g_AsianLow         = 0.0;
bool     g_AsianReady       = false;
bool     g_AsianValidRange  = false;

datetime g_SweepHighTime    = 0;
double   g_SweepHighExtreme = 0.0;
bool     g_HighBrokenOut    = false;

datetime g_SweepLowTime     = 0;
double   g_SweepLowExtreme  = 0.0;
bool     g_LowBrokenOut     = false;

datetime g_CurrentDay       = 0;
double   g_DayStartBalance  = 0.0;
int      g_TradesToday      = 0;
datetime g_LastBarTime      = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!symInfo.Name(_Symbol))
      return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   hATR_M1 = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
   hEMA_H1 = iMA(_Symbol, PERIOD_H1, InpH1EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(hATR_M1 == INVALID_HANDLE || hEMA_H1 == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles.");
      return(INIT_FAILED);
   }

   g_DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hATR_M1 != INVALID_HANDLE) IndicatorRelease(hATR_M1);
   if(hEMA_H1 != INVALID_HANDLE) IndicatorRelease(hEMA_H1);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!symInfo.RefreshRates()) return;

   MqlDateTime dt;
   TimeCurrent(dt);

   //--- New Day Reset
   datetime dayStart = StructToTime(dt) - (dt.hour * 3600 + dt.min * 60 + dt.sec);
   if(dayStart != g_CurrentDay)
   {
      g_CurrentDay       = dayStart;
      g_DayStartBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
      g_TradesToday      = 0;
      g_AsianHigh        = 0.0;
      g_AsianLow         = 0.0;
      g_AsianReady       = false;
      g_AsianValidRange  = false;
      g_SweepHighTime    = 0;
      g_SweepHighExtreme = 0.0;
      g_HighBrokenOut    = false;
      g_SweepLowTime     = 0;
      g_SweepLowExtreme  = 0.0;
      g_LowBrokenOut     = false;
   }

   //--- Manage Open Positions Every Tick (Time-Stop, Partial TP, Trailing)
   ManageOpenPositions(dt);

   //--- Run Entry & Range Logic on New M1 Bar
   datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
   if(barTime == g_LastBarTime) return;
   g_LastBarTime = barTime;

   //--- Build Asian Session High / Low
   if(dt.hour >= InpAsianStartHour && dt.hour < InpAsianEndHour)
   {
      double h1 = iHigh(_Symbol, PERIOD_M1, 1);
      double l1 = iLow(_Symbol, PERIOD_M1, 1);
      if(g_AsianHigh == 0.0 || h1 > g_AsianHigh) g_AsianHigh = h1;
      if(g_AsianLow  == 0.0 || l1 < g_AsianLow)  g_AsianLow  = l1;
      return;
   }

   if(!g_AsianReady && dt.hour >= InpAsianEndHour && g_AsianHigh > 0.0 && g_AsianLow > 0.0 && g_AsianHigh > g_AsianLow)
   {
      g_AsianReady = true;
      double asianRangePts = (g_AsianHigh - g_AsianLow) / symInfo.Point();
      g_AsianValidRange = (asianRangePts >= InpMinAsianRangePts && asianRangePts <= InpMaxAsianRangePts);
   }

   if(!g_AsianReady || !g_AsianValidRange) return;

   //--- Track Fresh Liquidity Sweeps Throughout Killzone
   UpdateSweepState();

   //--- Check Entry Window & Risk Limits
   if(dt.hour < InpTradeStartHour || dt.hour >= InpTradeEndHour) return;
   if(g_TradesToday >= InpMaxTradesPerDay) return;
   if(HasOpenPosition()) return;

   //--- Daily Loss Guard
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyLossPct = ((g_DayStartBalance - equity) / g_DayStartBalance) * 100.0;
   if(dailyLossPct >= InpMaxDailyLossPct) return;

   //--- Spread Guard
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints) return;

   //--- Evaluate Sweep + Displacement + FVG Setup
   CheckForSetup();
}

//+------------------------------------------------------------------+
//| Track Fresh Sweeps & Invalidate Runaway Breakouts                |
//+------------------------------------------------------------------+
void UpdateSweepState()
{
   double point     = symInfo.Point();
   double minSweep  = InpSweepMinPoints * point;
   double maxSweep  = InpSweepMaxPoints * point;

   double h1        = iHigh(_Symbol, PERIOD_M1, 1);
   double l1        = iLow(_Symbol, PERIOD_M1, 1);
   datetime t1      = iTime(_Symbol, PERIOD_M1, 1);

   //--- High Side Sweep Tracking
   if(!g_HighBrokenOut)
   {
      if(h1 > g_AsianHigh + maxSweep)
      {
         g_HighBrokenOut = true;
         g_SweepHighTime = 0; // Real breakout, not a liquidity sweep
      }
      else if(h1 >= g_AsianHigh + minSweep)
      {
         if(g_SweepHighTime == 0 || h1 > g_SweepHighExtreme)
         {
            g_SweepHighTime    = t1;
            g_SweepHighExtreme = h1;
         }
      }
   }

   //--- Low Side Sweep Tracking
   if(!g_LowBrokenOut)
   {
      if(l1 < g_AsianLow - maxSweep)
      {
         g_LowBrokenOut = true;
         g_SweepLowTime = 0; // Real breakout, not a liquidity sweep
      }
      else if(l1 <= g_AsianLow - minSweep)
      {
         if(g_SweepLowTime == 0 || l1 < g_SweepLowExtreme)
         {
            g_SweepLowTime    = t1;
            g_SweepLowExtreme = l1;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check Liquidity Sweep & Displacement Entry                       |
//+------------------------------------------------------------------+
void CheckForSetup()
{
   datetime t1 = iTime(_Symbol, PERIOD_M1, 1);
   int maxSweepSeconds = InpSweepMaxBars * 60;

   bool freshHighSweep = (!g_HighBrokenOut && g_SweepHighTime > 0 && (t1 - g_SweepHighTime) <= maxSweepSeconds);
   bool freshLowSweep  = (!g_LowBrokenOut  && g_SweepLowTime  > 0 && (t1 - g_SweepLowTime)  <= maxSweepSeconds);

   if(!freshHighSweep && !freshLowSweep) return;

   //--- Calculate Kaufman Efficiency Ratio (KER)
   double ker = CalculateKER(InpKERPeriod);
   if(ker > InpMaxKERForReversal) return;

   //--- Fetch Last 3 Closed M1 Bars
double o1 = iOpen(_Symbol, PERIOD_M1, 1),  c1 = iClose(_Symbol, PERIOD_M1, 1);
double h1 = iHigh(_Symbol, PERIOD_M1, 1),  l1 = iLow(_Symbol, PERIOD_M1, 1);
double h3 = iHigh(_Symbol, PERIOD_M1, 3),  l3 = iLow(_Symbol, PERIOD_M1, 3);
//--- Displacement Candle Body Check
double range1 = h1 - l1;
if(range1 <= 0.0) return;
double bodyRatio1 = MathAbs(c1 - o1) / range1;
if(bodyRatio1 < InpMinDisplacementBody) return;
//--- Get M1 ATR & H1 EMA 200 (Current + 3 Hours Ago for Slope)
double atrBuf, emaH1Buf;
if(CopyBuffer(hATR_M1, 0, 1, 1, atrBuf) < 1) return;
if(CopyBuffer(hEMA_H1, 0, 1, 4, emaH1Buf) < 4) return;
double atrM1     = atrBuf;
double emaH1_now = emaH1Buf; // Shift 1 (latest closed H1 bar)
double emaH1_old = emaH1Buf; // Shift 4 (3 H1 bars earlier)
if(atrM1 <= 0.0) return;
//==================================================================
// 1. BEARISH REVERSAL (Fresh Sweep Above Asian High -> Close Below)
//==================================================================
if(freshHighSweep && c1 < o1 && c1 < g_AsianHigh)
{
bool hasBearFVG = (!InpRequireFVG) || (h1 < l3);
bool bearTrend  = (!InpUseH1TrendFilter) || (c1 < emaH1_now && emaH1_now <= emaH1_old);
if(hasBearFVG && bearTrend)
{
double entry = symInfo.Bid();
double sl = NormalizeDouble(g_SweepHighExtreme + (atrM1 * InpSL_ATR_Mult), symInfo.Digits());
double slDist = sl - entry;
if(slDist > 0.0)
{
double tp = NormalizeDouble(entry - (slDist * InpFinalTargetRR), symInfo.Digits());
double lots = CalculateLotSize(slDist);
if(lots >= symInfo.LotsMin())
{
if(trade.Sell(lots, _Symbol, entry, sl, tp, "MT3.2_SweepSell"))
{
g_TradesToday++;
g_SweepHighTime = 0;
}
}
}
}
}
//==================================================================
// 2. BULLISH REVERSAL (Fresh Sweep Below Asian Low -> Close Above)
//==================================================================
if(freshLowSweep && c1 > o1 && c1 > g_AsianLow)
{
bool hasBullFVG = (!InpRequireFVG) || (l1 > h3);
bool bullTrend  = (!InpUseH1TrendFilter) || (c1 > emaH1_now && emaH1_now >= emaH1_old);
if(hasBullFVG && bullTrend)
{
double entry = symInfo.Ask();
double sl = NormalizeDouble(g_SweepLowExtreme - (atrM1 * InpSL_ATR_Mult), symInfo.Digits());
double slDist = entry - sl;
if(slDist > 0.0)
{
double tp = NormalizeDouble(entry + (slDist * InpFinalTargetRR), symInfo.Digits());
double lots = CalculateLotSize(slDist);
if(lots >= symInfo.LotsMin())
{
if(trade.Buy(lots, _Symbol, entry, sl, tp, "MT3.2_SweepBuy"))
{
g_TradesToday++;
g_SweepLowTime = 0;
}
}
}
}
}
}
//+------------------------------------------------------------------+
//| Manage Open Positions: Time-Stop, Partial Close & Trailing       |
//+------------------------------------------------------------------+
void ManageOpenPositions(const MqlDateTime &dt)
{
datetime now = TimeCurrent();
double atrBuf;
double atrM1 = 0.0;
if(CopyBuffer(hATR_M1, 0, 1, 1, atrBuf) >= 1)
atrM1 = atrBuf;
for(int i = PositionsTotal() - 1; i >= 0; i--)
{
if(!posInfo.SelectByIndex(i)) continue;
if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;
ulong  ticket   = posInfo.Ticket();
double openPrc  = posInfo.PriceOpen();
double sl       = posInfo.StopLoss();
double tp       = posInfo.TakeProfit();
double vol      = posInfo.Volume();
long   posType  = posInfo.PositionType();
datetime openTm = posInfo.Time();
//--- 1. Hard Pre-Rollover Daily Close
if(dt.hour > InpHardCloseHour || (dt.hour == InpHardCloseHour && dt.min >= InpHardCloseMinute))
{
trade.PositionClose(ticket);
continue;
}
//--- 2. Max Holding Duration Time-Stop
int heldMinutes = (int)((now - openTm) / 60);
if(heldMinutes >= InpMaxHoldMinutes)
{
trade.PositionClose(ticket);
continue;
}
double initialRisk = (tp > 0.0 && InpFinalTargetRR > 0.0) ? MathAbs(tp - openPrc) / InpFinalTargetRR : 0.0;
if(initialRisk <= 0.0) continue;
//--- 3. Partial Close (50%) & Breakeven Lock
if(posType == POSITION_TYPE_BUY)
{
double bid = symInfo.Bid();
double profitDist = bid - openPrc;
if(profitDist >= initialRisk * InpPartialCloseRR && sl < openPrc)
{
double closeVol = NormalizeLot(vol * 0.5);
if(closeVol >= symInfo.LotsMin() && (vol - closeVol) >= symInfo.LotsMin())
trade.PositionClosePartial(ticket, closeVol);
double beSL = NormalizeDouble(openPrc + 20 * symInfo.Point(), symInfo.Digits());
trade.PositionModify(ticket, beSL, tp);
}
else if(InpUseATRTrailing && sl >= openPrc && atrM1 > 0.0)
{
double newSL = NormalizeDouble(bid - (atrM1 * InpTrail_ATR_Mult), symInfo.Digits());
if(newSL > sl + 10 * symInfo.Point())
trade.PositionModify(ticket, newSL, tp);
}
}
else if(posType == POSITION_TYPE_SELL)
{
double ask = symInfo.Ask();
double profitDist = openPrc - ask;
if(profitDist >= initialRisk * InpPartialCloseRR && (sl > openPrc || sl == 0.0))
{
double closeVol = NormalizeLot(vol * 0.5);
if(closeVol >= symInfo.LotsMin() && (vol - closeVol) >= symInfo.LotsMin())
trade.PositionClosePartial(ticket, closeVol);
double beSL = NormalizeDouble(openPrc - 20 * symInfo.Point(), symInfo.Digits());
trade.PositionModify(ticket, beSL, tp);
}
else if(InpUseATRTrailing && sl <= openPrc && sl > 0.0 && atrM1 > 0.0)
{
double newSL = NormalizeDouble(ask + (atrM1 * InpTrail_ATR_Mult), symInfo.Digits());
if(newSL < sl - 10 * symInfo.Point())
trade.PositionModify(ticket, newSL, tp);
}
}
}
}
//+------------------------------------------------------------------+
//| Kaufman Efficiency Ratio (KER)                                   |
//+------------------------------------------------------------------+
double CalculateKER(int period)
{
double cNow  = iClose(_Symbol, PERIOD_M1, 1);
double cPast = iClose(_Symbol, PERIOD_M1, 1 + period);
double netChange = MathAbs(cNow - cPast);
double sumVolatility = 0.0;
for(int i = 1; i <= period; i++)
{
double ci = iClose(_Symbol, PERIOD_M1, i);
double cp = iClose(_Symbol, PERIOD_M1, i + 1);
sumVolatility += MathAbs(ci - cp);
}
if(sumVolatility <= 0.0) return(1.0);
return(netChange / sumVolatility);
}
//+------------------------------------------------------------------+
//| Dynamic Risk-Based Lot Sizing                                    |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
double riskCash = balance * (InpRiskPercent / 100.0);
double tickVal  = symInfo.TickValue();
double tickSize = symInfo.TickSize();
if(tickVal <= 0.0 || tickSize <= 0.0 || slDistance <= 0.0)
return(symInfo.LotsMin());
double lossPerLot = (slDistance / tickSize) * tickVal;
if(lossPerLot <= 0.0) return(symInfo.LotsMin());
double rawLots = riskCash / lossPerLot;
return(NormalizeLot(rawLots));
}
double NormalizeLot(double lots)
{
double minLot  = symInfo.LotsMin();
double maxLot  = symInfo.LotsMax();
double stepLot = symInfo.LotsStep();
lots = MathFloor(lots / stepLot) * stepLot;
if(lots < minLot) lots = minLot;
if(lots > maxLot) lots = maxLot;
return(NormalizeDouble(lots, 2));
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
//+------------------------------------------------------------------+
//| Custom Optimization Fitness Criterion                            |
//+------------------------------------------------------------------+
double OnTester()
{
double profit      = TesterStatistics(STAT_PROFIT);
double pf          = TesterStatistics(STAT_PROFIT_FACTOR);
double rf          = TesterStatistics(STAT_RECOVERY_FACTOR);
double ddPct       = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
double trades      = TesterStatistics(STAT_TRADES);
if(profit <= 0.0 || trades < 25 || ddPct > 15.0)
return(0.0);
return(pf * rf * MathSqrt(trades));
}
//+------------------------------------------------------------------+