import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../services/local_library_gateway.dart';
import 'local_photo_image.dart';

enum ThumbnailUse { foreground, background, embedded }

/// Retain decoded completers separately from viewer originals and background
/// churn. A hot thumbnail bypasses both native RPC and disk JPEG decoding.
class ThumbnailImage extends ImageProvider<ThumbnailImage> {
  ThumbnailImage(
    this.provider, {
    this.use = ThumbnailUse.foreground,
    this.mediaId,
    this.version,
  });
  factory ThumbnailImage.file(
    String path,
    LocalPhoto photo, {
    int? width,
    int? height,
    ThumbnailUse use = ThumbnailUse.foreground,
  }) => ThumbnailImage(
    ResizeImage.resizeIfNeeded(width, height, LocalPhotoImage(path, photo)),
    use: use,
    mediaId: photo.id,
    version: photo.contentVersion,
  );
  final ImageProvider provider;
  final ThumbnailUse use;
  final String? mediaId;
  final int? version;
  static final _caches = {
    ThumbnailUse.foreground: _DecodedCache(512, 96 * 1024 * 1024),
    ThumbnailUse.background: _DecodedCache(64, 16 * 1024 * 1024),
    ThumbnailUse.embedded: _DecodedCache(768, 12 * 1024 * 1024),
  };
  static void clear() {
    for (final cache in _caches.values) {
      cache.clear();
    }
  }

  static void evictMedia(String id, int contentVersion) {
    for (final cache in _caches.values) {
      for (final key
          in cache.entries.keys
              .where(
                (key) => key.mediaId == id && key.version == contentVersion,
              )
              .toList()) {
        cache.remove(key);
      }
    }
  }

  @visibleForTesting
  static Map<ThumbnailUse, int> get counts =>
      _caches.map((key, value) => MapEntry(key, value.entries.length));
  static bool isRetained(ThumbnailImage image) => _caches.values.any(
    (cache) => cache.entries.keys.any((key) => key.provider == image.provider),
  );
  @override
  Future<ThumbnailImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    ThumbnailImage key,
    ImageErrorListener handleError,
  ) {
    final cache = _caches[use]!;
    final hit = cache.entries.remove(key);
    if (hit != null) {
      cache.entries[key] = hit;
      stream.setCompleter(hit.completer);
      return;
    }
    if (use == ThumbnailUse.foreground) {
      final background = _caches[ThumbnailUse.background]!;
      final candidates = background.entries.keys
          .where((candidate) => candidate.provider == provider)
          .toList();
      if (candidates.isNotEmpty) {
        final entry = background.entries.remove(candidates.first)!;
        entry.owner = cache;
        entry.key = key;
        cache.entries[key] = entry;
        stream.setCompleter(entry.completer);
        cache.trim();
        return;
      }
    }
    // FileImage and ResizeImage(FileImage) obtain their keys synchronously.
    // Resolve the underlying provider so its normal decoder and error handling
    // stay intact, then retain that exact completer outside the global cache.
    final resolved = provider.resolve(configuration);
    final completer = resolved.completer;
    if (completer == null) {
      handleError(StateError('ThumbnailKeyUnavailable'), StackTrace.current);
      return;
    }
    final entry = _DecodedEntry(completer, cache, key);
    cache.entries[key] = entry;
    stream.setCompleter(completer);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, synchronous) {
        if (identical(entry.owner.entries[entry.key], entry)) {
          entry.bytes = info.image.width * info.image.height * 4;
          entry.owner.trim();
        }
        info.dispose();
        // A synchronous cache hit can invoke this listener in addListener.
        scheduleMicrotask(() {
          if (entry.listener != null) {
            completer.removeListener(listener);
            entry.listener = null;
          }
        });
      },
      onError: (Object error, StackTrace? stack) {
        scheduleMicrotask(() {
          if (identical(entry.owner.entries[entry.key], entry)) {
            entry.owner.remove(entry.key);
          }
        });
      },
    );
    entry.listener = listener;
    completer.addListener(listener);
    cache.trim();
  }

  @override
  bool operator ==(Object other) =>
      other is ThumbnailImage && provider == other.provider && use == other.use;
  @override
  int get hashCode => Object.hash(provider, use);
}

class _DecodedEntry {
  _DecodedEntry(this.completer, this.owner, this.key)
    : handle = completer.keepAlive();
  _DecodedCache owner;
  ThumbnailImage key;
  final ImageStreamCompleter completer;
  final ImageStreamCompleterHandle handle;
  ImageStreamListener? listener;
  int bytes = 0;
  void dispose() {
    if (listener != null) completer.removeListener(listener!);
    listener = null;
    handle.dispose();
  }
}

class _DecodedCache {
  _DecodedCache(this.limit, this.maxBytes);
  final int limit, maxBytes;
  final entries = <ThumbnailImage, _DecodedEntry>{};
  void remove(ThumbnailImage key) => entries.remove(key)?.dispose();
  void clear() {
    for (final entry in entries.values) {
      entry.dispose();
    }
    entries.clear();
  }

  void trim() {
    var bytes = entries.values.fold(0, (sum, entry) => sum + entry.bytes);
    while (entries.isNotEmpty && (entries.length > limit || bytes > maxBytes)) {
      final key = entries.keys.first;
      bytes -= entries[key]!.bytes;
      remove(key);
    }
  }
}
