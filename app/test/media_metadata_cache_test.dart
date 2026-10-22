import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_client/services/media_metadata_cache.dart';
import 'package:photo_client/services/local_library_gateway.dart';

void main() {
  const photo = LocalPhoto(
    id: 'photo',
    path: 'source.jpg',
    name: 'source',
    parent: 'folder',
    sizeBytes: 1,
    modifiedMs: 1,
    contentVersion: 1,
    favorite: false,
  );
  test(
    'reopening details shares one versioned read across observers',
    () async {
      final gateway = Object();
      final pending = Completer<Object?>();
      var reads = 0;
      Future<Object?> request() {
        reads++;
        return pending.future;
      }

      final first = MediaMetadataCache.load(gateway, photo, request);
      final second = MediaMetadataCache.load(gateway, photo, request);
      expect(identical(first, second), isTrue);
      pending.complete({'camera_make': 'camera'});
      expect((await second)['camera_make'], 'camera');
      await MediaMetadataCache.load(gateway, photo, request);
      expect(reads, 1);
      MediaMetadataCache.clear(gateway);
    },
  );
  test('metadata read failures remain retryable', () async {
    final gateway = Object();
    await expectLater(
      MediaMetadataCache.load(
        gateway,
        photo,
        () => Future.error(StateError('unavailable')),
      ),
      throwsStateError,
    );
    final retried = await MediaMetadataCache.load(
      gateway,
      photo,
      () async => {'animated': false},
    );
    expect(retried['animated'], isFalse);
    MediaMetadataCache.clear(gateway);
  });
}
