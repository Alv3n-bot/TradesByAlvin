//+------------------------------------------------------------------+
//|                                              DemoMorphMath3D.mq5 |
//|                             Copyright 2000-2026, MetaQuotes Ltd. |
//|                                                     www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2000-2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

//---
#include <Controls\Picture.mqh>
#include <Canvas\Canvas3D.mqh>
#include <Canvas\DX\DXSurface.mqh>
#include "Functions.mqh"

//--- resources
#define   TEXTURE_CHECKER "::Textures/checker.bmp"
#resource "Textures/checker.bmp"

//-- input data
input double   Inp_Morph_Time =3.0;     // Morphing time
input double   Inp_Freeze_Time=1.0;     // Fixing on result time
input int      Inp_Grid_Size  =150;     // Grid size
input color    Inp_Background =clrWhite;// Background color
input bool     Inp_UseChess   =false;   // Use chess texture


//+---------------------------------------------------------------------+
//| Chart constants                                                     |
//+---------------------------------------------------------------------+
#define CAMERA_ANGLES_TIMEOUT    3.0f
#define CAMERA_DISTANCE_TIMEOUT  3.0f
#define CAMERA_DISTANCE          40.0f
#define CAMERA_RETURN_STRENGTH   0.01f
#define CAMERA_ANGLE_Y_DEFAULT   DX_PI/6.0f
#define CAMERA_ANGLE_Y_SPEED     0.3f
//+------------------------------------------------------------------+
//| GenerateDataFixedSize                                            |
//+------------------------------------------------------------------+
bool NormalizeData(double &data[],double &data_min,double &data_max)
  {
   int data_size=ArraySize(data);
   if(data_size<1)
      return(false);
   data_min=DBL_MAX;
   data_max=-DBL_MAX;
   for(int i=0; i<data_size; i++)
     {
      if(data_min>data[i])
         data_min=data[i];
      if(data_max<data[i])
         data_max=data[i];
     }
   if(data_max-data_min<0.00001)
     {
      data_min=(data_max+data_min)/2.0-0.000005;
      data_max=data_min+0.00001;
     }
   double scale=1.0/(data_max-data_min);
   for(int i=0; i<data_size; i++)
     {
      data[i]*=scale;
     }
   data_min*=scale;
   data_max*=scale;
   return(true);
  }
//+------------------------------------------------------------------+
//| Application window                                               |
//+------------------------------------------------------------------+
class CCanvas3DWindow
  {
protected:
   CPicture          m_picture;
   CCanvas3D         m_canvas;
   //--- canvas data
   int               m_width;
   int               m_height;
   uint              m_background_color;
   uint              m_text_color;
   //--- source functions data
   int               morph_id1;
   int               morph_id2;
   int               m_data_size;
   double            m_data1[];
   double            m_data2[];
   double            m_data1_min;
   double            m_data2_min;
   double            m_data1_max;
   double            m_data2_max;
   int               m_functions_count;
   //--- last frame time
   double            m_last_frame;
   //--- morph data
   double            m_current_morph_factor;
   double            m_morpth_time;
   double            m_freeze_time;
   //--- camera data
   DXVector2         m_camera_angles;
   double            m_camera_angles_timeout;
   double            m_camera_distance;
   double            m_camera_distance_timeout;
   //--- input data
   int               m_mouse_x_old;
   int               m_mouse_y_old;
   //---
   CDXSurface        m_surface;

public:
   //+------------------------------------------------------------------+
   //| Constructor                                                      |
   //+------------------------------------------------------------------+
                     CCanvas3DWindow(void):m_mouse_x_old(-1),m_mouse_y_old(-1)
     {
     }
   //+------------------------------------------------------------------+
   //| Destructor                                                       |
   //+------------------------------------------------------------------+
                    ~CCanvas3DWindow(void)
     {
      //--- shutdown mesh
      m_surface.Shutdown();
     }
   //+------------------------------------------------------------------+
   //| DrawMesh                                                         |
   //+------------------------------------------------------------------+
   bool              UpdateMesh(void)
     {
      //--- calculate blend value
      double blend=sin(DX_PI*m_current_morph_factor/m_morpth_time-DX_PI/2.0)*0.5+0.5;
      //--- blend data
      double data[];
      int data_size=m_data_size*m_data_size;
      if(ArraySize(m_data1)<data_size || ArraySize(m_data2)<data_size || ArrayResize(data,data_size)<data_size)
         return(false);
      float min_value=(float)((1.0-blend)*m_data1_min+blend*m_data2_min);
      float max_value=(float)((1.0-blend)*m_data1_max+blend*m_data2_max);
      for(int j=0; j<m_data_size; j++)
         for(int i=0; i<m_data_size; i++)
           {
            int idx=j*m_data_size+i;
            data[idx]=(1.0-blend)*m_data1[idx]+blend*m_data2[idx];
           }
      //--- create new object
      m_surface.Update(data,(uint)m_data_size,(uint)m_data_size,max_value-min_value,DXVector3(-10,-5,-10),DXVector3(10,5,10),DXVector2(1.0f,1.0f),CDXSurface::SF_TWO_SIDED|CDXSurface::SF_USE_NORMALS,CDXSurface::CS_COLD_TO_HOT);
      //---
      return(true);
     }
   //+------------------------------------------------------------------+
   //| Update camera position                                           |
   //+------------------------------------------------------------------+
   bool              UpdateCamera(void)
     {
      DXVector4 camera=DXVector4(0.0f,0.0f,-(float)m_camera_distance,1.0f);
      DXVector4 light =DXVector4(0.25f,-0.25f,1.0f,0.0f);
      DXMatrix rotation;
      DXMatrixRotationX(rotation,m_camera_angles.x);
      DXVec4Transform(camera,camera,rotation);
      DXVec4Transform(light, light, rotation);
      DXMatrixRotationY(rotation,m_camera_angles.y);
      DXVec4Transform(camera,camera,rotation);
      DXVec4Transform(light, light, rotation);
      m_canvas.ViewPositionSet(DXVector3(camera));
      m_canvas.LightDirectionSet(DXVector3(light));
      //---
      return(true);
     }
   //+------------------------------------------------------------------+
   //| Create                                                           |
   //+------------------------------------------------------------------+
   virtual bool      Create(const int width,const int height)
     {
      //--- prepare the chart
      ChartSetInteger(0,CHART_SHOW,false);
      ChartRedraw();
      //--- save sizes
      m_width=width;
      m_height=height;
      //---
      ResetLastError();
      if(!m_canvas.CreateBitmapLabel("Morphing",0,0,m_width,m_height,COLOR_FORMAT_ARGB_NORMALIZE))
        {
         Print("Error creating canvas: ",GetLastError());
         return(false);
        }
      //--- set colors
      m_background_color=ColorToARGB(Inp_Background);
      if((GETRGBR(m_background_color)+GETRGBG(m_background_color)+GETRGBB(m_background_color))/3<128)
         m_text_color=ColorToARGB(clrWhite);
      else
         m_text_color=ColorToARGB(clrNavy);
      //---
      m_canvas.ProjectionMatrixSet((float)M_PI/6,(float)m_width/m_height,0.1f,100.0f);
      m_canvas.ViewTargetSet(DXVector3(0.0,-2.0,0.0));
      m_canvas.ViewUpDirectionSet(DXVector3(0.0,1.0,0.0));
      m_canvas.LightColorSet(DXColor(1.0f,1.0f,0.9f,0.27f));
      m_canvas.AmbientColorSet(DXColor(0.9f,0.9f,1.0f,0.8f));
      //--- set camera parameters
      m_camera_distance=CAMERA_DISTANCE;
      m_camera_distance_timeout=0.0;
      m_camera_angles=DXVector2(CAMERA_ANGLE_Y_DEFAULT,0.0);
      m_camera_angles_timeout=0.0;
      //--- set timers
      m_morpth_time=fabs(Inp_Morph_Time);
      m_freeze_time=fabs(Inp_Freeze_Time);
      //--- initial and final morph function
      m_functions_count=ArraySize(ExtFunctionsNames);
      morph_id1=MathRand()%m_functions_count;
      morph_id2=MathRand()%m_functions_count;
      if(morph_id2==morph_id1)
        {
         morph_id2=(morph_id1+1)%m_functions_count;
        }
      //--- initial morph settings
      m_current_morph_factor=0.0;
      m_last_frame=GetMicrosecondCount()/1000000.0;
      //--- save grid size with up and top limits
      m_data_size=Inp_Grid_Size;
      if(m_data_size<5)
         m_data_size=5;
      if(m_data_size>500)
         m_data_size=500;
      //--- generate end states data
      GenerateDataFixedSize(m_data_size,m_data_size,(EnMathFunction)morph_id1,m_data1);
      NormalizeData(m_data1,m_data1_min,m_data1_max);
      GenerateDataFixedSize(m_data_size,m_data_size,(EnMathFunction)morph_id2,m_data2);
      NormalizeData(m_data2,m_data2_min,m_data2_max);
      //--- create mesh
      if(!m_surface.Create(m_canvas.DXDispatcher(),m_canvas.InputScene(),m_data1,(uint)m_data_size,(uint)m_data_size,float(m_data1_max-m_data1_min),DXVector3(-10,-5,-10),DXVector3(10,5,10),DXVector2(1.0f,1.0f),CDXSurface::SF_TWO_SIDED|CDXSurface::SF_USE_NORMALS))
        {
         m_canvas.Destroy();
         return(false);
        }
      //--- set mesh parameters
      m_surface.SpecularColorSet(DXColor(1.0f,1.0f,1.0f,1.0f));
      if(Inp_UseChess)
         m_surface.TextureSet(m_canvas.DXDispatcher(),TEXTURE_CHECKER);
      //--- add mesh to scene
      m_canvas.ObjectAdd(&m_surface);
      //--- succeed
      return(true);
     }
   //+------------------------------------------------------------------+
   //| Update frame                                                     |
   //+------------------------------------------------------------------+
   void              Redraw()
     {
      //--- render 3D
      m_canvas.Render(DX_CLEAR_COLOR|DX_CLEAR_DEPTH,m_background_color);
      //--- draw text label
      int left=25,top=15;
      static int pos=left;
      m_canvas.FontSet("Arial",64,FW_BLACK);
      //---
      if(m_current_morph_factor<m_morpth_time)
        {
         //--- first function
         m_canvas.TextOut(left,top,ExtFunctionsNames[morph_id1],m_text_color,0);
         left+=m_canvas.TextWidth(ExtFunctionsNames[morph_id1]);
         //--- arrow
         m_canvas.TextOut(left,top-3," \x2192 ",m_text_color,0);
         left+=m_canvas.TextWidth(" \x2192 ");
         pos=left;
        }
      else
        {
         //--- move second function label to left while morphing freezed
         double t=(m_current_morph_factor-m_morpth_time)/m_freeze_time;
         t=0.5+0.5*sin(M_PI*t-M_PI/2.0);
         left=(int)((1-t)*pos+t*left);
        }
      //--- second function
      m_canvas.TextOut(left,top,ExtFunctionsNames[morph_id2],m_text_color,0);
      //--- update chart
      m_canvas.Update();
     }
   //+------------------------------------------------------------------+
   //| Process mouse moving event                                       |
   //+------------------------------------------------------------------+
   void              OnMouseMove(int x,int y,uint flags)
     {
      if((flags&1)==1)
        {
         if(m_mouse_x_old!=-1)
           {
            m_camera_angles.y+=(x-m_mouse_x_old)/300.0f;
            m_camera_angles.x+=(y-m_mouse_y_old)/300.0f;
            if(m_camera_angles.x<-DX_PI*0.49f)
               m_camera_angles.x=-DX_PI*0.49f;
            if(m_camera_angles.x>DX_PI*0.49f)
               m_camera_angles.x=DX_PI*0.49f;
            //---
            UpdateCamera();
           }
         //---
         m_mouse_x_old=x;
         m_mouse_y_old=y;
         //---
         m_camera_angles_timeout=CAMERA_ANGLES_TIMEOUT;
        }
      else
        {
         m_mouse_x_old=-1;
         m_mouse_y_old=-1;
        }
     }
   //+------------------------------------------------------------------+
   //| Process mouse moving event                                       |
   //+------------------------------------------------------------------+
   void              OnMouseWheel(double delta)
     {
      m_camera_distance*=1.0-delta*0.001;
      if(m_camera_distance>75.0)
         m_camera_distance=75.0;
      if(m_camera_distance<20.0)
         m_camera_distance=20.0;
      UpdateCamera();
      m_camera_distance_timeout=CAMERA_DISTANCE_TIMEOUT;
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
      double current_frame=GetMicrosecondCount()/1000000.0;
      double deltatime=current_frame-m_last_frame;
      if(deltatime>0.1)
         deltatime=0.1;
      m_last_frame=current_frame;
      m_current_morph_factor+=deltatime;


      if(m_current_morph_factor>=m_morpth_time+m_freeze_time)
        {
         m_current_morph_factor=0.0;
         int prev_id=morph_id1;
         //--- save second data to first
         morph_id1=morph_id2;
         ArraySwap(m_data1,m_data2);
         m_data1_min=m_data2_min;
         m_data1_max=m_data2_max;
         //--- generate new second data
         while(morph_id2==morph_id1 || morph_id2==prev_id)
           {
            morph_id2=MathRand()%m_functions_count;
           }
         GenerateDataFixedSize(m_data_size,m_data_size,(EnMathFunction)morph_id2,m_data2);
         NormalizeData(m_data2,m_data2_min,m_data2_max);

        }
      //--- generate morphed mesh
      if(m_current_morph_factor<=m_morpth_time)
         UpdateMesh();
      //---
      m_camera_angles_timeout-=deltatime;
      if(m_camera_angles_timeout<0.0)
        {
         m_camera_angles.y+=(float)deltatime*CAMERA_ANGLE_Y_SPEED;
         m_camera_angles.x=(1.0f-CAMERA_RETURN_STRENGTH)*m_camera_angles.x+CAMERA_RETURN_STRENGTH*CAMERA_ANGLE_Y_DEFAULT;
         UpdateCamera();
        }
      m_camera_distance_timeout-=deltatime;
      if(m_camera_distance_timeout<0.0 && m_camera_angles_timeout<0.0)
        {
         m_camera_distance=(1.0f-CAMERA_RETURN_STRENGTH)*m_camera_distance+CAMERA_RETURN_STRENGTH*CAMERA_DISTANCE;
         UpdateCamera();
        }
      //---
      Redraw();
     }
  };

//--- Global window
CCanvas3DWindow *ExtAppWindow=NULL;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   ChartSetInteger(0,CHART_EVENT_MOUSE_MOVE,1);
   ChartSetInteger(0,CHART_EVENT_MOUSE_WHEEL,1);
//--- get current chart window size
   int width =(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
   int height=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS);
//--- create canvas
   ExtAppWindow=new CCanvas3DWindow();
   if(!ExtAppWindow.Create(width,height))
      return(INIT_FAILED);
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
//--- kill timer
   EventKillTimer();
//--- revert chart showing mode
   ChartSetInteger(0,CHART_SHOW,true);
  }
//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
  {
   ExtAppWindow.OnTimer();
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
     }
   if(id==CHARTEVENT_CHART_CHANGE)
      ExtAppWindow.OnChartChange();
//--- process mouse moving
   if(id==CHARTEVENT_MOUSE_MOVE)
      ExtAppWindow.OnMouseMove((int)lparam,(int)dparam,(uint)sparam);
   if(id==CHARTEVENT_MOUSE_WHEEL)
      ExtAppWindow.OnMouseWheel(dparam);
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
