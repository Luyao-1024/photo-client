import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// The material tier the adaptive scope settled on.
///
/// The user's choice in the settings is the ceiling; this is what the machine
/// could actually sustain on the last measured frames. The scope reports it,
/// so diagnostics can tell "the user asked for premium" apart from "premium
/// is what the frame budget allowed".
final autoGlassProvider = NotifierProvider<AutoGlassPolicy, GlassQuality>(
  AutoGlassPolicy.new,
);

class AutoGlassPolicy extends Notifier<GlassQuality> {
  @override
  GlassQuality build() => GlassQuality.standard;

  void report(GlassQuality quality) {
    if (quality != state) state = quality;
  }
}
