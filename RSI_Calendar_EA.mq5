//+------------------------------------------------------------------+
//|                                              RSI_Calendar_EA.mq5 |
//|                          RSI + LuxAlgo Buy Sell Calendar Strategy |
//|                                                                  |
//| Logic:                                                           |
//| - BUY khi RSI > 70 va ngay truoc la BULLISH (cot xanh)           |
//| - SELL khi RSI < 30 va ngay truoc la BEARISH (cot do)            |
//+------------------------------------------------------------------+
#property copyright "RSI Calendar EA"
#property link      "https://t.me/Grokvn"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| TREND METHOD DEFINITION                                          |
//+------------------------------------------------------------------+
enum ENUM_TREND_METHOD
{
   METHOD_LINREG = 0,          // Linreg (WMA vs SMA)
   METHOD_DELTA = 1,           // Accumulated Delta
   METHOD_MAXMIN = 2           // Max/Min
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
//--- MAIN SETTINGS ---
input int    MagicNumber      = 234567;        // EA Magic Number
input string TradeComment     = "RSI_Calendar"; // Order Comment

//--- RSI SETTINGS ---
input int    RSI_Period       = 14;            // RSI Period
input ENUM_TIMEFRAMES RSI_Timeframe = PERIOD_M5; // RSI Timeframe
input double RSI_BuyLevel     = 70;            // RSI Buy Level (cross up)
input double RSI_SellLevel    = 30;            // RSI Sell Level (cross down)

//--- TREND METHOD (LuxAlgo) ---
input ENUM_TREND_METHOD TrendMethod = METHOD_LINREG; // Trend Method
input int    TrendDayShift    = 1;                   // D1 Column (1=today, 2=yesterday, 3=day before...)
input ENUM_TIMEFRAMES TrendTimeframe = PERIOD_D1;    // Trend Timeframe (D1)

//--- MONEY MANAGEMENT ---
input double LotSize          = 0.01;          // Base Lot Size
input double TakeProfitPips   = 50;            // Take Profit (pips)
input double StopLossPips     = 30;            // Stop Loss (pips)
input bool   UseTrailingStop  = false;         // Use Trailing Stop
input double TrailingPips     = 20;            // Trailing Stop (pips)

//--- MARTINGALE (ON LOSS) ---
input bool   UseMartingale    = false;         // Enable Martingale on Loss
input double MartingaleMultiplier = 2.0;       // Martingale Multiplier (x2, x3...)
input int    MaxMartingaleLevel = 5;           // Max Martingale Levels
input int    MartingaleStartAfter = 1;         // Start Martingale After X Losses (1=immediately)

//--- FILTERS ---
input int    MaxOrdersPerDay  = 3;             // Max Orders Per Day
input int    MinMinutesAfterTP = 5;            // Wait Time After TP (Minutes)
input int    MinMinutesAfterSL = 1;            // Wait Time After SL (Minutes)
input bool   CloseOnTrendChange = false;       // Close Order When Trend Changes (requires D1>=2)

//--- DAILY TP LIMIT ---
input bool   UseTPLimit       = false;         // Enable Daily TP Limit
input int    TPLimitPerDay    = 3;             // TP Count to Stop EA

//--- DISPLAY ---
input bool   ShowPanel        = true;          // Show Panel
input color  PanelColor       = clrWhite;      // Panel Text Color

//+------------------------------------------------------------------+
//| BIEN TOAN CUC                                                    |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  positionInfo;

int            g_rsiHandle;
double         g_rsiBuffer[];
double         g_point;
int            g_digits;
double         g_pipValue;
int            g_ordersToday = 0;
datetime       g_lastTradeTime = 0;
bool           g_lastTradeWasTP = true;   // true=TP, false=SL
datetime       g_lastDay = 0;

// Trend variables
double         g_dailyOpen[];
double         g_dailyClose[];
double         g_dailyHigh[];
double         g_dailyLow[];
int            g_trendDirection = 0; // 1=Bullish, -1=Bearish, 0=Neutral

// Martingale variables
int            g_loseStreak = 0;     // So lan thua lien tiep
int            g_winStreak = 0;      // So lan thang lien tiep
int            g_winCount = 0;       // Tong so lan thang
int            g_loseCount = 0;      // Tong so lan thua
double         g_currentLot = 0;     // Lot hien tai (sau khi tinh Martingale)
ulong          g_lastTicket = 0;     // Ticket lenh cuoi cung

// Thong ke thong tin
double         g_maxProfit = 0;      // Lai lon nhat 1 lenh
double         g_maxLoss = 0;        // Lo lon nhat 1 lenh
int            g_maxWinStreak = 0;   // Chuoi thang lon nhat
int            g_maxLoseStreak = 0;  // Chuoi thua lon nhat
double         g_maxLotUsed = 0;     // Lot lon nhat da vao lenh

// TP Limit trong ngay
int            g_tpCountToday = 0;   // So lan TP trong ngay
bool           g_eaStopped = false;  // EA da dung do dat TP limit

// Calendar
int            g_calendarTrend[31];  // Trend cua tung ngay trong thang (-1, 0, 1)
int            g_calendarMonth = 0;  // Thang hien tai
int            g_calendarYear = 0;   // Nam hien tai

// Day separator lines
int            g_numDayLines = 4;    // So duong phan cach ngay hien thi

//+------------------------------------------------------------------+
//| Ham khoi tao EA                                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   if(g_digits == 3 || g_digits == 5)
      g_pipValue = g_point * 10;
   else
      g_pipValue = g_point;
   
   // Tao RSI indicator handle
   g_rsiHandle = iRSI(_Symbol, RSI_Timeframe, RSI_Period, PRICE_CLOSE);
   if(g_rsiHandle == INVALID_HANDLE)
   {
      Print("Loi tao RSI indicator!");
      return(INIT_FAILED);
   }
   
   ArraySetAsSeries(g_rsiBuffer, true);
   ArraySetAsSeries(g_dailyOpen, true);
   ArraySetAsSeries(g_dailyClose, true);
   ArraySetAsSeries(g_dailyHigh, true);
   ArraySetAsSeries(g_dailyLow, true);
   
   if(ShowPanel)
   {
      CreatePanel();
      CreateCalendar();
      DrawDaySeparators();
   }
   
   Print("=== RSI Calendar EA v1.00 da khoi dong ===");
   Print("RSI Timeframe: ", EnumToString(RSI_Timeframe));
   Print("Trend Timeframe: ", EnumToString(TrendTimeframe));
   Print("Trend Method: ", EnumToString(TrendMethod));
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Ham huy EA                                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_rsiHandle != INVALID_HANDLE)
      IndicatorRelease(g_rsiHandle);
   
   ObjectsDeleteAll(0, "RSI_Panel_");
   ObjectsDeleteAll(0, "Cal_");
   ObjectsDeleteAll(0, "DaySep_");
   Print("=== RSI Calendar EA da dung ===");
   Print("Thong ke: Thang=", g_winCount, " Thua=", g_loseCount);
}

//+------------------------------------------------------------------+
//| Xu ly su kien giao dich (theo doi thang/thua)                    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // Chi xu ly khi deal hoan thanh
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   
   // Lay thong tin deal
   ulong dealTicket = trans.deal;
   if(dealTicket == 0)
      return;
   
   // Kiem tra deal co phai cua EA nay khong
   if(HistoryDealSelect(dealTicket))
   {
      long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      
      // Chi xu ly deal dong lenh (DEAL_ENTRY_OUT)
      if(dealMagic != MagicNumber || dealSymbol != _Symbol || dealEntry != DEAL_ENTRY_OUT)
         return;
      
      double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double dealSwap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      double dealCommission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      double totalProfit = dealProfit + dealSwap + dealCommission;
      
      if(totalProfit >= 0)
      {
         // THANG - Reset ve lot goc cho lenh tiep theo
         g_winCount++;
         g_winStreak++;
         g_loseStreak = 0;  // LUON reset ve 0 khi thang -> lenh tiep theo dung lot goc
         g_tpCountToday++;  // Tang dem TP trong ngay
         
         // Cap nhat lai lon nhat
         if(totalProfit > g_maxProfit)
            g_maxProfit = totalProfit;
         
         // Cap nhat chuoi thang lon nhat
         if(g_winStreak > g_maxWinStreak)
            g_maxWinStreak = g_winStreak;
         
         Print(">>> LENH THANG! Lai=", DoubleToString(totalProfit, 2), " USD - Reset lot ve goc (", LotSize, ") - TP hom nay: ", g_tpCountToday);
         
         // Luu thoi gian dong lenh de tinh thoi gian cho
         g_lastTradeTime = TimeCurrent();
         g_lastTradeWasTP = true;  // Danh dau la TP
         
         // Kiem tra TP limit
         if(UseTPLimit && g_tpCountToday >= TPLimitPerDay)
         {
            g_eaStopped = true;
            Print(">>> DA DAT ", TPLimitPerDay, " LAN TP TRONG NGAY - EA DUNG LAI!");
         }
      }
      else
      {
         // THUA - Tang cap Martingale
         g_loseCount++;
         g_loseStreak++;
         g_winStreak = 0;
         
         // Cap nhat lo lon nhat (luu gia tri duong)
         if(MathAbs(totalProfit) > g_maxLoss)
            g_maxLoss = MathAbs(totalProfit);
         
         // Cap nhat chuoi thua lon nhat
         if(g_loseStreak > g_maxLoseStreak)
            g_maxLoseStreak = g_loseStreak;
         
         Print(">>> LENH THUA! Lo=", DoubleToString(totalProfit, 2), " USD - Chuoi thua: ", g_loseStreak);
         
         // Luu thoi gian dong lenh de tinh thoi gian cho
         g_lastTradeTime = TimeCurrent();
         g_lastTradeWasTP = false;  // Danh dau la SL
         
         if(g_loseStreak >= MaxMartingaleLevel)
         {
            Print(">>> DA DAT GIOI HAN MARTINGALE (", MaxMartingaleLevel, " lan) - Lot se giu nguyen");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Ham xu ly moi tick                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // Reset dem lenh moi ngay
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != g_lastDay)
   {
      g_ordersToday = 0;
      g_tpCountToday = 0;    // Reset dem TP trong ngay
      g_eaStopped = false;   // Cho phep EA chay lai
      g_lastDay = today;
      Print(">>> NGAY MOI - Reset TP count va cho phep EA chay lai");
   }
   
   // Kiem tra EA da dung do dat TP limit chua
   if(g_eaStopped)
      return;
   
   // Lay RSI (can 2 gia tri de kiem tra cat len/xuong)
   if(CopyBuffer(g_rsiHandle, 0, 0, 3, g_rsiBuffer) < 3)
      return;
   
   double rsi = g_rsiBuffer[0];      // RSI hien tai
   double rsiPrev = g_rsiBuffer[1];  // RSI nen truoc
   
   // Lay trend theo cot mau da chon (TrendDayShift: 1=hom nay, 2=hom qua, ...)
   int trendShift = MathMax(0, TrendDayShift - 1);  // D=1 -> shift=0, D=2 -> shift=1
   int trend = GetDailyTrend(trendShift);
   
   // Cap nhat panel, calendar va day separators
   if(ShowPanel)
   {
      UpdatePanel(rsi, trend);
      UpdateCalendar();
      DrawDaySeparators();
   }
   
   // Kiem tra dieu kien giao dich
   if(!CanTrade())
      return;
   
   // Trailing Stop
   if(UseTrailingStop)
      ManageTrailingStop();
   
   // Dong lenh khi xu huong thay doi (chi hoat dong khi TrendDayShift >= 2)
   if(CloseOnTrendChange && TrendDayShift >= 2)
      CheckAndCloseOnTrendChange(trend);
   
   // Kiem tra da co lenh nao chua - EA chi mo 1 lenh duy nhat
   if(HasAnyPosition())
      return;
   
   // Logic giao dich
   // BUY: RSI cat len 70 (truoc < 70, gio >= 70) va ngay truoc Bullish
   bool rsiCrossUp = (rsiPrev < RSI_BuyLevel && rsi >= RSI_BuyLevel);
   if(rsiCrossUp && trend == 1)
   {
      OpenBuy();
      return;
   }
   
   // SELL: RSI cat xuong 30 (truoc > 30, gio <= 30) va ngay truoc Bearish
   bool rsiCrossDown = (rsiPrev > RSI_SellLevel && rsi <= RSI_SellLevel);
   if(rsiCrossDown && trend == -1)
   {
      OpenSell();
      return;
   }
}

//+------------------------------------------------------------------+
//| Kiem tra va dong lenh khi xu huong thay doi                      |
//+------------------------------------------------------------------+
void CheckAndCloseOnTrendChange(int currentTrend)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(positionInfo.SelectByIndex(i))
      {
         if(positionInfo.Symbol() == _Symbol && positionInfo.Magic() == MagicNumber)
         {
            ENUM_POSITION_TYPE posType = positionInfo.PositionType();
            
            // Neu dang co lenh BUY nhung trend chuyen sang Bearish (do) -> dong lenh
            if(posType == POSITION_TYPE_BUY && currentTrend == -1)
            {
               Print(">>> TREND CHANGED: RED (Sell) - Closing BUY position");
               trade.PositionClose(positionInfo.Ticket());
               return;
            }
            
            // Neu dang co lenh SELL nhung trend chuyen sang Bullish (xanh) -> dong lenh
            if(posType == POSITION_TYPE_SELL && currentTrend == 1)
            {
               Print(">>> TREND CHANGED: GREEN (Buy) - Closing SELL position");
               trade.PositionClose(positionInfo.Ticket());
               return;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Tinh trend theo phuong phap Linreg (WMA vs SMA) - Giong TradingView |
//| Logic: Tich luy tat ca nen trong ngay, tinh WMA va SMA           |
//| WMA = Sum(close * weight) / Sum(weight)                          |
//| SMA = Sum(close) / count                                         |
//+------------------------------------------------------------------+
int TrendLinreg(int dayIndex)
{
   // Lay thoi gian bat dau va ket thuc cua ngay can tinh
   datetime dayTime[];
   ArraySetAsSeries(dayTime, true);
   if(CopyTime(_Symbol, TrendTimeframe, dayIndex, 1, dayTime) < 1) return 0;
   
   datetime dayStart = dayTime[0];
   datetime dayEnd = dayStart + PeriodSeconds(TrendTimeframe);
   
   // Lay tat ca nen M1 trong ngay do (de tinh chinh xac nhu TradingView)
   double closes[];
   datetime times[];
   ArraySetAsSeries(closes, true);
   ArraySetAsSeries(times, true);
   
   // Copy du lieu M1 cua ngay do
   int totalBars = CopyClose(_Symbol, PERIOD_M1, dayStart, dayEnd, closes);
   if(totalBars < 10) 
   {
      // Fallback: dung du lieu cua khung thoi gian hien tai
      totalBars = CopyClose(_Symbol, PERIOD_M5, dayStart, dayEnd, closes);
      if(totalBars < 5) return 0;
   }
   
   // Tinh WMA va SMA theo logic TradingView
   // wma += close * den (den tang dan tu 1)
   // sma += close
   // trend = wma / (den*(den+1)/2) > sma / den
   
   double wmaSum = 0;
   double smaSum = 0;
   int den = 0;
   
   // Lap tu nen cu nhat den nen moi nhat (giong TradingView)
   for(int i = totalBars - 1; i >= 0; i--)
   {
      den++;
      wmaSum += closes[i] * den;
      smaSum += closes[i];
   }
   
   if(den == 0) return 0;
   
   double wmaValue = wmaSum / (den * (den + 1) / 2.0);
   double smaValue = smaSum / den;
   
   return wmaValue > smaValue ? 1 : -1;
}

//+------------------------------------------------------------------+
//| Tinh trend theo phuong phap Accumulated Delta - Giong TradingView|
//| Logic: Tich luy delta (close - open) cua tat ca nen trong ngay   |
//| up = sum of positive deltas, dn = sum of negative deltas         |
//| trend = up > dn ? bullish : bearish                              |
//+------------------------------------------------------------------+
int TrendDelta(int dayIndex)
{
   // Lay thoi gian bat dau va ket thuc cua ngay
   datetime dayTime[];
   ArraySetAsSeries(dayTime, true);
   if(CopyTime(_Symbol, TrendTimeframe, dayIndex, 1, dayTime) < 1) return 0;
   
   datetime dayStart = dayTime[0];
   datetime dayEnd = dayStart + PeriodSeconds(TrendTimeframe);
   
   // Lay du lieu M1 hoac M5
   double opens[], closes[];
   ArraySetAsSeries(opens, true);
   ArraySetAsSeries(closes, true);
   
   int totalBars = CopyOpen(_Symbol, PERIOD_M1, dayStart, dayEnd, opens);
   CopyClose(_Symbol, PERIOD_M1, dayStart, dayEnd, closes);
   
   if(totalBars < 10)
   {
      totalBars = CopyOpen(_Symbol, PERIOD_M5, dayStart, dayEnd, opens);
      CopyClose(_Symbol, PERIOD_M5, dayStart, dayEnd, closes);
      if(totalBars < 5) return 0;
   }
   
   // Tinh accumulated delta
   double up = 0;
   double dn = 0;
   
   for(int i = 0; i < totalBars; i++)
   {
      double delta = closes[i] - opens[i];
      if(delta > 0)
         up += delta;
      else
         dn += MathAbs(delta);
   }
   
   return up > dn ? 1 : -1;
}

//+------------------------------------------------------------------+
//| Tinh trend theo phuong phap Max/Min - Giong TradingView          |
//| Logic: Tim max high va min low cua ngay                          |
//| trend = close > avg(max, min) ? bullish : bearish                |
//+------------------------------------------------------------------+
int TrendMaxMin(int dayIndex)
{
   // Lay thoi gian bat dau va ket thuc cua ngay
   datetime dayTime[];
   ArraySetAsSeries(dayTime, true);
   if(CopyTime(_Symbol, TrendTimeframe, dayIndex, 1, dayTime) < 1) return 0;
   
   datetime dayStart = dayTime[0];
   datetime dayEnd = dayStart + PeriodSeconds(TrendTimeframe);
   
   // Lay du lieu
   double highs[], lows[], closes[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   ArraySetAsSeries(closes, true);
   
   int totalBars = CopyHigh(_Symbol, PERIOD_M1, dayStart, dayEnd, highs);
   CopyLow(_Symbol, PERIOD_M1, dayStart, dayEnd, lows);
   CopyClose(_Symbol, PERIOD_M1, dayStart, dayEnd, closes);
   
   if(totalBars < 10)
   {
      totalBars = CopyHigh(_Symbol, PERIOD_M5, dayStart, dayEnd, highs);
      CopyLow(_Symbol, PERIOD_M5, dayStart, dayEnd, lows);
      CopyClose(_Symbol, PERIOD_M5, dayStart, dayEnd, closes);
      if(totalBars < 5) return 0;
   }
   
   // Tim max high va min low
   double maxHigh = highs[0];
   double minLow = lows[0];
   double lastClose = closes[0];
   
   for(int i = 1; i < totalBars; i++)
   {
      if(highs[i] > maxHigh) maxHigh = highs[i];
      if(lows[i] < minLow) minLow = lows[i];
   }
   
   double avg = (maxHigh + minLow) / 2.0;
   
   return lastClose > avg ? 1 : -1;
}

//+------------------------------------------------------------------+
//| Lay trend cua ngay (1=Bullish, -1=Bearish)                       |
//+------------------------------------------------------------------+
int GetDailyTrend(int dayIndex)
{
   switch(TrendMethod)
   {
      case METHOD_LINREG:
         return TrendLinreg(dayIndex);
      case METHOD_DELTA:
         return TrendDelta(dayIndex);
      case METHOD_MAXMIN:
         return TrendMaxMin(dayIndex);
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Kiem tra co the giao dich khong                                  |
//+------------------------------------------------------------------+
bool CanTrade()
{
   // Kiem tra so lenh trong ngay
   if(g_ordersToday >= MaxOrdersPerDay)
      return false;
   
   // Kiem tra thoi gian toi thieu sau khi dong lenh (tinh bang phut)
   if(g_lastTradeTime > 0)
   {
      datetime currentTime = TimeCurrent();
      int minutesPassed = (int)((currentTime - g_lastTradeTime) / 60);
      int minWait = g_lastTradeWasTP ? MinMinutesAfterTP : MinMinutesAfterSL;
      if(minutesPassed < minWait)
         return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Kiem tra da co vi the chua (BAT KY loai nao)                     |
//+------------------------------------------------------------------+
bool HasAnyPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(positionInfo.SelectByIndex(i))
      {
         if(positionInfo.Symbol() == _Symbol && positionInfo.Magic() == MagicNumber)
         {
            return true;  // Co bat ky lenh nao -> tra ve true
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Tinh lot Martingale                                              |
//+------------------------------------------------------------------+
double CalculateMartingaleLot()
{
   double lot = LotSize;
   
   // Chi gap thep khi g_loseStreak >= MartingaleStartAfter
   if(UseMartingale && g_loseStreak >= MartingaleStartAfter)
   {
      // Tinh so lan gap thep thuc te (tru di so lan cho)
      int effectiveLosses = g_loseStreak - MartingaleStartAfter + 1;
      int level = MathMin(effectiveLosses, MaxMartingaleLevel);
      
      for(int i = 0; i < level; i++)
      {
         lot = lot * MartingaleMultiplier;
      }
      Print(">>> MARTINGALE: Loss #", g_loseStreak, " (effective #", effectiveLosses, ") - Lot = ", DoubleToString(lot, 2));
   }
   else if(UseMartingale && g_loseStreak > 0)
   {
      Print(">>> WAITING: Loss #", g_loseStreak, " < ", MartingaleStartAfter, " - Using base lot = ", DoubleToString(lot, 2));
   }
   
   // Gioi han lot
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lot = MathMax(minLot, lot);
   lot = MathMin(maxLot, lot);
   lot = MathFloor(lot / lotStep) * lotStep;
   
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Mo lenh Buy                                                      |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = StopLossPips > 0 ? ask - StopLossPips * g_pipValue : 0;
   double tp = TakeProfitPips > 0 ? ask + TakeProfitPips * g_pipValue : 0;
   
   sl = NormalizeDouble(sl, g_digits);
   tp = NormalizeDouble(tp, g_digits);
   
   g_currentLot = CalculateMartingaleLot();
   
   if(trade.Buy(g_currentLot, _Symbol, ask, sl, tp, TradeComment))
   {
      g_lastTicket = trade.ResultOrder();
      
      // Cap nhat lot lon nhat
      if(g_currentLot > g_maxLotUsed)
         g_maxLotUsed = g_currentLot;
      
      Print(">>> MO LENH BUY: Lot=", g_currentLot, " SL=", sl, " TP=", tp, " Ticket=", g_lastTicket);
      g_ordersToday++;
   }
   else
   {
      Print("Loi mo lenh BUY: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Mo lenh Sell                                                     |
//+------------------------------------------------------------------+
void OpenSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = StopLossPips > 0 ? bid + StopLossPips * g_pipValue : 0;
   double tp = TakeProfitPips > 0 ? bid - TakeProfitPips * g_pipValue : 0;
   
   sl = NormalizeDouble(sl, g_digits);
   tp = NormalizeDouble(tp, g_digits);
   
   g_currentLot = CalculateMartingaleLot();
   
   if(trade.Sell(g_currentLot, _Symbol, bid, sl, tp, TradeComment))
   {
      g_lastTicket = trade.ResultOrder();
      
      // Cap nhat lot lon nhat
      if(g_currentLot > g_maxLotUsed)
         g_maxLotUsed = g_currentLot;
      
      Print(">>> MO LENH SELL: Lot=", g_currentLot, " SL=", sl, " TP=", tp, " Ticket=", g_lastTicket);
      g_ordersToday++;
   }
   else
   {
      Print("Loi mo lenh SELL: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Quan ly Trailing Stop                                            |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double trailDistance = TrailingPips * g_pipValue;  // Khoang cach trailing (pip -> gia)
   double slDistance = StopLossPips * g_pipValue;     // SL ban dau (pip -> gia)
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(positionInfo.SelectByIndex(i))
      {
         if(positionInfo.Symbol() == _Symbol && positionInfo.Magic() == MagicNumber)
         {
            double currentSL = positionInfo.StopLoss();
            double openPrice = positionInfo.PriceOpen();
            
            if(positionInfo.PositionType() == POSITION_TYPE_BUY)
            {
               double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               double profitPips = (bid - openPrice) / g_pipValue;
               
               // Tinh so buoc hoan chinh (moi buoc = TrailingPips pip)
               int steps = (int)MathFloor(profitPips / TrailingPips);
               
               if(steps >= 1)
               {
                  // SL moi = SL ban dau + (so buoc * trailing)
                  // SL ban dau = entry - SL_pips
                  // => SL moi = entry - SL_pips + steps * trailing
                  //           = entry + (steps * trailing - SL_pips)
                  // Vi du: SL=30, trailing=50, profit=50 pip, step=1
                  // => SL = entry + (50 - 30) = entry + 20 pip
                  double newSL = openPrice + (steps * trailDistance - slDistance);
                  newSL = NormalizeDouble(newSL, g_digits);
                  
                  if(newSL > currentSL)
                  {
                     trade.PositionModify(positionInfo.Ticket(), newSL, positionInfo.TakeProfit());
                  }
               }
            }
            else if(positionInfo.PositionType() == POSITION_TYPE_SELL)
            {
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double profitPips = (openPrice - ask) / g_pipValue;
               
               // Tinh so buoc hoan chinh
               int steps = (int)MathFloor(profitPips / TrailingPips);
               
               if(steps >= 1)
               {
                  // SL moi = entry - (steps * trailing - SL_pips)
                  double newSL = openPrice - (steps * trailDistance - slDistance);
                  newSL = NormalizeDouble(newSL, g_digits);
                  
                  if(newSL < currentSL || currentSL == 0)
                  {
                     trade.PositionModify(positionInfo.Ticket(), newSL, positionInfo.TakeProfit());
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Tạo panel                                                        |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 10;
   int y = 30;
   int lineHeight = 18;
   
   CreateLabel("RSI_Panel_Title", "=== RSI Calendar EA v1.00 ===", x, y, PanelColor, 12);
   y += lineHeight;
   
   CreateLabel("RSI_Panel_Telegram", "Telegram: t.me/Grokvn", x, y, clrAqua, 9);
   y += lineHeight + 3;
   
   CreateLabel("RSI_Panel_Symbol", "Symbol: " + _Symbol, x, y, PanelColor, 10);
   y += lineHeight;
   
   CreateLabel("RSI_Panel_RSI", "RSI (" + GetTimeframeStr(RSI_Timeframe) + "): 0.00", x, y, PanelColor, 10);
   y += lineHeight;
   
   CreateLabel("RSI_Panel_Trend", "Trend (D1): ---", x, y, PanelColor, 10);
   y += lineHeight;
   
   CreateLabel("RSI_Panel_Signal", "Signal: WAIT", x, y, clrGray, 10);
   y += lineHeight;
   
   CreateLabel("RSI_Panel_Orders", "Orders Today: 0/" + IntegerToString(MaxOrdersPerDay), x, y, PanelColor, 10);
   y += lineHeight;
   
   CreateLabel("RSI_Panel_OpenPos", "Open Position: NONE", x, y, clrGray, 10);
   y += lineHeight;
   
   // TP Limit info
   if(UseTPLimit)
   {
      CreateLabel("RSI_Panel_TPLimit", "TP Today: 0/" + IntegerToString(TPLimitPerDay) + " (running)", x, y, clrAqua, 10);
      y += lineHeight;
   }
   
   // Martingale info
   if(UseMartingale)
   {
      string martInfo = "Martingale: ON (x" + DoubleToString(MartingaleMultiplier, 1) + ") Start after L" + IntegerToString(MartingaleStartAfter);
      CreateLabel("RSI_Panel_Martingale", martInfo, x, y, clrOrange, 10);
      y += lineHeight;
      
      CreateLabel("RSI_Panel_LoseStreak", "Current Streak: W0 / L0 | Lot: " + DoubleToString(LotSize, 2), x, y, PanelColor, 10);
      y += lineHeight;
   }
   
   CreateLabel("RSI_Panel_WinLose", "Win: 0 | Lose: 0", x, y, clrGray, 10);
   y += lineHeight;
   
   // Statistics
   CreateLabel("RSI_Panel_MaxProfit", "Max Profit: 0.00 USD", x, y, clrLime, 10);
   y += lineHeight;
   
   CreateLabel("RSI_Panel_MaxLoss", "Max Loss: 0.00 USD", x, y, clrRed, 10);
   y += lineHeight;
   
   CreateLabel("RSI_Panel_MaxStreak", "Max Streak: W0 / L0", x, y, clrGray, 10);
   y += lineHeight;
   
   CreateLabel("RSI_Panel_MaxLot", "Max Lot: 0.00", x, y, clrOrange, 10);
}

//+------------------------------------------------------------------+
//| Tao label                                                        |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr, int fontSize)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Cập nhật panel                                                   |
//+------------------------------------------------------------------+
void UpdatePanel(double rsi, int trend)
{
   // RSI
   color rsiColor = rsi > RSI_BuyLevel ? clrGreen : (rsi < RSI_SellLevel ? clrRed : clrWhite);
   ObjectSetString(0, "RSI_Panel_RSI", OBJPROP_TEXT, "RSI (" + GetTimeframeStr(RSI_Timeframe) + "): " + DoubleToString(rsi, 2));
   ObjectSetInteger(0, "RSI_Panel_RSI", OBJPROP_COLOR, rsiColor);
   
   // Trend - display based on selected column
   string trendText = "";
   color trendColor = clrGray;
   string dayLabel = TrendDayShift == 1 ? "today" : (TrendDayShift == 2 ? "yesterday" : "D" + IntegerToString(TrendDayShift));
   if(trend == 1)
   {
      trendText = "GREEN (" + dayLabel + ") -> BUY ONLY";
      trendColor = clrLime;
   }
   else if(trend == -1)
   {
      trendText = "RED (" + dayLabel + ") -> SELL ONLY";
      trendColor = clrRed;
   }
   else
   {
      trendText = "NEUTRAL -> WAIT";
   }
   ObjectSetString(0, "RSI_Panel_Trend", OBJPROP_TEXT, "Trend (D1): " + trendText);
   ObjectSetInteger(0, "RSI_Panel_Trend", OBJPROP_COLOR, trendColor);
   
   // Signal (display RSI status)
   string signalText = "WAIT";
   color signalColor = clrGray;
   
   if(rsi >= RSI_BuyLevel && trend == 1)
   {
      signalText = "RSI CROSS UP " + DoubleToString(RSI_BuyLevel, 0) + " - BUY";
      signalColor = clrLime;
   }
   else if(rsi <= RSI_SellLevel && trend == -1)
   {
      signalText = "RSI CROSS DOWN " + DoubleToString(RSI_SellLevel, 0) + " - SELL";
      signalColor = clrRed;
   }
   else if(rsi > RSI_BuyLevel)
   {
      signalText = "RSI > " + DoubleToString(RSI_BuyLevel, 0) + " (wait trend)";
      signalColor = clrYellow;
   }
   else if(rsi < RSI_SellLevel)
   {
      signalText = "RSI < " + DoubleToString(RSI_SellLevel, 0) + " (wait trend)";
      signalColor = clrYellow;
   }
   
   ObjectSetString(0, "RSI_Panel_Signal", OBJPROP_TEXT, "Signal: " + signalText);
   ObjectSetInteger(0, "RSI_Panel_Signal", OBJPROP_COLOR, signalColor);
   
   // Orders
   ObjectSetString(0, "RSI_Panel_Orders", OBJPROP_TEXT, "Orders Today: " + IntegerToString(g_ordersToday) + "/" + IntegerToString(MaxOrdersPerDay));
   
   // Open position
   string openPosText = "NONE";
   color openPosColor = clrGray;
   double openPosProfit = 0;
   double openPosLot = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(positionInfo.SelectByIndex(i))
      {
         if(positionInfo.Symbol() == _Symbol && positionInfo.Magic() == MagicNumber)
         {
            openPosLot = positionInfo.Volume();
            openPosProfit = positionInfo.Profit() + positionInfo.Swap() + positionInfo.Commission();
            
            if(positionInfo.PositionType() == POSITION_TYPE_BUY)
            {
               openPosText = "BUY " + DoubleToString(openPosLot, 2) + " | P/L: " + DoubleToString(openPosProfit, 2);
               openPosColor = openPosProfit >= 0 ? clrLime : clrRed;
            }
            else
            {
               openPosText = "SELL " + DoubleToString(openPosLot, 2) + " | P/L: " + DoubleToString(openPosProfit, 2);
               openPosColor = openPosProfit >= 0 ? clrLime : clrRed;
            }
            break;  // Chi lay 1 lenh duy nhat
         }
      }
   }
   ObjectSetString(0, "RSI_Panel_OpenPos", OBJPROP_TEXT, "Open Position: " + openPosText);
   ObjectSetInteger(0, "RSI_Panel_OpenPos", OBJPROP_COLOR, openPosColor);
   
   // TP Limit info
   if(UseTPLimit)
   {
      string tpStatus = g_eaStopped ? " (STOPPED)" : " (running)";
      color tpColor = g_eaStopped ? clrRed : clrAqua;
      ObjectSetString(0, "RSI_Panel_TPLimit", OBJPROP_TEXT, "TP Today: " + IntegerToString(g_tpCountToday) + "/" + IntegerToString(TPLimitPerDay) + tpStatus);
      ObjectSetInteger(0, "RSI_Panel_TPLimit", OBJPROP_COLOR, tpColor);
   }
   
   // Martingale info
   if(UseMartingale)
   {
      double nextLot = CalculateMartingaleLot();
      color loseColor = PanelColor;
      string martStatus = "";
      
      if(g_loseStreak > 0 && g_loseStreak < MartingaleStartAfter)
      {
         // Dang cho - chua du so lan thua de gap thep
         martStatus = " [WAIT " + IntegerToString(MartingaleStartAfter - g_loseStreak) + " more]";
         loseColor = clrYellow;
      }
      else if(g_loseStreak >= MartingaleStartAfter)
      {
         // Dang gap thep
         martStatus = " [ACTIVE]";
         loseColor = clrOrange;
      }
      
      string streakText = "Streak: W" + IntegerToString(g_winStreak) + " / L" + IntegerToString(g_loseStreak) + " | Lot: " + DoubleToString(nextLot, 2) + martStatus;
      ObjectSetString(0, "RSI_Panel_LoseStreak", OBJPROP_TEXT, streakText);
      ObjectSetInteger(0, "RSI_Panel_LoseStreak", OBJPROP_COLOR, loseColor);
   }
   
   // Win/Lose stats
   ObjectSetString(0, "RSI_Panel_WinLose", OBJPROP_TEXT, "Win: " + IntegerToString(g_winCount) + " | Lose: " + IntegerToString(g_loseCount));
   
   // Max profit/loss stats (display account currency)
   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   ObjectSetString(0, "RSI_Panel_MaxProfit", OBJPROP_TEXT, "Max Profit: " + DoubleToString(g_maxProfit, 2) + " " + currency);
   ObjectSetString(0, "RSI_Panel_MaxLoss", OBJPROP_TEXT, "Max Loss: " + DoubleToString(g_maxLoss, 2) + " " + currency);
   
   // Max win/lose streak
   ObjectSetString(0, "RSI_Panel_MaxStreak", OBJPROP_TEXT, "Max Streak: W" + IntegerToString(g_maxWinStreak) + " / L" + IntegerToString(g_maxLoseStreak));
   
   // Max lot used
   ObjectSetString(0, "RSI_Panel_MaxLot", OBJPROP_TEXT, "Max Lot: " + DoubleToString(g_maxLotUsed, 2));
}

//+------------------------------------------------------------------+
//| Tao Calendar giong TradingView (goc phai)                        |
//+------------------------------------------------------------------+
void CreateCalendar()
{
   // Tinh toan vi tri calendar
   int chartWidth = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int cellSize = 22;
   int cellGap = 2;
   int calWidth = 7 * (cellSize + cellGap) + 10;
   int startX = chartWidth - calWidth - 10;
   int startY = 30;
   
   // Lay thang/nam hien tai
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_calendarMonth = dt.mon;
   g_calendarYear = dt.year;
   
   // Tinh so ngay trong thang
   int daysInMonth = GetDaysInMonth(g_calendarYear, g_calendarMonth);
   
   // Tinh ngay dau thang la thu may (0=Sunday)
   datetime firstDayTime = StringToTime(IntegerToString(g_calendarYear) + "." + IntegerToString(g_calendarMonth) + ".01");
   MqlDateTime firstDayDt;
   TimeToStruct(firstDayTime, firstDayDt);
   int firstDayOfWeek = firstDayDt.day_of_week;
   
   // Tieu de thang/nam
   string monthNames[] = {"", "January", "February", "March", "April", "May", "June", 
                          "July", "August", "September", "October", "November", "December"};
   string title = monthNames[g_calendarMonth] + " " + IntegerToString(g_calendarYear);
   CreateCalLabel("Cal_Title", title, startX + calWidth/2 - 50, startY, clrWhite, 10);
   startY += 20;
   
   // Header ngay trong tuan
   string dayNames[] = {"Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"};
   for(int i = 0; i < 7; i++)
   {
      int x = startX + i * (cellSize + cellGap);
      CreateCalLabel("Cal_Day_" + IntegerToString(i), dayNames[i], x + 4, startY, clrGray, 8);
   }
   startY += 18;
   
   // Load trend cho tung ngay trong thang
   LoadMonthTrends();
   
   // Ve cac o ngay
   int row = 0;
   int col = firstDayOfWeek;
   int bullishCount = 0;
   int totalDays = 0;
   
   for(int day = 1; day <= daysInMonth; day++)
   {
      int x = startX + col * (cellSize + cellGap);
      int y = startY + row * (cellSize + cellGap);
      
      // Lay trend cua ngay
      int trend = g_calendarTrend[day - 1];
      color cellColor = trend == 1 ? clrTeal : (trend == -1 ? clrMaroon : clrDimGray);
      color textColor = clrWhite;
      
      if(trend == 1) bullishCount++;
      if(trend != 0) totalDays++;
      
      // Ve o ngay
      string rectName = "Cal_Rect_" + IntegerToString(day);
      string textName = "Cal_Text_" + IntegerToString(day);
      
      CreateCalRect(rectName, x, y, cellSize, cellSize, cellColor);
      CreateCalLabel(textName, IntegerToString(day), x + (day < 10 ? 7 : 4), y + 4, textColor, 9);
      
      col++;
      if(col > 6)
      {
         col = 0;
         row++;
      }
   }
   
   // Hien thi % Bullish
   startY += (row + 1) * (cellSize + cellGap) + 5;
   int percent = totalDays > 0 ? (int)MathRound((double)bullishCount / totalDays * 100) : 0;
   CreateCalLabel("Cal_Percent", IntegerToString(percent) + "% Bullish", startX + calWidth/2 - 30, startY, clrWhite, 9);
}

//+------------------------------------------------------------------+
//| Load trend cho tung ngay trong thang                             |
//+------------------------------------------------------------------+
void LoadMonthTrends()
{
   ArrayInitialize(g_calendarTrend, 0);
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int today = dt.day;
   
   // Tinh trend cho moi ngay da qua trong thang
   for(int day = 1; day <= today; day++)
   {
      // Tim bar D1 tuong ung voi ngay
      datetime dayTime = StringToTime(IntegerToString(g_calendarYear) + "." + 
                                       IntegerToString(g_calendarMonth) + "." + 
                                       IntegerToString(day));
      int shift = iBarShift(_Symbol, PERIOD_D1, dayTime, false);
      if(shift >= 0)
      {
         g_calendarTrend[day - 1] = GetDailyTrend(shift);
      }
   }
}

//+------------------------------------------------------------------+
//| Lay so ngay trong thang                                          |
//+------------------------------------------------------------------+
int GetDaysInMonth(int year, int month)
{
   int days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
   if(month == 2 && ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0))
      return 29;
   return days[month - 1];
}

//+------------------------------------------------------------------+
//| Tao label cho calendar                                           |
//+------------------------------------------------------------------+
void CreateCalLabel(string name, string text, int x, int y, color clr, int fontSize)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Tao hinh chu nhat cho calendar                                   |
//+------------------------------------------------------------------+
void CreateCalRect(string name, int x, int y, int width, int height, color clr)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrBlack);
}

//+------------------------------------------------------------------+
//| Cap nhat Calendar                                                |
//+------------------------------------------------------------------+
void UpdateCalendar()
{
   // Kiem tra xem can cap nhat khong (ngay moi)
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   if(dt.mon != g_calendarMonth || dt.year != g_calendarYear)
   {
      // Thang moi - tao lai calendar
      ObjectsDeleteAll(0, "Cal_");
      CreateCalendar();
   }
   else
   {
      // Cap nhat trend ngay hom nay
      int today = dt.day;
      int shift = 0;  // Ngay hom nay
      g_calendarTrend[today - 1] = GetDailyTrend(shift);
      
      // Cap nhat mau o ngay hom nay
      int trend = g_calendarTrend[today - 1];
      color cellColor = trend == 1 ? clrTeal : (trend == -1 ? clrMaroon : clrDimGray);
      string rectName = "Cal_Rect_" + IntegerToString(today);
      ObjectSetInteger(0, rectName, OBJPROP_BGCOLOR, cellColor);
      
      // Cap nhat % Bullish
      int bullishCount = 0;
      int totalDays = 0;
      for(int day = 1; day <= today; day++)
      {
         if(g_calendarTrend[day - 1] == 1) bullishCount++;
         if(g_calendarTrend[day - 1] != 0) totalDays++;
      }
      int percent = totalDays > 0 ? (int)MathRound((double)bullishCount / totalDays * 100) : 0;
      ObjectSetString(0, "Cal_Percent", OBJPROP_TEXT, IntegerToString(percent) + "% Bullish");
   }
}

//+------------------------------------------------------------------+
//| Chuyen ENUM_TIMEFRAMES thanh chuoi ngan gon                      |
//+------------------------------------------------------------------+
string GetTimeframeStr(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";
      default:         return EnumToString(tf);
   }
}

//+------------------------------------------------------------------+
//| Ve duong phan cach ngay tren bieu do                             |
//+------------------------------------------------------------------+
void DrawDaySeparators()
{
   // Xoa cac duong cu
   ObjectsDeleteAll(0, "DaySep_");
   
   // Lay thong tin chart
   double priceHigh = ChartGetDouble(0, CHART_PRICE_MAX);
   double priceLow = ChartGetDouble(0, CHART_PRICE_MIN);
   
   // Ve duong cho 4 ngay gan nhat
   for(int i = 0; i < g_numDayLines; i++)
   {
      // Lay thoi gian bat dau cua ngay
      datetime dayTime[];
      ArraySetAsSeries(dayTime, true);
      if(CopyTime(_Symbol, PERIOD_D1, i, 1, dayTime) < 1) continue;
      
      datetime dayStart = dayTime[0];
      
      // Lay trend cua ngay
      int trend = GetDailyTrend(i);
      color lineColor = trend == 1 ? clrTeal : (trend == -1 ? clrMaroon : clrGray);
      
      // Tao duong doc
      string lineName = "DaySep_" + IntegerToString(i);
      
      if(ObjectFind(0, lineName) >= 0)
         ObjectDelete(0, lineName);
      
      ObjectCreate(0, lineName, OBJ_VLINE, 0, dayStart, 0);
      ObjectSetInteger(0, lineName, OBJPROP_COLOR, lineColor);
      ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_DOT);  // Net dut
      ObjectSetInteger(0, lineName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, lineName, OBJPROP_BACK, true);        // Hien thi phia sau chart
      ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lineName, OBJPROP_HIDDEN, true);
   }
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
