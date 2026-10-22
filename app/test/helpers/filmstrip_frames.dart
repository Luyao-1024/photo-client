import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/ui/viewer_filmstrip_visibility.dart';

/// File/codec work needs the real event loop; pumping only the widget clock can
/// leave a correctly hidden strip waiting for its decoded thumbnails forever.
Future<void> waitForFilmstripFrames(WidgetTester tester) async {
  Future<void>? observed;
  var ready = false;
  for (var attempt = 0; attempt < 100; attempt++) {
    final future = tester
        .widget<ViewerFilmstripVisibility>(
          find.byType(ViewerFilmstripVisibility),
        )
        .ready;
    if (!identical(future, observed)) {
      observed = future;
      ready = false;
      future.then((_) {
        if (identical(future, observed)) ready = true;
      });
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (ready) return;
  }
  fail('the visible filmstrip frames did not finish decoding');
}
