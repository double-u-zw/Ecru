#include "InkModelerBridge.h"
#include <algorithm>
#include <memory>
#include <vector>
#include "ink_stroke_modeler/stroke_modeler.h"
using namespace ink::stroke_model;
namespace {
struct Model {
  StrokeModeler modeler;
  double origin_x, origin_y, time = 0;
  std::vector<Result> stable, provisional;
};
}
extern "C" void *ecru_ink_create(double x, double y, double factor) {
  auto m = std::make_unique<Model>();
  m->origin_x = x; m->origin_y = y;
  StrokeModelParams p;
  p.wobble_smoother_params.is_enabled = false;
  p.position_modeler_params.spring_mass_constant = 0.00005;
  p.position_modeler_params.drag_constant = 250;
  auto &loop = p.position_modeler_params.loop_contraction_mitigation_params;
  loop.is_enabled = true;
  loop.speed_lower_bound = 10; loop.speed_upper_bound = 300;
  loop.interpolation_strength_at_speed_lower_bound = 0.55;
  loop.interpolation_strength_at_speed_upper_bound = 0.10;
  loop.min_speed_sampling_window = Duration(0.024);
  p.stylus_state_modeler_params.use_stroke_normal_projection = true;
  p.sampling_params.min_output_rate = 480;
  p.sampling_params.end_of_stroke_stopping_distance = 0.005;
  p.sampling_params.end_of_stroke_max_iterations = 32;
  p.sampling_params.max_outputs_per_call = 512;
  p.sampling_params.max_estimated_angle_to_traverse_per_input = 0.2;
  if (!m->modeler.Reset(p).ok()) return nullptr;
  Input input{.event_type=Input::EventType::kDown,.position={0,0},.time=Time(0),.pressure=static_cast<float>(factor/1.6)};
  if (!m->modeler.Update(input,m->stable).ok()) return nullptr;
  m->stable.clear();
  return m.release();
}
extern "C" void ecru_ink_destroy(void *handle) {delete static_cast<Model *>(handle);}
extern "C" int ecru_ink_update(void *handle, double x, double y, double factor, double time,
                               int release, EcruModeledPoint *points, int capacity, int *stable_count) {
  if (!handle || !points || capacity < 1024 || !stable_count) return -1;
  auto &m = *static_cast<Model *>(handle);
  // The host bounds gaps and guarantees a monotonic model clock. The native
  // engine never receives an invented location or a future extrapolation.
  if (!std::isfinite(time) || time <= m.time || time-m.time > 0.1) return -2;
  Input input{.event_type=release ? Input::EventType::kUp:Input::EventType::kMove,
              .position={static_cast<float>(x-m.origin_x),static_cast<float>(y-m.origin_y)},
              .time=Time(time),.pressure=static_cast<float>(factor/1.6)};
  m.stable.clear();m.provisional.clear();
  if (!m.modeler.Update(input,m.stable).ok()) return -3;
  if (!release && !m.modeler.Predict(m.provisional).ok()) return -4;
  if (m.stable.size()+m.provisional.size()>static_cast<size_t>(capacity)) return -5;
  *stable_count=static_cast<int>(m.stable.size());
  int count=0;
  for (const auto *list:{&m.stable,&m.provisional}) {
    for (const auto &r:*list) {
      points[count++]={m.origin_x+r.position.x,m.origin_y+r.position.y,r.pressure*1.6};
    }
  }
  m.time=time;
  return count;
}
