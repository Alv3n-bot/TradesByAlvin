//+------------------------------------------------------------------+
//|                                                      Math_3D.mq5 |
//|                             Copyright 2000-2026, MetaQuotes Ltd. |
//|                                                     www.mql5.com |
//+------------------------------------------------------------------+
#include  "Functions.mqh"

#property optimization_chart_mode "3d,InpX,InpY"

//--- input parameters
sinput EnFunctionType InpFunction=Chomolungma;
input  double         InpX       =0.0;
input  double         InpY       =0.0;
//--- a pointer to the mathematical function
MathFunction ExtFunction;
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- this EA is designed for optimization
   if(!MQLInfoInteger(MQL_OPTIMIZATION))
     {
      MessageBox("This EA is designed for 3D visualization of optimization results\r\n\r\nRun this EA in the Strategy Tester using the Math Calculations mode!",
                 "EA warning", 0x00000030);
      return(INIT_FAILED);
     }
//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| TesterInit function                                              |
//+------------------------------------------------------------------+
int OnTesterInit()
  {
//--- get a pointer to a mathematical function by its type
   ExtFunction=GetMathFunction(InpFunction);
   Print(__FUNCTION__, ": ExtFunction=", ExtFunction);
//--- variables to get values during optimization
   double  x_cur, x_start, x_stop, x_step;
   double  y_cur, y_start, y_stop, y_step;
   bool    x_enable, y_enable;
//--- get parameter values
   ParameterGetRange("InpX", x_enable, x_cur, x_start, x_step, x_stop);
   ParameterGetRange("InpY", y_enable, y_cur, y_start, y_step, y_stop);
   PrintFormat("x=%G start=%G step=%G stop=%G", x_cur, x_start, x_step, x_stop);
   PrintFormat("y=%G start=%G step=%G stop=%G", y_cur, y_start, y_step, y_stop);
   PrintFormat("Function=%s", EnumToString(InpFunction));
//--- check if parameters are selected
   if(!x_enable || !y_enable)
     {
      Print("Select both parameters InpX and InpY for optimization! Optimization stopped");
      return (INIT_PARAMETERS_INCORRECT);
     }
//--- check input parameters
   if(x_step==0 || y_step==0)
     {
      Print("Specify non-zero value for x_step and y_step! Optimization stopped");
      return (INIT_PARAMETERS_INCORRECT);
     }
//---
   return (INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Tester function                                                  |
//+------------------------------------------------------------------+
double OnTester()
  {
//--- get a pointer to a mathematical function by its type
   ExtFunction=GetMathFunction(InpFunction);
//--- calculate function result
   double value=ExtFunction(InpX, InpY);
   return(value);
  }
//+------------------------------------------------------------------+
//| TesterDeinit function                                            |
//+------------------------------------------------------------------+
void OnTesterDeinit()
  {
//---

  }
//+------------------------------------------------------------------+
