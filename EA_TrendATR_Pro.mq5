//+------------------------------------------------------------------+
//| EA_TrendATR_Pro.mq5                                              |
//| Conservative trend-following EA for MT5                         |
//| Strategy: EMA 50/200 + ADX + ATR risk management                |
//| Use on DEMO first. No strategy guarantees profit.                |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "EMA 50/200 + ADX + ATR trend-following EA"

#include <Trade/Trade.mqh>

CTrade trade;

//--------------------------- Inputs ---------------------------------
input ulong   InpMagic              = 26082026;
input double  InpRiskPercent        = 0.50;   // Risk per trade (% equity)
input int     InpFastEMA             = 50;
input int     InpSlowEMA             = 200;
input int     InpADXPeriod           = 14;
input double  InpMinADX              = 20.0;
input int     InpATRPeriod           = 14;
input double  InpSL_ATR              = 2.0;
input double  InpTP_ATR              = 3.0;

input bool    InpUseBreakEven        = true;
input double  InpBE_Trigger_ATR      = 1.0;
input double  InpBE_Lock_ATR         = 0.10;

input bool    InpUseTrailing         = true;
input double  InpTrail_ATR           = 1.5;

input int     InpMaxSpreadPoints     = 80;     // 0 = disabled
input int     InpStartHour           = 7;      // Broker/server hour
input int     InpEndHour             = 22;     // Broker/server hour
input bool    InpOnePositionSymbol   = true;
input bool    InpTradeOnNewBarOnly   = true;

//------------------------- Handles ----------------------------------
int hFastEMA = INVALID_HANDLE;
int hSlowEMA = INVALID_HANDLE;
int hADX     = INVALID_HANDLE;
int hATR     = INVALID_HANDLE;

datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);

   hFastEMA = iMA(_Symbol, _Period, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, _Period, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hADX     = iADX(_Symbol, _Period, InpADXPeriod);
   hATR     = iATR(_Symbol, _Period, InpATRPeriod);

   if(hFastEMA == INVALID_HANDLE ||
      hSlowEMA == INVALID_HANDLE ||
      hADX     == INVALID_HANDLE ||
      hATR     == INVALID_HANDLE)
   {
      Print("Gagal membuat indicator handle. Error=", GetLastError());
      return INIT_FAILED;
   }

   Print("EA TrendATR Pro aktif pada ", _Symbol, " / ", EnumToString(_Period));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hFastEMA != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hADX     != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   ManageOpenPosition();

   if(InpTradeOnNewBarOnly && !IsNewBar())
      return;

   if(!TradingAllowed())
      return;

   if(InpOnePositionSymbol && HasOurPosition())
      return;

   double fast[3], slow[3], adx[3], plusDI[3], minusDI[3], atr[3], closePrice[3];

   // Shift 1 = last fully closed candle, shift 2 = candle before it.
   if(CopyBuffer(hFastEMA, 0, 1, 3, fast) < 3) return;
   if(CopyBuffer(hSlowEMA, 0, 1, 3, slow) < 3) return;
   if(CopyBuffer(hADX,     0, 1, 3, adx) < 3) return;
   if(CopyBuffer(hADX,     1, 1, 3, plusDI) < 3) return;
   if(CopyBuffer(hADX,     2, 1, 3, minusDI) < 3) return;
   if(CopyBuffer(hATR,     0, 1, 3, atr) < 3) return;
   if(CopyClose(_Symbol, _Period, 1, 3, closePrice) < 3) return;

   double atrValue = atr[0];
   if(atrValue <= 0.0)
      return;

   // Trend confirmation:
   // BUY: EMA50 > EMA200, ADX strong, +DI > -DI, close above EMA50.
   bool buySignal =
      fast[0] > slow[0] &&
      adx[0] >= InpMinADX &&
      plusDI[0] > minusDI[0] &&
      closePrice[0] > fast[0];

   // SELL: EMA50 < EMA200, ADX strong, -DI > +DI, close below EMA50.
   bool sellSignal =
      fast[0] < slow[0] &&
      adx[0] >= InpMinADX &&
      minusDI[0] > plusDI[0] &&
      closePrice[0] < fast[0];

   if(buySignal)
      OpenTrade(ORDER_TYPE_BUY, atrValue);
   else if(sellSignal)
      OpenTrade(ORDER_TYPE_SELL, atrValue);
}

//+------------------------------------------------------------------+
//| Open a trade                                                      |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double atrValue)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (type == ORDER_TYPE_BUY ? ask : bid);

   double slDistance = atrValue * InpSL_ATR;
   double tpDistance = atrValue * InpTP_ATR;

   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = (double)stopsLevel * _Point;

   if(slDistance < minStopDistance)
      slDistance = minStopDistance + 2.0 * _Point;

   if(tpDistance < minStopDistance)
      tpDistance = minStopDistance + 2.0 * _Point;

   double sl, tp;

   if(type == ORDER_TYPE_BUY)
   {
      sl = NormalizePrice(price - slDistance);
      tp = NormalizePrice(price + tpDistance);
   }
   else
   {
      sl = NormalizePrice(price + slDistance);
      tp = NormalizePrice(price - tpDistance);
   }

   double volume = CalculateRiskVolume(slDistance);
   if(volume <= 0.0)
   {
      Print("Volume tidak valid.");
      return;
   }

   bool ok = false;

   if(type == ORDER_TYPE_BUY)
      ok = trade.Buy(volume, _Symbol, 0.0, sl, tp, "TrendATR BUY");
   else
      ok = trade.Sell(volume, _Symbol, 0.0, sl, tp, "TrendATR SELL");

   if(!ok)
      Print("Order gagal. Retcode=", trade.ResultRetcode(),
            " / ", trade.ResultRetcodeDescription());
   else
      Print("Order berhasil. Volume=", volume, " SL=", sl, " TP=", tp);
}

//+------------------------------------------------------------------+
//| Risk-based position sizing                                        |
//+------------------------------------------------------------------+
double CalculateRiskVolume(double slDistance)
{
   if(InpRiskPercent <= 0.0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(slDistance <= 0.0 || tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;

   double lossPerLot = (slDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return 0.0;

   double volume = riskMoney / lossPerLot;
   return NormalizeVolume(volume);
}

//+------------------------------------------------------------------+
//| Manage break-even and ATR trailing                                |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(!PositionSelect(_Symbol))
      return;

   long magic = PositionGetInteger(POSITION_MAGIC);
   if((ulong)magic != InpMagic)
      return;

   long type = PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);

   double atrBuf[1];
   if(CopyBuffer(hATR, 0, 0, 1, atrBuf) < 1)
      return;

   double atr = atrBuf[0];
   if(atr <= 0.0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(type == POSITION_TYPE_BUY)
   {
      double profitDistance = bid - openPrice;
      double newSL = currentSL;

      if(InpUseBreakEven && profitDistance >= atr * InpBE_Trigger_ATR)
      {
         double beSL = NormalizePrice(openPrice + atr * InpBE_Lock_ATR);
         if(currentSL == 0.0 || beSL > currentSL)
            newSL = beSL;
      }

      if(InpUseTrailing)
      {
         double trailSL = NormalizePrice(bid - atr * InpTrail_ATR);
         if((newSL == 0.0 || trailSL > newSL) && trailSL > openPrice)
            newSL = trailSL;
      }

      if(newSL > 0.0 && (currentSL == 0.0 || newSL > currentSL + _Point))
         trade.PositionModify(_Symbol, newSL, currentTP);
   }
   else if(type == POSITION_TYPE_SELL)
   {
      double profitDistance = openPrice - ask;
      double newSL = currentSL;

      if(InpUseBreakEven && profitDistance >= atr * InpBE_Trigger_ATR)
      {
         double beSL = NormalizePrice(openPrice - atr * InpBE_Lock_ATR);
         if(currentSL == 0.0 || beSL < currentSL)
            newSL = beSL;
      }

      if(InpUseTrailing)
      {
         double trailSL = NormalizePrice(ask + atr * InpTrail_ATR);
         if((newSL == 0.0 || trailSL < newSL) && trailSL < openPrice)
            newSL = trailSL;
      }

      if(newSL > 0.0 && (currentSL == 0.0 || newSL < currentSL - _Point))
         trade.PositionModify(_Symbol, newSL, currentTP);
   }
}

//+------------------------------------------------------------------+
//| Check whether this EA already has a position                      |
//+------------------------------------------------------------------+
bool HasOurPosition()
{
   if(!PositionSelect(_Symbol))
      return false;

   return ((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic);
}

//+------------------------------------------------------------------+
//| Trading conditions                                                |
//+------------------------------------------------------------------+
bool TradingAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE))
      return false;

   if(InpMaxSpreadPoints > 0)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double spreadPoints = (ask - bid) / _Point;

      if(spreadPoints > InpMaxSpreadPoints)
         return false;
   }

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   if(InpStartHour == InpEndHour)
      return true;

   if(InpStartHour < InpEndHour)
      return (tm.hour >= InpStartHour && tm.hour < InpEndHour);

   // Overnight window, e.g. 22 -> 6.
   return (tm.hour >= InpStartHour || tm.hour < InpEndHour);
}

//+------------------------------------------------------------------+
//| New bar detector                                                  |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBar = iTime(_Symbol, _Period, 0);

   if(currentBar == 0)
      return false;

   if(currentBar != lastBarTime)
   {
      lastBarTime = currentBar;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Normalize price                                                   |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

//+------------------------------------------------------------------+
//| Normalize volume                                                  |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      return 0.0;

   volume = MathMax(minVol, MathMin(maxVol, volume));
   volume = MathFloor(volume / step) * step;

   int volDigits = 2;
   if(step < 0.01) volDigits = 3;
   if(step < 0.001) volDigits = 4;

   return NormalizeDouble(volume, volDigits);
}
//+------------------------------------------------------------------+
