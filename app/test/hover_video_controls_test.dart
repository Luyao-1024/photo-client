import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/ui/hover_video_controls.dart';

void main() {
  Widget host() => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 600,
          height: 500,
          child: HoverVideoControls(
            bottomInset: 104,
            child: SizedBox.expand(
              child: GestureDetector(
                onPanUpdate: (_) {},
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  double opacity(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find.descendant(
          of: find.byKey(const ValueKey('video-controls-fade')),
          matching: find.byType(FadeTransition),
        ),
      )
      .opacity
      .value;

  testWidgets(
    'playback controls reveal only near the lower bar and fade on exit',
    (tester) async {
      await tester.pumpWidget(host());
      final bounds = tester.getRect(find.byType(HoverVideoControls));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: bounds.center);
      await tester.pumpAndSettle();
      expect(opacity(tester), 0);
      // Neither the photo footer nor hidden playback buttons activate chrome.
      await mouse.moveTo(bounds.bottomCenter - const Offset(0, 20));
      await tester.pumpAndSettle();
      expect(opacity(tester), 0);
      await mouse.moveTo(bounds.bottomCenter - const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(opacity(tester), 0);
      await mouse.moveTo(bounds.bottomLeft + const Offset(4, -162));
      await tester.pumpAndSettle();
      expect(opacity(tester), 0);
      await mouse.moveTo(bounds.bottomCenter - const Offset(0, 162));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(opacity(tester), allOf(greaterThan(0), lessThan(1)));
      await tester.pumpAndSettle();
      expect(opacity(tester), 1);
      await mouse.moveTo(bounds.bottomCenter - const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(opacity(tester), 1);
      await mouse.moveTo(bounds.bottomCenter - const Offset(0, 20));
      await tester.pumpAndSettle();
      expect(opacity(tester), 0);
      await mouse.removePointer();
    },
  );

  testWidgets(
    'playback controls stay hidden when mounted under a stationary pointer',
    (tester) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 388));
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(opacity(tester), 0);
      await mouse.moveBy(const Offset(1, 0));
      await tester.pumpAndSettle();
      expect(opacity(tester), 1);
      await mouse.removePointer();
    },
  );

  testWidgets('playback controls remain usable while dragging beyond the bar', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final bounds = tester.getRect(find.byType(HoverVideoControls));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: bounds.center);
    await mouse.moveTo(bounds.bottomCenter - const Offset(0, 162));
    await tester.pumpAndSettle();
    await mouse.down(bounds.bottomCenter - const Offset(0, 162));
    await mouse.moveTo(bounds.topCenter + const Offset(0, 10));
    await tester.pumpAndSettle();
    expect(opacity(tester), 1);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(opacity(tester), 0);
    await mouse.removePointer();
  });
}
