//+------------------------------------------------------------------+
//|                                        Smart Chandelier Exit.mq5 |
//|                                        Copyright 2026, algoteknik |
//+------------------------------------------------------------------+
#property copyright "algoteknik"
#property link      "https://www.mql5.com/en/users/algoteknik"
#property version   "1.00"
#property description "Smart Chandelier Exit — an adaptive ATR trailing-stop and trend-direction"
#property description "indicator with a built-in Pearson R trend-quality (regime) filter."
#property description "An on-chart panel shows the current direction, the active stop distance"
#property description "measured in R (ATR units), the R value with its regime label, and rolling"
#property description "statistics that separate genuine trend flips from short-lived fake flips."

#property indicator_chart_window
#property indicator_buffers 7
#property indicator_plots   2

#property indicator_label1  "CE Long SL"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLimeGreen
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "CE Short SL"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrCrimson
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== CE Parameters ==="
input int    InpATRPeriod  = 22;    // ATR period (stop distance sizing)
input int    InpLookback   = 22;    // Highest/Lowest lookback (bars)
input double InpMultiplier = 3.0;   // ATR multiplier (larger = wider stop)

input group "=== Pearson R (Trend Quality) ==="
input int    InpRPeriod        = 22;   // Correlation lookback (price vs time)
input double InpRStrongLevel   = 0.7;  // |R| >= this = Strong regime
input double InpRModerateLevel = 0.5;  // |R| >= this = Moderate regime

input group "=== Fake Flip Detection ==="
input int    InpFakeFlipBars = 5;      // A flip held <= this many bars is tagged FAKE

input group "=== Visual ==="
input bool   InpShowPanel  = true;      // Show info panel
input bool   InpShowFlips  = true;      // Show confirmed flip arrows
input int    InpCornerX    = 20;        // Panel offset from left edge (px)
input int    InpCornerY    = 20;        // Panel offset from top edge (px)

input group "=== Distance Unit ==="
enum ENUM_UNIT_MODE { UNIT_AUTO=0, UNIT_PIP=1, UNIT_POINT=2 };
input ENUM_UNIT_MODE InpUnitMode = UNIT_AUTO;  // Panel distance: auto / pip / point

input group "=== Alerts ==="
input bool   InpAlertOnFlip = false;   // Pop-up alert on confirmed flip
input bool   InpPushOnFlip  = false;   // Push notification on confirmed flip

//+------------------------------------------------------------------+
//| Buffers                                                          |
//+------------------------------------------------------------------+
double LongSLBuffer[];
double ShortSLBuffer[];
double DirectionBuffer[];
double LongRawBuffer[];
double ShortRawBuffer[];
double RBuffer[];
double ATRBuffer[];

int atrHandle = INVALID_HANDLE;

string panelPrefix = "CE_V2LW_";
string arrowPrefix = "CE_V2LW_Arr_";

string distLabel = "pt";
double distSize  = 1.0;

struct FlipRecord
{
   datetime time;
   int      direction;
   double   price;
   int      barsHeld;
   double   mfe, mae;
   bool     wasFake;
   double   rAtFlip;
};
FlipRecord flipHistory[];
int        flipCount = 0;

struct PendingArrow
{
   datetime flipTime;
   double   flipPrice;
   int      direction;
   int      flipBar;
   bool     drawn;
};
PendingArrow pendingArrows[];
int          pendingCount = 0;

int    curTrendStartBar   = -1;
double curTrendStartPrice = 0;
double curTrendMFE        = 0;
double curTrendMAE        = 0;
int    curDirection       = 0;

datetime lastFlipTime  = 0;
int      lastDirection = 0;

int    cachedTotalFlips = 0;
int    cachedFakeFlips  = 0;
double cachedFakeAvgR   = 0;
double cachedRealAvgR   = 0;
int    lastFlipCountForStats = -1;

bool   panelCreated = false;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpATRPeriod <= 0 || InpLookback <= 0 || InpRPeriod <= 0 || InpMultiplier <= 0)
   {
      Print("Smart Chandelier Exit: invalid input. Periods and multiplier must be greater than zero.");
      return INIT_PARAMETERS_INCORRECT;
   }

   SetIndexBuffer(0, LongSLBuffer,    INDICATOR_DATA);
   SetIndexBuffer(1, ShortSLBuffer,   INDICATOR_DATA);
   SetIndexBuffer(2, DirectionBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, LongRawBuffer,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(4, ShortRawBuffer,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, RBuffer,         INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, ATRBuffer,       INDICATOR_CALCULATIONS);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, DBL_MAX);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, DBL_MAX);

   int warmup = MathMax(MathMax(InpATRPeriod, InpLookback), InpRPeriod);
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, warmup);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, warmup);

   atrHandle = iATR(_Symbol, _Period, InpATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("Smart Chandelier Exit: ATR handle failed. Err=", GetLastError());
      return INIT_FAILED;
   }

   DetermineDistUnit();

   IndicatorSetString(INDICATOR_SHORTNAME,
      StringFormat("Smart Chandelier Exit [%d/%d/%.1f]",
                   InpATRPeriod, InpLookback, InpMultiplier));

   ArrayResize(flipHistory,   200);
   ArrayResize(pendingArrows, 100);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(atrHandle);
   ObjectsDeleteAll(0, panelPrefix);
   ObjectsDeleteAll(0, arrowPrefix);
   ChartRedraw();
}

//+------------------------------------------------------------------+
void DetermineDistUnit()
{
   if(InpUnitMode==UNIT_PIP)
   {
      distLabel="pip";
      distSize=(_Digits==5||_Digits==3)?_Point*10:_Point;
      return;
   }
   if(InpUnitMode==UNIT_POINT) { distLabel="pt"; distSize=_Point; return; }
   
   ENUM_SYMBOL_CALC_MODE cm=(ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_CALC_MODE);
   bool fx=(cm==SYMBOL_CALC_MODE_FOREX||cm==SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE);
   
   if(fx)
   { 
      distLabel="pip"; 
      distSize=(_Digits==5||_Digits==3)?_Point*10:_Point; 
   }
   else  
   { 
      // Endeks, Kripto ve Hisse senetleri için MT5 Point'i yerine direkt fiyat farkını kullan
      distLabel="";  
      distSize=1.0; 
   }
}

//+------------------------------------------------------------------+
double ComputePearsonR(int bar, const double &close[])
{
   int from = bar - InpRPeriod + 1;
   if(from < 0) return 0;

   double n = InpRPeriod;
   double mT = (n-1)/2.0;
   double mP = 0;
   for(int k=0; k<InpRPeriod; k++) mP += close[from+k];
   mP /= n;

   double covPT=0, varP=0, varT=0;
   for(int k=0; k<InpRPeriod; k++)
   {
      double dp = close[from+k] - mP;
      double dt = k - mT;
      covPT += dp*dt;
      varP  += dp*dp;
      varT  += dt*dt;
   }
   double d = MathSqrt(varP*varT);
   if(d<=0) return 0;
   double r = covPT/d;
   return MathMax(-1.0, MathMin(1.0, r));
}

//+------------------------------------------------------------------+
void RefreshRollingStats()
{
   if(flipCount == lastFlipCountForStats) return;
   lastFlipCountForStats = flipCount;

   cachedTotalFlips = 0; cachedFakeFlips = 0;
   double sumFR=0, sumRR=0;
   int fc=0, rc=0;

   int limit = MathMin(flipCount, 50);
   for(int i=flipCount-1; i>=flipCount-limit; i--)
   {
      cachedTotalFlips++;
      double ra = MathAbs(flipHistory[i].rAtFlip);
      if(flipHistory[i].wasFake) { cachedFakeFlips++; sumFR+=ra; fc++; }
      else { sumRR+=ra; rc++; }
   }
   cachedFakeAvgR = (fc>0) ? sumFR/fc : 0;
   cachedRealAvgR = (rc>0) ? sumRR/rc : 0;
}

//+------------------------------------------------------------------+
string DirLbl(int d) { return (d==1)?"BULLISH":(d==-1)?"BEARISH":"----"; }
color  DirClr(int d) { return (d==1)?clrLimeGreen:(d==-1)?clrCrimson:clrGray; }

string RegimeLbl(double r)
{
   double a=MathAbs(r);
   if(a>=InpRStrongLevel)   return (r>0)?"Strong UP":"Strong DOWN";
   if(a>=InpRModerateLevel) return (r>0)?"Moderate up":"Moderate down";
   if(a>=0.3)               return "Weak";
   return "RANGING";
}
color RegimeClr(double r)
{
   double a=MathAbs(r);
   if(a>=InpRStrongLevel)   return (r>0)?clrLime:clrRed;
   if(a>=InpRModerateLevel) return (r>0)?clrLightGreen:clrLightCoral;
   if(a>=0.3)               return clrGoldenrod;
   return clrGray;
}

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void MakeRect(string name, int x, int y, int w, int h)
{
   if(ObjectFind(0,name) < 0) ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,     w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,     h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,   C'15,15,15'); // Onyx Dark
   ObjectSetInteger(0,name,OBJPROP_COLOR,     C'200,120,0'); // DarkOrange/Gold border
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,    true);
   ObjectSetInteger(0,name,OBJPROP_BACK,      false);
}

void MakeLbl(string name, int x, int y, int fontSize, color clr, string font="Trebuchet MS")
{
   if(ObjectFind(0,name) < 0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE, y);
   ObjectSetString (0,name,OBJPROP_FONT,      font);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,  fontSize);
   ObjectSetInteger(0,name,OBJPROP_COLOR,     clr);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,    true);
   ObjectSetInteger(0,name,OBJPROP_BACK,      false);
}

void CreatePanelObjects()
{
   if(panelCreated) return;
   int x = InpCornerX;
   int y = InpCornerY;
   
   // Background
   MakeRect(panelPrefix+"BG", x, y, 220, 240);
   MakeLbl(panelPrefix+"Title", x+10, y+8, 10, clrWhite, "Trebuchet MS");
   ObjectSetString(0, panelPrefix+"Title", OBJPROP_TEXT, "SMART CHANDELIER EXIT");

   // --- SETUP ---
   MakeLbl(panelPrefix+"H1", x+10, y+35, 9, C'200,120,0', "Trebuchet MS");
   ObjectSetString(0, panelPrefix+"H1", OBJPROP_TEXT, "■ SETUP");
   
   MakeLbl(panelPrefix+"P_R_L", x+15, y+55, 9, clrSilver, "Consolas"); ObjectSetString(0, panelPrefix+"P_R_L", OBJPROP_TEXT, "Pearson R:");
   MakeLbl(panelPrefix+"P_R_V", x+100, y+55, 9, clrWhite, "Consolas");
   
   MakeLbl(panelPrefix+"Reg_L", x+15, y+70, 9, clrSilver, "Consolas"); ObjectSetString(0, panelPrefix+"Reg_L", OBJPROP_TEXT, "Regime:");
   MakeLbl(panelPrefix+"Reg_V", x+100, y+70, 9, clrWhite, "Consolas");

   MakeLbl(panelPrefix+"ATR_L", x+15, y+85, 9, clrSilver, "Consolas"); ObjectSetString(0, panelPrefix+"ATR_L", OBJPROP_TEXT, "ATR Base:");
   MakeLbl(panelPrefix+"ATR_V", x+100, y+85, 9, clrWhite, "Consolas");

   // --- EXECUTION ---
   MakeLbl(panelPrefix+"H2", x+10, y+110, 9, C'200,120,0', "Trebuchet MS");
   ObjectSetString(0, panelPrefix+"H2", OBJPROP_TEXT, "■ EXECUTION");
   
   MakeLbl(panelPrefix+"Dir_L", x+15, y+130, 9, clrSilver, "Consolas"); ObjectSetString(0, panelPrefix+"Dir_L", OBJPROP_TEXT, "Direction:");
   MakeLbl(panelPrefix+"Dir_V", x+100, y+130, 9, clrWhite, "Consolas");
   
   MakeLbl(panelPrefix+"Stop_L", x+15, y+145, 9, clrSilver, "Consolas"); ObjectSetString(0, panelPrefix+"Stop_L", OBJPROP_TEXT, "Stop Level:");
   MakeLbl(panelPrefix+"Stop_V", x+100, y+145, 9, clrWhite, "Consolas");
   
   MakeLbl(panelPrefix+"Dist_L", x+15, y+160, 9, clrSilver, "Consolas"); ObjectSetString(0, panelPrefix+"Dist_L", OBJPROP_TEXT, "Distance:");
   MakeLbl(panelPrefix+"Dist_V", x+100, y+160, 9, clrWhite, "Consolas");

   // --- INSIGHTS ---
   MakeLbl(panelPrefix+"H3", x+10, y+185, 9, C'200,120,0', "Trebuchet MS");
   ObjectSetString(0, panelPrefix+"H3", OBJPROP_TEXT, "■ INSIGHTS");
   
   MakeLbl(panelPrefix+"Fake_L", x+15, y+205, 9, clrSilver, "Consolas"); ObjectSetString(0, panelPrefix+"Fake_L", OBJPROP_TEXT, "Fake Flips:");
   MakeLbl(panelPrefix+"Fake_V", x+100, y+205, 9, clrWhite, "Consolas");
   
   MakeLbl(panelPrefix+"Last_L", x+15, y+220, 9, clrSilver, "Consolas"); ObjectSetString(0, panelPrefix+"Last_L", OBJPROP_TEXT, "Bars Since:");
   MakeLbl(panelPrefix+"Last_V", x+100, y+220, 9, clrWhite, "Consolas");

   panelCreated = true;
}

void SetLblTxt(string name, string txt, color clr=clrNONE)
{
   ObjectSetString(0, panelPrefix+name, OBJPROP_TEXT, txt);
   if(clr != clrNONE) ObjectSetInteger(0, panelPrefix+name, OBJPROP_COLOR, clr);
}

void UpdatePanel(int idx, const double &close[], const double &atr[])
{
   if(!InpShowPanel) return;
   CreatePanelObjects();

   int    curDir = (int)DirectionBuffer[idx];
   double rNow   = RBuffer[idx];
   double rPrev  = (idx>=3) ? RBuffer[idx-3] : rNow;
   double rDelta = rNow - rPrev;
   string dIcon  = (rDelta>0.10)?"^":(rDelta>0.02)?"~":(rDelta<-0.10)?"v":(rDelta<-0.02)?"_":"-";

   double activeSL = (curDir==1)?LongRawBuffer[idx]:ShortRawBuffer[idx];
   
   // DÜZELTME: MQL5'te close fiyatı Bid'dir. Short stop'lar Ask ile tetiklenir.
   // Gerçek SL mesafesini bulmak için Short yönünde fiyata spread ekleyerek Ask fiyatını buluyoruz.
   double livePrice = close[idx];
   if(curDir == -1) livePrice += SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;

   double slDist   = MathAbs(livePrice - activeSL);
   double slU      = (distSize>0) ? slDist/distSize : 0;
   double slR      = (atr[idx]>0) ? slDist/atr[idx] : 0;

   RefreshRollingStats();

   // Setup
   SetLblTxt("P_R_V", StringFormat("%.2f %s", rNow, dIcon), RegimeClr(rNow));
   SetLblTxt("Reg_V", RegimeLbl(rNow), RegimeClr(rNow));
   SetLblTxt("ATR_V", StringFormat("%d / %.1fx", InpATRPeriod, InpMultiplier), clrSilver);

   // Execution
   SetLblTxt("Dir_V", DirLbl(curDir), DirClr(curDir));
   SetLblTxt("Stop_V", DoubleToString(activeSL, _Digits), clrWhite);
   
   if(distLabel == "")
      SetLblTxt("Dist_V", StringFormat("%.1f (%.1fR)", slU, slR), clrSilver);
   else
      SetLblTxt("Dist_V", StringFormat("%.1f %s (%.1fR)", slU, distLabel, slR), clrSilver);

   // Insights
   double fakePct = (cachedTotalFlips>0) ? (cachedFakeFlips*100.0/cachedTotalFlips) : 0;
   color fakeClr = (fakePct>40) ? clrCrimson : (fakePct>20) ? clrGoldenrod : clrLimeGreen;
   SetLblTxt("Fake_V", StringFormat("%.1f%%", fakePct), fakeClr);
   
   int barsSince = (curTrendStartBar>0) ? (idx - curTrendStartBar) : 0;
   SetLblTxt("Last_V", StringFormat("%d bars", barsSince), clrSilver);

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   int warmup = MathMax(MathMax(InpATRPeriod,InpLookback),InpRPeriod);
   if(rates_total < warmup+2) return 0;

   int to_copy = (prev_calculated == 0) ? rates_total : (rates_total - prev_calculated + 1);
   double temp_atr[];
   if(CopyBuffer(atrHandle, 0, 0, to_copy, temp_atr) <= 0) return 0;
   
   int atr_offset = rates_total - to_copy;
   for(int i = 0; i < to_copy; i++)
   {
      ATRBuffer[atr_offset + i] = temp_atr[i];
   }

   bool fullRecalc = (prev_calculated==0);
   int  start;

   if(fullRecalc)
   {
      for(int i=0;i<warmup;i++)
      {
         LongSLBuffer[i]=ShortSLBuffer[i]=DBL_MAX;
         DirectionBuffer[i]=LongRawBuffer[i]=ShortRawBuffer[i]=RBuffer[i]=0;
      }
      start = warmup;
      flipCount=0; pendingCount=0;
      curTrendStartBar=-1; curDirection=0;
      lastFlipCountForStats=-1;
      panelCreated=false;
      lastDirection=0; lastFlipTime=0;   // alarm durumunu da sıfırla: TF/sembol degisiminde sahte flip alarmi cikmasin
      ObjectsDeleteAll(0, panelPrefix);
   }
   else { start = prev_calculated-1; }

   for(int i=start; i<rates_total; i++)
   {
      int from = MathMax(0, i-InpLookback+1);
      int count = i - from + 1;
      int highest_idx = ArrayMaximum(high, from, count);
      int lowest_idx  = ArrayMinimum(low, from, count);
      double hh = (highest_idx >= 0) ? high[highest_idx] : high[i];
      double ll = (lowest_idx >= 0) ? low[lowest_idx] : low[i];

      double longRaw  = hh - ATRBuffer[i]*InpMultiplier;
      double shortRaw = ll + ATRBuffer[i]*InpMultiplier;

      double pL=(i>0)?LongRawBuffer[i-1]:longRaw;
      double pS=(i>0)?ShortRawBuffer[i-1]:shortRaw;
      int    pD=(i>0)?(int)DirectionBuffer[i-1]:0;
      double pC=(i>0)?close[i-1]:close[i];

      double longSL  = (pC>pL) ? MathMax(longRaw,pL)  : longRaw;
      double shortSL = (pC<pS) ? MathMin(shortRaw,pS) : shortRaw;

      int dir=pD;
      if(dir==0)                        dir=(close[i]>longSL)?1:-1;
      else if(dir==1&&close[i]<longSL)  dir=-1;
      else if(dir==-1&&close[i]>shortSL)dir=1;

      DirectionBuffer[i]=dir;
      LongRawBuffer[i]=longSL; ShortRawBuffer[i]=shortSL;
      RBuffer[i] = ComputePearsonR(i, close);

      LongSLBuffer[i]  = (dir==1)  ? longSL  : DBL_MAX;
      ShortSLBuffer[i] = (dir==-1) ? shortSL : DBL_MAX;

      UpdateTrendStats(i, dir, pD, high[i], low[i], close[i], time[i],
                       rates_total, fullRecalc, RBuffer[i]);

      if(InpShowFlips && i>0 && dir!=pD && pD!=0)
      {
         if(pendingCount >= ArraySize(pendingArrows))
            ArrayResize(pendingArrows, ArraySize(pendingArrows) + 100, 1000); 
         pendingArrows[pendingCount].flipTime  = time[i];
         pendingArrows[pendingCount].flipPrice = (dir==1)?low[i]:high[i];
         pendingArrows[pendingCount].direction = dir;
         pendingArrows[pendingCount].flipBar   = i;
         pendingArrows[pendingCount].drawn     = false;
         pendingCount++;
      }

      if(InpShowFlips)
      {
         for(int p=0;p<pendingCount;p++)
         {
            if(pendingArrows[p].drawn) continue;
            if(i - pendingArrows[p].flipBar >= InpFakeFlipBars)
            {
               if(dir == pendingArrows[p].direction)
                  DrawFlipArrow(pendingArrows[p].flipTime,
                                pendingArrows[p].flipPrice,
                                pendingArrows[p].direction);
               pendingArrows[p].drawn = true;
            }
         }
      }
   }

   if(InpAlertOnFlip && rates_total>=2)
   {
      int cd=(int)DirectionBuffer[rates_total-2];
      if(lastDirection!=0 && cd!=lastDirection && time[rates_total-2]!=lastFlipTime)
      {
         string msg=StringFormat("[%s %s] CE FLIP: %s (R=%+.2f)",
                                 _Symbol,PeriodToString(_Period),
                                 (cd==1)?"BULL":"BEAR",RBuffer[rates_total-2]);
         Alert(msg);
         if(InpPushOnFlip) SendNotification(msg);
         lastFlipTime=time[rates_total-2];
      }
      lastDirection=(int)DirectionBuffer[rates_total-2];
   }

   if(InpShowPanel)
      UpdatePanel(rates_total-1, close, ATRBuffer);

   return rates_total;
}

//+------------------------------------------------------------------+
void UpdateTrendStats(int i, int dir, int prevDir,
                      double h, double l, double c, datetime t,
                      int rates_total, bool fullRecalc, double rVal)
{
   if(curDirection==0 && dir!=0)
   {
      curDirection=dir; curTrendStartBar=i;
      curTrendStartPrice=c; curTrendMFE=0; curTrendMAE=0;
      return;
   }
   if(prevDir!=0 && dir!=prevDir)
   {
      if(flipCount >= ArraySize(flipHistory))
         ArrayResize(flipHistory, ArraySize(flipHistory) + 200, 1000);
      {
         flipHistory[flipCount].time      = t;
         flipHistory[flipCount].direction = dir;
         flipHistory[flipCount].price     = c;
         flipHistory[flipCount].barsHeld  = i - curTrendStartBar;
         flipHistory[flipCount].mfe       = curTrendMFE;
         flipHistory[flipCount].mae       = curTrendMAE;
         flipHistory[flipCount].wasFake   = (flipHistory[flipCount].barsHeld <= InpFakeFlipBars);
         flipHistory[flipCount].rAtFlip   = rVal;
         flipCount++;
      }
      curDirection=dir; curTrendStartBar=i;
      curTrendStartPrice=c; curTrendMFE=0; curTrendMAE=0;
   }
   else
   {
      if(curDirection==1)
      {
         curTrendMFE=MathMax(curTrendMFE, h-curTrendStartPrice);
         curTrendMAE=MathMax(curTrendMAE, curTrendStartPrice-l);
      }
      else if(curDirection==-1)
      {
         curTrendMFE=MathMax(curTrendMFE, curTrendStartPrice-l);
         curTrendMAE=MathMax(curTrendMAE, h-curTrendStartPrice);
      }
   }
}

//+------------------------------------------------------------------+
void DrawFlipArrow(datetime t, double price, int direction)
{
   string name = arrowPrefix + IntegerToString((long)t);
   if(ObjectFind(0,name)>=0) return;
   if(ObjectCreate(0,name,OBJ_ARROW,0,t,price))
   {
      ObjectSetInteger(0,name,OBJPROP_ARROWCODE,(direction==1)?233:234);
      ObjectSetInteger(0,name,OBJPROP_COLOR,(direction==1)?clrLimeGreen:clrCrimson);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,(direction==1)?ANCHOR_TOP:ANCHOR_BOTTOM);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   }
}

//+------------------------------------------------------------------+
string PeriodToString(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";  case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15"; case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";  case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";  case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
      default: return EnumToString(tf);
   }
}
//+------------------------------------------------------------------+
