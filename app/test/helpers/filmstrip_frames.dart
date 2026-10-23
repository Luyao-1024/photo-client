import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/ui/viewer_filmstrip_visibility.dart';

/// File/codec work needs the real event loop; pumping only the widget clock can
/// leave a correctly hidden strip waiting for its decoded thumbnails forever.
Future<void> waitForFilmstripFrames(WidgetTester tester) async {
  // The strip may replace its preparation future while its width settles, so
  // accept the completion of whichever future is current on any attempt.
  final seen = <Future<void>>{};
  var completed = 0;
  for (var attempt = 0; attempt < 400; attempt++) {
    final future = tester
        .widget<ViewerFilmstripVisibility>(
          find.byType(ViewerFilmstripVisibility),
        )
        .ready;
    if (seen.add(future)) {
      future.then(
        (_) => completed++,
        onError: (Object _, StackTrace _) => completed++,
      );
    }
    final before = completed;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (completed > before) {
      await tester.pump();
      return;
    }
  }
  fail('the visible filmstrip frames did not finish decoding');
}
