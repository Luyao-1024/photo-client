import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final videoPlaybackLifecycleProvider = Provider((ref) {
  final lifecycle = VideoPlaybackLifecycle();
  ref.onDispose(() => unawaited(lifecycle.shutdown()));
  return lifecycle;
});

/// Keep native callbacks alive until every player has finished releasing them.
/// Window teardown must await this barrier before destroying the Flutter engine.
class VideoPlaybackLifecycle {
  final _active = <Object, Future<void> Function()>{};
  final _pending = <Object, Future<void>>{};
  bool _closing = false;
  bool get acceptingSessions => !_closing;

  void register(Object session, Future<void> Function() dispose) {
    if (_closing) throw StateError('Video playback is shutting down');
    _active[session] = dispose;
  }

  Future<void> release(Object session) {
    final pending = _pending[session];
    if (pending != null) return pending;
    final dispose = _active.remove(session);
    if (dispose == null) return Future.value();
    late final Future<void> result;
    result = Future<void>.sync(dispose).whenComplete(() {
      _pending.remove(session);
    });
    _pending[session] = result;
    return result;
  }

  Future<void> shutdown() async {
    _closing = true;
    await Future.wait([
      ..._active.keys.toList().map(release),
      ..._pending.values,
    ]);
  }
}

/// Reuse the video plugin's mapped inode, including in dev sessions whose
/// LD_LIBRARY_PATH also contains the unpacked build dependencies.
String linuxMpvLibraryPath({String? executable, Iterable<String>? mappings}) {
  final mapped =
      mappings ??
      (executable == null
          ? File('/proc/self/maps').readAsLinesSync()
          : const <String>[]);
  final loaded = <String>{};
  for (final line in mapped) {
    final start = line.indexOf('/');
    if (start < 0) continue;
    final path = line.substring(start);
    if (!path.split('/').last.startsWith('libmpv.so')) continue;
    loaded.add(File(path).resolveSymbolicLinksSync());
  }
  if (loaded.length > 1) {
    throw StateError('Multiple libmpv libraries are loaded');
  }
  if (loaded.isNotEmpty) return loaded.single;
  final binary = File(executable ?? Platform.resolvedExecutable);
  final library = File('${binary.parent.path}/lib/libmpv.so.2');
  return library.existsSync()
      ? library.resolveSymbolicLinksSync()
      : 'libmpv.so.2';
}
