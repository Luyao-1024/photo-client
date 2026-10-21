import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/ui/backdrop_viewport.dart';

void main() {
  testWidgets(
    'continuous scrolling samples periodically and settles on its last target',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final updates = <BackdropViewport?>[];
      container.listen(
        backdropViewportProvider,
        (_, value) => updates.add(value),
      );
      final controller = container.read(backdropViewportProvider.notifier);
      for (var rank = 0; rank < 12; rank++) {
        controller.track(queryEpoch: 1, rank: rank);
        if (rank < 11) expect(container.read(backdropViewportProvider), isNull);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(updates, [(queryEpoch: 1, rank: 11)]);
      for (var rank = 12; rank <= 14; rank++) {
        controller.track(queryEpoch: 1, rank: rank);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(updates.length, 1);
      await tester.pump(const Duration(milliseconds: 199));
      expect(updates.length, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(updates.last, (queryEpoch: 1, rank: 14));
      await tester.pump(const Duration(seconds: 2));
      expect(updates.length, 2);
      controller.track(queryEpoch: 1, rank: 14);
      await tester.pump(const Duration(milliseconds: 300));
      expect(updates.length, 2);
    },
  );

  testWidgets(
    'new destinations and explicit covers cancel pending viewport targets',
    (tester) async {
      final container = ProviderContainer();
      final controller = container.read(backdropViewportProvider.notifier);
      controller.track(queryEpoch: 1, rank: 30);
      await tester.pump(const Duration(milliseconds: 100));
      controller.track(queryEpoch: 2, rank: 4);
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(backdropViewportProvider), (
        queryEpoch: 2,
        rank: 4,
      ));
      controller.track(queryEpoch: 2, rank: 10);
      controller.reset();
      await tester.pump(const Duration(seconds: 2));
      expect(container.read(backdropViewportProvider), isNull);
      controller.track(queryEpoch: 2, rank: 8);
      container.dispose();
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );
}
