import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// Real-input contract for the acceptance journey.
///
/// The X11 driver hands coordinates to an external helper that injects events
/// into the real window through XTest, so the app observes genuine platform
/// input. The framework driver keeps the journey runnable without X tooling and
/// is reported separately, never as real-window evidence.
abstract interface class JourneyInput {
  String get mode;
  Future<void> tap(Offset position, double devicePixelRatio);
  Future<void> secondaryTap(Offset position, double devicePixelRatio);
  Future<void> drag(
    Offset from,
    Offset to,
    double devicePixelRatio, {
    Duration hold = Duration.zero,
  });
  Future<void> moveTo(Offset position, double devicePixelRatio);
  Future<void> scroll(Offset position, int clicks, double devicePixelRatio);
  Future<void> key(String keyName);
  Future<void> type(String text);

  /// Capture the real window; only the external X11 helper can do this.
  Future<bool> capture(String name);
  Future<void> dispose();
}

class JourneyInputFailure implements Exception {
  JourneyInputFailure(this.message);
  final String message;
  @override
  String toString() => 'JourneyInputFailure: $message';
}

JourneyInput createJourneyInput(String mode, String? evidenceDir) {
  switch (mode) {
    case 'x11':
      final directory = evidenceDir;
      if (directory == null) {
        throw JourneyInputFailure('x11 input needs --evidence-dir');
      }
      return X11HandshakeInput(Directory(directory));
    case 'framework':
      return FrameworkInput();
    default:
      throw JourneyInputFailure('Unsupported input mode: $mode');
  }
}

/// File-handshake driver: one pending request at a time, matched by step id.
final class X11HandshakeInput implements JourneyInput {
  X11HandshakeInput(this.directory)
    : request = File('${directory.path}/input-request.json'),
      response = File('${directory.path}/input-response.json') {
    directory.createSync(recursive: true);
    if (response.existsSync()) response.deleteSync();
    if (request.existsSync()) request.deleteSync();
  }

  final Directory directory;
  final File request;
  final File response;
  int _step = 0;

  @override
  String get mode => 'x11';

  Future<void> _exchange(Map<String, Object?> payload) async {
    final step = ++_step;
    final staged = File('${request.path}.tmp');
    staged.writeAsStringSync(
      jsonEncode({...payload, 'step': step}),
      flush: true,
    );
    staged.renameSync(request.path);
    stderr.writeln(
      'INPUT step=$step kind=${payload['kind']} ${payload['detail'] ?? ''}',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      if (response.existsSync()) {
        try {
          final decoded = jsonDecode(response.readAsStringSync());
          if (decoded is Map<String, Object?> && decoded['step'] == step) {
            response.deleteSync();
            stderr.writeln(
              'INPUT step=$step status=${decoded['status']} detail=${decoded['detail']}',
            );
            if (decoded['status'] != 'ok') {
              throw JourneyInputFailure(
                'input step $step failed: ${decoded['detail']}',
              );
            }
            // Let the engine deliver and the framework settle the event.
            await Future<void>.delayed(const Duration(milliseconds: 120));
            return;
          }
        } on FormatException {
          // A partially written response is retried on the next poll.
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw JourneyInputFailure('input step $step timed out waiting for helper');
  }

  @override
  Future<void> tap(Offset position, double devicePixelRatio) => _exchange({
    'kind': 'tap',
    'x': position.dx,
    'y': position.dy,
    'device_pixel_ratio': devicePixelRatio,
  });

  @override
  Future<void> secondaryTap(Offset position, double devicePixelRatio) =>
      _exchange({
        'kind': 'secondary-tap',
        'x': position.dx,
        'y': position.dy,
        'device_pixel_ratio': devicePixelRatio,
      });

  @override
  Future<void> drag(
    Offset from,
    Offset to,
    double devicePixelRatio, {
    Duration hold = Duration.zero,
  }) => _exchange({
    'kind': 'drag',
    'x': from.dx,
    'y': from.dy,
    'to_x': to.dx,
    'to_y': to.dy,
    'hold_ms': hold.inMilliseconds,
    'device_pixel_ratio': devicePixelRatio,
  });

  @override
  Future<void> moveTo(Offset position, double devicePixelRatio) => _exchange({
    'kind': 'move',
    'x': position.dx,
    'y': position.dy,
    'device_pixel_ratio': devicePixelRatio,
  });

  @override
  Future<void> scroll(Offset position, int clicks, double devicePixelRatio) =>
      _exchange({
        'kind': 'scroll',
        'x': position.dx,
        'y': position.dy,
        'clicks': clicks,
        'device_pixel_ratio': devicePixelRatio,
      });

  @override
  Future<void> key(String keyName) =>
      _exchange({'kind': 'key', 'key': keyName});

  @override
  Future<void> type(String text) => _exchange({'kind': 'text', 'text': text});

  @override
  Future<bool> capture(String name) async {
    await _exchange({'kind': 'screenshot', 'name': name});
    return true;
  }

  @override
  Future<void> dispose() async {
    if (request.existsSync()) request.deleteSync();
  }
}

/// In-process driver using the same framework entry points as platform input.
final class FrameworkInput implements JourneyInput {
  FrameworkInput();

  final Stopwatch _clock = Stopwatch()..start();

  @override
  String get mode => 'framework';

  static const Map<String, (LogicalKeyboardKey, PhysicalKeyboardKey)> _keys = {
    'Right': (LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight),
    'Left': (LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft),
    'Escape': (LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape),
  };

  Future<void> _settle() async {
    for (var index = 0; index < 3; index += 1) {
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }

  @override
  Future<void> tap(Offset position, double devicePixelRatio) async {
    final binding = GestureBinding.instance;
    binding.handlePointerEvent(PointerDownEvent(position: position));
    binding.handlePointerEvent(PointerUpEvent(position: position));
    await _settle();
  }

  @override
  Future<void> secondaryTap(Offset position, double devicePixelRatio) async {
    final binding = GestureBinding.instance;
    binding.handlePointerEvent(
      PointerDownEvent(
        position: position,
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      ),
    );
    binding.handlePointerEvent(
      PointerUpEvent(position: position, kind: PointerDeviceKind.mouse),
    );
    await _settle();
  }

  @override
  Future<void> drag(
    Offset from,
    Offset to,
    double devicePixelRatio, {
    Duration hold = Duration.zero,
  }) async {
    final binding = GestureBinding.instance;
    binding.handlePointerEvent(PointerDownEvent(position: from));
    if (hold > Duration.zero) {
      await Future<void>.delayed(hold);
    }
    const steps = 8;
    for (var index = 1; index <= steps; index += 1) {
      binding.handlePointerEvent(
        PointerMoveEvent(
          position: Offset.lerp(from, to, index / steps)!,
          buttons: kPrimaryButton,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    binding.handlePointerEvent(PointerUpEvent(position: to));
    await _settle();
  }

  @override
  Future<void> moveTo(Offset position, double devicePixelRatio) async {
    GestureBinding.instance.handlePointerEvent(
      PointerHoverEvent(position: position, kind: PointerDeviceKind.mouse),
    );
    await _settle();
  }

  @override
  Future<void> scroll(
    Offset position,
    int clicks,
    double devicePixelRatio,
  ) async {
    final binding = GestureBinding.instance;
    for (var index = 0; index < clicks.abs(); index += 1) {
      binding.handlePointerEvent(
        PointerScrollEvent(
          position: position,
          scrollDelta: Offset(0, clicks > 0 ? -20 : 20),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await _settle();
  }

  @override
  Future<bool> capture(String name) async => false;

  /// Injected at the engine key-data boundary, the same entry point the
  /// embedder uses, so focus and shortcut routing stay real.
  @override
  Future<void> key(String keyName) async {
    final entry = _keys[keyName];
    if (entry == null) {
      throw JourneyInputFailure('framework input has no mapping for $keyName');
    }
    final onKeyData = ui.PlatformDispatcher.instance.onKeyData;
    if (onKeyData == null) {
      throw JourneyInputFailure('framework input has no key data channel');
    }
    for (final type in const [ui.KeyEventType.down, ui.KeyEventType.up]) {
      final stamp = _clock.elapsed + const Duration(milliseconds: 8);
      onKeyData(
        ui.KeyData(
          timeStamp: stamp,
          type: type,
          physical: entry.$2.usbHidUsage,
          logical: entry.$1.keyId,
          character: null,
          synthesized: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
    await _settle();
  }

  @override
  Future<void> type(String text) => Future<void>.error(
    JourneyInputFailure(
      'framework input cannot type into a TextField; use --input=x11',
    ),
  );

  @override
  Future<void> dispose() async {}
}
