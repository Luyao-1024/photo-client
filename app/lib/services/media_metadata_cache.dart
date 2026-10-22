import 'dart:async';

import 'local_library_gateway.dart';

/// EXIF/details are immutable for one native content version. Keep navigation
/// from rereading the same source and coalesce detail-pane/viewer requests.
class MediaMetadataCache {
  static final _byGateway =
      Expando<Map<String, Future<Map<String, dynamic>>>>();
  static Future<Map<String, dynamic>> load(
    Object gateway,
    LocalPhoto photo,
    Future<Object?> Function() request,
  ) {
    final entries = _byGateway[gateway] ??= {};
    final key = '${photo.id}:${photo.contentVersion}';
    final hit = entries.remove(key);
    if (hit != null) {
      entries[key] = hit;
      return hit;
    }
    late final Future<Map<String, dynamic>> result;
    result = Future<Object?>.sync(request).then(
      (value) => value is Map
          ? Map<String, dynamic>.unmodifiable(value)
          : <String, dynamic>{},
      onError: (Object error, StackTrace stack) {
        if (identical(entries[key], result)) entries.remove(key);
        Error.throwWithStackTrace(error, stack);
      },
    );
    entries[key] = result;
    while (entries.length > 512) {
      entries.remove(entries.keys.first);
    }
    return result;
  }

  static void clear(Object gateway) => _byGateway[gateway]?.clear();
}
