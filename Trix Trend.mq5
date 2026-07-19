//+------------------------------------------------------------------+
//|                                                      Trix Trend.mq5 |
//|                                        Copyright 2026, algoteknik |
//+------------------------------------------------------------------+
#property copyright "algoteknik"
#property link      "https://www.mql5.com/en/users/algoteknik"
#property version   "1.00"
#property description "Trix Trend — a triple-smoothed TRIX momentum oscillator with a slope-colored"
#property description "trend line, a weighted signal line, and dynamic overbought/oversold levels."
#property description "A crossover-preserving visual gap widens the line/signal spacing for clarity"
#property description "without moving the actual cross points, so signal reading stays accurate."

#include <MovingAverages.mqh>

#property indicator_separate_window
#property indicator_buffers 10  
#property indicator_plots   2   

//--- 1. Çizgi: TRIX
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrLimeGreen, clrRed, clrDimGray
#property indicator_width1  2
#property indicator_style1  STYLE_SOLID
#property indicator_label1  "Trix Trend"

//--- 2. Çizgi: Signal (Exaggerated)
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrGold
#property indicator_width2  1
#property indicator_style2  STYLE_DOT
#property indicator_label2  "Signal"

#property indicator_applied_price PRICE_CLOSE

//─────────────────────────────────────────────────────────────────
//  Kullanıcı Girdileri
//─────────────────────────────────────────────────────────────────
input group "--- TRIX Math ---"
input int    InpPeriodEMA             = 14;    
input int    InpPeriodSignalFast      = 3;     
input int    InpPeriodSignalSlow      = 9;     
input double InpFastWeight            = 0.7;   
input double InpSlowWeight            = 0.3;   
input bool   InpAutoNormalizeWeights  = true;  
input int    InpAmpPeriod             = 20;    

input group "--- Visual ---"
input double InpVisualGapMultiplier   = 2.5;   // Line/Signal visual gap (2.0 - 4.0; cross points preserved)
input double InpUpperLevel            =  5.0;  
input double InpLowerLevel            = -5.0;  

//─────────────────────────────────────────────────────────────────
//  Buffer Tanımlamaları
//─────────────────────────────────────────────────────────────────
double TRIX_Buffer[];
double TRIX_Color[];
double Signal_Buffer[];
double AdaptiveAmp_Buffer[]; 
double EMA[];
double SecondEMA[];
double ThirdEMA[];
double SignalFast_Calc[];
double SignalSlow_Calc[];
double AbsTRIX_Buffer[];

double g_FastW = 0.7;
double g_SlowW = 0.3;

int MinBars()
{
   return (3 * InpPeriodEMA - 2) + MathMax(InpPeriodSignalSlow, InpPeriodSignalFast) + InpAmpPeriod;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPeriodEMA < 2 || InpPeriodSignalFast < 1 || InpPeriodSignalSlow < 1 || InpAmpPeriod < 2)
   {
      Alert("Trix Trend: invalid parameters. Please check the minimum values.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   double wSum = InpFastWeight + InpSlowWeight;
   if(InpAutoNormalizeWeights)
   {
      if(wSum < DBL_EPSILON) return(INIT_PARAMETERS_INCORRECT);
      g_FastW = InpFastWeight / wSum;
      g_SlowW = InpSlowWeight / wSum;
   }
   else
   {
      if(MathAbs(wSum - 1.0) > 0.001) return(INIT_PARAMETERS_INCORRECT);
      g_FastW = InpFastWeight;
      g_SlowW = InpSlowWeight;
   }

   SetIndexBuffer(0,  TRIX_Buffer,         INDICATOR_DATA);
   SetIndexBuffer(1,  TRIX_Color,          INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2,  Signal_Buffer,       INDICATOR_DATA);
   SetIndexBuffer(3,  AdaptiveAmp_Buffer,  INDICATOR_DATA); 
   
   SetIndexBuffer(4,  EMA,                 INDICATOR_CALCULATIONS);
   SetIndexBuffer(5,  SecondEMA,           INDICATOR_CALCULATIONS);
   SetIndexBuffer(6,  ThirdEMA,            INDICATOR_CALCULATIONS);
   SetIndexBuffer(7,  SignalFast_Calc,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(8,  SignalSlow_Calc,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(9,  AbsTRIX_Buffer,      INDICATOR_CALCULATIONS);

   int trixBegin   = 3 * InpPeriodEMA - 2;
   int signalBegin = trixBegin + MathMax(InpPeriodSignalSlow, InpPeriodSignalFast);

   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, trixBegin);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, signalBegin);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetInteger(INDICATOR_DIGITS, 2);
   IndicatorSetInteger(INDICATOR_LEVELS, 3);
   IndicatorSetDouble(INDICATOR_LEVELVALUE,  0, 0.0);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 0, clrDimGray);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 0, STYLE_SOLID);
   IndicatorSetDouble(INDICATOR_LEVELVALUE,  1, InpUpperLevel);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 1, clrDodgerBlue);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 1, STYLE_DOT);
   IndicatorSetDouble(INDICATOR_LEVELVALUE,  2, InpLowerLevel);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 2, clrDarkOrange);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 2, STYLE_DOT);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const int begin,
                const double &price[])
{
   int minBars = MinBars();
   if(rates_total <= minBars) return(0);

   int trixBegin   = 3 * InpPeriodEMA - 2;
   int signalBegin = trixBegin + MathMax(InpPeriodSignalSlow, InpPeriodSignalFast);

   int start;
   if(prev_calculated == 0)
   {
      start = 1; 
      for(int i = 0; i < rates_total; i++)
      {
         TRIX_Buffer[i]        = EMPTY_VALUE;
         TRIX_Color[i]         = 2;
         Signal_Buffer[i]      = EMPTY_VALUE;
         AdaptiveAmp_Buffer[i] = 0.0;
         AbsTRIX_Buffer[i]     = 0.0;
         EMA[i]                = 0.0;
         SecondEMA[i]          = 0.0;
         ThirdEMA[i]           = 0.0;
         SignalFast_Calc[i]    = 0.0;
         SignalSlow_Calc[i]    = 0.0;
      }
   }
   else
   {
      start = MathMax(prev_calculated - 1, 1);
   }

   // ─── EMA zinciri
   ExponentialMAOnBuffer(rates_total, prev_calculated, 0, InpPeriodEMA, price, EMA);
   ExponentialMAOnBuffer(rates_total, prev_calculated, 0, InpPeriodEMA, EMA, SecondEMA);
   ExponentialMAOnBuffer(rates_total, prev_calculated, 0, InpPeriodEMA, SecondEMA, ThirdEMA);

   // ─── TRIX ve mutlak TRIX hesabı
   for(int i = start; i < rates_total && !IsStopped(); i++)
   {
      if(i < trixBegin)
      {
         TRIX_Buffer[i]    = EMPTY_VALUE;
         TRIX_Color[i]     = 2;
         AbsTRIX_Buffer[i] = 0.0;
         continue;
      }

      if(MathAbs(ThirdEMA[i-1]) > DBL_EPSILON)
         TRIX_Buffer[i] = 10000.0 * (ThirdEMA[i] - ThirdEMA[i-1]) / ThirdEMA[i-1];
      else
         TRIX_Buffer[i] = (i > trixBegin) ? TRIX_Buffer[i-1] : 0.0;

      AbsTRIX_Buffer[i] = MathAbs(TRIX_Buffer[i]);
   }

   // ─── Signal EMA'ları ve AdaptiveAmp SMA
   ExponentialMAOnBuffer(rates_total, prev_calculated, trixBegin, InpPeriodSignalFast, TRIX_Buffer, SignalFast_Calc);
   ExponentialMAOnBuffer(rates_total, prev_calculated, trixBegin, InpPeriodSignalSlow, TRIX_Buffer, SignalSlow_Calc);
   SimpleMAOnBuffer(rates_total, prev_calculated, trixBegin, InpAmpPeriod, AbsTRIX_Buffer, AdaptiveAmp_Buffer);

   // ─── Renk ve Sinyal Döngüsü
   for(int i = start; i < rates_total && !IsStopped(); i++)
   {
      if(i < trixBegin || TRIX_Buffer[i] == EMPTY_VALUE)
      {
         TRIX_Color[i] = 2;
         Signal_Buffer[i] = EMPTY_VALUE;
         continue;
      }

      // RENK MANTIĞI
      if(i > trixBegin && TRIX_Buffer[i-1] != EMPTY_VALUE)
      {
         double trixDelta = TRIX_Buffer[i] - TRIX_Buffer[i-1];
         double ampRef    = (AdaptiveAmp_Buffer[i] > DBL_EPSILON) ? AdaptiveAmp_Buffer[i] : MathAbs(TRIX_Buffer[i]) * 0.1;
         double threshold = MathMax(ampRef * 0.05, DBL_EPSILON * 100);

         if(trixDelta > threshold)       TRIX_Color[i] = 0; // Yeşil
         else if(trixDelta < -threshold) TRIX_Color[i] = 1; // Kırmızı
         else                            TRIX_Color[i] = 2; // Gri
      }

      // SİNYAL MANTIĞI VE GÖRSEL MAKYAJ (Sihrin Olduğu Yer)
      if(i >= signalBegin)
      {
         // 1. Orijinal Saf Sinyal
         double pure_signal = (SignalFast_Calc[i] * g_FastW) + (SignalSlow_Calc[i] * g_SlowW);
         
         // 2. Çapalı Büyüteç (Anchored Magnifier) Formülü
         // Kesişimi bozmadan, aradaki farkı 'InpVisualGapMultiplier' kadar açar.
         Signal_Buffer[i] = TRIX_Buffer[i] - ((TRIX_Buffer[i] - pure_signal) * InpVisualGapMultiplier);
      }
      else
      {
         Signal_Buffer[i] = EMPTY_VALUE;
      }
   }

   return(rates_total);
}
//+------------------------------------------------------------------+