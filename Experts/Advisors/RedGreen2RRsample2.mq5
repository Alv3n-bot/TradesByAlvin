//+------------------------------------------------------------------+
//|                                              RedGreen2RR.mq5      |
//|   Strategy:                                                       |
//|   - When a candle CLOSES RED  -> SELL at market (close price)     |
//|       SL = that candle's HIGH                                     |
//|       TP = 2 x Risk (Reward:Risk = 2)                             |
//|   - When a candle CLOSES GREEN -> BUY at market (close price)     |
//|       SL = that candle's LOW                                      |
//|       TP = 2 x Risk                                                |
//|   - Works on any timeframe the EA is attached to                  |
//|   - Trades every new closed candle (subject to input filters)     |
//+------------------------------------------------------------------+
#property copyright "Alvin"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs
input double   RiskPercent        = 1.0;     // % of account balance to risk per trade
input double   RewardToRisk       = 2.0;     // Take profit multiple of risk (2 = 2RR)
input ulong    MagicNumber        = 202608;  // EA magic number
input bool     OnlyOneTradeAtTime = true;    // If true, skip new signal while a position from this EA is open
input int      SlippagePoints     = 10;      // Allowed slippage in points

input bool     UseSessionWindow   = true;    // If true, only trade within the NY time window below
input int      SessionStartHour   = 3;       // NY time - start allowing new trades (24h)
input int      SessionStartMin    = 0;
input int      SessionEndHour     = 9;       // NY time - stop allowing NEW trades (24h)
input int      SessionEndMin      = 15;
input int      FlattenHour        = 9;       // NY time - force close ALL open trades from this EA
input int      FlattenMin         = 29;

//--- Globals
datetime lastBarTime = 0;
int      lastFlattenDay = -1;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   lastBarTime = 0;
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
//| Check if there's already an open position from this EA/symbol     |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Calculate lot size so that hitting SL loses RiskPercent% of       |
//| current account balance (compounds automatically as balance moves)|
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePrice)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (RiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0 || slDistancePrice <= 0)
      return 0.0;

   // Value of the SL distance for 1.0 lot
   double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0)
      return 0.0;

   double lots = riskMoney / lossPerLot;

   // Normalize to broker's allowed lot step/min/max
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / lotStep) * lotStep; // round down so we never over-risk
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Is a given GMT datetime within US Daylight Saving Time?           |
//| Rule: 2nd Sunday of March 02:00 -> 1st Sunday of November 02:00   |
//+------------------------------------------------------------------+
bool IsUSDaylightSaving(datetime gmt)
  {
   MqlDateTime t;
   TimeToStruct(gmt, t);
   int year = t.year;

   // Find 2nd Sunday of March
   datetime march1 = StringToTime(IntegerToString(year) + ".03.01 00:00");
   MqlDateTime m1;
   TimeToStruct(march1, m1);
   int marchFirstSundayOffset = (7 - m1.day_of_week) % 7;
   int marchSecondSunday = 1 + marchFirstSundayOffset + 7;
   datetime dstStart = StringToTime(IntegerToString(year) + ".03." + IntegerToString(marchSecondSunday) + " 07:00"); // 2am local EST = 7am GMT

   // Find 1st Sunday of November
   datetime nov1 = StringToTime(IntegerToString(year) + ".11.01 00:00");
   MqlDateTime n1;
   TimeToStruct(nov1, n1);
   int novFirstSundayOffset = (7 - n1.day_of_week) % 7;
   int novFirstSunday = 1 + novFirstSundayOffset;
   datetime dstEnd = StringToTime(IntegerToString(year) + ".11." + IntegerToString(novFirstSunday) + " 06:00"); // 2am local EDT = 6am GMT

   return (gmt >= dstStart && gmt < dstEnd);
  }

//+------------------------------------------------------------------+
//| Get current true New York wall-clock time as hour*60+minute       |
//+------------------------------------------------------------------+
int GetNYMinutesOfDay()
  {
   datetime gmt = TimeGMT();
   int offsetHours = IsUSDaylightSaving(gmt) ? -4 : -5;
   datetime nyTime = gmt + offsetHours * 3600;

   MqlDateTime t;
   TimeToStruct(nyTime, t);
   return t.hour * 60 + t.min;
  }

//+------------------------------------------------------------------+
//| Close every open position belonging to this EA on this symbol     |
//+------------------------------------------------------------------+
void CloseAllEAPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
        {
         trade.PositionClose(ticket);
        }
     }
  }

//+------------------------------------------------------------------+
//| Detect a new bar (candle just closed)                             |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime != lastBarTime)
     {
      lastBarTime = currentBarTime;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Flatten check runs on EVERY tick, not just new bars, so the
   //--- close happens as close to FlattenHour:FlattenMin as possible
   if(UseSessionWindow)
     {
      int nyMinutesNow = GetNYMinutesOfDay();
      int flattenMinutes = FlattenHour * 60 + FlattenMin;

      MqlDateTime nowStruct;
      TimeToStruct(TimeGMT(), nowStruct);
      int todayKey = nowStruct.year * 10000 + nowStruct.mon * 100 + nowStruct.day;

      if(nyMinutesNow >= flattenMinutes && lastFlattenDay != todayKey)
        {
         if(HasOpenPosition())
            CloseAllEAPositions();
         lastFlattenDay = todayKey; // don't re-trigger again today
        }
     }

   if(!IsNewBar())
      return;

   // Index 1 = the candle that just closed (index 0 = current forming candle)
   double openPrev  = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double closePrev = iClose(_Symbol, PERIOD_CURRENT, 1);
   double highPrev  = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double lowPrev   = iLow(_Symbol, PERIOD_CURRENT, 1);

   if(OnlyOneTradeAtTime && HasOpenPosition())
      return;

   //--- Session window gate: only allow NEW entries inside the window
   if(UseSessionWindow)
     {
      int nyMinutesNow    = GetNYMinutesOfDay();
      int sessionStart    = SessionStartHour * 60 + SessionStartMin;
      int sessionEnd      = SessionEndHour * 60 + SessionEndMin;

      if(nyMinutesNow < sessionStart || nyMinutesNow >= sessionEnd)
         return; // outside trading window - EA stays on, just won't open new trades
     }

   double point = _Point;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //--- RED candle -> SELL
   if(closePrev < openPrev)
     {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID); // sell fills at bid
      double sl    = highPrev;
      double risk  = sl - entry;

      if(risk <= 0)
         return; // sanity check, avoid invalid SL

      double tp = entry - RewardToRisk * risk;
      double lots = CalculateLotSize(risk);

      if(lots <= 0)
         return; // risk too small for min lot, or bad symbol data - skip trade

      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);

      trade.Sell(lots, _Symbol, entry, sl, tp, "RedCandleSell");
     }
   //--- GREEN candle -> BUY
   else if(closePrev > openPrev)
     {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK); // buy fills at ask
      double sl    = lowPrev;
      double risk  = entry - sl;

      if(risk <= 0)
         return;

      double tp = entry + RewardToRisk * risk;
      double lots = CalculateLotSize(risk);

      if(lots <= 0)
         return; // risk too small for min lot, or bad symbol data - skip trade

      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);

      trade.Buy(lots, _Symbol, entry, sl, tp, "GreenCandleBuy");
     }
   //--- Doji (close == open) -> no trade
  }
//+------------------------------------------------------------------+