import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/ui/viewer_filmstrip_visibility.dart';

void main() {
  Widget host(Future<void> ready, {bool playing = false}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 600,
          height: 84,
          child: ViewerFilmstripVisibility(
            ready: ready,
            playbackActive: playing,
            child: const ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    ),
  );

  double opacity(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find.descendant(
          of: find.byKey(const ValueKey('viewer-filmstrip-fade')),
          matching: find.byType(FadeTransition),
        ),
      )
      .opacity
      .value;

  testWidgets('filmstrip waits for the whole visible group before fading in', (
    tester,
  ) async {
    final frames = List.generate(3, (_) => Completer<void>());
    final ready = Future.wait(frames.map((frame) => frame.future))
        .then<void>((_) {});
    await tester.pumpWidget(host(ready));
    frames[0].complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(tester), 0);
    frames[1].complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(tester), 0);
    frames[2].complete();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(tester), allOf(greaterThan(0), lessThan(1)));
    await tester.pumpAndSettle();
    expect(opacity(tester), 1);
  });

  testWidgets(
    'hovering the hidden strip reveals it early without ending playback',
    (tester) async {
      final ready = Future<void>.value();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await tester.pumpWidget(host(ready, playing: true));
      await tester.pumpAndSettle();
      final bounds = tester.getRect(find.byType(ViewerFilmstripVisibility));
      expect(opacity(tester), 0);
      await mouse.moveTo(bounds.center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(opacity(tester), allOf(greaterThan(0), lessThan(1)));
      await tester.pumpAndSettle();
      expect(opacity(tester), 1);
      expect(tester.getRect(find.byType(ViewerFilmstripVisibility)), bounds);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(opacity(tester), 0);
      await tester.pumpWidget(host(ready));
      await tester.pumpAndSettle();
      expect(opacity(tester), 1);
      await mouse.removePointer();
    },
  );

  testWidgets('a slow thumbnail cannot keep navigation invisible', (
    tester,
  ) async {
    final slow = Completer<void>();
    await tester.pumpWidget(host(slow.future));
    await tester.pump(const Duration(milliseconds: 399));
    expect(opacity(tester), 0);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 250));
    expect(opacity(tester), 1);
    slow.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('new preparation does not hide an already visible strip', (
    tester,
  ) async {
    await tester.pumpWidget(host(Future<void>.value()));
    await tester.pumpAndSettle();
    expect(opacity(tester), 1);
    final slow = Completer<void>();
    await tester.pumpWidget(host(slow.future));
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(tester), 1);
    slow.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a stale preparation cannot expose a new filmstrip', (
    tester,
  ) async {
    final old = Completer<void>(), current = Completer<void>();
    await tester.pumpWidget(host(old.future));
    await tester.pumpWidget(host(current.future));
    old.complete();
    await tester.pumpAndSettle();
    expect(opacity(tester), 0);
    current.complete();
    await tester.pumpAndSettle();
    expect(opacity(tester), 1);
  });
}
