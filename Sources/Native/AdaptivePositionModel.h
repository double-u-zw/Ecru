// Ecru's sole position model. Coordinates are PDF points; time is seconds.
// Inspired by Casiez et al.'s 1 Euro filter (CHI 2012). Original implementation.
#ifndef ECRU_ADAPTIVE_POSITION_MODEL_H
#define ECRU_ADAPTIVE_POSITION_MODEL_H
#include <algorithm>
#include <cmath>

namespace ecru {
struct Position { double x, y; };
struct PositionDefaults {
  static constexpr double minimum_dt_seconds = 0.0005;
  static constexpr double pause_seconds = 0.12;
  static constexpr double resumed_dt_seconds = 1.0 / 120;
  static constexpr double maximum_dt_seconds = 0.032;
  static constexpr double integration_hz = 480;
  static constexpr double minimum_cutoff_hz = 2.6;
  static constexpr double velocity_cutoff_hz = 2.0;
  static constexpr double speed_coefficient = 0.06;
  static constexpr double escape_start_pt = 0.60;
  static constexpr double escape_gain_hz_per_pt = 12.0;
  static constexpr double maximum_cutoff_hz = 32.0;
  static constexpr double maximum_lag_pt = 1.60;
  static constexpr double initial_lag_pt = 0.32;
  static constexpr double initial_extent_pt = 1.0;
  static constexpr double extent_lag_slope = 0.64;
  static constexpr double turn_cutoff_hz = 2.0;
  static constexpr double turn_coefficient = 0.38;
  static constexpr double turn_speed_floor = 2.0;
  static constexpr double maximum_turn_rad_per_second = 80.0;
};
class AdaptivePositionModel {
 public:
  struct Diagnostics { double speed=0, cutoff=0, error=0, lag_limited=0, turn=0; };
  Diagnostics diagnostics() const { return diagnostics_; }
  Position Update(double x, double y, double time) {
    if (!initialized_) {
      initialized_ = true;
      origin_ = raw_ = filtered_ = {x, y};
      time_ = last_motion_time_ = time;
      return filtered_;
    }
    const double elapsed = std::max(time - time_, PositionDefaults::minimum_dt_seconds);
    // A resumed stream must not spend the whole pause catching up to raw ink.
    const bool resumed = time - last_motion_time_ > PositionDefaults::pause_seconds;
    const double dt = resumed ? PositionDefaults::resumed_dt_seconds : std::min(elapsed, PositionDefaults::maximum_dt_seconds);
    const double dx = x - raw_.x, dy = y - raw_.y;
    if (resumed) { velocity_ = {0, 0}; angular_velocity_ = 0; }
    // Integrate a raw segment in bounded time steps. This keeps response close
    // across 60/120/240 Hz and subdivided/coalesced callbacks; no extra layer.
    const int steps = std::max(1, int(std::ceil(dt * PositionDefaults::integration_hz)));
    const double step = dt / steps;
    const double av = -std::expm1(-2 * pi * PositionDefaults::velocity_cutoff_hz * step);
    for (int i = 1; i <= steps; ++i) {
      // Smooth signed velocity before magnitude: tremor cancels rather than
      // being counted as a succession of fast intentional movements.
      const Position previous_velocity = velocity_;
      velocity_.x += av * (dx / elapsed - velocity_.x);
      velocity_.y += av * (dy / elapsed - velocity_.y);
      const double speed = std::hypot(velocity_.x, velocity_.y);
      const double previous_speed = std::hypot(previous_velocity.x, previous_velocity.y);
      // Signed, low-passed turning distinguishes a sustained small circle from
      // alternating transverse tremor. Never reset position or bypass filtering.
      double turn = 0;
      if (speed > PositionDefaults::turn_speed_floor && previous_speed > PositionDefaults::turn_speed_floor) {
        turn = std::atan2(previous_velocity.x*velocity_.y-previous_velocity.y*velocity_.x,
                          previous_velocity.x*velocity_.x+previous_velocity.y*velocity_.y) / step;
      }
      const double at = -std::expm1(-2*pi*PositionDefaults::turn_cutoff_hz*step);
      angular_velocity_ += at*(std::clamp(turn,-PositionDefaults::maximum_turn_rad_per_second,PositionDefaults::maximum_turn_rad_per_second)-angular_velocity_);
      const double target_x = raw_.x + dx * i / steps;
      const double target_y = raw_.y + dy * i / steps;
      const double error = std::hypot(target_x-filtered_.x, target_y-filtered_.y);
      double cutoff = PositionDefaults::minimum_cutoff_hz + PositionDefaults::speed_coefficient * speed;
      // Spatial escape activates only outside the micro-motion band. It
      // protects short hooks and reversals when the slow derivative cancels.
      cutoff = std::max(cutoff, PositionDefaults::minimum_cutoff_hz + PositionDefaults::escape_gain_hz_per_pt * std::max(0.0, error - PositionDefaults::escape_start_pt));
      cutoff = std::max(cutoff, PositionDefaults::minimum_cutoff_hz +
                        PositionDefaults::turn_coefficient * std::abs(angular_velocity_));
      cutoff = std::min(cutoff, PositionDefaults::maximum_cutoff_hz);
      // Protect truly short strokes with a continuously expanding lag budget.
      // Extent, not accumulated path length, prevents tremor from opening it.
      extent_ = std::max(extent_, std::hypot(target_x-origin_.x,target_y-origin_.y));
      const double lag_budget = std::min(PositionDefaults::maximum_lag_pt,
          PositionDefaults::initial_lag_pt + PositionDefaults::extent_lag_slope *
          std::max(0.0, extent_-PositionDefaults::initial_extent_pt));
      // Bound spatial lag even for sparse, fast input; never snap to raw.
      const double alpha = std::max(-std::expm1(-2 * pi * cutoff * step),
                                    1.0 - lag_budget / std::max(error, 1e-12));
      diagnostics_ = {speed, cutoff, error,
          (1.0-lag_budget/std::max(error,1e-12)) > -std::expm1(-2*pi*cutoff*step) ? 1.0 : 0.0,
          angular_velocity_};
      if (dx != 0 || dy != 0) {
        filtered_.x += alpha * (target_x - filtered_.x);
        filtered_.y += alpha * (target_y - filtered_.y);
      }
    }
    // Exact stationary callbacks and lift never produce a late settling tail.
    if (dx != 0 || dy != 0) last_motion_time_ = time;
    raw_ = {x, y};
    time_ = time;
    return filtered_;
  }
 private:
  static constexpr double pi = 3.14159265358979323846;
  Diagnostics diagnostics_;
  bool initialized_ = false;
  Position origin_{0,0}, raw_{0, 0}, filtered_{0, 0}, velocity_{0, 0};
  double time_ = 0, last_motion_time_ = 0, angular_velocity_ = 0, extent_ = 0;
};
}  // namespace ecru
#endif
