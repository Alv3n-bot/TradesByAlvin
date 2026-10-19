//+------------------------------------------------------------------+
//| Candle1_2R_Session_EA.mq5                                         |
//| On every closed 1m candle INSIDE the trading window:              |
//|   green -> BUY,  SL = candle low,  TP = entry + 2 x risk          |
//|   red   -> SELL, SL = candle high, TP = entry - 2 x risk          |
//| Lot size is calculated so a stop-out loses ~RiskAmount.           |
//| Trades stack. Optional: force-close at window end, max open       |
//| trades, max spread. All times are BROKER SERVER TIME.             |
//+------------------------------------------------------------------+
#property copyright "Candle1 2R Session EA"
#property version   "1.10"

#include <Trade/Trade.mqh>

input double          RiskAmount       = 10.0;        // Risk per trade (account currency)
input double          RewardRatio      = 2.0;         // Take profit as multiple of risk (2 = 2R)
input ENUM_TIMEFRAMES SignalTF         = PERIOD_M1;   // Candle timeframe used for signals
input ulong           MagicNumber      = 150002;      // Magic number
input int             SlippagePoints   = 20;          // Max slippage (points)

input group "Trading window 1 (server time)"
input bool            UseTimeFilter    = true;        // Only trade inside the window(s)
input int             Win1StartHour    = 3;           // Window 1 start hour
input int             Win1StartMin     = 0;           // Window 1 start minute
input int             Win1EndHour      = 9;           // Window 1 end hour
input int             Win1EndMin       = 15;          // Window 1 end minute

input group "Trading window 2 (optional, server time)"
input bool            UseWindow2       = false;       // Enable a second window
input int             Win2StartHour    = 13;          // Window 2 start hour
input int             Win2StartMin     = 0;           // Window 2 start minute
input int             Win2EndHour      = 16;          // Window 2 end hour
input int             Win2EndMin       = 0;           // Window 2 end minute

input group "Optional safeguards (0 / false = off)"
input bool            CloseOutsideWindow = true;      // Close all this EA's trades when the window ends
input int             MaxOpenPositions = 0;           // Max stacked trades at once (0 = unlimited)
input int             MaxSpreadPoints  = 0;           // Skip entry if spread is above this (0 = no limit)

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
// True if time t falls inside [start, end). Handles windows that cross midnight.
bool InWindow(const datetime t, const int sH, const int sM, const int eH, const int eM)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   const int now   = dt.hour * 60 + dt.min;
   const int start = sH * 60 + sM;
   const int end   = eH * 60 + eM;

   if(start == end)
      return true;                       // same start and end = all day
   if(start < end)
      return (now >= start && now < end);
   return (now >= start || now < end);   // crosses midnight
  }

bool InSession(const datetime t)
  {
   if(!UseTimeFilter)
      return true;
   if(InWindow(t, Win1StartHour, Win1StartMin, Win1EndHour, Win1EndMin))
      return true;
   if(UseWindow2 && InWindow(t, Win2StartHour, Win2StartMin, Win2EndHour, Win2EndMin))
      return true;
   return false;
  }

//+------------------------------------------------------------------+
int CountMyPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         n++;
     }
   return n;
  }

void CloseMyPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if(!trade.PositionClose(ticket))
         PrintFormat("Close failed on #%I64u: retcode=%u (%s)", ticket,
                     trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   const bool inSession = InSession(TimeCurrent());

   // Window over: flatten anything still open
   if(!inSession && UseTimeFilter && CloseOutsideWindow && CountMyPositions() > 0)
      CloseMyPositions();

   datetime barTime = iTime(_Symbol, SignalTF, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return;                       // still the same candle
   g_lastBarTime = barTime;         // a new candle just opened -> bar 1 just closed

   if(!inSession)
      return;                       // outside trading window: no new trades

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
   if(MaxOpenPositions > 0 && CountMyPositions() >= MaxOpenPositions)
     {
      Print("Skipped: max open positions reached");
      return;
     }

   if(MaxSpreadPoints > 0 && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints)
     {
      Print("Skipped: spread above MaxSpreadPoints");
      return;
     }

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