//+------------------------------------------------------------------+
//| Candle15_2R_Session_News_Target_EA.mq5                            |
//| On every closed 15m candle INSIDE the trading window:             |
//|   green -> BUY,  SL = candle low,  TP = entry + 2 x risk          |
//|   red   -> SELL, SL = candle high, TP = entry - 2 x risk          |
//| Lot size is calculated so a stop-out loses ~RiskAmount.           |
//| Trades stack. Filters: time window(s), weekdays, news days        |
//| (news day + the trading day before it, read from a text file).    |
//| Daily profit target: closes everything and stops for the day.    |
//| All times are BROKER SERVER TIME.                                 |
//+------------------------------------------------------------------+
#property copyright "Candle15 2R Session News Target EA"
#property version   "1.30"

#include <Trade/Trade.mqh>

input double          RiskAmount       = 10.0;        // Risk per trade (account currency)
input double          RewardRatio      = 2.0;         // Take profit as multiple of risk (2 = 2R)
input ENUM_TIMEFRAMES SignalTF         = PERIOD_M15;  // Candle timeframe used for signals
input ulong           MagicNumber      = 150018;      // Magic number
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

input group "Weekday filter (server time)"
input bool            TradeMonday      = true;        // Allow Monday
input bool            TradeTuesday     = true;        // Allow Tuesday
input bool            TradeWednesday   = true;        // Allow Wednesday
input bool            TradeThursday    = true;        // Allow Thursday
input bool            TradeFriday      = true;        // Allow Friday

input group "News-day filter"
input bool            UseNewsFilter    = true;        // Skip news days (and the day before)
input bool            BlockDayBefore   = true;        // Also skip the trading day before each news day
input string          NewsDatesFile    = "news_dates.txt"; // In Common\Files, one YYYY.MM.DD per line

input group "Daily profit target (0 = off)"
input double          DailyProfitTarget    = 30.0;    // Closed profit today + open profit >= this: close all, stop for the day
input double          FloatingProfitTarget = 30.0;    // Open (unrealised) profit alone >= this: close all, stop for the day

input group "Optional safeguards (0 / false = off)"
input bool            CloseOutsideWindow = true;      // Close all this EA's trades when the window ends
input int             MaxOpenPositions = 0;           // Max stacked trades at once (0 = unlimited)
input int             MaxSpreadPoints  = 0;           // Skip entry if spread is above this (0 = no limit)

CTrade   trade;
datetime g_lastBarTime = 0;
datetime g_blocked[];                 // midnight timestamps of blocked days
datetime g_lockDay      = 0;          // server date on which the profit target was hit
double   g_realized     = 0.0;        // cached closed P/L of this EA today
datetime g_realizedDay  = 0;          // day the cache belongs to
int      g_lastPosCount = -1;         // position count when the cache was refreshed

//+------------------------------------------------------------------+
int OnInit()
  {
   if(RiskAmount <= 0.0 || RewardRatio <= 0.0)
     {
      Print("RiskAmount and RewardRatio must be greater than 0");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(UseNewsFilter && !LoadNewsDates())
      return INIT_FAILED;           // refuse to run with a missing file instead of silently trading news days

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Start from the current bar so nothing fires until the next candle closes
   g_lastBarTime = iTime(_Symbol, SignalTF, 0);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
// Time window helpers
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
// Weekday filter
int DayOfWeekOf(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.day_of_week;                // 0 = Sunday ... 6 = Saturday
  }

bool DayAllowed(const datetime t)
  {
   switch(DayOfWeekOf(t))
     {
      case 1: return TradeMonday;
      case 2: return TradeTuesday;
      case 3: return TradeWednesday;
      case 4: return TradeThursday;
      case 5: return TradeFriday;
     }
   return true;                          // Sat/Sun: market is normally closed anyway
  }

//+------------------------------------------------------------------+
// News-day filter
void AddBlocked(const datetime d)
  {
   const int n = ArraySize(g_blocked);
   ArrayResize(g_blocked, n + 1);
   g_blocked[n] = d;
  }

// Reads one date per line (YYYY.MM.DD, anything after the date is ignored).
// Blocks that day, and optionally the previous trading day (Mon -> previous Friday).
bool LoadNewsDates()
  {
   ArrayResize(g_blocked, 0);

   const int h = FileOpen(NewsDatesFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("News file '%s' not found in the Common\\Files folder (error %d). "
                  "Put it in MetaQuotes\\Terminal\\Common\\Files or turn UseNewsFilter off.",
                  NewsDatesFile, GetLastError());
      return false;
     }

   int count = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) == 0)
         continue;
      const ushort first = StringGetCharacter(line, 0);
      if(first == '#' || first == '/')
         continue;                       // comment line

      // find the first digit (also skips a stray BOM)
      int p = 0;
      const int n = StringLen(line);
      while(p < n)
        {
         const ushort ch = StringGetCharacter(line, p);
         if(ch >= '0' && ch <= '9')
            break;
         p++;
        }
      if(n - p < 10)
         continue;

      const string ds = StringSubstr(line, p, 10);
      if(StringGetCharacter(ds, 4) != '.' || StringGetCharacter(ds, 7) != '.')
         continue;

      const datetime d = StringToTime(ds);
      if(d <= 0)
         continue;

      AddBlocked(d);
      count++;

      if(BlockDayBefore)
        {
         datetime prev = d - 86400;
         while(DayOfWeekOf(prev) == 0 || DayOfWeekOf(prev) == 6)
            prev -= 86400;                // skip the weekend
         AddBlocked(prev);
        }
     }
   FileClose(h);

   PrintFormat("News filter: loaded %d news dates, %d blocked days in total", count, ArraySize(g_blocked));
   if(count == 0)
     {
      Print("News file has no valid dates. Format: YYYY.MM.DD, one per line.");
      return false;
     }
   return true;
  }

bool IsNewsBlocked(const datetime t)
  {
   const datetime day = DayStartOf(t);
   const int n = ArraySize(g_blocked);
   for(int i = 0; i < n; i++)
      if(g_blocked[i] == day)
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
datetime DayStartOf(const datetime t)
  {
   return (datetime)((long)t - ((long)t % 86400));   // midnight of that server date
  }

bool IsLockedToday(const datetime t)
  {
   return (g_lockDay != 0 && g_lockDay == DayStartOf(t));
  }

// Closed P/L of this EA (this symbol + magic) since server midnight, incl. swap and commission
double RealizedToday()
  {
   const datetime now = TimeCurrent();
   if(!HistorySelect(DayStartOf(now), now + 60))
      return 0.0;

   double total = 0.0;
   const int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      const ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol ||
         (ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber)
         continue;
      const ENUM_DEAL_TYPE dt = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(dt != DEAL_TYPE_BUY && dt != DEAL_TYPE_SELL)
         continue;
      total += HistoryDealGetDouble(ticket, DEAL_PROFIT)
             + HistoryDealGetDouble(ticket, DEAL_SWAP)
             + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
             + HistoryDealGetDouble(ticket, DEAL_FEE);
     }
   return total;
  }

// Open (unrealised) P/L of this EA's positions
double FloatingProfit()
  {
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return total;
  }

// Locks the day and closes everything once a profit target is reached.
// The closed-P/L history is only re-read when something changed (new day,
// position opened/closed, new candle), so this is cheap to call every tick.
void CheckDailyTarget(const bool refresh)
  {
   if(DailyProfitTarget <= 0.0 && FloatingProfitTarget <= 0.0)
      return;

   const datetime now   = TimeCurrent();
   const datetime today = DayStartOf(now);
   if(g_lockDay == today)
      return;                            // already locked for today

   const int posCount = CountMyPositions();
   if(refresh || today != g_realizedDay || posCount != g_lastPosCount)
     {
      g_realized     = RealizedToday();
      g_realizedDay  = today;
      g_lastPosCount = posCount;
     }

   const double floating = (posCount > 0) ? FloatingProfit() : 0.0;
   const bool hitTotal   = (DailyProfitTarget    > 0.0 && (g_realized + floating) >= DailyProfitTarget);
   const bool hitFloat   = (FloatingProfitTarget > 0.0 && floating >= FloatingProfitTarget);

   if(hitTotal || hitFloat)
     {
      g_lockDay = today;
      PrintFormat("Profit target hit: closed %.2f + open %.2f. Closing all trades, no more entries today.",
                  g_realized, floating);
      if(posCount > 0)
         CloseMyPositions();
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   const datetime now = TimeCurrent();
   const bool inSession = InSession(now);

   // Daily profit target: checked every tick; retry the close if it did not go through
   CheckDailyTarget(false);
   if(IsLockedToday(now) && CountMyPositions() > 0)
      CloseMyPositions();

   // Window over: flatten anything still open
   if(!inSession && UseTimeFilter && CloseOutsideWindow && CountMyPositions() > 0)
      CloseMyPositions();

   datetime barTime = iTime(_Symbol, SignalTF, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return;                       // still the same candle
   g_lastBarTime = barTime;         // a new candle just opened -> bar 1 just closed

   CheckDailyTarget(true);          // refresh today's closed P/L before deciding on a new entry

   if(!inSession)
      return;                       // outside trading window: no new trades
   if(!DayAllowed(now))
      return;                       // weekday switched off
   if(UseNewsFilter && IsNewsBlocked(now))
      return;                       // news day or the day before: no new trades
   if(IsLockedToday(now))
      return;                       // daily profit target already hit: done for today

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

   if(!trade.PositionOpen(_Symbol, type, lots, entry, sl, tp, "C15 2R"))
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