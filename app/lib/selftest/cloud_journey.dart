part of 'local_journey.dart';

/// Cloud journeys drive the shipped widgets against a real SyncServer.
///
/// The password never enters a launch argument: it is read from the child
/// process environment by [LaunchOptions.cloudPassword]. Assertions mix the
/// rendered tree with the same native gateway the product uses, plus the real
/// downloaded files under the data root.
extension CloudJourney on LocalJourney {
  CloudSyncState get _cloud => _container!.read(cloudSyncProvider);

  Future<void> _waitCloud(
    bool Function(CloudSyncState state) predicate, {
    required String reason,
    Duration timeout = const Duration(seconds: 90),
  }) => _waitFor(() => predicate(_cloud), reason: reason, timeout: timeout);

  bool _cloudPageOpen() =>
      _elementByKey(const ValueKey('cloud-endpoint')) != null ||
      _elementByKey(const ValueKey('cloud-account')) != null;

  Future<void> _openCloudSettings() async {
    if (!_cloudPageOpen()) {
      if (_elementByKey(const ValueKey('settings-category-4')) == null) {
        await _tapKey('sidebar-settings');
        await _waitForElement(
          'settings-category-4',
          reason: 'the settings dialog did not offer the cloud category',
        );
      }
      await _tapKey('settings-category-4');
    }
    await _waitFor(
      _cloudPageOpen,
      reason: 'the cloud settings page did not open',
    );
  }

  Future<void> _closeSettings() async {
    if (_elementByKey(const ValueKey('settings-close')) == null) return;
    await _tapKey('settings-close');
    await _waitFor(
      () => _elementByKey(const ValueKey('settings-close')) == null,
      reason: 'the settings dialog did not close',
    );
  }

  Future<void> _setCloudField(String key, String text) async {
    await _tapKey(key);
    await _key('ctrl+a');
    await _type(text);
  }

  Future<void> _tapEnabled(String key) async {
    await _waitFor(() {
      final widget = _elementByKey(ValueKey(key))?.widget;
      if (widget is IconButton) return widget.onPressed != null;
      if (widget is FilledButton) return widget.onPressed != null;
      if (widget is OutlinedButton) return widget.onPressed != null;
      if (widget is TextButton) return widget.onPressed != null;
      return false;
    }, reason: 'control $key was never enabled');
    await _tapKey(key);
  }

  Future<void> _submitCloudLogin() async {
    await _setCloudField('cloud-endpoint', options.requireCloudEndpoint());
    await _setCloudField('cloud-username', options.requireCloudUsername());
    await _setCloudField('cloud-password', options.cloudPassword);
    await _tapEnabled('cloud-login');
  }

  Future<void> _loginExpectingError(String code, {String? password}) async {
    await _setCloudField('cloud-endpoint', options.requireCloudEndpoint());
    await _setCloudField('cloud-username', options.requireCloudUsername());
    await _setCloudField('cloud-password', password ?? options.cloudPassword);
    await _tapEnabled('cloud-login');
    await _waitCloud(
      (state) => !state.busy && state.errorCode == code,
      reason: 'neither success nor the stable $code error appeared',
    );
    if (_cloud.loggedIn) {
      throw JourneyFailure('a failed $code login still reported signed in');
    }
    final text = _textOf(const ValueKey('cloud-error')) ?? '';
    if (text.isEmpty) {
      throw JourneyFailure('the $code error has no user-facing text');
    }
    if (!_cloudErrorTextMatches(code, text)) {
      throw JourneyFailure('error text for $code was unexpected: $text');
    }
  }

  bool _cloudErrorTextMatches(String code, String text) {
    final expected = switch (code) {
      'AuthFailed' => ['登录失败', 'Sign-in failed'],
      'EndpointRejected' => ['服务器地址无效', 'Invalid endpoint'],
      'Network' => ['无法连接', 'Cannot reach'],
      'AccountExists' => ['其他账号', 'another account'],
      _ => <String>[],
    };
    return expected.isEmpty || expected.any(text.contains);
  }

  Future<void> _loginSuccessfully() async {
    await _submitCloudLogin();
    await _waitCloud(
      (state) =>
          state.loggedIn && !state.busy && state.status.errorCode == null,
      reason: 'cloud sign-in did not complete',
    );
    if (_elementByKey(const ValueKey('cloud-error')) != null) {
      throw JourneyFailure('a successful sign-in still shows an error');
    }
  }

  Future<void> _syncNow() async {
    await _openCloudSettings();
    await _tapEnabled('cloud-sync-now');
    await _waitCloud(
      (state) => !state.busy,
      reason: 'the manual sync did not finish',
      timeout: const Duration(minutes: 3),
    );
    final error = _cloud.status.errorCode;
    if (error != null) {
      throw JourneyFailure('manual sync failed with $error');
    }
  }

  Future<void> _logout() async {
    await _openCloudSettings();
    await _tapEnabled('cloud-logout');
    await _waitCloud(
      (state) => !state.loggedIn && !state.busy,
      reason: 'cloud sign-out did not complete',
    );
  }

  Future<void> _expectCloudFiles(String accountId, int expected) async {
    final root = options.dataRoot;
    if (root == null) throw JourneyFailure('cloud journeys need --data-root');
    final media = Directory('$root/cloud/$accountId/media');
    if (!media.existsSync()) {
      throw JourneyFailure(
        'downloaded media directory is missing: ${media.path}',
      );
    }
    final photos = media.listSync().whereType<Directory>().toList();
    if (photos.length != expected) {
      throw JourneyFailure(
        'expected $expected downloaded cloud photos, found ${photos.length}',
      );
    }
    final facts = <String, Object?>{};
    for (final photo in photos) {
      final generations = photo.listSync().whereType<Directory>().toList();
      if (generations.length != 1) {
        throw JourneyFailure(
          '${photo.path} has ${generations.length} generation directories',
        );
      }
      final files = generations.single.listSync().whereType<File>().toList();
      final original = files
          .where((file) => file.path.contains('/original.'))
          .toList();
      final thumbnail = files
          .where((file) => file.path.contains('/thumbnail.'))
          .toList();
      if (original.length != 1 || thumbnail.length != 1) {
        throw JourneyFailure(
          '${photo.path} is missing its original or thumbnail file',
        );
      }
      final originalSize = original.single.lengthSync();
      final thumbnailSize = thumbnail.single.lengthSync();
      if (originalSize == 0 || thumbnailSize == 0) {
        throw JourneyFailure('${photo.path} contains an empty downloaded file');
      }
      if (thumbnailSize > 2 * 1024 * 1024) {
        throw JourneyFailure('${photo.path} thumbnail exceeds 2 MiB');
      }
      final thumbnailBytes = thumbnail.single.readAsBytesSync();
      final codec = await ui.instantiateImageCodec(thumbnailBytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      if (image.width == 0 || image.height == 0) {
        throw JourneyFailure('${photo.path} thumbnail decoded empty');
      }
      final longest = image.width > image.height ? image.width : image.height;
      if (longest > 2048) {
        throw JourneyFailure('${photo.path} thumbnail exceeds 2048 px');
      }
      facts[photo.path
          .split('/')
          .skipWhile((part) => part != 'media')
          .join('/')] = {
        'original_bytes': originalSize,
        'thumbnail_bytes': thumbnailSize,
        'thumbnail_width': image.width,
        'thumbnail_height': image.height,
      };
      image.dispose();
      codec.dispose();
    }
    this.facts['cloud_files'] = {
      'account_id': accountId,
      'photos': photos.length,
      'files': facts,
    };
  }

  String? _cloudAccountId() {
    final root = options.dataRoot;
    if (root == null) return null;
    final cloud = Directory('$root/cloud');
    if (!cloud.existsSync()) return null;
    final accounts = cloud.listSync().whereType<Directory>().toList();
    return accounts.isEmpty ? null : accounts.single.path.split('/').last;
  }

  LocalAlbum? _albumNamed(String name) {
    for (final album in _state.albums) {
      if (album.name == name) return album;
    }
    return null;
  }

  LocalAlbum _requireAlbum(String path) {
    for (final album in _state.albums) {
      if (album.path == path) return album;
    }
    throw JourneyFailure('the library does not list album $path');
  }

  /// Bring a mounted row fully into its own scroll viewport. The sidebar rows
  /// sit in a lazy list, so the driver still scrolls it over real X11 input;
  /// this only avoids tapping a row clipped by the viewport edge.
  Future<void> _centerInScrollable(ValueKey<String> key, String label) async {
    final element = _elementByKey(key);
    if (element == null) {
      throw JourneyFailure('sidebar entry $label is not mounted');
    }
    try {
      await Scrollable.ensureVisible(
        element,
        alignment: .5,
        duration: Duration.zero,
      );
    } on FlutterError {
      // A row outside any scrollable is already at its resting place.
    }
    await _settle();
  }

  Future<void> _revealSidebarKey(ValueKey<String> key) async {
    if (_elementByKey(key) != null) return;
    // Album order is user controlled; start from the top, then walk down.
    for (var index = 0; index < 6; index += 1) {
      await _input!.scroll(
        Offset(120, _viewSize.height * .55),
        8,
        _devicePixelRatio,
      );
      await _settle();
    }
    for (var index = 0; index < 24 && _elementByKey(key) == null; index += 1) {
      await _input!.scroll(
        Offset(120, _viewSize.height * .55),
        -3,
        _devicePixelRatio,
      );
      await _settle();
    }
    if (_elementByKey(key) == null) {
      throw JourneyFailure('sidebar entry ${key.value} never became visible');
    }
  }

  Future<LocalAlbum> _openAlbumPath(String path) async {
    await _waitFor(
      () => _state.albums.any((album) => album.path == path),
      reason: 'album $path was not indexed',
    );
    final album = _requireAlbum(path);
    await _tapAlbum(album);
    await _waitFor(
      () =>
          _state.folder == album.path &&
          !_state.loading &&
          _state.total == album.count &&
          (_state.pages[0]?.isNotEmpty ?? false) &&
          _state.pages[0]!.first.parent == album.path,
      reason: 'album ${album.name} did not open with ${album.count} photos',
    );
    return album;
  }

  Future<void> _tapAlbum(LocalAlbum album) async {
    final key = ValueKey('sidebar-album-${album.path}');
    for (var attempt = 1; ; attempt += 1) {
      await _revealSidebarKey(key);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await _settle();
      try {
        await _centerInScrollable(key, album.path);
        await _tapKey('sidebar-album-${album.path}');
        return;
      } on JourneyFailure {
        if (attempt == 3) rethrow;
        await _input!.scroll(
          Offset(120, _viewSize.height * .55),
          -1,
          _devicePixelRatio,
        );
        await _settle();
      }
    }
  }

  Future<void> _openCloudAlbum(int expected) async {
    await _waitFor(
      () => _albumNamed('Cloud') != null,
      reason: 'the downloaded Cloud album never appeared',
    );
    final album = _albumNamed('Cloud')!;
    if (album.count != expected) {
      throw JourneyFailure(
        'Cloud album lists ${album.count} photos, expected $expected',
      );
    }
    await _tapAlbum(album);
    await _waitFor(
      () =>
          _state.folder == album.path &&
          !_state.loading &&
          _state.total == expected &&
          (_state.pages[0]?.length ?? 0) >= expected,
      reason: 'the Cloud album did not show $expected downloaded photos',
    );
    for (final photo in _state.pages[0]!) {
      await _waitForElement(
        'cloud-badge-${photo.id}',
        reason: 'downloaded photo ${photo.name} has no cloud badge',
      );
    }
  }

  Future<void> _selectAllAndUploadCloud() async {
    await _tapKey('library-options');
    await _waitForElement(
      'library-menu-select',
      reason: 'the library menu did not offer multi-select',
    );
    await _tapKey('library-menu-select');
    await _waitForElement('select-all', reason: 'multi-select did not start');
    await _tapKey('select-all');
    await _waitForElement(
      'selection-count',
      reason: 'select-all did not select the album',
    );
    await _tapKey('batch-upload-cloud');
  }

  Future<void> _rightTapThen(String key, String menuKey) async {
    for (var attempt = 1; attempt <= 2; attempt += 1) {
      final element = await _waitForElement(
        key,
        reason: 'widget $key is not mounted for a right click',
      );
      await _waitForStableRect(element, key);
      final position = _centerOf(element, key);
      await _input!.secondaryTap(position, _devicePixelRatio);
      await _settle();
      if (_elementByKey(ValueKey(menuKey)) != null) {
        await _tapKey(menuKey);
        return;
      }
      if (attempt == 2) {
        throw JourneyFailure('right-clicking $key did not open $menuKey');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _expectReadOnlyViewer(LocalPhoto photo) async {
    await _tapKey('photo-${photo.id}');
    await _waitForElement('viewer', reason: 'the viewer did not open');
    final viewer = _elementByKey(const ValueKey('viewer'))!;
    final image = await _waitForRenderedImage(viewer, 'cloud original');
    _expectDecodedMatchesRecord(image, photo);
    if (_elementByKey(const ValueKey('viewer-edit')) != null) {
      throw JourneyFailure('a bound photo still offers the editor');
    }
    for (final key in const [
      'viewer-trash',
      'viewer-rotate-left',
      'viewer-rotate-right',
    ]) {
      if (!_controlDisabled(key)) {
        throw JourneyFailure('$key is enabled for a read-only cloud photo');
      }
    }
    await _tapKey('viewer-details');
    await _waitForElement(
      'viewer-details-panel',
      reason: 'the details panel did not open',
    );
    if (!_controlDisabled('viewer-details-rename')) {
      throw JourneyFailure('cloud photos can still be renamed from details');
    }
    await _tapKey('viewer-details-close');
    await _key('Delete');
    await _settle();
    if (_elementByKey(const ValueKey('viewer-confirm-trash')) != null) {
      throw JourneyFailure('the Delete key opened trash for a cloud photo');
    }
    facts['cloud_read_only'] = {
      'photo': photo.name,
      'editor': 'absent',
      'trash_rotate_rename': 'disabled',
      'delete_key': 'ignored',
    };
  }

  bool _controlDisabled(String key) {
    final widget = _elementByKey(ValueKey(key))?.widget;
    if (widget is IconButton) return widget.onPressed == null;
    if (widget is TextButton) return widget.onPressed == null;
    if (widget is OutlinedButton) return widget.onPressed == null;
    if (widget is FilledButton) return widget.onPressed == null;
    return false;
  }

  Future<void> _closeViewer() async {
    await _key('Escape');
    await _waitFor(
      () => _elementByKey(const ValueKey('viewer')) == null,
      reason: 'Escape did not close the viewer',
    );
  }

  Future<void> _favoriteAndUpload(LocalPhoto photo) async {
    await _tapKey('photo-${photo.id}');
    await _waitForElement('viewer', reason: 'the viewer did not open');
    await _tapKey('viewer-favorite');
    await _waitFor(
      () =>
          _state.favoritePending.isEmpty &&
          (_state.photoAt(_state.indexOf(photo.id) ?? 0)?.favorite ?? false),
      reason: 'the favorite toggle did not reach the library',
    );
    await _closeViewer();
    await _syncNow();
    final state = _cloud;
    final report = state.report;
    if (state.status.pendingFavorites != 0) {
      throw JourneyFailure(
        'favorite upload left ${state.status.pendingFavorites} pending changes',
      );
    }
    if (report == null || report.favoritesUploaded < 1) {
      throw JourneyFailure('the manual sync did not report a favorite upload');
    }
    facts['favorite_upload'] = {
      'photo': photo.name,
      'favorites_uploaded': report.favoritesUploaded,
      'pending_favorites': state.status.pendingFavorites,
    };
  }

  Future<void> _expectTokenAbsent() async {
    final account = _cloudAccountId();
    if (account == null) {
      throw JourneyFailure('the cloud account directory disappeared');
    }
    final token = File('${options.dataRoot}/cloud/$account/session.token');
    if (token.existsSync()) {
      throw JourneyFailure('signing out left the session token on disk');
    }
    facts['cloud_account_id'] = account;
  }

  Future<void> _expectCloudCount(int expected) async {
    await _waitCloud(
      (state) =>
          !state.busy &&
          state.loggedIn &&
          state.status.boundCount == expected &&
          state.boundIds.length == expected,
      reason: 'the library did not reach $expected cloud photos',
      timeout: const Duration(minutes: 3),
    );
  }

  Future<void> _cloudUploadJourney() async {
    await _step('cloud-starts-signed-out', () async {
      await _waitCloud(
        (state) => state.available && !state.loading,
        reason: 'cloud state never loaded',
      );
      if (_cloud.loggedIn || _cloud.boundIds.isNotEmpty) {
        throw JourneyFailure('the fresh data root was not signed out');
      }
      facts['cloud_initial'] = {
        'available': _cloud.available,
        'logged_in': _cloud.loggedIn,
        'bound': _cloud.boundIds.length,
      };
    });
    await _step('cloud-settings-sign-in', () async {
      await _openCloudSettings();
      await _loginSuccessfully();
      final status = _cloud.status;
      if (status.username != options.requireCloudUsername()) {
        throw JourneyFailure('the account row does not show the username');
      }
      final expectedEndpoint = options.requireCloudEndpoint();
      if ((status.endpoint ?? '').replaceAll(RegExp(r'/+$'), '') !=
          expectedEndpoint.replaceAll(RegExp(r'/+$'), '')) {
        throw JourneyFailure('the account row does not show the endpoint');
      }
      if (_elementByKey(const ValueKey('cloud-account')) == null) {
        throw JourneyFailure('the signed-in account row is missing');
      }
      facts['cloud_login'] = {
        'username': status.username,
        'endpoint': status.endpoint,
        'bound': status.boundCount,
      };
      await _closeSettings();
    });
    await _step('cloud-album-upload-only-selected', () async {
      final album = await _openAlbumPath(
        options.requireCloudAlbum('cloud-batch-album', options.cloudBatchAlbum),
      );
      if (album.count != 1) {
        throw JourneyFailure(
          'the batch album ${album.name} must contain exactly one photo, '
          'found ${album.count}',
        );
      }
      final photo = _state.pages[0]!.single;
      if (_cloud.boundIds.isNotEmpty) {
        throw JourneyFailure('the selected album was already bound');
      }
      await _selectAllAndUploadCloud();
      await _expectCloudCount(1);
      await _waitForElement(
        'cloud-badge-${photo.id}',
        reason: 'the uploaded album photo has no cloud badge',
      );
      facts['cloud_album_upload'] = {
        'album': album.path,
        'album_count': album.count,
        'bound_ids': _cloud.boundIds.toList(),
        'media_id': photo.id,
        'name': photo.name,
      };
      if (_cloud.boundIds.single != photo.id) {
        throw JourneyFailure('an unselected photo was uploaded');
      }
      await _screenshot('30-cloud-album-upload');
    });
    await _step('cloud-single-photo-upload', () async {
      final album = await _openAlbumPath(
        options.requireCloudAlbum(
          'cloud-single-album',
          options.cloudSingleAlbum,
        ),
      );
      if (album.count != 1) {
        throw JourneyFailure('the single-upload album must contain one photo');
      }
      final photo = _state.pages[0]!.single;
      await _rightTapThen('photo-${photo.id}', 'photo-upload-cloud');
      await _expectCloudCount(2);
      await _waitForElement(
        'cloud-badge-${photo.id}',
        reason: 'the single-uploaded photo has no cloud badge',
      );
      facts['cloud_single_upload'] = {
        'album': album.path,
        'media_id': photo.id,
        'name': photo.name,
        'bound_ids': _cloud.boundIds.toList(),
      };
      if (!_cloud.boundIds.contains(photo.id)) {
        throw JourneyFailure('the right-click upload did not bind the photo');
      }
    });
    await _step('cloud-bound-photo-is-read-only', () async {
      final album = await _openAlbumPath(
        options.requireCloudAlbum(
          'cloud-single-album',
          options.cloudSingleAlbum,
        ),
      );
      await _expectReadOnlyViewer(_state.pages[0]!.single);
      await _closeViewer();
      facts['cloud_read_only_album'] = album.path;
      await _screenshot('31-cloud-read-only');
    });
    await _step('cloud-favorite-uploads', () async {
      final photo = _state.pages[0]!.single;
      await _favoriteAndUpload(photo);
      if (_cloud.status.pendingUploads != 0) {
        throw JourneyFailure('the upload root still has pending uploads');
      }
    });
    await _step('cloud-sign-out-keeps-local-content', () async {
      await _logout();
      await _expectTokenAbsent();
      await _closeSettings();
      if (_cloud.status.boundCount != 2) {
        throw JourneyFailure('signing out dropped the bound cloud photos');
      }
      for (final path in [
        options.requireCloudAlbum('cloud-batch-album', options.cloudBatchAlbum),
        options.requireCloudAlbum(
          'cloud-single-album',
          options.cloudSingleAlbum,
        ),
      ]) {
        await _openAlbumPath(path);
        final photo = _state.pages[0]!.single;
        if (!_cloud.isBound(photo.id)) {
          throw JourneyFailure(
            'the cloud binding for ${photo.name} vanished after sign-out',
          );
        }
        await _waitForElement(
          'cloud-badge-${photo.id}',
          reason: 'a cloud badge disappeared after sign-out',
        );
      }
      facts['cloud_sign_out'] = {
        'logged_in': _cloud.loggedIn,
        'bound': _cloud.status.boundCount,
        'token': 'removed',
      };
      await _closeSettings();
      await _screenshot('32-cloud-signed-out');
    });
  }

  Future<void> _cloudDownloadJourney() async {
    await _waitCloud(
      (state) => state.available && !state.loading,
      reason: 'cloud state never loaded',
    );
    await _step('cloud-rejects-localhost', () async {
      await _openCloudSettings();
      await _setCloudField('cloud-endpoint', 'http://localhost:8790');
      await _setCloudField('cloud-username', options.requireCloudUsername());
      await _setCloudField('cloud-password', options.cloudPassword);
      await _tapEnabled('cloud-login');
      await _waitCloud(
        (state) => !state.busy && state.errorCode != null,
        reason: 'localhost was not rejected',
      );
      if (_cloud.loggedIn) {
        throw JourneyFailure('localhost still produced a session');
      }
      final text = _textOf(const ValueKey('cloud-error')) ?? '';
      if (!_cloudErrorTextMatches('EndpointRejected', text)) {
        throw JourneyFailure('unexpected localhost error text: $text');
      }
      facts['cloud_endpoint_rejection'] = {'text': text};
    });
    await _step('cloud-rejects-wrong-password', () async {
      await _loginExpectingError(
        'AuthFailed',
        password: 'not-${options.cloudPassword}',
      );
      facts['cloud_auth_failure'] = {
        'text': _textOf(const ValueKey('cloud-error')),
        'signed_in': _cloud.loggedIn,
      };
    });
    await _step('cloud-login-downloads', () async {
      await _setCloudField('cloud-password', options.cloudPassword);
      await _tapEnabled('cloud-login');
      await _expectCloudCount(options.cloudExpectedPhotos);
      final account = _cloudAccountId();
      if (account == null) {
        throw JourneyFailure('no account directory was created');
      }
      await _expectCloudFiles(account, options.cloudExpectedPhotos);
      await _waitFor(
        () => _textOf(const ValueKey('cloud-error')) == null,
        reason: 'a successful download still shows an error',
      );
      facts['cloud_login'] = {
        'account_id': account,
        'downloaded': _cloud.status.boundCount,
        'error': _cloud.status.errorCode,
      };
      await _closeSettings();
    });
    await _step('cloud-downloads-have-thumbnails-and-originals', () async {
      await _openCloudAlbum(options.cloudExpectedPhotos);
      final photos = _state.pages[0]!;
      for (final photo in photos) {
        final tile = _elementByKey(ValueKey('photo-${photo.id}'))!;
        final image = await _waitForRenderedImage(tile, 'downloaded thumbnail');
        final longest = image.width > image.height ? image.width : image.height;
        if (image.width == 0 || image.height == 0 || longest > 1024) {
          throw JourneyFailure(
            'downloaded thumbnail ${photo.name} is not usable',
          );
        }
      }
      final remoteFavorite = photos.where((photo) => photo.favorite).toList();
      if (remoteFavorite.length != 1) {
        throw JourneyFailure(
          'expected the remote favorite on exactly one download, '
          'found ${remoteFavorite.length}',
        );
      }
      facts['cloud_grid'] = {
        'photos': photos.length,
        'thumbs': [
          for (final photo in photos) {'name': photo.name, 'id': photo.id},
        ],
        'remote_favorite': remoteFavorite.single.name,
      };
      await _screenshot('40-cloud-download-grid');
    });
    await _step('cloud-original-opens-in-viewer', () async {
      final photo = _state.pages[0]!.first;
      await _tapKey('photo-${photo.id}');
      await _waitForElement(
        'viewer',
        reason: 'the downloaded photo did not open',
      );
      final image = await _waitForRenderedImage(
        _elementByKey(const ValueKey('viewer'))!,
        'downloaded original',
      );
      _expectDecodedMatchesRecord(image, photo);
      await _closeViewer();
      facts['cloud_viewer'] = {
        'name': photo.name,
        'decoded_width': image.width,
        'decoded_height': image.height,
      };
    });
    await _step('cloud-downloaded-photo-is-read-only', () async {
      await _expectReadOnlyViewer(_state.pages[0]!.first);
      await _closeViewer();
      await _screenshot('41-cloud-download-read-only');
    });
    await _step('cloud-favorite-round-trip', () async {
      await _favoriteAndUpload(_state.pages[0]!.first);
      final account = _cloudAccountId();
      if (account == null) {
        throw JourneyFailure('no account directory was found');
      }
      await _expectCloudFiles(account, options.cloudExpectedPhotos);
    });
  }

  Future<void> _cloudOfflineJourney() async {
    await _step('cloud-startup-reports-network', () async {
      await _waitCloud(
        (state) =>
            !state.busy &&
            (state.errorCode == 'Network' ||
                state.status.errorCode == 'Network'),
        reason: 'the startup sync did not report a network failure',
        timeout: const Duration(minutes: 2),
      );
      if (!_cloud.loggedIn) {
        throw JourneyFailure('a network failure discarded the stored session');
      }
      facts['cloud_offline_startup'] = {
        'error': _cloud.errorCode ?? _cloud.status.errorCode,
        'state': _cloud.status.state,
        'bound': _cloud.status.boundCount,
      };
      await _screenshot('50-cloud-offline-startup');
    });
    await _step('cloud-offline-content-still-opens', () async {
      await _openCloudAlbum(options.cloudExpectedPhotos);
      final photo = _state.pages[0]!.first;
      await _tapKey('photo-${photo.id}');
      await _waitForElement(
        'viewer',
        reason: 'offline cloud photo did not open',
      );
      final image = await _waitForRenderedImage(
        _elementByKey(const ValueKey('viewer'))!,
        'offline cloud original',
      );
      _expectDecodedMatchesRecord(image, photo);
      await _closeViewer();
      facts['cloud_offline_viewer'] = {
        'name': photo.name,
        'decoded_width': image.width,
        'decoded_height': image.height,
      };
    });
    await _step('cloud-offline-upload-queues-durably', () async {
      final album = await _openAlbumPath(
        options.requireCloudAlbum('cloud-extra-album', options.cloudExtraAlbum),
      );
      if (album.count != 1) {
        throw JourneyFailure('the offline album must contain one photo');
      }
      final photo = _state.pages[0]!.single;
      await _selectAllAndUploadCloud();
      await _waitCloud(
        (state) =>
            !state.busy &&
            (state.errorCode == 'Network' ||
                state.status.errorCode == 'Network') &&
            state.status.pendingUploads >= 1,
        reason: 'the offline upload did not remain queued',
        timeout: const Duration(minutes: 2),
      );
      if (_cloud.boundIds.contains(photo.id)) {
        throw JourneyFailure('an offline upload was reported as published');
      }
      facts['cloud_offline_upload'] = {
        'media_id': photo.id,
        'name': photo.name,
        'pending_uploads': _cloud.status.pendingUploads,
        'error': _cloud.errorCode ?? _cloud.status.errorCode,
      };
    });
    await _step('cloud-offline-sign-out-and-retry', () async {
      await _openCloudSettings();
      await _tapEnabled('cloud-logout');
      await _waitCloud(
        (state) => !state.loggedIn && !state.busy,
        reason: 'offline sign-out did not complete',
      );
      await _expectTokenAbsent();
      if (_cloud.status.pendingUploads < 1) {
        throw JourneyFailure('signing out discarded the queued offline upload');
      }
      await _loginAttemptOffline();
      await _closeSettings();
      facts['cloud_offline_logout'] = {
        'pending_uploads': _cloud.status.pendingUploads,
        'login_error': _cloud.errorCode,
      };
      await _screenshot('51-cloud-offline-login-error');
    });
  }

  Future<void> _loginAttemptOffline() async {
    await _setCloudField('cloud-endpoint', options.requireCloudEndpoint());
    await _setCloudField('cloud-username', options.requireCloudUsername());
    await _setCloudField('cloud-password', options.cloudPassword);
    await _tapEnabled('cloud-login');
    await _waitCloud(
      (state) => !state.busy && state.errorCode == 'Network',
      reason: 'the offline login did not fail with Network',
      timeout: const Duration(minutes: 2),
    );
    if (_cloud.loggedIn) {
      throw JourneyFailure('an offline login reported a session');
    }
  }

  Future<void> _cloudReconnectJourney() async {
    await _waitCloud(
      (state) => state.available && !state.loading,
      reason: 'cloud state never loaded',
    );
    await _step('cloud-reconnect-restores-session', () async {
      if (_cloud.loggedIn) {
        throw JourneyFailure('the offline sign-out did not persist');
      }
      await _openCloudSettings();
      await _loginSuccessfully();
      await _expectCloudCount(options.cloudExpectedPhotos);
      await _waitCloud(
        (state) =>
            !state.busy &&
            state.status.pendingUploads == 0 &&
            state.status.errorCode == null,
        reason: 'the queued offline upload was not published',
        timeout: const Duration(minutes: 3),
      );
      facts['cloud_reconnect'] = {
        'bound': _cloud.status.boundCount,
        'pending_uploads': _cloud.status.pendingUploads,
        'error': _cloud.status.errorCode,
      };
      await _closeSettings();
    });
    await _step('cloud-reconnect-upload-has-badge', () async {
      // Two photos are downloads and live in the virtual Cloud album; the
      // third was uploaded from a real album and keeps that album.
      final downloaded = options.cloudExpectedPhotos - 1;
      await _openCloudAlbum(downloaded);
      for (final photo in _state.pages[0]!) {
        await _waitForElement(
          'cloud-badge-${photo.id}',
          reason: 'reconnected photo ${photo.name} has no cloud badge',
        );
      }
      final album = await _openAlbumPath(
        options.requireCloudAlbum('cloud-extra-album', options.cloudExtraAlbum),
      );
      final uploaded = _state.pages[0]!.single;
      if (!_cloud.isBound(uploaded.id)) {
        throw JourneyFailure(
          'the queued offline upload ${uploaded.name} was not published',
        );
      }
      await _waitForElement(
        'cloud-badge-${uploaded.id}',
        reason: 'the reconnected upload has no cloud badge',
      );
      final account = _cloudAccountId();
      if (account == null) {
        throw JourneyFailure('the account directory is gone');
      }
      await _expectCloudFiles(account, downloaded);
      facts['cloud_reconnect_upload'] = {
        'album': album.path,
        'name': uploaded.name,
        'bound': _cloud.status.boundCount,
      };
      await _screenshot('60-cloud-reconnected');
    });
  }

  Future<void> _cloudReconcileJourney() async {
    await _step('cloud-reconcile-account', () async {
      await _waitCloud(
        (state) => state.available && !state.loading,
        reason: 'cloud state never loaded',
      );
      if (_cloud.loggedIn) {
        throw JourneyFailure('the upload root was expected to be signed out');
      }
      await _openCloudSettings();
      await _loginSuccessfully();
      await _expectCloudCount(options.cloudExpectedPhotos);
      await _closeSettings();
      facts['cloud_reconcile'] = {
        'bound': _cloud.status.boundCount,
        'error': _cloud.status.errorCode,
      };
    });
    await _step('cloud-reconcile-remote-favorite-and-new-photo', () async {
      // Only the photo uploaded by the other root is a download here; the two
      // photos this root uploaded stay in their real albums.
      await _openCloudAlbum(1);
      final downloaded = _state.pages[0]!.single;
      await _waitForElement(
        'cloud-badge-${downloaded.id}',
        reason: 'the newly downloaded photo has no cloud badge',
      );
      final single = await _openAlbumPath(
        options.requireCloudAlbum(
          'cloud-single-album',
          options.cloudSingleAlbum,
        ),
      );
      final favorite = _state.pages[0]!.single;
      if (!favorite.favorite) {
        throw JourneyFailure(
          'the remote favorite was not applied to ${favorite.name}',
        );
      }
      await _waitForElement(
        'cloud-badge-${favorite.id}',
        reason: 'the favorited photo lost its cloud badge',
      );
      final batch = await _openAlbumPath(
        options.requireCloudAlbum('cloud-batch-album', options.cloudBatchAlbum),
      );
      final uploaded = _state.pages[0]!.single;
      if (!uploaded.favorite) {
        throw JourneyFailure(
          'the favorite uploaded by the download root was not applied to '
          '${uploaded.name}',
        );
      }
      await _waitForElement(
        'cloud-badge-${uploaded.id}',
        reason: 'the earlier upload lost its cloud badge',
      );
      final account = _cloudAccountId();
      if (account == null) {
        throw JourneyFailure('the account directory is gone');
      }
      await _expectCloudFiles(account, 1);
      facts['cloud_reconcile_photos'] = {
        'downloaded': downloaded.name,
        'favorite': favorite.name,
        'uploaded': uploaded.name,
        'albums': [single.path, batch.path],
      };
      await _screenshot('70-cloud-reconciled');
    });
  }
}
