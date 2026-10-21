import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Effective automatic quality is transient; the user's chosen mode is durable.
final autoGlassProvider = NotifierProvider<AutoGlassPolicy, bool>(
  AutoGlassPolicy.new,
);

class AutoGlassPolicy extends Notifier<bool> {
  int _slow = 0, _steady = 0, _samples = 0;
  @override
  bool build() => false;
  void record(List<FrameTiming> timings) {
    for (final timing in timings) {
      if (++_samples < 60) continue;
      final slow = timing.rasterDuration.inMicroseconds > 16700;
      _slow = slow ? _slow + 1 : (_slow - 1).clamp(0, 60);
      _steady = slow ? 0 : _steady + 1;
      if (!state && _slow >= 20) {
        state = true;
        _steady = 0;
      }
      if (state && _steady >= 240) {
        state = false;
        _slow = 0;
        _steady = 0;
      }
    }
  }
}
