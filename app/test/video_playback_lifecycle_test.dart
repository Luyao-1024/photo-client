import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:photo_client/services/video_playback_lifecycle.dart';
import 'package:photo_client/services/window_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native window closure waits until playback has been released',
    () async {
      final lifecycle = VideoPlaybackLifecycle();
      final gate = Completer<void>();
      lifecycle.register(Object(), () => gate.future);
      final window = WindowController.instance;
      const channel = MethodChannel('photo_client/window');
      final calls = <String>[];
      window.prepareClose = lifecycle.shutdown;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return null;
          });
      addTearDown(() {
        window.prepareClose = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final closing = window.close();
      await Future<void>.delayed(Duration.zero);
      expect(calls, isNot(contains('close')));
      gate.complete();
      await closing.timeout(const Duration(seconds: 3));
      expect(calls, ['close']);
    },
  );
  test(
    'shutdown drains active and already releasing players exactly once',
    () async {
      final lifecycle = VideoPlaybackLifecycle();
      final active = Object(), released = Object();
      final activeGate = Completer<void>(), releasedGate = Completer<void>();
      var closes = 0, finished = false;
      lifecycle.register(active, () {
        closes++;
        return activeGate.future;
      });
      lifecycle.register(released, () {
        closes++;
        return releasedGate.future;
      });
      final pending = lifecycle.release(released);
      final closing = lifecycle.shutdown().then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      expect(closes, 2);
      expect(finished, isFalse);
      expect(lifecycle.acceptingSessions, isFalse);
      expect(() => lifecycle.register(Object(), () async {}), throwsStateError);
      activeGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      releasedGate.complete();
      await pending;
      await closing;
      await lifecycle.shutdown();
      expect(closes, 2);
      expect(finished, isTrue);
    },
  );

  test(
    'Linux playback resolves the bundled library to the plugin inode',
    () async {
      final root = await Directory.systemTemp.createTemp('photo-mpv-library-');
      addTearDown(() => root.delete(recursive: true));
      final lib = File('${root.path}/bundle/lib/libmpv.so.2.5.0');
      await lib.parent.create(recursive: true);
      await lib.writeAsString('native fixture');
      await Link('${lib.parent.path}/libmpv.so.2').create('libmpv.so.2.5.0');
      expect(
        linuxMpvLibraryPath(executable: '${root.path}/bundle/photo_client'),
        lib.resolveSymbolicLinksSync(),
      );
      expect(
        linuxMpvLibraryPath(executable: '${root.path}/missing/photo_client'),
        'libmpv.so.2',
      );
      final runtime = File('${root.path}/runtime/libmpv.so.2.5.0');
      await runtime.parent.create();
      await runtime.writeAsString('plugin library');
      expect(
        linuxMpvLibraryPath(
          executable: '${root.path}/bundle/photo_client',
          mappings: [
            '1000 2000 r-xp 0 00:00 1 ${runtime.path}',
            '2000 3000 r--p 0 00:00 1 ${runtime.path}',
          ],
        ),
        runtime.resolveSymbolicLinksSync(),
      );
      expect(
        () => linuxMpvLibraryPath(
          mappings: [
            '1000 2000 r-xp 0 00:00 1 ${runtime.path}',
            '3000 4000 r-xp 0 00:00 2 ${lib.path}',
          ],
        ),
        throwsStateError,
      );
    },
  );
}
