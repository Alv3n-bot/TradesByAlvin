//+------------------------------------------------------------------+
//| ICT_NAS100_Sweep_EA_Full.mq5                                     |
//| Version 1.10 (full)                                              |
//| Liquidity sweep -> displacement + MSS -> limit entry             |
//| Defaults reproduce the approved version 1 rules exactly.         |
//| Every planned experiment (stage 4) is an input.                  |
//+------------------------------------------------------------------+
#property copyright "ICT NAS100 Sweep EA"
#property version   "1.10"
#property description "NAS100 ICT model. Run on M5 (or M1 for the 1-minute experiment)."
#property description "Check InpServerMinusNYHours against your broker before testing."

#include <Trade\Trade.mqh>

enum ENUM_TP_MODE    { TP_LIQUIDITY = 0, TP_FIXED_R = 1 };
enum ENUM_ENTRY_MODE { ENTRY_FVG_50 = 0, ENTRY_FVG_EDGE = 1, ENTRY_OTE = 2, ENTRY_OB = 3 };
enum ENUM_BIAS_MODE  { BIAS_NONE = 0, BIAS_H4_AND_MID = 1, BIAS_H4_ONLY = 2, BIAS_MID_ONLY = 3 };

//--- Risk
input group "Risk"
input double InpRiskUSD            = 10.0;   // fixed risk per trade (account currency)
input int    InpMaxTradesPerDay    = 2;      // 2nd trade only after a loss
input double InpDailyLossR         = 2.0;    // stop for the day after this many R lost
input double InpWeeklyLossR        = 5.0;    // stop for the week after this many R lost
input double InpKillDDR            = 10.0;   // kill switch: drawdown from equity peak in R
input bool   InpResetPeak          = false;  // true once to reset the stored equity peak after a kill
input double InpMaxSpread          = 5.0;    // max spread in price units, 0 = off
input bool   InpAllowMinLot        = false;  // if the minimum lot risks more than the budget, still trade the minimum lot (testing only)

//--- Time (all New York time, minutes after midnight)
input group "Time (New York)"
input int    InpServerMinusNYHours = 7;      // broker server time minus New York time, in hours
input int    InpWindowStartMin     = 570;    // 09:30  (London test: 120)
input int    InpWindowEndMin       = 660;    // 11:00  (London test: 300)
input int    InpCancelMin          = 690;    // 11:30  (London test: 330)
input int    InpExitMin            = 720;    // 12:00  (London test: 360)
input int    InpAsianStartMin      = 1200;   // 20:00 previous evening to 00:00
input int    InpLondonStartMin     = 120;    // 02:00
input int    InpLondonEndMin       = 420;    // 07:00  (London levels are skipped if the window starts before this)

//--- Strategy
input group "Strategy"
input ENUM_TIMEFRAMES InpTF        = PERIOD_M5;
input int    InpSwingN             = 2;      // fractal width
input int    InpAtrPeriod          = 14;
input double InpSweepMinDepthATR   = 0.05;   // minimum sweep depth, in ATR
input int    InpSweepConfirmBars   = 3;      // candles allowed to close back inside
input double InpDispBodyATR        = 1.2;    // displacement body >= this x ATR
input double InpDispCloseFrac      = 0.65;   // close in outer part of the candle range
input int    InpMSSMaxBars         = 12;     // MSS must come within this many bars of the sweep
input double InpEqTolATR           = 0.10;   // equal highs/lows tolerance, in ATR

//--- Sweep triggers (which levels can start a setup)
input group "Sweep triggers"
input bool   InpTrigAsian          = true;
input bool   InpTrigLondon         = true;
input bool   InpTrigPrevDay        = true;
input bool   InpTrigEqual          = false;  // equal highs/lows as triggers (targets only when false)

//--- Entry
input group "Entry"
input ENUM_ENTRY_MODE InpEntryMode = ENTRY_FVG_50;
input double InpOTELevel           = 0.705;  // retracement of the displacement leg for ENTRY_OTE (0.62 - 0.79)
input int    InpFVGWaitBars        = 3;      // bars to wait for the FVG after the MSS
input double InpMinFVGATR          = 0.10;   // minimum gap size, in ATR
input int    InpPendingMaxBars     = 6;      // cancel unfilled limit order after this many bars

//--- Stop and target
input group "Stop and target"
input double InpSLBufferATR        = 0.10;   // stop buffer (plus spread), in ATR
input double InpMaxStopATR         = 3.0;    // skip if stop is wider than this x ATR
input ENUM_TP_MODE InpTPMode       = TP_LIQUIDITY;
input double InpMinRR              = 2.0;    // liquidity target must be at least this many R away
input double InpFixedR             = 2.0;    // used when TP mode = fixed R
input double InpTPBufferATR        = 0.05;   // place target this far before the level, in ATR

//--- Trade management (all off by default = version 1)
input group "Trade management"
input double InpBreakevenAtR       = 0.0;    // move stop to entry at this R, 0 = off
input double InpPartialAtR         = 0.0;    // take partial profit at this R, 0 = off
input double InpPartialPct         = 50.0;   // percent of the position closed at the partial
input double InpTrailStartR        = 0.0;    // start ATR trailing at this R, 0 = off
input double InpTrailATR           = 1.0;    // trailing distance in ATR (ATR measured at order time)

//--- Filters
input group "Filters"
input ENUM_BIAS_MODE InpBiasMode   = BIAS_H4_AND_MID;
input double InpMaxRangeADR        = 0.0;    // skip if today's range so far > this x average daily range, 0 = off
input string InpSkipDates          = "";     // YYYY.MM.DD list (news days, day before, holidays), comma separated

//--- Misc
input group "Misc"
input long   InpMagic              = 20261017;
input bool   InpDraw               = true;
input bool   InpLog                = true;
input bool   InpPrint              = true;   // also print events to the Journal tab

#define LOGFILE "ICT_NAS100_v1_log.csv"

struct SLevel
{
   string   name;
   double   price;
   bool     isHigh;     // true = buy-side liquidity (above), false = sell-side (below)
   bool     trigger;    // true = can be swept to start a setup, false = target only
   int      state;      // 0 fresh, 1 sweep candidate, 2 consumed
   int      candBars;
   double   candExtreme;
   datetime candTime;
};

CTrade   trade;
SLevel   g_levels[];

int      g_state = 0;              // 0 idle, 1 swept (wait MSS), 5 MSS (wait entry zone), 2 order pending, 3 in trade, 4 done
int      g_dir = 0;                // +1 long, -1 short
int      g_dayIdx = -1;
bool     g_levelsReady = false;
bool     g_dayBlocked = false;
bool     g_allowLong = false;
bool     g_allowShort = false;
datetime g_lastBar = 0;
datetime g_dayStart = 0;           // server time of NY midnight
datetime g_weekStart = 0;          // server time of NY Monday midnight
int      g_tradesToday = 0;

double   g_sweepExtreme = 0;
datetime g_sweepExtremeTime = 0;
string   g_sweepLevel = "";
double   g_swingRef = 0;
int      g_barsSinceSweep = 0;
int      g_fvgWait = 0;
int      g_pendBars = 0;
double   g_fvgLow = 0, g_fvgHigh = 0;
double   g_atrOrder = 0;

datetime g_fillTime = 0;
double   g_riskDist = 0;
bool     g_partialDone = false;
bool     g_beDone = false;

double   g_peak = 0;
bool     g_kill = false;
string   g_peakKey = "";

// funnel counters (printed when the EA stops, so you can see where setups die)
int      c_days = 0, c_noBias = 0, c_over = 0, c_sweeps = 0, c_mss = 0, c_zone = 0, c_orders = 0, c_skipOrder = 0, c_fills = 0;
bool     g_dayLogged = false;

//+------------------------------------------------------------------+
//| Time helpers                                                     |
//+------------------------------------------------------------------+
datetime NYT(datetime t) { return (datetime)((long)t - (long)InpServerMinusNYHours * 3600); }
int NYDay(datetime t)    { return (int)((long)NYT(t) / 86400); }
int NYMin(datetime t)    { return (int)(((long)NYT(t) % 86400) / 60); }

//+------------------------------------------------------------------+
//| Logging                                                          |
//+------------------------------------------------------------------+
void Lg(string ev, string detail)
{
   if(InpPrint && ev != "LEVEL") Print(ev, " | ", detail);
   if(!InpLog) return;
   int h = FileOpen(LOGFILE, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, TimeToString(NYT(TimeCurrent()), TIME_DATE | TIME_MINUTES) + ";" + ev + ";" + detail + "\r\n");
   FileClose(h);
}

//+------------------------------------------------------------------+
//| Drawing                                                          |
//+------------------------------------------------------------------+
void DrawLine(string name, double price, color c, datetime t1, datetime t2, string tip)
{
   if(!InpDraw) return;
   string nm = "ICT_" + name + "_" + TimeToString(t1, TIME_DATE);
   if(ObjectFind(0, nm) >= 0) ObjectDelete(0, nm);
   ObjectCreate(0, nm, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
   ObjectSetInteger(0, nm, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, nm, OBJPROP_RAY_RIGHT, false);
   ObjectSetString(0, nm, OBJPROP_TOOLTIP, tip);
}

void DrawMark(string name, datetime t, double price, color c)
{
   if(!InpDraw) return;
   string nm = "ICT_" + name + "_" + TimeToString(t, TIME_DATE | TIME_MINUTES);
   if(ObjectFind(0, nm) >= 0) ObjectDelete(0, nm);
   ObjectCreate(0, nm, OBJ_ARROW, 0, t, price);
   ObjectSetInteger(0, nm, OBJPROP_ARROWCODE, 159);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
   ObjectSetString(0, nm, OBJPROP_TOOLTIP, name);
}

void DrawZone(datetime t1, datetime t2, double lo, double hi)
{
   if(!InpDraw) return;
   string nm = "ICT_ZONE_" + TimeToString(t1, TIME_DATE | TIME_MINUTES);
   if(ObjectFind(0, nm) >= 0) ObjectDelete(0, nm);
   ObjectCreate(0, nm, OBJ_RECTANGLE, 0, t1, lo, t2, hi);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, nm, OBJPROP_FILL, true);
   ObjectSetInteger(0, nm, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| Price / structure helpers                                        |
//+------------------------------------------------------------------+
double NT(double p)
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) return NormalizeDouble(p, _Digits);
   return NormalizeDouble(MathRound(p / ts) * ts, _Digits);
}

bool IsSwingHigh(const MqlRates &r[], int k, int n)
{
   if(k - n < 1 || k + n >= ArraySize(r)) return false;
   for(int j = 1; j <= n; j++)
      if(r[k].high <= r[k - j].high || r[k].high <= r[k + j].high) return false;
   return true;
}

bool IsSwingLow(const MqlRates &r[], int k, int n)
{
   if(k - n < 1 || k + n >= ArraySize(r)) return false;
   for(int j = 1; j <= n; j++)
      if(r[k].low >= r[k - j].low || r[k].low >= r[k + j].low) return false;
   return true;
}

double ATRat(const MqlRates &r[], int shift)
{
   int n = InpAtrPeriod;
   if(shift + n + 1 >= ArraySize(r)) return 0;
   double s = 0;
   for(int i = shift; i < shift + n; i++)
   {
      double pc = r[i + 1].close;
      double tr = MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - pc), MathAbs(r[i].low - pc)));
      s += tr;
   }
   return s / n;
}

int ShiftOfTime(const MqlRates &r[], datetime t)
{
   for(int i = 0; i < ArraySize(r); i++)
      if(r[i].time == t) return i;
   return -1;
}

//--- last confirmed 4H break of structure: +1 up, -1 down, 0 none
int H4Bias()
{
   MqlRates h[];
   ArraySetAsSeries(h, true);
   int n = CopyRates(_Symbol, PERIOD_H4, 0, 120, h);
   if(n < 30) return 0;
   double lastSH = 0, lastSL = 0;
   int bias = 0;
   for(int k = n - 2; k >= 1; k--)
   {
      int s = k + InpSwingN;
      if(s + InpSwingN < n)
      {
         if(IsSwingHigh(h, s, InpSwingN)) lastSH = h[s].high;
         if(IsSwingLow(h, s, InpSwingN))  lastSL = h[s].low;
      }
      if(lastSH > 0 && h[k].close > lastSH) { bias = 1;  lastSH = 0; }
      if(lastSL > 0 && h[k].close < lastSL) { bias = -1; lastSL = 0; }
   }
   return bias;
}

string EntryModeName()
{
   switch(InpEntryMode)
   {
      case ENTRY_FVG_50:   return "FVG 50%";
      case ENTRY_FVG_EDGE: return "FVG near edge";
      case ENTRY_OTE:      return "OTE";
      case ENTRY_OB:       return "order block";
   }
   return "?";
}

//+------------------------------------------------------------------+
//| Level map                                                        |
//+------------------------------------------------------------------+
void AddLevel(string name, double price, bool isHigh, bool trigger, double refClose)
{
   int c = ArraySize(g_levels);
   ArrayResize(g_levels, c + 1);
   g_levels[c].name = name;
   g_levels[c].price = price;
   g_levels[c].isHigh = isHigh;
   g_levels[c].trigger = trigger;
   g_levels[c].state = 0;
   g_levels[c].candBars = 0;
   g_levels[c].candExtreme = 0;
   g_levels[c].candTime = 0;
   // already beyond the level at window start = already swept before the window
   if(isHigh ? (refClose > price) : (refClose < price)) g_levels[c].state = 2;
   Lg("LEVEL", name + " " + DoubleToString(price, _Digits) + (trigger ? " trigger" : " target") + (g_levels[c].state == 2 ? " (already taken)" : ""));
}

void AddEqual(const MqlRates &r[], bool isHigh, double refClose, double atr)
{
   double tol = InpEqTolATR * atr;
   int idx[];
   ArrayResize(idx, 0);
   for(int k = InpSwingN + 1; k < 260; k++)
   {
      bool sw = isHigh ? IsSwingHigh(r, k, InpSwingN) : IsSwingLow(r, k, InpSwingN);
      if(sw)
      {
         int c = ArraySize(idx);
         ArrayResize(idx, c + 1);
         idx[c] = k;
      }
   }
   for(int a = 0; a < ArraySize(idx); a++)
   {
      for(int b = a + 1; b < ArraySize(idx); b++)
      {
         double pa = isHigh ? r[idx[a]].high : r[idx[a]].low;
         double pb = isHigh ? r[idx[b]].high : r[idx[b]].low;
         if(MathAbs(pa - pb) <= tol)
         {
            double lvl = isHigh ? MathMax(pa, pb) : MathMin(pa, pb);
            bool unswept = true;
            for(int j = 1; j < idx[a]; j++)
            {
               if(isHigh ? (r[j].high > lvl) : (r[j].low < lvl)) { unswept = false; break; }
            }
            if(unswept)
            {
               AddLevel(isHigh ? "EQH" : "EQL", lvl, isHigh, InpTrigEqual, refClose);
               return;
            }
            break;
         }
      }
   }
}

void BuildLevels()
{
   MqlRates rr[];
   ArraySetAsSeries(rr, true);
   int n = CopyRates(_Symbol, InpTF, 0, 1800, rr);
   if(n < 600) { g_dayBlocked = true; Lg("SKIP", "not enough history"); return; }

   datetime t0 = rr[0].time;
   int today = NYDay(t0);
   double aH = 0, aL = 0, lH = 0, lL = 0, tH = 0, tL = 0;
   double dH[8], dL[8];
   int dC[8];
   ArrayInitialize(dH, 0);
   ArrayInitialize(dL, 0);
   ArrayInitialize(dC, 0);

   for(int i = 1; i < n; i++)
   {
      int d = NYDay(rr[i].time);
      int m = NYMin(rr[i].time);
      int k = today - d;
      if(k < 0) continue;
      if(k > 7) break;
      if(k == 0)
      {
         tH = (tH == 0) ? rr[i].high : MathMax(tH, rr[i].high);
         tL = (tL == 0) ? rr[i].low  : MathMin(tL, rr[i].low);
      }
      if(k == 1 && m >= InpAsianStartMin)
      {
         aH = (aH == 0) ? rr[i].high : MathMax(aH, rr[i].high);
         aL = (aL == 0) ? rr[i].low  : MathMin(aL, rr[i].low);
      }
      if(k == 0 && m >= InpLondonStartMin && m < InpLondonEndMin)
      {
         lH = (lH == 0) ? rr[i].high : MathMax(lH, rr[i].high);
         lL = (lL == 0) ? rr[i].low  : MathMin(lL, rr[i].low);
      }
      if(k >= 1 && m >= 570 && m < 960)   // previous trading day regular hours 09:30-16:00 NY
      {
         dC[k]++;
         dH[k] = (dC[k] == 1) ? rr[i].high : MathMax(dH[k], rr[i].high);
         dL[k] = (dC[k] == 1) ? rr[i].low  : MathMin(dL[k], rr[i].low);
      }
   }

   double pdh = 0, pdl = 0;
   for(int k = 1; k <= 7; k++)
      if(dC[k] > 0) { pdh = dH[k]; pdl = dL[k]; break; }
   if(pdh == 0) { g_dayBlocked = true; Lg("SKIP", "no previous day data"); return; }

   double refClose = rr[1].close;
   double atr = ATRat(rr, 1);

   // overextended-day filter: today's range so far against the average daily range (last 5 trading days)
   if(InpMaxRangeADR > 0)
   {
      double sum = 0;
      int cnt = 0;
      for(int k = 1; k <= 7 && cnt < 5; k++)
         if(dC[k] > 0) { sum += (dH[k] - dL[k]); cnt++; }
      if(cnt > 0)
      {
         double adr = sum / cnt;
         if(tH > 0 && (tH - tL) > InpMaxRangeADR * adr)
         {
            g_dayBlocked = true;
            c_over++;
            Lg("SKIP", "overextended day: range " + DoubleToString(tH - tL, 1) + " vs ADR " + DoubleToString(adr, 1));
            return;
         }
      }
   }

   bool useLondon = (InpWindowStartMin >= InpLondonEndMin);   // London range must be complete before we use it
   if(aH > 0) { AddLevel("AsianH", aH, true, InpTrigAsian, refClose); AddLevel("AsianL", aL, false, InpTrigAsian, refClose); }
   if(lH > 0 && useLondon) { AddLevel("LondonH", lH, true, InpTrigLondon, refClose); AddLevel("LondonL", lL, false, InpTrigLondon, refClose); }
   AddLevel("PDH", pdh, true, InpTrigPrevDay, refClose);
   AddLevel("PDL", pdl, false, InpTrigPrevDay, refClose);

   double pwh = iHigh(_Symbol, PERIOD_W1, 1);
   double pwl = iLow(_Symbol, PERIOD_W1, 1);
   if(pwh > 0) AddLevel("PWH", pwh, true, false, refClose);
   if(pwl > 0) AddLevel("PWL", pwl, false, false, refClose);

   if(atr > 0) { AddEqual(rr, true, refClose, atr); AddEqual(rr, false, refClose, atr); }

   // bias
   int h4 = H4Bias();
   double mid = (pdh + pdl) / 2.0;
   switch(InpBiasMode)
   {
      case BIAS_NONE:        g_allowLong = true;                        g_allowShort = true;                        break;
      case BIAS_H4_AND_MID:  g_allowLong = (h4 > 0 && refClose > mid);  g_allowShort = (h4 < 0 && refClose < mid);  break;
      case BIAS_H4_ONLY:     g_allowLong = (h4 > 0);                    g_allowShort = (h4 < 0);                    break;
      case BIAS_MID_ONLY:    g_allowLong = (refClose > mid);            g_allowShort = (refClose < mid);            break;
   }
   Lg("BIAS", "h4=" + IntegerToString(h4) + " price=" + DoubleToString(refClose, _Digits) + " pdMid=" + DoubleToString(mid, _Digits) +
              " long=" + (string)g_allowLong + " short=" + (string)g_allowShort);
   if(!g_allowLong && !g_allowShort) { g_dayBlocked = true; c_noBias++; Lg("SKIP", "no bias"); }

   // draw
   datetime d1 = t0 - 12 * 3600, d2 = t0 + 4 * 3600;
   for(int i = 0; i < ArraySize(g_levels); i++)
      DrawLine(g_levels[i].name, g_levels[i].price, g_levels[i].isHigh ? clrTomato : clrSeaGreen, d1, d2, g_levels[i].name);

   g_levelsReady = true;
   c_days++;
}

//+------------------------------------------------------------------+
//| Money / orders                                                   |
//+------------------------------------------------------------------+
double CalcLots(double dist)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickVal <= 0) tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickVal <= 0 || dist <= 0) return 0;
   double lossPerLot = dist / tickSize * tickVal;
   double lots = InpRiskUSD / lossPerLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < minv) return 0;      // minimum lot already risks more than the budget
   if(lots > maxv) lots = maxv;
   int vd = 0;
   double s = step;
   while(s < 1.0 && vd < 8) { s *= 10.0; vd++; }
   return NormalizeDouble(lots, vd);
}

bool HasPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic) return true;
   }
   return false;
}

void ClosePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         trade.PositionClose(tk);
   }
}

bool HasPending()
{
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagic) return true;
   }
   return false;
}

void CancelPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagic)
         trade.OrderDelete(tk);
   }
}

double ClosedPnl(datetime from)
{
   if(!HistorySelect(from, TimeCurrent() + 60)) return 0;
   double s = 0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
      s += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP) + HistoryDealGetDouble(tk, DEAL_COMMISSION);
   }
   return s;
}

bool LimitsHit()
{
   if(ClosedPnl(g_dayStart)  <= -InpDailyLossR  * InpRiskUSD) return true;
   if(ClosedPnl(g_weekStart) <= -InpWeeklyLossR * InpRiskUSD) return true;
   return false;
}

double NextTarget(double entry)
{
   double best = 0;
   for(int i = 0; i < ArraySize(g_levels); i++)
   {
      if(g_levels[i].state == 2) continue;
      double p = g_levels[i].price;
      if(g_dir > 0)
      {
         if(!g_levels[i].isHigh) continue;
         if(p > entry && (best == 0 || p < best)) best = p;
      }
      else
      {
         if(g_levels[i].isHigh) continue;
         if(p < entry && (best == 0 || p > best)) best = p;
      }
   }
   return best;
}

bool PlaceOrder(double entryRaw, double zlo, double zhi, double atr)
{
   double entry = NT(entryRaw);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(InpMaxSpread > 0 && (ask - bid) > InpMaxSpread) { Lg("SKIP", "spread too wide"); return false; }

   double buf = (ask - bid) + InpSLBufferATR * atr;
   double sl, dist;
   if(g_dir > 0)
   {
      if(ask <= entry) { Lg("SKIP", "price already at or below entry"); return false; }
      sl = g_sweepExtreme - buf;
      dist = entry - sl;
   }
   else
   {
      if(bid >= entry) { Lg("SKIP", "price already at or above entry"); return false; }
      sl = g_sweepExtreme + buf;
      dist = sl - entry;
   }
   if(dist <= 0) { Lg("SKIP", "bad stop distance"); return false; }
   if(dist > InpMaxStopATR * atr) { Lg("SKIP", "stop wider than cap"); return false; }

   double tp;
   if(InpTPMode == TP_FIXED_R)
      tp = (g_dir > 0) ? entry + InpFixedR * dist : entry - InpFixedR * dist;
   else
   {
      double lvl = NextTarget(entry);
      if(lvl == 0) { Lg("SKIP", "no opposing liquidity target"); return false; }
      tp = (g_dir > 0) ? lvl - InpTPBufferATR * atr : lvl + InpTPBufferATR * atr;
      double rr = MathAbs(tp - entry) / dist;
      if(rr < InpMinRR) { Lg("SKIP", "target closer than min R: " + DoubleToString(rr, 2)); return false; }
   }

   sl = NT(sl);
   tp = NT(tp);
   double lots = CalcLots(dist);
   if(lots <= 0)
   {
      double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      Lg("LOTS", "risk budget too small: stopDist=" + DoubleToString(dist, 2) +
                 " tickSize=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), 5) +
                 " tickValue=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), 5) +
                 " minLot=" + DoubleToString(minv, 2));
      if(InpAllowMinLot && minv > 0) lots = minv;
      else { Lg("SKIP", "lot size below minimum for risk budget"); return false; }
   }

   bool ok;
   if(g_dir > 0) ok = trade.BuyLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "ICT v1.1");
   else          ok = trade.SellLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "ICT v1.1");
   if(!ok) { Lg("ORDER_FAIL", "retcode=" + IntegerToString((int)trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription()); return false; }

   g_fvgLow = zlo;
   g_fvgHigh = zhi;
   g_pendBars = 0;
   g_atrOrder = atr;
   Lg("ORDER", (g_dir > 0 ? "BUY LIMIT " : "SELL LIMIT ") + DoubleToString(lots, 2) + " entry=" + DoubleToString(entry, _Digits) +
               " sl=" + DoubleToString(sl, _Digits) + " tp=" + DoubleToString(tp, _Digits) + " via " + g_sweepLevel + " mode=" + EntryModeName());
   return true;
}

//+------------------------------------------------------------------+
//| Entry zone: returns 1 = found, 0 = not yet (keep waiting), -1 = fail
//+------------------------------------------------------------------+
int FindEntry(const MqlRates &r[], int es, double atr, double &entry, double &zlo, double &zhi, datetime &zt)
{
   if(InpEntryMode == ENTRY_FVG_50 || InpEntryMode == ENTRY_FVG_EDGE)
   {
      for(int s = es - 2; s >= 1; s--)
      {
         double lo, hi;
         if(g_dir > 0) { lo = r[s + 2].high; hi = r[s].low; }
         else          { lo = r[s].high;     hi = r[s + 2].low; }
         if(hi - lo >= InpMinFVGATR * atr)
         {
            zlo = lo;
            zhi = hi;
            zt = r[s + 2].time;
            if(InpEntryMode == ENTRY_FVG_50) entry = (lo + hi) / 2.0;
            else entry = (g_dir > 0) ? hi : lo;   // near edge: top of a bullish gap, bottom of a bearish gap
            return 1;
         }
      }
      return 0;
   }

   if(InpEntryMode == ENTRY_OTE)
   {
      double leg = (g_dir > 0) ? -DBL_MAX : DBL_MAX;
      for(int j = 1; j <= es; j++)
      {
         if(g_dir > 0) leg = MathMax(leg, r[j].high);
         else          leg = MathMin(leg, r[j].low);
      }
      double range = MathAbs(leg - g_sweepExtreme);
      if(range <= 0) return -1;
      if(g_dir > 0)
      {
         entry = leg - InpOTELevel * range;
         zlo = leg - 0.79 * range;
         zhi = leg - 0.62 * range;
      }
      else
      {
         entry = leg + InpOTELevel * range;
         zlo = leg + 0.62 * range;
         zhi = leg + 0.79 * range;
      }
      zlo = MathMin(zlo, entry);
      zhi = MathMax(zhi, entry);
      zt = r[es].time;
      return 1;
   }

   // order block: the last opposite-colour candle at or before the sweep extreme
   for(int k = es; k <= es + 6 && k < ArraySize(r); k++)
   {
      bool opp = (g_dir > 0) ? (r[k].close < r[k].open) : (r[k].close > r[k].open);
      if(opp)
      {
         zlo = r[k].low;
         zhi = r[k].high;
         zt = r[k].time;
         entry = (zlo + zhi) / 2.0;
         return 1;
      }
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Setup state machine (called once per closed bar)                 |
//+------------------------------------------------------------------+
void ResetSetup(string why)
{
   g_state = 0;
   Lg("RESET", why);
}

void ProcessEntry(const MqlRates &r[], bool first)
{
   int es = ShiftOfTime(r, g_sweepExtremeTime);
   if(es < 0) { ResetSetup("sweep bar not found"); return; }
   double atr = ATRat(r, 1);
   if(atr <= 0) return;

   bool failed = (g_dir > 0) ? (r[1].close < g_sweepExtreme) : (r[1].close > g_sweepExtreme);
   if(failed) { ResetSetup("close beyond sweep extreme before entry"); return; }

   double entry = 0, zlo = 0, zhi = 0;
   datetime zt = 0;
   int res = FindEntry(r, es, atr, entry, zlo, zhi, zt);
   if(res < 0) { ResetSetup("no entry zone (" + EntryModeName() + ")"); return; }
   if(res == 0)
   {
      if(!first) g_fvgWait++;
      if(g_fvgWait >= InpFVGWaitBars) ResetSetup("no FVG after MSS");
      return;
   }

   DrawZone(zt, r[1].time + 3600, zlo, zhi);
   c_zone++;
   Lg("ZONE", EntryModeName() + " " + DoubleToString(zlo, _Digits) + " - " + DoubleToString(zhi, _Digits) + " entry=" + DoubleToString(entry, _Digits));
   if(PlaceOrder(entry, zlo, zhi, atr)) { g_state = 2; c_orders++; }
   else { g_state = 0; c_skipOrder++; }
}

void ProcessMSS(const MqlRates &r[])
{
   double atr = ATRat(r, 1);
   if(atr <= 0) return;

   bool failed = (g_dir > 0) ? (r[1].close < g_sweepExtreme) : (r[1].close > g_sweepExtreme);
   if(failed) { ResetSetup("close beyond sweep extreme"); return; }

   // opposite-side sweep before the MSS = ambiguous, drop the setup
   double depth = InpSweepMinDepthATR * atr;
   for(int i = 0; i < ArraySize(g_levels); i++)
   {
      if(!g_levels[i].trigger || g_levels[i].state == 2) continue;
      if(g_levels[i].isHigh != (g_dir > 0)) continue;   // opposite side only
      double p = g_levels[i].price;
      bool opp = g_levels[i].isHigh ? (r[1].high > p + depth && r[1].close < p) : (r[1].low < p - depth && r[1].close > p);
      if(opp) { ResetSetup("opposite sweep, ambiguous"); return; }
   }

   double body = MathAbs(r[1].close - r[1].open);
   double rng = r[1].high - r[1].low;
   bool disp = (body >= InpDispBodyATR * atr);
   bool dirCandle = (g_dir > 0) ? (r[1].close > r[1].open) : (r[1].close < r[1].open);
   bool brk = (g_dir > 0) ? (r[1].close > g_swingRef) : (r[1].close < g_swingRef);
   bool frac = false;
   if(rng > 0) frac = (g_dir > 0) ? ((r[1].close - r[1].low) / rng >= InpDispCloseFrac) : ((r[1].high - r[1].close) / rng >= InpDispCloseFrac);

   if(brk && disp && dirCandle && frac)
   {
      Lg("MSS", "close " + DoubleToString(r[1].close, _Digits) + " beyond " + DoubleToString(g_swingRef, _Digits));
      DrawMark("MSS", r[1].time, r[1].close, clrOrange);
      g_state = 5;
      c_mss++;
      g_fvgWait = 0;
      ProcessEntry(r, true);
      return;
   }

   g_barsSinceSweep++;
   if(g_barsSinceSweep > InpMSSMaxBars) ResetSetup("MSS timeout");
}

void StartSetup(const MqlRates &r[], int li, double ext, datetime et)
{
   g_dir = g_levels[li].isHigh ? -1 : 1;
   g_sweepExtreme = ext;
   g_sweepExtremeTime = et;
   g_sweepLevel = g_levels[li].name;

   int es = ShiftOfTime(r, et);
   if(es < 0) { Lg("RESET", "sweep bar not in history"); return; }

   double ref = 0;
   for(int k = MathMax(es + 1, InpSwingN + 1); k < ArraySize(r) - InpSwingN - 1 && k < es + 150; k++)
   {
      if(g_dir > 0) { if(IsSwingHigh(r, k, InpSwingN)) { ref = r[k].high; break; } }
      else          { if(IsSwingLow(r, k, InpSwingN))  { ref = r[k].low;  break; } }
   }
   if(ref == 0) { Lg("RESET", "no swing reference for MSS"); return; }

   g_swingRef = ref;
   g_barsSinceSweep = 0;
   g_state = 1;
   c_sweeps++;
   Lg("SWEEP", g_sweepLevel + " extreme=" + DoubleToString(ext, _Digits) + " mssLevel=" + DoubleToString(ref, _Digits) +
               (g_dir > 0 ? " (long setup)" : " (short setup)"));
   DrawMark("SWEEP", et, ext, clrMagenta);
}

void DetectSweeps(const MqlRates &r[])
{
   double atr = ATRat(r, 1);
   if(atr <= 0) return;
   double depth = InpSweepMinDepthATR * atr;

   for(int i = 0; i < ArraySize(g_levels); i++)
   {
      if(!g_levels[i].trigger || g_levels[i].state == 2) continue;
      bool hi = g_levels[i].isHigh;
      if(hi && !g_allowShort) continue;
      if(!hi && !g_allowLong) continue;

      double p = g_levels[i].price;
      bool confirmed = false;
      double ext = 0;
      datetime et = 0;

      if(g_levels[i].state == 0)
      {
         bool pierced = hi ? (r[1].high > p + depth) : (r[1].low < p - depth);
         if(pierced)
         {
            ext = hi ? r[1].high : r[1].low;
            et = r[1].time;
            bool back = hi ? (r[1].close < p) : (r[1].close > p);
            if(back) confirmed = true;
            else
            {
               g_levels[i].state = 1;
               g_levels[i].candBars = 0;
               g_levels[i].candExtreme = ext;
               g_levels[i].candTime = et;
            }
         }
      }
      else if(g_levels[i].state == 1)
      {
         g_levels[i].candBars++;
         bool newExt = hi ? (r[1].high > g_levels[i].candExtreme) : (r[1].low < g_levels[i].candExtreme);
         if(newExt)
         {
            g_levels[i].candExtreme = hi ? r[1].high : r[1].low;
            g_levels[i].candTime = r[1].time;
         }
         bool back = hi ? (r[1].close < p) : (r[1].close > p);
         if(back)
         {
            confirmed = true;
            ext = g_levels[i].candExtreme;
            et = g_levels[i].candTime;
         }
         else if(g_levels[i].candBars >= InpSweepConfirmBars)
         {
            g_levels[i].state = 2;
            Lg("BREAKOUT", g_levels[i].name + " closed beyond, not a sweep");
         }
      }

      if(confirmed)
      {
         g_levels[i].state = 2;
         StartSetup(r, i, ext, et);
         return;
      }
   }
}

void ManagePending(const MqlRates &r[])
{
   g_pendBars++;
   bool through = (g_dir > 0) ? (r[1].close < g_fvgLow) : (r[1].close > g_fvgHigh);
   if(through || g_pendBars >= InpPendingMaxBars)
   {
      CancelPending();
      g_state = 0;
      Lg("CANCEL", through ? "closed through the zone" : "order expired");
   }
}

void NewDayReset(int today)
{
   g_dayIdx = today;
   g_levelsReady = false;
   g_dayBlocked = false;
   g_tradesToday = 0;
   g_dayLogged = false;
   ArrayResize(g_levels, 0);
   if(g_state != 2 && g_state != 3) g_state = 0;

   datetime nyMid = (datetime)((long)today * 86400);
   g_dayStart = (datetime)((long)nyMid + (long)InpServerMinusNYHours * 3600);
   MqlDateTime dt;
   TimeToStruct(nyMid, dt);
   int back = (dt.day_of_week + 6) % 7;
   g_weekStart = (datetime)((long)g_dayStart - (long)back * 86400);

   if(dt.day_of_week == 0 || dt.day_of_week == 6) { g_dayBlocked = true; return; }

   string list = InpSkipDates;
   StringReplace(list, " ", "");
   list = "," + list + ",";
   string d0 = TimeToString(nyMid, TIME_DATE);
   string d1 = TimeToString((datetime)((long)nyMid + 86400), TIME_DATE);   // day before a listed day
   if(StringFind(list, "," + d0 + ",") >= 0) { g_dayBlocked = true; Lg("SKIP", "listed skip date " + d0); return; }
   if(StringFind(list, "," + d1 + ",") >= 0) { g_dayBlocked = true; Lg("SKIP", "day before listed date " + d1); return; }
}

void OnNewBar()
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpTF, 0, 300, r) < 150) return;

   datetime t0 = r[0].time;
   int today = NYDay(t0);
   if(today != g_dayIdx) NewDayReset(today);

   if(g_dayBlocked || g_state == 4 || g_state == 3) return;
   if(g_state == 2) { ManagePending(r); return; }

   int mn0 = NYMin(t0);
   int mn1 = NYMin(r[1].time);

   if(!g_levelsReady)
   {
      if(mn0 >= InpWindowStartMin && mn0 < InpWindowEndMin) BuildLevels();
      return;   // first setups are evaluated from the next bar
   }

   if(mn1 >= InpWindowEndMin && !g_dayLogged)
   {
      g_dayLogged = true;
      Lg("DAY_END", "state=" + IntegerToString(g_state) + " levels=" + IntegerToString(ArraySize(g_levels)) +
                    " long=" + (string)g_allowLong + " short=" + (string)g_allowShort);
   }
   if(mn1 < InpWindowStartMin || mn1 >= InpWindowEndMin) return;
   if(LimitsHit()) { g_state = 4; Lg("SKIP", "loss limit reached"); return; }

   if(g_state == 0) DetectSweeps(r);
   if(g_state == 1)      ProcessMSS(r);
   else if(g_state == 5) ProcessEntry(r, false);
}

//+------------------------------------------------------------------+
//| Open-trade management: partial, breakeven, trailing              |
//+------------------------------------------------------------------+
void InitPositionRisk()
{
   g_partialDone = false;
   g_beDone = false;
   g_riskDist = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      g_riskDist = MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - PositionGetDouble(POSITION_SL));
      break;
   }
}

void ManageOpenPosition()
{
   if(g_riskDist <= 0) return;
   if(InpBreakevenAtR <= 0 && InpPartialAtR <= 0 && InpTrailStartR <= 0) return;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      bool buy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double price = buy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double rMult = (buy ? (price - open) : (open - price)) / g_riskDist;

      if(InpPartialAtR > 0 && !g_partialDone && rMult >= InpPartialAtR)
      {
         double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(step <= 0) step = 0.01;
         double cv = MathFloor(vol * InpPartialPct / 100.0 / step + 1e-9) * step;
         if(cv >= minv && (vol - cv) >= minv)
         {
            if(trade.PositionClosePartial(tk, cv)) Lg("PARTIAL", DoubleToString(cv, 2) + " lots at " + DoubleToString(rMult, 2) + "R");
         }
         g_partialDone = true;
      }

      if(InpBreakevenAtR > 0 && !g_beDone && rMult >= InpBreakevenAtR)
      {
         double nsl = NT(open);
         bool better = buy ? (nsl > sl) : (sl == 0 || nsl < sl);
         if(better)
         {
            if(trade.PositionModify(tk, nsl, tp)) { Lg("BREAKEVEN", "stop to entry at " + DoubleToString(rMult, 2) + "R"); sl = nsl; }
         }
         g_beDone = true;
      }

      if(InpTrailStartR > 0 && rMult >= InpTrailStartR && g_atrOrder > 0)
      {
         double td = InpTrailATR * g_atrOrder;
         double nsl = NT(buy ? price - td : price + td);
         bool better = buy ? (nsl > sl) : (sl == 0 || nsl < sl);
         if(better) trade.PositionModify(tk, nsl, tp);
      }
      break;
   }
}

//+------------------------------------------------------------------+
//| Equity peak / kill switch                                        |
//+------------------------------------------------------------------+
void UpdateKill()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_peak) { g_peak = eq; GlobalVariableSet(g_peakKey, g_peak); }
   if(!g_kill && (g_peak - eq) >= InpKillDDR * InpRiskUSD)
   {
      g_kill = true;
      Lg("KILL", "drawdown limit hit, EA disabled");
      Alert("ICT NAS100 EA: drawdown kill switch hit. Review before re-enabling (set InpResetPeak = true once).");
   }
}

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_peakKey = "ICT_PEAK_" + IntegerToString(InpMagic);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peak = eq;
   if(GlobalVariableCheck(g_peakKey) && !InpResetPeak) g_peak = MathMax(eq, GlobalVariableGet(g_peakKey));
   GlobalVariableSet(g_peakKey, g_peak);

   Print("SPEC symbol=", _Symbol, " digits=", _Digits, " minLot=", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), 2),
         " lotStep=", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), 2),
         " tickSize=", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), 5),
         " tickValue=", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), 5),
         " contractSize=", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE), 2),
         " spreadPoints=", SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), " point=", DoubleToString(_Point, 5));
   Lg("INIT", "v1.10 symbol=" + _Symbol + " serverMinusNY=" + IntegerToString(InpServerMinusNYHours) + " entry=" + EntryModeName());
   Print("ICT NAS100 EA v1.10 started. Verify InpServerMinusNYHours for your broker (default 7).");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   string f = "FUNNEL daysWithLevels=" + IntegerToString(c_days) + " noBiasDays=" + IntegerToString(c_noBias) +
              " overextendedDays=" + IntegerToString(c_over) + " sweeps=" + IntegerToString(c_sweeps) +
              " mss=" + IntegerToString(c_mss) + " zonesFound=" + IntegerToString(c_zone) +
              " ordersPlaced=" + IntegerToString(c_orders) + " orderSkipped=" + IntegerToString(c_skipOrder) +
              " fills=" + IntegerToString(c_fills);
   Print(f);
   Lg("FUNNEL", f);
}

// Custom optimisation criterion: average result per trade in R (approximate when partials are used)
double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   if(trades < 1 || InpRiskUSD <= 0) return 0;
   return TesterStatistics(STAT_PROFIT) / (InpRiskUSD * trades);
}

void OnTick()
{
   datetime now = TimeCurrent();
   int mn = NYMin(now);

   UpdateKill();
   if(g_kill)
   {
      if(HasPending())  CancelPending();
      if(HasPosition()) ClosePositions();
      return;
   }

   // time-based housekeeping on every tick
   if(HasPending() && (mn >= InpCancelMin || mn < InpWindowStartMin)) { CancelPending(); Lg("CANCEL", "time cutoff"); }
   if(HasPosition() && (mn >= InpExitMin || mn < InpWindowStartMin)) { ClosePositions(); Lg("EXIT", "time exit"); }

   bool pos = HasPosition();
   bool pend = HasPending();

   if(g_state == 2)
   {
      if(pos)
      {
         g_state = 3;
         c_fills++;
         g_tradesToday++;
         g_fillTime = now;
         InitPositionRisk();
         Lg("FILL", "position open, trades today=" + IntegerToString(g_tradesToday));
      }
      else if(!pend) { g_state = 0; Lg("ORDER_GONE", "unfilled or cancelled"); }
   }
   else if(g_state == 3)
   {
      if(pos) ManageOpenPosition();
      else
      {
         double lp = ClosedPnl(g_fillTime - 60);
         Lg("CLOSED", "pnl=" + DoubleToString(lp, 2) + " R=" + DoubleToString(lp / InpRiskUSD, 2));
         if(lp < 0 && g_tradesToday < InpMaxTradesPerDay && !LimitsHit()) g_state = 0;   // 2nd trade only after a loss
         else g_state = 4;
      }
   }

   datetime bt = iTime(_Symbol, InpTF, 0);
   if(bt != g_lastBar)
   {
      g_lastBar = bt;
      OnNewBar();
   }
}