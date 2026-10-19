//+------------------------------------------------------------------+
//|                                          CorrelationMatrix3D.mq5 |
//|                             Copyright 2000-2026, MetaQuotes Ltd. |
//|                                                     www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2000-2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

//---
#include <Controls\Picture.mqh>
#include <Canvas\Canvas3D.mqh>
#include <Canvas\DX\DXBox.mqh>
//--- constants
#define BAR_WIDTH    1.25f
#define BAR_HEIGHT   5.0f

//--- input data
input color    InpBackground  = clrWhiteSmoke; // Background color
input datetime InpStartDate   = D'01.01.2015';
input datetime InpFinishDate  = D'01.11.2019';
input string   InpSymbolsList = "EURUSD,EURGBP,EURCHF,EURJPY,GBPUSD,GBPCHF,GBPJPY,USDCHF,USDJPY,CHFJPY";

//+------------------------------------------------------------------+
//| sSymbolData                                                      |
//+------------------------------------------------------------------+
struct sSymbolData
  {
   string            name;
   //--- synchronized close prices
   MqlRates          rates[];
   //--- percent of empty bars
   double            zero_data_percent;
   //--- times and returns (in points)
   datetime          returns_times[];
   double            returns_prices_points[];
   //--- array with current data window
   double            current_data_array[];
   bool              synchronized_flag;
   datetime          history_first_date;
  };
//+------------------------------------------------------------------+
//| Application window                                               |
//+------------------------------------------------------------------+
class CCanvas3DWindow
  {
protected:
   CPicture          m_picture;
   CCanvas3D         m_canvas;
   //---
   int               m_width;
   int               m_height;
   uint              m_background_color;
   uint              m_text_color;
   //--- function data
   double            m_data[];
   int               m_data_size;
   //--- source functions data
   CDXBox            m_boxes[];
   //---
   DXVector4         m_labels_x[];
   DXVector4         m_labels_z[];
   //--- rotation Y
   float             m_angle_y;
   float             m_angle_x;
   int               m_mouse_x_old;
   int               m_mouse_y_old;
   //--- price data for correlations calculations
   int               m_total_symbols;
   string            m_symbols_used;
   sSymbolData       m_symbols_data[];
   bool              m_data_ready;
   ENUM_TIMEFRAMES   m_timeframe;
   int               m_timeframe_minutes;
   //---
   datetime          m_date_start;          // start date
   datetime          m_date_finish;         // finish date
   //---
   datetime          m_date_current;        // date of data at current index
   int               m_index_current;       // current index
   int               m_index_boundary1;     // inital index for sliding window
   int               m_index_boundary2;     // final index for sliding window
   int               m_data_count;
   bool              m_symbol_selected[];   // array with flags to draw symbol
   //---
   int               m_window_size_bars;    // window size
   int               m_index_step_bars;     // sliding window
   int               m_time_format;         // time format
public:
   //+------------------------------------------------------------------+
   //| Constructor                                                      |
   //+------------------------------------------------------------------+
                     CCanvas3DWindow(void):m_angle_y(0),m_angle_x(0),m_mouse_x_old(-1),m_mouse_y_old(-1)
     {
     }
   //+------------------------------------------------------------------+
   //| Destructor                                                       |
   //+------------------------------------------------------------------+
                    ~CCanvas3DWindow(void)
     {
      int count=ArraySize(m_boxes);
      for(int i=0; i<count; i++)
         m_boxes[i].Shutdown();
     }

   //+------------------------------------------------------------------+
   //| Update boxes                                                     |
   //+------------------------------------------------------------------+
   bool              UpdateBoxes()
     {
      float offset=BAR_WIDTH*(m_data_size-1)/2.0f;
      DXMatrix translation;
      DXMatrix scale;
      DXColor clr;
      for(int i=0; i<m_data_size; i++)
         for(int j=0; j<m_data_size; j++)
           {
            int   idx=i*m_data_size+j;
            float value=(i==j)?0.0f:(float)m_data[idx];
            if(fabs(value)<0.001f || (!m_symbol_selected[i] && !m_symbol_selected[j]))
               value=0.001f;
            //--- check value sign, never use negative scale
            if(value>0)
              {
               DXMatrixTranslation(translation,i*BAR_WIDTH-offset,0.0,j*BAR_WIDTH-offset);
               DXMatrixScaling(scale,BAR_WIDTH,value*BAR_HEIGHT,BAR_WIDTH);
              }
            else
              {
               DXMatrixTranslation(translation,i*BAR_WIDTH-offset,value*BAR_HEIGHT,j*BAR_WIDTH-offset);
               DXMatrixScaling(scale,BAR_WIDTH,-value*BAR_HEIGHT,BAR_WIDTH);
              }
            //---
            DXMatrixMultiply(translation,scale,translation);
            m_boxes[idx].TransformMatrixSet(translation);
            if(i==j)
               clr=DXColor(0.5,0.5,0.5,1.0);
            else
               DXComputeColorRedToGreen((float)m_data[idx]*0.5f+0.5f,clr);
            m_boxes[idx].DiffuseColorSet(clr);
           }
      //--- prepare to scrren space projection matrix
      DXMatrix projection,view;
      m_canvas.ViewMatrixGet(view);
      m_canvas.ProjectionMatrixGet(projection);
      DXMatrixMultiply(projection,view,projection);
      for(int j=-1,idx=0; j<=1; j+=2)
         for(int i=0; i<m_data_size; i++,idx++)
           {
            //--- calculate labels positions in screen space
            DXVec4Transform(m_labels_x[idx],DXVector4(i*BAR_WIDTH-offset,0.0,j*(BAR_WIDTH+offset),1.0),projection);
            if(m_labels_x[idx].w>0)
               DXVec4Scale(m_labels_x[idx],m_labels_x[idx],1.0f/m_labels_x[idx].w);
            DXVec4Transform(m_labels_z[idx],DXVector4(j*(BAR_WIDTH+offset),0.0,i*BAR_WIDTH-offset,1.0),projection);
            if(m_labels_z[idx].w>0)
               DXVec4Scale(m_labels_z[idx],m_labels_z[idx],1.0f/m_labels_z[idx].w);
           }
      //---
      return(true);
     }
   //+------------------------------------------------------------------+
   //| Update boxes                                                     |
   //+------------------------------------------------------------------+
   bool              UpdateCamera()
     {
      DXVector4 camera=DXVector4(0.0f,0.0f,-30.0f,1.0f);
      DXVector4 light =DXVector4(0.25f,-0.25f,1.0f,0.0f);
      DXMatrix rotation;
      DXMatrixRotationX(rotation,m_angle_x);
      DXVec4Transform(camera,camera,rotation);
      DXVec4Transform(light,light,rotation);
      DXMatrixRotationY(rotation,m_angle_y);
      DXVec4Transform(camera,camera,rotation);
      DXVec4Transform(light,light,rotation);
      m_canvas.ViewPositionSet(DXVector3(camera));
      m_canvas.LightDirectionSet(DXVector3(light));
      //---
      return(true);
     }
   //+------------------------------------------------------------------+
   //| CopyRatesTimeSynchronized                                        |
   //+------------------------------------------------------------------+
   bool              CopyRatesTimeSynchronized(string symbol,ENUM_TIMEFRAMES timeframe,datetime time1,datetime time2,MqlRates &rates[])
     {
      //--- check parameters
      if(time1>=time2)
        {
         PrintFormat("Wrong times. Start time=%s, Finish time=%s",TimeToString(time1,TIME_DATE|TIME_MINUTES|TIME_SECONDS),TimeToString(time2,TIME_DATE|TIME_MINUTES|TIME_SECONDS));
         return(false);
        }
      //---
      ResetLastError();
      MqlRates server_rates[];
      ArraySetAsSeries(server_rates,false);
      int rates_copied=CopyRates(symbol,timeframe,time1,time2,server_rates);
      if(rates_copied==-1)
        {
         PrintFormat("CopyRates error, rates_copied=%d   Error=%d",rates_copied,GetLastError());
         return(false);
        }
      //---
      uint time_delta = uint(time2-time1);
      int data_needed = int(time_delta/(60*m_timeframe_minutes))+1;
      //--- prepare rates with correct continous times data
      ArrayResize(rates,data_needed);
      ArraySetAsSeries(rates,false);
      ZeroMemory(rates);
      //--- prepare times data
      int data_count=0;
      datetime time=time1;
      while(time<=time2)
        {
         rates[data_count].time=time;
         data_count++;
         time+=m_timeframe_minutes*60;
        }
      //--- analyze data gaps
      int total_gap_bars=0;
      int previous_time_index = 0;
      int fill_bars_needed=0;
      double current_price_close=0;
      double previous_price_close=0;
      for(int i=0; i<rates_copied; i++)
        {
         current_price_close=server_rates[i].close;
         int time_index = int ((server_rates[i].time-time1)/(60*m_timeframe_minutes));
         bool gap_found=((time_index-previous_time_index)>1);
         if(gap_found)
           {
            //--- gap needed to fill with previous close price
            if(time_index>=0 || time_index<data_count)
              {
               fill_bars_needed=time_index-previous_time_index-1;
               for(int k=0; k<fill_bars_needed; k++)
                 {
                  //rates[previous_time_index+k+1].close=previous_price_close;
                  rates[previous_time_index+k+1].close=0; // mark gap
                  total_gap_bars++;
                 }
               //--- current bar
               if(rates[time_index].time==server_rates[i].time)
                  rates[time_index].close=current_price_close;
               else
                 {
                  PrintFormat("The times are different:   %d  vs  %d",rates[time_index].time,server_rates[i].time);
                 }
              }
           }
         else
           {
            //--- no gap, normal set close price
            if(time_index>=0 || time_index<data_count)
              {
               rates[time_index].close=current_price_close;
              }
            else
              {
               Print("Error in time_index=%d",time_index);
              }
           }
         //---
         previous_time_index = time_index;
         previous_price_close = current_price_close;
        }
      //---
      int total_zero_bars=0;
      for(int i=0; i<data_count; i++)
        {
         if(rates[i].close==0)
            total_zero_bars++;
        }
      PrintFormat("Total=%d bars. Symbol=%s, time1=%s, time2=%s.  Total gaps filled=%d, Total zero bars=%d",data_count,symbol,
                  TimeToString(time1,TIME_DATE|TIME_MINUTES|TIME_SECONDS),TimeToString(time2,TIME_DATE|TIME_MINUTES|TIME_SECONDS),
                  total_gap_bars,total_zero_bars);
      //---
      return(true);
     }
   //+------------------------------------------------------------------+
   //| FilterNonzeroRates                                               |
   //+------------------------------------------------------------------+
   bool              FilterNonzeroRates(void)
     {
      if(m_total_symbols==0)
         return(false);
      if(ArraySize(m_symbols_data)!=m_total_symbols)
         return(false);
      //---
      int rates_count=ArraySize(m_symbols_data[0].rates);
      for(int i=0; i<m_total_symbols; i++)
        {
         if(ArraySize(m_symbols_data[i].rates)!=rates_count)
           {
            PrintFormat("Symbol: %s Wrong array size=%d vs %d",m_symbols_data[i].name,ArraySize(m_symbols_data[i].rates),rates_count);
            DebugBreak();
            return(false);
           }
        }
      //---
      int total_nonzero_rates=0;
      bool rates_flags[];
      ArrayResize(rates_flags,rates_count);
      ZeroMemory(rates_flags);
      for(int i=0; i<rates_count; i++)
        {
         int counter=0;
         for(int k=0; k<m_total_symbols; k++)
           {
            if(m_symbols_data[k].rates[i].close>0)
               counter++;
           }
         if(counter==m_total_symbols)
           {
            rates_flags[i]=true;
            total_nonzero_rates++;
           }
        }
      //---
      total_nonzero_rates=0;
      //--- filter nonzero rates
      for(int i=0; i<rates_count; i++)
        {
         if(rates_flags[i]==true)
           {
            for(int k=0; k<m_total_symbols; k++)
              {
               m_symbols_data[k].rates[total_nonzero_rates]=m_symbols_data[k].rates[i];
              }
            total_nonzero_rates++;
           }
        }
      for(int k=0; k<m_total_symbols; k++)
         ArrayResize(m_symbols_data[k].rates,total_nonzero_rates);
      PrintFormat("rates_count=%d  total_nonzero_rates=%d",rates_count,total_nonzero_rates);
      //---
      return(true);
     }
   //+------------------------------------------------------------------+
   //| PreparePriceReturnsInPoints                                      |
   //+------------------------------------------------------------------+
   bool              PreparePriceReturnsInPoints(int symbol_index)
     {
      double point_size=SymbolInfoDouble(m_symbols_data[symbol_index].name,SYMBOL_POINT);
      if(point_size==0)
        {
         PrintFormat("Wrong point size =%f for symbol=%s. ",point_size,m_symbols_data[symbol_index].name);
         return(false);
        }
      //---
      int data_count=ArraySize(m_symbols_data[symbol_index].rates);
      if(data_count==0)
         return(false);
      //--- prepare price returns in points
      int returns_count=data_count-1;
      ArrayResize(m_symbols_data[symbol_index].returns_times,returns_count);
      ArrayResize(m_symbols_data[symbol_index].returns_prices_points,returns_count);
      //---
      for(int i=0; i<returns_count; i++)
        {
         double price1=m_symbols_data[symbol_index].rates[i].close;
         double price2=m_symbols_data[symbol_index].rates[i+1].close;
         double delta=(price2-price1)/point_size;
         if(price1==0 || price2==0)
            delta=0;
         //---
         m_symbols_data[symbol_index].returns_prices_points[i]=delta;
         m_symbols_data[symbol_index].returns_times[i]=m_symbols_data[symbol_index].rates[i+1].time;
        }
      //---
      return(true);
     }
   //+------------------------------------------------------------------+
   //| SymbolsDataReady                                                 |
   //+------------------------------------------------------------------+
   bool              SymbolsDataReady(datetime start_date)
     {
      //---
      bool     all_symbols_synchronized = true;
      datetime first_date               = start_date;
      //---
      for(int n_tries=0; n_tries<100 && !IsStopped(); n_tries++, Sleep(50))
        {
         all_symbols_synchronized=true;
         //--- proceed all symbols
         for(int i=0; i<m_total_symbols; i++)
           {
            m_symbols_data[i].synchronized_flag=SeriesInfoInteger(m_symbols_data[i].name,m_timeframe,SERIES_SYNCHRONIZED);
            if(m_symbols_data[i].synchronized_flag)
              {
               if(SeriesInfoInteger(m_symbols_data[i].name,m_timeframe,SERIES_FIRSTDATE,(long&)m_symbols_data[i].history_first_date))
                 {
                  if(m_symbols_data[i].history_first_date>first_date)
                     first_date = m_symbols_data[i].history_first_date;
                  continue;
                 }
               else
                  Print("Symbol '",m_symbols_data[i].name,"' first date is not available");
              }
            else
               Print("Symbol '",m_symbols_data[i].name,"' is not synchronized");
            //--- try to check
            all_symbols_synchronized=false;
            datetime tmp[1];
            CopyTime(m_symbols_data[i].name,m_timeframe,first_date,1,tmp);
           }
         //--- all symbols synchonized
         if(all_symbols_synchronized)
            break;
         //---
         Print("Try again #",n_tries);
        }
      //--- check all synchronized
      if(!all_symbols_synchronized)
        {
         Print("Some symbols not ready to use:");
         for(int i=0; i<m_total_symbols; i++)
            if(!m_symbols_data[i].synchronized_flag)
               PrintFormat("%s ",m_symbols_data[i].name);
         return(false);
        }
      //---
      return(true);
     }
   //+------------------------------------------------------------------+
   //| PrepareData                                                      |
   //+------------------------------------------------------------------+
   bool              PrepareData(string symbols, datetime start_date,datetime finish_date)
     {
      //--- check dates
      if(start_date>finish_date)
        {
         PrintFormat("Error in dates settings:  start date=%s, finish date=%s",TimeToString(start_date,m_time_format),TimeToString(finish_date,m_time_format));
         return(false);
        }
      //---
      m_timeframe=PERIOD_D1;
      m_timeframe_minutes=GetTimeframeMinutes(m_timeframe);
      m_time_format=TIME_DATE;
      if(m_timeframe<PERIOD_H6)
         m_time_format|=TIME_MINUTES;
      //--- check if symbols exists
      string symbols_list[]= {};
      StringSplit(symbols,',',symbols_list);
      m_total_symbols=0;
      m_symbols_used="";
      for(int i=0; i<ArraySize(symbols_list); i++)
        {
         PrintFormat("%d  %s ",i,symbols_list[i]);
         bool is_custom=false;
         if(SymbolExist(symbols_list[i],is_custom)==false)
           {
            PrintFormat("Error. Symbol %s is not found.",symbols_list[i]);
            return(false);
           }
         m_total_symbols++;
         m_symbols_used+=" "+symbols_list[i];
        }
      //---
      if(m_total_symbols==0)
        {
         Print("No symbols.");
         return(false);
        }
      //---  resize selected flags
      ArrayResize(m_symbol_selected,m_total_symbols);
      ArrayInitialize(m_symbol_selected,true);
      //--- prepare structure for symbols
      ArrayResize(m_symbols_data,m_total_symbols);
      for(int i=0; i<m_total_symbols; i++)
         ZeroMemory(m_symbols_data[i]);
      for(int i=0; i<m_total_symbols; i++)
        {
         m_symbols_data[i].name=symbols_list[i];
         m_symbols_data[i].synchronized_flag=false;
        }
      //--- check data
      if(!SymbolsDataReady(start_date))
        {
         PrintFormat("Error. Symbols not synchronized.");
         return(false);
        }
      //---
      m_date_start=start_date;
      m_date_finish=finish_date;
      //--- Pass 1. prepare time synchronized data with gaps marked with rates[k].close=0;
      for(int i=0; i<m_total_symbols; i++)
        {
         if(CopyRatesTimeSynchronized(m_symbols_data[i].name,m_timeframe,m_date_start,m_date_finish,m_symbols_data[i].rates))
           {
            double point_size=SymbolInfoDouble(m_symbols_data[i].name,SYMBOL_POINT);
            if(point_size==0)
              {
               PrintFormat("Wrong point size =%f for symbol=%s. ",point_size,m_symbols_data[i].name);
               return(false);
              }
           }
         else
           {
            Print("Error in CopyRatesTimeSynchronized for symbol = %s ",m_symbols_data[i].name);
            return(false);
           }
        }
      //--- Pass 2. Filter nonzero quotes for all symbols
      FilterNonzeroRates();
      //--- Pass 3. Calculate return prices in points for all symbol
      for(int i=0; i<m_total_symbols; i++)
        {
         PreparePriceReturnsInPoints(i);
        }
      m_data_count=ArraySize(m_symbols_data[0].returns_prices_points);
      m_window_size_bars = 100;
      if(m_data_count<m_window_size_bars)
        {
         PrintFormat("Window size=%d is too small.",m_window_size_bars);
         return(false);
        }
      m_index_boundary1 = 0;
      m_index_boundary2 = m_data_count-1-m_window_size_bars;
      m_index_current   = 200;
      m_index_step_bars = 1;
      m_data_size=m_total_symbols;
      //---
      return(true);
     }
   //+------------------------------------------------------------------+
   //| CorrelationPearson                                               |
   //+------------------------------------------------------------------+
   double            CorrelationPearson(double &X[], double  &Y[])
     {
      int N = ArraySize(X);
      double sum_X = 0, sum_Y = 0, sum_XY = 0;
      double squareSum_X = 0, squareSum_Y = 0;
      for(int i=0; i<N; i++)
        {
         sum_X += X[i];
         sum_Y +=  Y[i];
         sum_XY +=  X[i]*Y[i];
         squareSum_X += X[i]*X[i];
         squareSum_Y += Y[i]*Y[i];
        }
      double multi_sigma=(N*squareSum_X-sum_X*sum_X)*(N*squareSum_Y-sum_Y*sum_Y);
      if(multi_sigma==0)
         return(0);
      double corr = (double)(N*sum_XY-sum_X*sum_Y)/MathSqrt(multi_sigma);
      //---
      return(corr);
     }
   //+------------------------------------------------------------------+
   //| CopyData                                                         |
   //+------------------------------------------------------------------+
   bool              CopyData(double &data_array[],const int index,int count,double &out_data_array[])
     {
      int size=ArraySize(data_array);
      if(size==0)
         return(false);
      //---
      if(index+count>size)
        {
         PrintFormat("Error in index=%d   count=%d   ArraySize(data_array)=%d",index,count,ArraySize(data_array));
         return(false);
        }
      //---
      ArrayResize(out_data_array,count);
      ZeroMemory(out_data_array);
      for(int i=0; i<count; i++)
        {
         out_data_array[i]=data_array[i+index];
        }
      //---
      return(true);
     }
   //+------------------------------------------------------------------+
   //| CalculatePearsonCoefficient                                      |
   //+------------------------------------------------------------------+
   bool              CalculatePearsonCoefficient(double &value,const int ind1,const int ind2, const int data_start_index, const int count)
     {
      value=0.0;
      //--- check parameters
      if(ind1<0 || ind1>=m_total_symbols)
         return(false);
      if(ind2<0 || ind2>=m_total_symbols)
         return(false);
      //---
      bool res1=CopyData(m_symbols_data[ind1].returns_prices_points,data_start_index,count,m_symbols_data[ind1].current_data_array);
      bool res2=CopyData(m_symbols_data[ind2].returns_prices_points,data_start_index,count,m_symbols_data[ind2].current_data_array);
      //--- check data
      int size1=ArraySize(m_symbols_data[ind1].current_data_array);
      if(size1==0)
         return(false);
      //---
      if(res1 && res2)
         value=CorrelationPearson(m_symbols_data[ind1].current_data_array,m_symbols_data[ind2].current_data_array);
      else
         return(false);
      //---
      return(true);
     }
   //+------------------------------------------------------------------+
   //| Prepare box geometry                                             |
   //+------------------------------------------------------------------+
   virtual bool      PrepareBoxes(void)
     {
      ArrayResize(m_boxes,m_data_size*m_data_size);
      //--- create boxes
      for(int i=0; i<m_data_size; i++)
         for(int j=0; j<m_data_size; j++)
           {
            int idx=i*m_data_size+j;
            m_data[idx]=0;
            m_boxes[idx].Create(m_canvas.DXDispatcher(),m_canvas.InputScene(),DXVector3(-0.45f,0.0,-0.45f),DXVector3(0.45f,1.0f,0.45f));
            m_boxes[idx].SpecularColorSet(DXColor(1.0f,1.0f,1.0f,0.5f));
            m_boxes[idx].SpecularPowerSet(128.0);
            m_canvas.ObjectAdd(&m_boxes[idx]);
           }
      //--- success
      return(true);
     }
   //+------------------------------------------------------------------+
   //| Create                                                           |
   //+------------------------------------------------------------------+
   virtual bool      Create(const int width,const int height,color background_color)
     {
      if(m_data_size<1)
        {
         PrintFormat("No symbols selected.");
         return(false);
        }
      //--- prepare the chart
      ChartSetInteger(0,CHART_SHOW,false);
      ChartRedraw();
      //--- save sizes
      m_width=width;
      m_height=height;
      if(m_width<1)
         m_width=1;
      if(m_height<1)
         m_height=1;
      //---
      ResetLastError();
      if(!m_canvas.CreateBitmapLabel("CorrelationMatrix3D",0,0,m_width,m_height,COLOR_FORMAT_ARGB_NORMALIZE))
        {
         Print("Error creating canvas: ",GetLastError());
         return(false);
        }
      //--- set colors
      m_background_color=ColorToARGB(background_color);
      if((GETRGBR(m_background_color)+GETRGBG(m_background_color)+GETRGBB(m_background_color))/3<128)
         m_text_color=ColorToARGB(clrWhite);
      else
         m_text_color=ColorToARGB(clrNavy);
      //---
      m_canvas.ProjectionMatrixSet((float)M_PI/6,(float)width/height,0.1f,100.0f);
      m_canvas.ViewTargetSet(DXVector3(0.0,0.0,0.0));
      m_canvas.ViewUpDirectionSet(DXVector3(0.0,1.0,0.0));
      m_canvas.LightColorSet(DXColor(1.0f,1.0f,0.9f,0.55f));
      m_canvas.AmbientColorSet(DXColor(0.9f,0.9f,1.0f,0.55f));
      m_angle_y=DX_PI/12.0f;
      m_angle_x=DX_PI/4.0f;
      //--- prepare data and boxes
      ArrayResize(m_data,m_data_size*m_data_size);
      if(!PrepareBoxes())
         return(false);
      //--- prepare label points
      ArrayResize(m_labels_x,2*m_data_size);
      ArrayResize(m_labels_z,2*m_data_size);
      //--- redraw data
      RedrawData();
      //--- succeed
      return(true);
     }
   //+------------------------------------------------------------------+
   //| Draw labels                                                      |
   //+------------------------------------------------------------------+
   void              DrawLabels()
     {
      int alignment=TA_CENTER|TA_VCENTER;
      //--- set font size
      int font_size=int(13.0*m_height/600.0+0.5);
      if(font_size<8)
         font_size=8;
      if(font_size>54)
         font_size=54;
      m_canvas.FontSizeSet(font_size);
      m_canvas.FontSet("Arial",font_size,FW_SEMIBOLD);
      //--- draw x axis on right side
      float dx1=m_labels_x[m_data_size-1].x-m_labels_x[0].x;
      float dx2=m_labels_x[m_data_size].x-m_labels_x[2*m_data_size-1].x;
      int tx=0,ty=0;
      if(dx1>dx2)
        {
         for(int i=0; i<m_data_size; i++)
           {
            tx=(int)(m_width*(0.5f+0.5f*m_labels_x[i].x));
            ty=(int)(m_height*(0.5f-0.5f*m_labels_x[i].y));
            m_canvas.TextOut(tx,ty,m_symbols_data[i].name,m_text_color,alignment);
           }
        }
      else
        {
         for(int i=0; i<m_data_size; i++)
           {
            int idx=i+m_data_size;
            tx=(int)(m_width*(0.5f+0.5f*m_labels_x[idx].x));
            ty=(int)(m_height*(0.5f-0.5f*m_labels_x[idx].y));
            m_canvas.TextOut(tx,ty,m_symbols_data[i].name,m_text_color,alignment);
           }
        }
      //--- draw z axis on right side
      dx1=m_labels_z[m_data_size-1].x-m_labels_z[0].x;
      dx2=m_labels_z[m_data_size].x-m_labels_z[2*m_data_size-1].x;
      //--- draw z axis on left side
      if(dx2>dx1)
        {
         for(int i=0; i<m_data_size; i++)
           {
            tx=(int)(m_width*(0.5f+0.5f*m_labels_z[i].x));
            ty=(int)(m_height*(0.5f-0.5f*m_labels_z[i].y));
            m_canvas.TextOut(tx,ty,m_symbols_data[i].name,m_text_color,alignment);
           }
        }
      else
        {
         for(int i=0; i<m_data_size; i++)
           {
            int idx=i+m_data_size;
            tx=(int)(m_width*(0.5f+0.5f*m_labels_z[idx].x));
            ty=(int)(m_height*(0.5f-0.5f*m_labels_z[idx].y));
            m_canvas.TextOut(tx,ty,m_symbols_data[i].name,m_text_color,alignment);
           }
        }
     }
   //+------------------------------------------------------------------+
   //| SetSelected                                                      |
   //+------------------------------------------------------------------+
   void              SetSelected(int number)
     {
      if(number<0 || number>=ArraySize(m_symbol_selected))
         return;
      //---
      m_symbol_selected[number]=!m_symbol_selected[number];
     }
   //+------------------------------------------------------------------+
   //| UpdateCorrelationMatrix                                          |
   //+------------------------------------------------------------------+
   void              UpdateCorrelationMatrix()
     {
      if(ArraySize(m_symbols_data)==0)
         return;
      //--- calculate matrix of Pearson coefficients
      for(int i=0; i<m_data_size; i++)
        {
         for(int j=i; j<m_data_size; j++)
           {
            if(i==j)
              {
               m_data[i*m_data_size+j]=1.0;
              }
            else
              {
               double value=0;
               if(CalculatePearsonCoefficient(value,i,j,m_index_current,m_window_size_bars))
                 {
                  m_data[i*m_data_size+j]=value;
                  m_data[j*m_data_size+i]=value;
                 }
              }
           }
        }
     }
   //+------------------------------------------------------------------+
   //| Update frame                                                     |
   //+------------------------------------------------------------------+
   void              Redraw()
     {
      //--- update
      m_canvas.Render(DX_CLEAR_COLOR|DX_CLEAR_DEPTH,m_background_color);
      string str=TimeToString(m_date_current,m_time_format);
      m_canvas.FontSet("Arial",64,FW_BLACK);
      m_canvas.TextOut(25,15,str,m_text_color,0);
      //--- draw axis labels
      DrawLabels();
      //---
      m_canvas.Update();
     }
   //+------------------------------------------------------------------+
   //| RedrawData                                                       |
   //+------------------------------------------------------------------+
   void              RedrawData()
     {
      UpdateCorrelationMatrix();
      UpdateCamera();
      UpdateBoxes();
      //---
      Redraw();
     }
   //+------------------------------------------------------------------+
   //| Process mouse moving event                                       |
   //+------------------------------------------------------------------+
   void              OnMouseEvent(int x,int y,uint flags)
     {
      if((flags&1)==1)
        {
         if(m_mouse_x_old!=-1)
           {
            m_angle_y+=(x-m_mouse_x_old)/300.0f;
            m_angle_x+=(y-m_mouse_y_old)/300.0f;
            if(m_angle_x<-DX_PI*0.49f)
               m_angle_x=-DX_PI*0.49f;
            if(m_angle_x>DX_PI*0.49f)
               m_angle_x=DX_PI*0.49f;
            //---
            RedrawData();
           }
         //---
         m_mouse_x_old=x;
         m_mouse_y_old=y;
        }
      else
        {
         m_mouse_x_old=-1;
         m_mouse_y_old=-1;
        }
     }
   //+------------------------------------------------------------------+
   //| Process chart change event                                       |
   //+------------------------------------------------------------------+
   void              OnChartChange(void)
     {
      //--- get current chart window size
      int w=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
      int h=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS);
      //--- update size everywhere it needed
      if(w!=m_width || h!=m_height)
        {
         m_width =w;
         m_height=h;
         if(m_width<1)
            m_width=1;
         if(m_height<1)
            m_height=1;
         m_canvas.Resize(w,h);
         DXContextSetSize(m_canvas.DXContext(),w,h);
         m_canvas.ProjectionMatrixSet((float)M_PI/6,(float)m_width/m_height,0.1f,100.0f);
         Redraw();
        }
     }
   //+------------------------------------------------------------------+
   //| Timer handler                                                    |
   //+------------------------------------------------------------------+
   void              OnTimer(void)
     {
      //--- update time
      m_index_current += m_index_step_bars;
      //--- reverse time
      if(m_index_current<m_index_boundary1)
        {
         m_index_step_bars *= -1;
         m_index_current=m_index_boundary1;
         m_date_current=m_symbols_data[0].returns_times[m_index_current+m_window_size_bars];
         PrintFormat("REVERSE TIME  %s at index=%d",TimeToString(m_date_current,m_time_format),m_index_current);
        }
      else
         if(m_index_current>m_index_boundary2)
           {
            m_index_step_bars *= -1;
            m_index_current=m_index_boundary2;
            m_date_current=m_symbols_data[0].returns_times[m_index_current+m_window_size_bars];
            PrintFormat("REVERSE TIME  %s at index=%d",TimeToString(m_date_current,m_time_format),m_index_current);
           }
      m_date_current=m_symbols_data[0].returns_times[m_index_current+m_window_size_bars];
      //---
      RedrawData();
     }
  };

CCanvas3DWindow   *ExtAppWindow;
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int               OnInit()
  {
   ChartSetInteger(0,CHART_EVENT_MOUSE_MOVE,1);
//--- get current chart window size
   int width =(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
   int height=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS);
//--- create canvas
   ExtAppWindow=new CCanvas3DWindow();
   if(!ExtAppWindow.PrepareData(InpSymbolsList,InpStartDate,InpFinishDate))
     {
      PrintFormat("Error. Rates data is not loaded.");
      return(INIT_FAILED);
     }
   if(!ExtAppWindow.Create(width,height,InpBackground))
     {
      return(INIT_FAILED);
     }
//--- set timer
   EventSetMillisecondTimer(10);
//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- destroy
   delete ExtAppWindow;
//--- revert chart showing mode
   ChartSetInteger(0,CHART_SHOW,true);
  }
//+------------------------------------------------------------------+
//| OnTick function                                                  |
//+------------------------------------------------------------------+
void OnTick()
  {
   ExtAppWindow.RedrawData();
  }
//+------------------------------------------------------------------+
//| ChartEvent function                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
//---
   if(id==CHARTEVENT_KEYDOWN)
     {
      if(lparam==27)
         ExpertRemove();
      if(lparam>='0' && lparam<='9')
        {
         int index=(int)(lparam-'1');
         if(index<0)
            index=9;
         ExtAppWindow.SetSelected(index);
        }
     }
   if(id==CHARTEVENT_CHART_CHANGE)
      ExtAppWindow.OnChartChange();
//--- process mouse moving
   if(id==CHARTEVENT_MOUSE_MOVE)
      ExtAppWindow.OnMouseEvent((int)lparam,(int)dparam,(uint)sparam);
  }
//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
  {
   ExtAppWindow.OnTimer();
  }
//+------------------------------------------------------------------+
//| GetTimeframeMinutes                                              |
//+------------------------------------------------------------------+
int GetTimeframeMinutes(ENUM_TIMEFRAMES timeframe)
  {
   switch(timeframe)
     {
      case PERIOD_M1:
         return(1);
      case PERIOD_M2:
         return(2);
      case PERIOD_M3:
         return(3);
      case PERIOD_M4:
         return(4);
      case PERIOD_M5:
         return(5);
      case PERIOD_M6:
         return(6);
      case PERIOD_M10:
         return(10);
      case PERIOD_M12:
         return(12);
      case PERIOD_M15:
         return(15);
      case PERIOD_M20:
         return(20);
      case PERIOD_M30:
         return(30);
      case PERIOD_H1:
         return(60);
      case PERIOD_H2:
         return(2*60);
      case PERIOD_H3:
         return(3*60);
      case PERIOD_H4:
         return(4*60);
      case PERIOD_H6:
         return(6*60);
      case PERIOD_H8:
         return(8*60);
      case PERIOD_H12:
         return(12*60);
      case PERIOD_D1:
         return(24*60);
      case PERIOD_W1:
         return(7*24*60);
      default:
         return(0);
     }
//---
   return(0);
  };
//+------------------------------------------------------------------+
