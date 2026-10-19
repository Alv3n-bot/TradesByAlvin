//+------------------------------------------------------------------+
//|                                                    Functions.mqh |
//|                             Copyright 2000-2026, MetaQuotes Ltd. |
//|                                                     www.mql5.com |
//+------------------------------------------------------------------+
//--- custom function y=f(x,y)
typedef double(*MathFunction)(double, double);
//--- Math functions list
enum EnFunctionType
  {
   Chomolungma=1,
   ClimberDream=2,
   Granite=3,
   Hedgehog=4,
   Hill=5,
   Josephine=6,
   Screw=7,
   DoubleScrew=8,
   MultyExtremalScrew=9,
   Sink=10,
   Skin=11,
   Trapfall=12,
  };
//+------------------------------------------------------------------+
//|  Returns a pointer to a function by its type from FunctionType   |
//+------------------------------------------------------------------+
MathFunction GetMathFunction(EnFunctionType type)
  {
   MathFunction function=ClimberDreamFunction;
   switch(type)
     {
      case  Chomolungma:
         function=ChomolungmaFunction;
         break;
      case  ClimberDream:
         function=ClimberDreamFunction;
         break;
      case  Granite:
         function=GraniteFunction;
         break;
      case  Hedgehog:
         function=HedgehogFunction;
         break;
      case  Hill:
         function=HillFunction;
         break;
      case  Josephine:
         function=JosephineFunction;
         break;
      case  Screw:
         function=ScrewFunction;
         break;
      case  DoubleScrew:
         function=DoubleScrewFunction;
         break;
      case  MultyExtremalScrew:
         function=MultyExtremalScrewFunction;
         break;
      case  Sink:
         function=SinkFunction;
         break;
      case  Skin:
         function=SkinFunction;
         break;
      case  Trapfall:
         function=TrapfallFunction;
         break;
     }
   return(function);
  }
//+------------------------------------------------------------------+
//| Function Chomolungma                                             |
//+------------------------------------------------------------------+
double ChomolungmaFunction(double x, double y)
  {
   double a= MathCos(x*x)+MathCos(y*y);
   double b= MathPow(MathCos(5*x*y), 5);
   double c=1.0/MathPow(2, b);
//--- calculate result
   double res=a-c;
   return(res);
//---
  }
//+------------------------------------------------------------------+
//| Function ClimberDream                                            |
//+------------------------------------------------------------------+
double ClimberDreamFunction(double x, double y)
  {
   double a= MathSin(MathSqrt(MathAbs(x - 1.3) + MathAbs(y)));
   double b= MathCos(MathSqrt(MathAbs(MathSin(x))) + MathSqrt(MathAbs(MathSin(y))));
   double f=a+b;
//--- calculate result
   double res=MathPow(f, 4);
   return(res);
//---
  }
//+------------------------------------------------------------------+
//| Function Granite                                                 |
//+------------------------------------------------------------------+
double GraniteFunction(double x, double y)
  {
   double a= MathPow(MathSin(MathSqrt(MathAbs(x)+MathAbs(y))), 2);
   double b= MathPow(MathCos(MathSqrt(MathAbs(x)+MathAbs(y))), 2);
//--- calculate result
   double res=a*b;
   return(res);
//---
  }
//+------------------------------------------------------------------+
//| Function Hedgehog                                                |
//+------------------------------------------------------------------+
double HedgehogFunction(double x, double y)
  {
   double a1=MathSin(MathSqrt(MathAbs(x-2)+MathAbs(y)));
   double a2=MathCos(MathSqrt(MathAbs(MathSin(x)))+MathSqrt(MathAbs(MathSin(y))));
//--- calculate result
   double res=a1+a2;
   return(res);
//---
  }
//+------------------------------------------------------------------+
//| Function Hill                                                    |
//+------------------------------------------------------------------+
double HillFunction(double x, double y)
  {
//--- calculate result
   double res=MathExp(-x*x-y*y);
   return(res);
//---
  }
//+------------------------------------------------------------------+
//| Function Josephine                                               |
//+------------------------------------------------------------------+
double JosephineFunction(double x, double y)
  {
   double a= MathSin(MathPow(MathAbs(x)+MathAbs(y), 0.5));
   double b= MathCos(MathPow(MathAbs(x), 0.5)+MathPow(MathAbs(y), 0.5));
//--- calculate function
   double res=a+b;
   return(res);
//---
  }
//+------------------------------------------------------------------+
//| Function Screw                                                   |
//+------------------------------------------------------------------+
double ScrewFunction(double x, double y)
  {
   double a=(y==0)?0:((x*y<0)?MathArctan(x/y):MathArctan(x/y)+M_PI);
   double b=x*x+y*y;
   double f=MathSin(b+a);
//--- calculate result
   double  res=(f*f);
   return(res);
//---
  }
//+------------------------------------------------------------------+
//| Function DoubleScrew                                             |
//+------------------------------------------------------------------+
double DoubleScrewFunction(double x, double y)
  {
   double a=(y==0)?0:((x*y<0)?MathArctan(x/y):MathArctan(x/y)+M_PI);
   double b=x*x+y*y;
   double res1=MathCos(b/2+a*3);
   res1=((res1*res1)/sqrt(b+1)-0.2);
   double res2=MathCos(b/2-a*3);
   res2=((res2*res2)/sqrt(b+1)-0.2);
   double f=fmax(res1, res2);
//--- calculate result
   double    res=(f>0)?f:0;
   return(res);
//---
  }
//+------------------------------------------------------------------+
//| Function MultyExtremalScrew                                      |
//+------------------------------------------------------------------+
double MultyExtremalScrewFunction(double x, double y)
  {
   double a=(y==0)?0:((x*y<0)?MathArctan(x/y):MathArctan(x/y)+M_PI);
   double b=x*x+y*y;
   double res1=MathCos(b/2+a*3);
   res1=((res1*res1)/sqrt(b+1)-0.2);
   double res2=MathCos(b/2-a*3);
   res2=((res2*res2)/sqrt(b+1)-0.2);
//--- calculate function
   double res=fmin(res1, res2);
   return(res);
//---
  }
//+------------------------------------------------------------------+
//| Function Sink                                                    |
//+------------------------------------------------------------------+
double SinkFunction(double x, double y)
  {
   static double   k=5.0;
   static double   p=6.0;
//--- calculate result
   double     res=MathSin(x*x+y*y)+k*MathExp(-p*x*x-p*y*y);
   return(res);
//---
  }
//+------------------------------------------------------------------+
//| Function Skin                                                    |
//+------------------------------------------------------------------+
double SkinFunction(double x, double y)
  {
   double a1=2*x*x;
   double a2=2*y*y;
   double b1=MathCos(a1)-1.1;
   b1=b1*b1;
   double c1=MathSin(0.5*x)-1.2;
   c1=c1*c1;
   double d1=MathCos(a2)-1.1;
   d1=d1*d1;
   double e1=MathSin(0.5*y)-1.2;
   e1=e1*e1;
//--- calculate result
   double res=b1+c1-d1+e1;
   return(res);
//---
  }
//+------------------------------------------------------------------+
//| Function Trapfall                                                |
//+------------------------------------------------------------------+
double TrapfallFunction(double x, double y)
  {
   double a1=MathSqrt(MathAbs(MathSin(x-1.0)));
   double b1=MathSqrt(MathAbs(MathSin(y+2.0)));
//--- calculate result
   double     res=-MathSqrt(MathAbs(MathSin(MathSin(a1+b1))));
   return(res);
//---
  }
//+------------------------------------------------------------------+
