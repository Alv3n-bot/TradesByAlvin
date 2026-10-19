//+------------------------------------------------------------------+
//| GreenRedCandleEA_safe.mq5                                         |
//|   Green candle close -> Buy, SL = candle low,  TP = 2RR          |
//|   Red   candle close -> Sell, SL = candle high, TP = 2RR          |
//|   Lot size from risk %, capped and checked against free margin   |
//|   so orders never get rejected for "not enough money".           |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES InpTimeframe   = PERIOD_CURRENT; // timeframe to watch
input double          InpRiskPercent = 1.0;            // % balance risked per trade
input double          InpRewardRatio = 2.0;            // reward:risk (2.0 = 2RR)
input double          InpMaxLot      = 5.0;            // hard ceiling, no trade ever exceeds this
input ulong           InpMagicNumber = 20260924;

CTrade   trade;
datetime lastBarTime = 0;   // starts at 0 -> first tick scans immediately, no warm-up

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   datetime barTime = iTime(_Symbol, InpTimeframe, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;

   double o = iOpen(_Symbol, InpTimeframe, 1);
   double c = iClose(_Symbol, InpTimeframe, 1);

   if(c > o)      OpenTrade(true,  iLow(_Symbol, InpTimeframe, 1));
   else if(c < o) OpenTrade(false, iHigh(_Symbol, InpTimeframe, 1));
}

void OpenTrade(bool isBuy, double sl)
{
   double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double risk  = isBuy ? (entry - sl) : (sl - entry);
   if(risk <= 0) return;

   //--- Reject candles whose SL distance is too tight for this broker.
   //--- Brokers enforce a minimum stop distance (in points); anything
   //--- closer than that gets rejected as "invalid stops" anyway.
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = stopsLevel * point;
   if(minStopDist > 0 && risk < minStopDist) return;

   double tp  = isBuy ? entry + risk * InpRewardRatio : entry - risk * InpRewardRatio;

   double lot = LotFromRisk(risk);
   lot = FitToMargin(lot, isBuy, entry);
   if(lot <= 0) return;

   if(isBuy) trade.Buy(lot, _Symbol, 0, sl, tp);
   else      trade.Sell(lot, _Symbol, 0, sl, tp);
}

//+------------------------------------------------------------------+
//| Calculates lot size from risk %, then hard-caps it at InpMaxLot  |
//| so one tiny-range candle can never produce an oversized trade.   |
//+------------------------------------------------------------------+
double LotFromRisk(double riskDistance)
{
   double moneyRisk  = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0) return 0;

   double lot = moneyRisk / ((riskDistance / tickSize) * tickValue);

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lot = MathFloor(lot / step) * step;
   lot = MathMax(minL, MathMin(lot, maxL));
   lot = MathMin(lot, InpMaxLot);          // <-- hard ceiling, regardless of the math above

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Checks the lot against ACTUAL free margin right now, and shrinks |
//| it to whatever fits rather than letting the broker reject it.    |
//| This is the piece that directly eliminates "not enough money".  |
//+------------------------------------------------------------------+
double FitToMargin(double lot, bool isBuy, double entry)
{
   if(lot <= 0) return 0;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double neededMargin;
   ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if(!OrderCalcMargin(orderType, _Symbol, lot, entry, neededMargin))
      return 0; // couldn't even calculate margin -> don't risk sending the order

   // Leave a small buffer (use only 95% of free margin) so price
   // wiggling a bit before the order fills doesn't tip it into rejection.
   double usableMargin = freeMargin * 0.95;

   if(neededMargin <= usableMargin)
      return lot; // ideal lot already fits, nothing to shrink

   // Doesn't fit -> scale the lot down proportionally to what DOES fit.
   double scaledLot = lot * (usableMargin / neededMargin);

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   scaledLot = MathFloor(scaledLot / step) * step;

   if(scaledLot < minL)
      return 0; // even the smallest allowed lot wouldn't fit -> skip this trade entirely

   return NormalizeDouble(scaledLot, 2);
}