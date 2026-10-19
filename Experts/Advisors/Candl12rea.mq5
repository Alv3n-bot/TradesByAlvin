//+------------------------------------------------------------------+
//| Candle1_2R_EA.mq5                                                 |
//| On every closed 1m candle:                                        |
//|   green -> BUY,  SL = candle low,  TP = entry + 2 x risk          |
//|   red   -> SELL, SL = candle high, TP = entry - 2 x risk          |
//| Lot size is calculated so a stop-out loses ~RiskAmount.           |
//| Trades stack: no check on existing positions.                     |
//+------------------------------------------------------------------+
#property copyright "Candle1 2R EA"
#property version   "1.00"

#include <Trade/Trade.mqh>

input double          RiskAmount     = 10.0;        // Risk per trade (account currency)
input double          RewardRatio    = 2.0;         // Take profit as multiple of risk (2 = 2R)
input ENUM_TIMEFRAMES SignalTF       = PERIOD_M1;   // Candle timeframe used for signals
input ulong           MagicNumber    = 150001;      // Magic number (different from the M15 EA)
input int             SlippagePoints = 20;          // Max slippage (points)

CTrade   trade;
datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(RiskAmount <= 0.0 || RewardRatio <= 0.0)
     {
      Print("RiskAmount and RewardRatio must be greater than 0");
      return INIT_PARAMETERS_INCORRECT;
     }
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Start from the current bar so nothing fires until the next candle closes
   g_lastBarTime = iTime(_Symbol, SignalTF, 0);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime barTime = iTime(_Symbol, SignalTF, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return;                       // still the same candle
   g_lastBarTime = barTime;         // a new candle just opened -> bar 1 just closed

   double o = iOpen (_Symbol, SignalTF, 1);
   double h = iHigh (_Symbol, SignalTF, 1);
   double l = iLow  (_Symbol, SignalTF, 1);
   double c = iClose(_Symbol, SignalTF, 1);

   if(c > o)
      OpenTrade(ORDER_TYPE_BUY, l);     // green candle
   else if(c < o)
      OpenTrade(ORDER_TYPE_SELL, h);    // red candle
   // doji (close == open): no trade
  }

//+------------------------------------------------------------------+
void OpenTrade(const ENUM_ORDER_TYPE type, const double slRaw)
  {
   const bool isBuy = (type == ORDER_TYPE_BUY);
   const double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double sl   = NormalizeDouble(slRaw, _Digits);
   const double dist = isBuy ? (entry - sl) : (sl - entry);

   if(dist <= 0.0)
     {
      Print("Skipped: price already beyond the stop level");
      return;
     }

   const double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dist <= minDist)
     {
      Print("Skipped: stop distance is inside the broker's minimum stop level");
      return;
     }

   const double tp = NormalizeDouble(isBuy ? entry + dist * RewardRatio
                                           : entry - dist * RewardRatio, _Digits);

   const double lots = CalcLots(type, entry, sl);
   if(lots <= 0.0)
      return;

   // Margin check
   double margin = 0.0;
   if(OrderCalcMargin(type, _Symbol, lots, entry, margin) &&
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      Print("Skipped: not enough free margin for ", DoubleToString(lots, 2), " lots");
      return;
     }

   if(!trade.PositionOpen(_Symbol, type, lots, entry, sl, tp, "C1 2R"))
      PrintFormat("Order failed: retcode=%u (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
// Lots such that (entry -> SL) loses about RiskAmount. Rounds DOWN.
double CalcLots(const ENUM_ORDER_TYPE type, const double entry, const double sl)
  {
   double profit = 0.0;
   if(!OrderCalcProfit(type, _Symbol, 1.0, entry, sl, profit) || profit >= 0.0)
     {
      Print("Skipped: could not calculate loss per lot");
      return 0.0;
     }

   const double lossPerLot = MathAbs(profit);
   double lots = RiskAmount / lossPerLot;

   const double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / step + 1e-8) * step;

   if(lots < minLot)
     {
      PrintFormat("Skipped: %.2f lots needed for %.2f risk is below min lot %.2f",
                  lots, RiskAmount, minLot);
      return 0.0;
     }
   if(lots > maxLot)
      lots = maxLot;

   const int lotDigits = (int)MathMax(0.0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lots, lotDigits);
  }
//+------------------------------------------------------------------+