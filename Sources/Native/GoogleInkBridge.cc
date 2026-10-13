#include "InkModelerBridge.h"
#include "AdaptivePositionModel.h"
#include "EcruInkBuild.h"
#include <sstream>
#include <algorithm>
#include <cmath>
#include <memory>
#include <vector>
#include "ink/brush/brush.h"
#include "ink/brush/brush_behavior.h"
#include "ink/brush/easing_function.h"
#include "ink/strokes/in_progress_stroke.h"

namespace {
using B = ink::BrushBehavior;
struct WritingStroke {
  ink::InProgressStroke stroke;
  ecru::AdaptivePositionModel position;
  double x, y, last_x, last_y;
  double modeling_scale = 1;
  float time = 0, pressure = -1;
  bool finished = false;
  std::vector<EcruInkVertex> outline;
};
ink::BrushFamily WritingFamily(double sensitivity = -1) {
  ink::BrushTip tip;
  // Round, restrained daily pen. No direction/acceleration/velocity width,
  // rotating ellipse, or moving-tail width modulation at joins and reversals.
  tip.behaviors = {{.nodes = {
    B::SourceNode{.source=B::Source::kNormalizedPressure, .source_value_range={0,1}},
    B::ResponseNode{.response_curve={ink::EasingFunction::Linear{
      .points={{0.04f,0.18f},{0.12f,0.36f},{0.3f,0.61f},{0.6f,0.82f}}}}},
    B::DampingNode{.damp_over=B::ProgressDomain::kDistanceInMultiplesOfBrushSize,.strength=0.8f},
    B::TargetNode{.target=B::Target::kSizeMultiplier,.target_modifier_range={static_cast<float>(sensitivity < 0 ? 0.86 : 1-0.55*sensitivity),static_cast<float>(sensitivity < 0 ? 1.10 : 1+0.5*sensitivity)}}
  }}};
  return *ink::BrushFamily::Create(tip, {}, ink::BrushFamily::PassthroughModel{});
}
bool Update(WritingStroke& m, double x, double y, double pressure, double elapsed, bool release) {
  if(m.finished || !std::isfinite(x) || !std::isfinite(y) || !std::isfinite(elapsed) || elapsed<0 || elapsed>86400) return false;
  // A zero-pressure mouse-up at the same location carries no new pen input.
  // Finish the existing shape without extending time and reshaping its tail.
  if(release && x==m.last_x && y==m.last_y && m.stroke.InputCount()>0) {
    m.stroke.FinishInputs(); m.finished=true;
    return m.stroke.UpdateShape(ink::Duration32::Seconds(m.time)).ok();
  }
  // Preserve callback order and genuine elapsed time. Float timestamps need
  // a 0.5 ms floor only for collapsed timestamps. This retains their order
  // and gives each received sample finite influence instead of a 1 us impulse.
  float time=static_cast<float>(elapsed);
  if(m.stroke.InputCount()>0 && time<=m.time) time=std::max(m.time+0.0005f,std::nextafter(m.time,INFINITY));
  if(m.pressure>=0 && !release && std::isfinite(pressure) && pressure>=0)
    m.pressure=std::clamp(static_cast<float>(pressure),0.0f,1.0f);
  const auto modeled = m.position.Update((x-m.x)*m.modeling_scale, (y-m.y)*m.modeling_scale, time);
  ink::StrokeInput input{.tool_type=m.pressure>=0 ? ink::StrokeInput::ToolType::kStylus : ink::StrokeInput::ToolType::kMouse,
    .position={static_cast<float>(modeled.x/m.modeling_scale),static_cast<float>(modeled.y/m.modeling_scale)},
    .elapsed_time=ink::Duration32::Seconds(time),.pressure=m.pressure};
  ink::StrokeInputBatch batch;
  if(!batch.Append(input).ok() || !m.stroke.EnqueueInputs(batch,{}).ok()) return false;
  if(release) {m.stroke.FinishInputs();m.finished=true;}
  if(!m.stroke.UpdateShape(input.elapsed_time).ok()) return false;
  m.time=time;m.last_x=x;m.last_y=y;
  return true;
}
}
extern "C" void *ecru_google_ink_create(double x,double y,double width,double pressure) {
  return ecru_google_ink_create_scaled(x,y,width,pressure,2.0);
}
extern "C" void *ecru_google_ink_create_scaled(double x,double y,double width,double pressure,double view_scale) {
  return ecru_google_ink_create_configured(x,y,width,pressure,view_scale,-1);
}
extern "C" void *ecru_google_ink_create_configured(double x,double y,double width,double pressure,double view_scale,double sensitivity) {
  if(!std::isfinite(sensitivity) || sensitivity < -1 || sensitivity > 1) return nullptr;
  if(!std::isfinite(view_scale) || view_scale<=0) return nullptr;
  if(!std::isfinite(x)||!std::isfinite(y)||!std::isfinite(width)||width<0.1||width>256) return nullptr;
  auto m=std::make_unique<WritingStroke>();m->x=x;m->y=y;m->last_x=x;m->last_y=y;
  // Freeze the interaction scale for this stroke. Geometry/width remain PDF points.
  m->modeling_scale=view_scale/2.0;
  if(std::isfinite(pressure)&&pressure>=0) m->pressure=std::clamp(static_cast<float>(pressure),0.0f,1.0f);
  const auto family=WritingFamily(sensitivity);
  auto brush=ink::Brush::Create(family,ink::Color::Black(),width,std::min(0.025,width*0.015));
  if(!brush.ok()) return nullptr;
  m->stroke.Start(*brush);
  if(!Update(*m,x,y,pressure,0,false)) return nullptr;
  return m.release();
}
extern "C" void ecru_google_ink_destroy(void *handle) {delete static_cast<WritingStroke*>(handle);}
extern "C" int ecru_google_ink_update(void *handle,double x,double y,double pressure,double elapsed,int release) {
  return handle && Update(*static_cast<WritingStroke*>(handle),x,y,pressure,elapsed,release!=0);
}
extern "C" int ecru_google_ink_outline(void *handle,const EcruInkVertex **vertices) {
  if(!handle || !vertices) return -1;
  auto& m=*static_cast<WritingStroke*>(handle);m.outline.clear();
  const auto& mesh=m.stroke.GetMesh(0);
  for(auto contour:m.stroke.GetCoatOutlines(0)) {
    if(contour.size()<3) continue;
    bool start=true;
    for(auto i:contour) {
      auto p=mesh.VertexPosition(i);
      m.outline.push_back({m.x+p.x,m.y+p.y,start ? 1:0});start=false;
    }
  }
  *vertices=m.outline.data();return static_cast<int>(m.outline.size());
}

extern "C" const char *ecru_google_ink_configuration(void) {
  static const std::string config = [] {
    using P = ecru::PositionDefaults;
    std::ostringstream s;
    s << R"({"version":"0.5.0-beta.4","build":20,"recipe":"google-ink-daily-v5","model":"AdaptivePositionModel + Google Ink PassthroughModel","units":"interaction points at reference scale, seconds","referenceViewScale":2,"sourceSHA256":")"
      << ECRU_POSITION_SHA256 << R"(","minimumDtSeconds":)" << P::minimum_dt_seconds
      << R"(,"pauseSeconds":)" << P::pause_seconds
      << R"(,"resumedDtSeconds":)" << P::resumed_dt_seconds
      << R"(,"maximumDtSeconds":)" << P::maximum_dt_seconds
      << R"(,"integrationHz":)" << P::integration_hz
      << R"(,"minimumCutoffHz":)" << P::minimum_cutoff_hz
      << R"(,"velocityCutoffHz":)" << P::velocity_cutoff_hz
      << R"(,"speedCoefficient":)" << P::speed_coefficient
      << R"(,"escapeStartPt":)" << P::escape_start_pt
      << R"(,"escapeGainHzPerPt":)" << P::escape_gain_hz_per_pt
      << R"(,"maximumCutoffHz":)" << P::maximum_cutoff_hz
      << R"(,"maximumLagPt":)" << P::maximum_lag_pt
      << R"(,"initialLagPt":)" << P::initial_lag_pt
      << R"(,"initialExtentPt":)" << P::initial_extent_pt
      << R"(,"extentLagSlope":)" << P::extent_lag_slope
      << R"(,"turnCutoffHz":)" << P::turn_cutoff_hz
      << R"(,"turnCoefficient":)" << P::turn_coefficient
      << R"(,"turnSpeedFloor":)" << P::turn_speed_floor
      << R"(,"maximumTurnRadPerSecond":)" << P::maximum_turn_rad_per_second << "}";
    return s.str();
  }();
  return config.c_str();
}
