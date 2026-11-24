//+------------------------------------------------------------------+
//|                                         MyTrader80_ScalpHedge.mq5|
//|     Trend-Aligned M5 Pullback Scalper + Capped 1-Step Hedge      |
//|     Version 8.10 - Low-Capital Cent Build (EURUSDc / XAUUSDc)    |
//+------------------------------------------------------------------+
#property copyright "My Trader 8.1 Low-Capital Quant"
#property version   "8.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

//--- 1. Low-Capital Risk & Daily Circuit Breakers
input group "=== 1. Low-Capital Risk & Guardrails ==="
input double   InpBaseLotSize          = 0.01;     // Base Cent Lot Size (0.01 = Safe at 1:100+ Lev)
input double   InpMaxBasketLossPct     = 3.00;     // Hard Basket Stop-Loss (% of Balance)
input double   InpMaxDailyLossPct      = 5.00;     // Daily Account Kill-Switch (%)
input int      InpMaxSpreadPoints      = 18;       // Max Spread Points (18 EURUSDc / 350 XAUUSDc)
input ulong    InpMagicNumber          = 2026081;  // EA Magic Number

//--- 2. Macro Trend & Volatility Filters (H1 + M15)
input group "=== 2. Macro Trend & ADX Regime Filters ==="
input int      InpH1_TrendEMA          = 200;      // H1 Macro Trend EMA Period
input double   InpMinADX_M15           = 16.0;     // Min M15 ADX (Avoid Dead Asian Chop)
input double   InpMaxADX_M15           = 38.0;     // Max M15 ADX (Avoid News Blowoffs)

//--- 3. M5 Pullback Scalp Engine
input group "=== 3. M5 Micro-Scalp Entry & Quick Exit ==="
input int      InpEMA_TrendPeriod      = 50;       // M5 Micro-Trend EMA
input int      InpRSI_Period           = 10;       // Pullback RSI Period (9-14 Optimal)
input double   InpRSI_Oversold         = 30.0;     // Oversold Trigger in Uptrend
input double   InpRSI_Overbought       = 70.0;     // Overbought Trigger in Downtrend
input double   InpScalpTP_ATR_Mult     = 1.35;     // Quick Scalp Take-Profit (x M5 ATR)
input int      InpCooldownSeconds      = 300;      // Min Seconds Between New Cycles (5 mins)

//--- 4. Capped 1-Step Hedge Recovery (Anti-Blowup)
input group "=== 4. Capped 1-Step Hedge Recovery ==="
input bool     InpEnableSingleHedge    = true;     // Allow Max 1 Counter-Hedge Leg
input double   InpHedgeTrigger_ATR     = 2.00;     // Adverse Move to Trigger Hedge (x M5 ATR)
input double   InpHedgeLotMultiplier   = 2.00;     // Hedge Lot Multiplier (2.0x = 0.02 on 0.01)
input double   InpBasketTarget_ATR     = 0.50;     // Net Basket Profit Target to Close Both (x M5 ATR)

//--- 5. Session & HMR Rollover Protection
input group "=== 5. Killzone & Exness HMR Protection ==="
input int      InpTradeStartHour       = 7;        // London Open Start Hour (Server Time)
input int      InpTradeEndHour         = 18;       // NY Session Cutoff Hour
input int      InpHardCloseHour        = 20;       // Pre-Rollover / HMR Flat Hour
input int      InpHardCloseMinute      = 30;       // Pre-Rollover / HMR Flat Minute

//--- Indicator Handles & State
int      hEMA_M5          = INVALID_HANDLE;
int      hRSI_M5          = INVALID_HANDLE;
int      hATR_M5          = INVALID_HANDLE;
int      hEMA_H1          = INVALID_HANDLE;
int      hADX_M15         = INVALID_HANDLE;

datetime g_CurrentDay     = 0;
double   g_DayStartBal    = 0.0;
datetime g_LastCycleClose = 0;
datetime g_LastBarTime    = 0;

//+------------------------------------------------------------------+
//| Safe Indicator Buffer Reader Helper                              |
//+------------------------------------------------------------------+
double GetVal(int handle, int bufferNum, int shift)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, bufferNum, shift, 1, buf) <= 0)
      return(EMPTY_VALUE);
   return(buf[0]);
}

//+------------------------------------------------------------------+
//| Expert Initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!symInfo.Name(_Symbol)) return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   hEMA_M5  = iMA(_Symbol, PERIOD_M5, InpEMA_TrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hRSI_M5  = iRSI(_Symbol, PERIOD_M5, InpRSI_Period, PRICE_CLOSE);
   hATR_M5  = iATR(_Symbol, PERIOD_M5, 14);
   hEMA_H1  = iMA(_Symbol, PERIOD_H1, InpH1_TrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hADX_M15 = iADX(_Symbol, PERIOD_M15, 14);

   if(hEMA_M5 == INVALID_HANDLE || hRSI_M5 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE ||
      hEMA_H1 == INVALID_HANDLE || hADX_M15 == INVALID_HANDLE)
      return(INIT_FAILED);

   g_DayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hEMA_M5);
   IndicatorRelease(hRSI_M5);
   IndicatorRelease(hATR_M5);
   IndicatorRelease(hEMA_H1);
   IndicatorRelease(hADX_M15);
}

//+------------------------------------------------------------------+
//| Main Tick Loop                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!symInfo.RefreshRates()) return;

   MqlDateTime dt;
   TimeCurrent(dt);

   datetime dayStart = StructToTime(dt) - (dt.hour * 3600 + dt.min * 60 + dt.sec);
   if(dayStart != g_CurrentDay)
   {
      g_CurrentDay  = dayStart;
      g_DayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   }

   //--- Pre-Rollover / HMR Flat Exit
   if(dt.hour > InpHardCloseHour || (dt.hour == InpHardCloseHour && dt.min >= InpHardCloseMinute))
   {
      if(CountBasketPositions() > 0)
         CloseAllBasketPositions();
      return;
   }

   //--- Active Basket Management Every Tick
   int openCount = CountBasketPositions();
   if(openCount > 0)
   {
      ManageActiveBasket(openCount);
      return;
   }

   //--- New Scalp Entry Check on M5 Bar Close
   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime == g_LastBarTime) return;
   g_LastBarTime = barTime;

   if(dt.hour < InpTradeStartHour || dt.hour >= InpTradeEndHour) return;
   if(g_LastCycleClose > 0 && (TimeCurrent() - g_LastCycleClose) < InpCooldownSeconds) return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(((g_DayStartBal - balance) / g_DayStartBal) * 100.0 >= InpMaxDailyLossPct) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints) return;

   CheckM5ScalpEntry();
}

//+------------------------------------------------------------------+
//| Trend-Aligned M5 Pullback Scalp Entry                            |
//+------------------------------------------------------------------+
void CheckM5ScalpEntry()
{
   double ema1    = GetVal(hEMA_M5, 0, 1);
   double rsi1    = GetVal(hRSI_M5, 0, 1);
   double rsi2    = GetVal(hRSI_M5, 0, 2);
   double atr1    = GetVal(hATR_M5, 0, 1);
   double h1Ema1  = GetVal(hEMA_H1, 0, 1);
   double h1Ema2  = GetVal(hEMA_H1, 0, 2);
   double adx1    = GetVal(hADX_M15, 0, 1);

   double c1      = iClose(_Symbol, PERIOD_M5, 1);
   double o1      = iOpen(_Symbol, PERIOD_M5, 1);
   double h1Close = iClose(_Symbol, PERIOD_H1, 1);

   if(ema1 == EMPTY_VALUE || atr1 == EMPTY_VALUE || h1Ema1 == EMPTY_VALUE || adx1 == EMPTY_VALUE) return;
   if(ema1 <= 0.0 || atr1 <= 0.0 || h1Ema1 <= 0.0) return;

   //--- Regime Gate: Trade only healthy trend/pullback volatility (skip dead chop & news spikes)
   if(adx1 < InpMinADX_M15 || adx1 > InpMaxADX_M15) return;

   bool h1Bullish = (h1Close > h1Ema1 && h1Ema1 >= h1Ema2);
   bool h1Bearish = (h1Close < h1Ema1 && h1Ema1 <= h1Ema2);

   double lots   = NormalizeLot(InpBaseLotSize);
   double tpDist = atr1 * InpScalpTP_ATR_Mult;
   int    digits = symInfo.Digits();

   //--- Bullish M5 Pullback Scalp (Aligned with H1 Uptrend + M5 EMA + RSI Hook Up)
   if(h1Bullish && c1 > ema1 && rsi2 <= InpRSI_Oversold && rsi1 > rsi2 && c1 > o1)
   {
      double entry = symInfo.Ask();
      double tp    = NormalizeDouble(entry + tpDist, digits);
      trade.Buy(lots, _Symbol, entry, 0.0, tp, "MT81_ScalpBuy");
   }
   //--- Bearish M5 Pullback Scalp (Aligned with H1 Downtrend + M5 EMA + RSI Hook Down)
   else if(h1Bearish && c1 < ema1 && rsi2 >= InpRSI_Overbought && rsi1 < rsi2 && c1 < o1)
   {
      double entry = symInfo.Bid();
      double tp    = NormalizeDouble(entry - tpDist, digits);
      trade.Sell(lots, _Symbol, entry, 0.0, tp, "MT81_ScalpSell");
   }
}

//+------------------------------------------------------------------+
//| Manage Active Basket: Quick Profit, 1-Step Hedge, & Hard Stop    |
//+------------------------------------------------------------------+
void ManageActiveBasket(int openCount)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double maxLossVal = balance * (InpMaxBasketLossPct / 100.0);
   double atr1       = GetVal(hATR_M5, 0, 1);
   if(atr1 == EMPTY_VALUE || atr1 <= 0.0) return;

   double netProfit   = 0.0;
   double leg1Open    = 0.0;
   double leg1Lots    = 0.0;
   long   leg1Type    = -1;
   ulong  leg1Ticket  = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;

      netProfit += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
      if(openCount == 1)
      {
         leg1Open   = posInfo.PriceOpen();
         leg1Lots   = posInfo.Volume();
         leg1Type   = posInfo.PositionType();
         leg1Ticket = posInfo.Ticket();
      }
   }

   //--- 1. Hard Equity Circuit Breaker (Prevents Account Blowup)
   if(netProfit <= -maxLossVal)
   {
      CloseAllBasketPositions();
      return;
   }

   //--- 2. Capped 1-Step Hedge Recovery Trigger
   if(openCount == 1 && InpEnableSingleHedge)
   {
      double triggerDist = atr1 * InpHedgeTrigger_ATR;
double hedgeLots   = NormalizeLot(leg1Lots * InpHedgeLotMultiplier);
if(leg1Type == POSITION_TYPE_BUY && (leg1Open - symInfo.Bid()) >= triggerDist)
{
trade.PositionModify(leg1Ticket, 0.0, 0.0);
trade.Sell(hedgeLots, _Symbol, symInfo.Bid(), 0.0, 0.0, "MT81_HedgeSell");
return;
}
else if(leg1Type == POSITION_TYPE_SELL && (symInfo.Ask() - leg1Open) >= triggerDist)
{
trade.PositionModify(leg1Ticket, 0.0, 0.0);
trade.Buy(hedgeLots, _Symbol, symInfo.Ask(), 0.0, 0.0, "MT81_HedgeBuy");
return;
}
}
//--- 3. Close Hedged Basket as Soon as Combined Profit Hits Micro-Target
if(openCount >= 2)
{
double tickVal    = symInfo.TickValue();
double tickSize   = symInfo.TickSize();
double targetCash = ((atr1 * InpBasketTarget_ATR) / tickSize) * tickVal * InpBaseLotSize;
if(netProfit >= MathMax(targetCash, 0.10))
{
CloseAllBasketPositions();
}
}
}
//+------------------------------------------------------------------+
//| Utility Functions                                                |
//+------------------------------------------------------------------+
int CountBasketPositions()
{
int count = 0;
for(int i = PositionsTotal() - 1; i >= 0; i--)
{
if(posInfo.SelectByIndex(i))
if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
count++;
}
return(count);
}
void CloseAllBasketPositions()
{
for(int i = PositionsTotal() - 1; i >= 0; i--)
{
if(posInfo.SelectByIndex(i))
if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
trade.PositionClose(posInfo.Ticket());
}
g_LastCycleClose = TimeCurrent();
}
double NormalizeLot(double lots)
{
double minLot  = symInfo.LotsMin();
double maxLot  = symInfo.LotsMax();
double stepLot = symInfo.LotsStep();
// Use MathRound so 0.01 * 1.50 rounds cleanly to 0.02 instead of flooring back to 0.01
lots = MathRound(lots / stepLot) * stepLot;
if(lots < minLot) lots = minLot;
if(lots > maxLot) lots = maxLot;
return(NormalizeDouble(lots, 2));
}
//+------------------------------------------------------------------+
//| Smooth Continuous Custom Genetic Fitness Criterion               |
//+------------------------------------------------------------------+
double OnTester()
{
double profit = TesterStatistics(STAT_PROFIT);
double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
double ddPct  = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
double trades = TesterStatistics(STAT_TRADES);
// Require minimum statistical sample (60 trades in 16-month In-Sample) & positive expectancy
if(profit <= 0.0 || trades < 60.0 || pf <= 1.0)
return(0.0);
double tradeFactor = MathMin(trades / 150.0, 2.0);
double ddPenalty   = MathMax(ddPct, 1.0);
return((profit * pf * tradeFactor) / ddPenalty);
}
//+------------------------------------------------------------------+