import '../ui/thumbnail_image.dart';

import 'dart:async';
import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';

import 'local_library_gateway.dart';

/// Optional native scheduling capability. Test gateways can keep the basic
/// library contract without impersonating a native thumbnail scheduler.
abstract interface class ThumbnailPipelineGateway {
  Future<Object?> thumbnailCommand(Map<String, Object?> command);
}

class ThumbnailHandle {
  ThumbnailHandle._(this._pool, this._entry);
  final ThumbnailPool _pool;
  final _Entry _entry;
  bool _released = false;
  Future<String> get future => _entry.future;
  int get sizeClass => _entry.size;
  String? get path => _entry.path;
  Future<String?> get placeholder => _pool._placeholder(_entry);
  void release() {
    if (_released) return;
    _released = true;
    _pool._release(_entry);
  }

  Future<void> invalidate() => _pool._invalidate(_entry);
}

class _Entry {
  _Entry(this.photo, this.size, this.token, this.priority);
  final LocalPhoto photo;
  final int size;
  final String token;
  int priority, users = 0;
  String? path;
  bool finished = false, submitted = false, cancelled = false;
  Completer<void>? admission;
  late Future<String> future;
  String get key => '${photo.id}:${photo.contentVersion}:$size';
}

/// Share native work across grid, viewer and background. A recycled cell releases
/// its waiter; only the final observer cancels an unfinished native request.
/// Idle prewarm stays native and never churns Flutter's decoded-image cache.
class ThumbnailPool {
  ThumbnailPool._(this.gateway);
  static final _pools = Expando<ThumbnailPool>();
  static int _sequence = 0;
  static ThumbnailPool forGateway(LocalLibraryGateway gateway) =>
      _pools[gateway] ??= ThumbnailPool._(gateway);
  final LocalLibraryGateway gateway;
  final epoch = ValueNotifier<int>(0);
  final activity = ValueNotifier<int>(0);
  bool rebuildingCache = false;
  int? get desiredSize => _sentViewport?.$2;
  final _entries = <String, _Entry>{};
  final _embedded = <String, Future<String?>>{};
  final _prewarmedPaths = <String, String>{};
  final cacheReady = ValueNotifier<int>(0);
  (int, int)? _readyCount;
  void reportReady(int size, int count) {
    if (_readyCount == (size, count)) return;
    _readyCount = (size, count);
    cacheReady.value++;
  }

  String? cachedPath(LocalPhoto photo, int size) =>
      _entries['${photo.id}:${photo.contentVersion}:$size']?.path ??
      _prewarmedPaths['${photo.id}:${photo.contentVersion}:$size'];
  void rememberCached(LocalPhoto photo, int size, String path) {
    final key = '${photo.id}:${photo.contentVersion}:$size';
    if (_entries[key]?.path != null) return;
    _prewarmedPaths.remove(key);
    _prewarmedPaths[key] = path;
    while (_prewarmedPaths.length > 64) {
      _prewarmedPaths.remove(_prewarmedPaths.keys.first);
    }
  }

  final _pending = Queue<_Entry>();
  int _issuedThisFrame = 0;
  int? _frameCallback;
  Timer? _viewportTimer, _completionActivity;
  (String?, int)? _pendingViewport, _sentViewport;

  int? bestAvailableSize(LocalPhoto photo) {
    for (final size in [512, 1024, 256]) {
      if (cachedPath(photo, size) != null) {
        return size;
      }
    }
    return null;
  }

  ThumbnailHandle acquire(LocalPhoto photo, int size, {int priority = 0}) {
    final key = '${photo.id}:${photo.contentVersion}:$size';
    var entry = _entries.remove(key);
    final warm = entry == null ? _prewarmedPaths.remove(key) : null;
    if (warm != null) {
      entry = _Entry(photo, size, 'warm-${++_sequence}', priority);
      entry.path = warm;
      entry.finished = true;
      entry.future = Future.value(warm);
    }
    if (entry == null) {
      entry = _Entry(photo, size, 'dart-${++_sequence}', priority);
      final current = entry;
      current.future = _load(current).then(
        (path) {
          current.path = path;
          current.finished = true;
          if (!current.cancelled &&
              identical(_entries[current.key], current) &&
              gateway is ThumbnailPipelineGateway) {
            _completionActivity ??= Timer(const Duration(seconds: 1), () {
              _completionActivity = null;
              activity.value++;
            });
          }
          _trim();
          return path;
        },
        onError: (Object error, StackTrace stack) {
          current.finished = true;
          // Retain failures like the old unavailable-thumbnail memory cache.
          // Explicit retry and a new content version invalidate this entry.
          _trim();
          Error.throwWithStackTrace(error, stack);
        },
      );
      // A caller can release before FutureBuilder subscribes. Keep cancellation
      // and failed lookups observed without converting its result to success.
      unawaited(
        current.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    } else if (priority < entry.priority && !entry.finished) {
      entry.priority = priority;
      _quiet({
        'op': 'thumbnailPromote',
        'id': photo.id,
        'version': photo.contentVersion,
        'size': size,
      });
    }
    entry.users++;
    _entries[key] = entry;
    _trim();
    return ThumbnailHandle._(this, entry);
  }

  Future<String> _load(_Entry entry) async {
    if (_issuedThisFrame >= 24) {
      entry.admission = Completer<void>();
      _pending.add(entry);
      _scheduleBatch();
      await entry.admission!.future;
    } else {
      _issuedThisFrame++;
      _scheduleBatch();
    }
    entry.submitted = true;
    final native = gateway;
    if (native is ThumbnailPipelineGateway) {
      return await (native as ThumbnailPipelineGateway).thumbnailCommand({
        'op': 'thumbnailRequest',
        'id': entry.photo.id,
        'version': entry.photo.contentVersion,
        'size': entry.size,
        'token': entry.token,
        'tier': entry.priority,
      }) as String;
    }
    return gateway.thumbnail(entry.photo.id, sizeClass: entry.size);
  }

  void _scheduleBatch() {
    _frameCallback ??= SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frameCallback = null;
      _issuedThisFrame = 0;
      while (_pending.isNotEmpty && _issuedThisFrame < 24) {
        final entry = _pending.removeFirst();
        if (entry.users == 0 || entry.admission!.isCompleted) continue;
        _issuedThisFrame++;
        entry.admission!.complete();
      }
      if (_pending.isNotEmpty || _issuedThisFrame > 0) _scheduleBatch();
    });
  }

  void _cancel(_Entry entry) {
    if (entry.cancelled) return;
    entry.cancelled = true;
    if (entry.submitted) {
      _quiet({'op': 'thumbnailCancel', 'token': entry.token});
    } else if (entry.admission?.isCompleted == false) {
      _pending.remove(entry);
      entry.admission!.completeError(StateError('ThumbnailCancelled'));
    }
  }

  Future<String?> _placeholder(_Entry entry) {
    if (entry.path != null || gateway is! ThumbnailPipelineGateway) {
      return Future.value(null);
    }
    final key = '${entry.photo.id}:${entry.photo.contentVersion}';
    final existing = _embedded.remove(key);
    final future =
        existing ??
        (gateway as ThumbnailPipelineGateway)
            .thumbnailCommand({
              'op': 'thumbnailEmbedded',
              'id': entry.photo.id,
              'version': entry.photo.contentVersion,
            })
            .then(
              (value) => value as String?,
              onError: (Object _, StackTrace _) => null,
            );
    _embedded[key] = future;
    while (_embedded.length > 768) {
      _embedded.remove(_embedded.keys.first);
    }
    return future;
  }

  void _release(_Entry entry) {
    entry.users--;
    if (entry.users == 0 && !entry.finished) {
      if (identical(_entries[entry.key], entry)) _entries.remove(entry.key);
      _cancel(entry);
    }
    _trim();
  }

  Future<void> _invalidate(_Entry entry) async {
    _prewarmedPaths.remove(entry.key);
    ThumbnailImage.evictMedia(entry.photo.id, entry.photo.contentVersion);
    if (identical(_entries[entry.key], entry)) _entries.remove(entry.key);
    if (gateway is ThumbnailPipelineGateway) {
      await (gateway as ThumbnailPipelineGateway).thumbnailCommand({
        'op': 'thumbnailInvalidate',
        'path': entry.path,
        'id': entry.photo.id,
        'version': entry.photo.contentVersion,
        'size': entry.size,
      });
    }
    activity.value++;
  }

  void clear({bool rebuild = false}) {
    rebuildingCache = rebuild;
    ThumbnailImage.clear();
    for (final entry in _entries.values) {
      if (!entry.finished) {
        _cancel(entry);
      }
    }
    _entries.clear();
    _embedded.clear();
    _prewarmedPaths.clear();
    _readyCount = null;
    _pending.clear();
    if (_frameCallback != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(_frameCallback!);
    }
    _frameCallback = null;
    _issuedThisFrame = 0;
    _viewportTimer?.cancel();
    _completionActivity?.cancel();
    _completionActivity = null;
    _viewportTimer = null;
    _pendingViewport = _sentViewport = null;
    epoch.value++;
    activity.value++;
  }

  void viewport(String? id, int size) {
    _pendingViewport = (id, size);
    if (_pendingViewport == _sentViewport || _viewportTimer != null) return;
    _viewportTimer = Timer(const Duration(milliseconds: 200), () {
      _viewportTimer = null;
      final pending = _pendingViewport;
      if (pending == null || pending == _sentViewport) return;
      final changedSize = _sentViewport?.$2 != pending.$2;
      _sentViewport = pending;
      if (changedSize) activity.value++;
      _quiet({'op': 'thumbnailViewport', 'id': pending.$1, 'size': pending.$2});
    });
  }

  void _quiet(Map<String, Object?> command) {
    if (gateway is ThumbnailPipelineGateway) {
      unawaited(
        (gateway as ThumbnailPipelineGateway)
            .thumbnailCommand(command)
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  }

  void _trim() {
    if (_entries.length <= 512) return;
    final unused = _entries.values
        .where((entry) => entry.users == 0 && entry.finished)
        .map((entry) => entry.key)
        .toList();
    for (final key in unused) {
      if (_entries.length <= 512) break;
      _entries.remove(key);
    }
  }
}

/// Album covers can be requested before their photo DTO page is resident. The
/// native scheduler resolves the current version and still supports cancellation.
class MediaThumbnailHandle {
  MediaThumbnailHandle(
    LocalLibraryGateway gateway,
    String id,
    int size, {
    int priority = 1,
  }) : _gateway = gateway,
       _token = 'cover-${++_sequence}' {
    final native = gateway;
    final result = native is ThumbnailPipelineGateway
        ? (native as ThumbnailPipelineGateway)
              .thumbnailCommand({
                'op': 'thumbnailRequest',
                'id': id,
                'size': size,
                'token': _token,
                'tier': priority,
              })
              .then((value) => value as String)
        : gateway.thumbnail(id, sizeClass: size);
    future = result.then((value) {
      path = value;
      return value;
    });
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }
  static int _sequence = 0;
  final LocalLibraryGateway _gateway;
  final String _token;
  late final Future<String> future;
  String? path;
  bool _released = false;
  void release() {
    if (_released) return;
    _released = true;
    if (path == null && _gateway is ThumbnailPipelineGateway) {
      unawaited(
        (_gateway as ThumbnailPipelineGateway)
            .thumbnailCommand({'op': 'thumbnailCancel', 'token': _token})
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  }
}
