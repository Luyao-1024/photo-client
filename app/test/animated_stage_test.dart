import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/ui/local_animated_stage.dart';

void main() {
  late Directory fixtures;
  late List<AnimatedFrame> frames;

  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('photo-animated-stage-');
    // A one pixel PNG stands in for a decoded frame file.
    final frame = File('${fixtures.path}/frame-0000.png');
    await frame.writeAsBytes([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
      0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00,
      0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78,
      0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);
    frames = [
      AnimatedFrame(path: frame.path, delayMs: 40),
      AnimatedFrame(path: frame.path, delayMs: 40),
    ];
  });

  tearDownAll(() => fixtures.delete(recursive: true));

  testWidgets('the stage advances through the frames and loops', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AnimatedImageStage(frames: frames)),
      ),
    );
    expect(find.byType(Image), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    // The animation keeps running, so the stage stays mounted.
    expect(find.byType(AnimatedImageStage), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    expect(find.byType(AnimatedImageStage), findsOneWidget);
  });

  testWidgets('an empty frame list renders nothing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AnimatedImageStage(frames: const [])),
      ),
    );
    expect(find.byType(Image), findsNothing);
  });
}
