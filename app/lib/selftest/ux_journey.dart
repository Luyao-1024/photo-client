part of 'local_journey.dart';

/// Scripted answers for the UX journey's four picker roles. The journey sets
/// the next answer before every tap so the test never depends on call order.
final class UxSourcePicker implements LocalSourcePicker {
  UxSourcePicker({required this.evidenceRoot, required this.sourceDirectory});

  final String evidenceRoot;
  final String sourceDirectory;
  String? directoryResponse;
  List<String> fileResponse = const [];
  int directoryRequests = 0;
  int fileRequests = 0;
  final List<String?> directoryHistory = [];
  final List<List<String>> fileHistory = [];

  @override
  Future<String?> chooseDirectory() async {
    directoryRequests += 1;
    directoryHistory.add(directoryResponse);
    return directoryResponse;
  }

  @override
  Future<List<String>> chooseFiles() async {
    fileRequests += 1;
    fileHistory.add(List.of(fileResponse));
    return fileResponse;
  }
}

extension UxJourney on LocalJourney {
  UxSourcePicker get _uxSourcePicker {
    final picker = _uxPicker;
    if (picker == null) {
      throw JourneyFailure('the ux source picker is not installed');
    }
    return picker;
  }

  PresentationPreferences get _uxPreferences =>
      _container!.read(presentationProvider);

  String get _uxRoot => '${options.evidenceDir}/ux';
  String get _uxSourceRoot =>
      Directory(options.sources.isEmpty ? '' : options.sources.first)
          .resolveSymbolicLinksSync();
  String get _uxAlbumRoot =>
      Directory('$_uxRoot/albums').resolveSymbolicLinksSync();
  String get _uxExportRoot =>
      Directory('$_uxRoot/export').resolveSymbolicLinksSync();
  String get _uxExtraFile =>
      File('$_uxRoot/extra/extra.png').resolveSymbolicLinksSync();
  String get _uxMediaRoot =>
      Directory('${options.evidenceDir}/fixtures/media-kinds')
          .resolveSymbolicLinksSync();
  String get _uxDataRoot =>
      Directory(options.dataRoot!).resolveSymbolicLinksSync();

  Future<void> _uxJourney() async {
    final started = DateTime.now();
    facts['ux'] = <String, Object?>{};
    await _uxStepEmptyState();
    await _uxStepSettingsAppearance();
    await _uxStepSettingsSources();
    await _uxStepGridModes();
    await _uxStepSearch();
    await _uxStepSelectionAndFavorites();
    await _uxStepAlbums();
    await _uxStepRenameAndDetails();
    await _uxStepExport();
    await _uxStepTrashLifecycle();
    await _uxStepViewer();
    await _uxStepEditor();
    await _uxStepMediaKinds();
    await _uxStepSettingsCleanup();
    await _uxStepFinalFacts();
    _uxRecord('elapsed_ms', DateTime.now().difference(started).inMilliseconds);
  }

  // ------------------------------------------------------------------- steps

  Future<void> _uxStepEmptyState() async {
    await _step('ux-empty-library', () async {
      await _waitFor(
        () => _state.info != null && !_state.loading && _state.total == 0,
        reason: 'the fresh ux library never reached the empty state',
      );
      await _waitForElement(
        'open-settings',
        reason: 'the empty library does not offer the settings button',
      );
      _uxRecord('initial_total', 0);
    });
    await _step('ux-open-settings-button', () async {
      await _tapKey('open-settings');
      await _waitForElement(
        'settings-close',
        reason: 'the empty-state settings button did not open settings',
      );
      for (var index = 0; index < 4; index += 1) {
        if (_elementByKey(ValueKey('settings-category-$index')) == null) {
          throw JourneyFailure('settings category $index is missing');
        }
      }
      await _screenshot('ux-01-settings');
    });
  }

  Future<void> _uxStepSettingsAppearance() async {
    await _step('ux-settings-shortcuts', () async {
      await _tapKey('settings-shortcuts');
      await _waitForElement(
        'shortcuts-close',
        reason: 'the shortcuts row did not open the reference',
      );
      if (_textElements('Ctrl+F').isEmpty) {
        throw JourneyFailure('the shortcut reference omitted Ctrl+F');
      }
      await _tapKey('shortcuts-close');
      await _uxWaitGone(
        'shortcuts-close',
        'the shortcut reference did not close',
      );
    });
    await _step('ux-settings-appearance', () async {
      await _tapKey('settings-category-0');
      await _tapKey('settings-language-en');
      await _waitFor(
        () => _uxPreferences.locale?.languageCode == 'en',
        reason: 'the journey could not switch the UI to English',
      );
      await _tapKey('settings-category-0');
      await _uxScrollToKey(
        'settings-theme-dark',
        container: 'settings-content',
      );
      await _tapKey('settings-theme-dark');
      await _waitFor(
        () => _uxPreferences.themeMode == ThemeMode.dark,
        reason: 'the dark theme choice did not reach the preference state',
      );
      await _tapKey('settings-category-1');
      await _uxScrollToKey(
        'settings-background-blur',
        container: 'settings-content',
      );
      await _uxTapFraction('settings-background-blur', .75, .5);
      await _waitFor(
        () => _uxPreferences.backgroundBlur > .5,
        reason: 'the background blur slider did not update',
      );
      await _tapKey('settings-follow-scroll');
      await _waitFor(
        () => !_uxPreferences.followScroll,
        reason: 'the background follow switch did not turn off',
      );
      await _tapKey('settings-follow-scroll');
      await _waitFor(
        () => _uxPreferences.followScroll,
        reason: 'the background follow switch did not turn on',
      );
      await _tapKey('settings-category-0');
      await _uxScrollToKey(
        'settings-reduce-motion',
        container: 'settings-content',
      );
      await _tapKey('settings-reduce-motion');
      await _waitFor(
        () => _uxPreferences.reduceMotion,
        reason: 'Reduce motion was not saved',
      );
      await _tapKey('settings-category-0');
      await _tapKey('settings-language-zh');
      await _waitFor(
        () => _uxPreferences.locale?.languageCode == 'zh',
        reason: 'the Chinese language chip did not apply',
      );
      await _tapKey('settings-language-en');
      await _waitFor(
        () => _uxPreferences.locale?.languageCode == 'en',
        reason: 'the English language chip did not apply',
      );
      _uxRecord('theme', _uxPreferences.themeMode.name);
      _uxRecord('material', 'liquid_glass');
      _uxRecord('background_blur', _uxPreferences.backgroundBlur);
      _uxRecord('follow_scroll', _uxPreferences.followScroll);
      _uxRecord('reduce_motion', _uxPreferences.reduceMotion);
    });
  }

  Future<void> _uxStepSettingsSources() async {
    await _step('ux-settings-grid-controls', () async {
      await _tapKey('settings-category-2');
      await _uxScrollTop('settings-content');
      await _uxScrollToKey(
        'settings-day-columns',
        container: 'settings-content',
      );
      final before = _uxPreferences.dayColumns;
      await _uxTapFraction('settings-day-columns', .98, .5);
      await _waitFor(
        () => _uxPreferences.dayColumns > before,
        reason: 'the day-column slider did not change the column count',
      );
      await _uxScrollToKey('settings-order', container: 'settings-content');
      await _uxTapDropdown('settings-order');
      await _uxTapMenuText('Name: ascending');
      await _waitFor(
        () => _uxPreferences.order == 'name_asc',
        reason: 'the sort dropdown did not apply Name: ascending',
      );
      await _uxTapDropdown('settings-order');
      await _uxTapMenuText('Date: newest first');
      await _waitFor(
        () => _uxPreferences.order == 'date_desc',
        reason: 'the sort dropdown did not return to Date: newest first',
      );
      _uxRecord('day_columns', _uxPreferences.dayColumns);
    });
    await _step('ux-settings-add-folder', () async {
      _uxSourcePicker.directoryResponse = _uxSourceRoot;
      await _uxScrollToKey('add-folder', container: 'settings-content');
      final previous = _state.scanResult;
      await _tapKey('add-folder');
      final result = await _uxWaitForScan(previous, 'add folder');
      if (result.discovered != 6) {
        throw JourneyFailure(
          'the real add-folder scan discovered ${result.discovered}, expected 6',
        );
      }
      await _uxWaitTotal(6, 'the scanned photos did not appear');
      await _uxScrollToKey('settings-order', container: 'settings-content');
      await _uxTapDropdown('settings-order');
      await _uxTapMenuText('Name: ascending');
      await _waitFor(
        () =>
            !_state.loading &&
            (_state.pages[0]?.isNotEmpty ?? false) &&
            _state.pages[0]!.first.name == 'alpha.png',
        reason: 'the grid did not reorder to the ascending name order',
      );
      await _uxTapDropdown('settings-order');
      await _uxTapMenuText('Date: newest first');
      await _waitFor(
        () => _uxPreferences.order == 'date_desc',
        reason: 'the grid did not return to the newest-first order',
      );
      _uxRecord('order_applied', 'name_asc');
      _uxRecord('scan_folder', {
        'discovered': result.discovered,
        'skipped': result.skipped,
        'failed': result.failed,
        'cancelled': result.cancelled,
      });
    });
    await _step('ux-settings-add-files', () async {
      _uxSourcePicker.fileResponse = [_uxExtraFile];
      await _uxScrollToKey('add-files', container: 'settings-content');
      final previous = _state.scanResult;
      await _tapKey('add-files');
      final result = await _uxWaitForScan(previous, 'add files');
      if (result.discovered != 1) {
        throw JourneyFailure(
          'the real add-files scan discovered ${result.discovered}, expected 1',
        );
      }
      await _uxWaitTotal(7, 'the extra file did not join the library');
      if (!await File(_uxExtraFile).exists()) {
        throw JourneyFailure('add-files consumed the selected original');
      }
      _uxRecord('scan_files', {'discovered': result.discovered});
    });
    await _step('ux-settings-rescan', () async {
      await _uxScrollToKey('settings-rescan', container: 'settings-content');
      final previous = _state.scanResult;
      await _tapKey('settings-rescan');
      final result = await _uxWaitForScan(previous, 'rescan');
      await _uxWaitTotal(7, 'the rescan changed the library count');
      // The scan is incremental: an unchanged file is stat'ed and skipped
      // instead of being indexed a second time.
      if (result.discovered != 0) {
        throw JourneyFailure(
          'the rescan rediscovered ${result.discovered} unchanged items, expected 0',
        );
      }
      if (result.skipped < 7) {
        throw JourneyFailure(
          'the rescan skipped ${result.skipped} items, expected the 7 indexed ones',
        );
      }
      _uxRecord('rescan', {
        'discovered': result.discovered,
        'skipped': result.skipped,
        'failed': result.failed,
        'total': _state.total,
      });
    });
    await _step('ux-settings-remove-file-source-keeps-file', () async {
      await _uxScrollToKey(
        'settings-remove-source-$_uxExtraFile',
        container: 'settings-content',
      );
      await _tapKey('settings-remove-source-$_uxExtraFile');
      await _waitForElement(
        'remove-source-confirm',
        reason: 'removing a source did not ask for confirmation',
      );
      await _tapKey('remove-source-confirm');
      await _uxWaitTotal(
        6,
        'removing the extra source did not update the grid',
      );
      if (!await File(_uxExtraFile).exists()) {
        throw JourneyFailure('removing a source deleted the original file');
      }
      _uxRecord('extra_source_removed', true);
    });
    await _step('ux-close-settings', () async {
      await _tapKey('settings-close');
      await _uxWaitGone('settings-close', 'the settings dialog did not close');
      final alpha = await _uxWaitSourcePhoto('alpha.png');
      await _waitForElement(
        'photo-${alpha.id}',
        reason: 'the grid did not become visible after closing settings',
        timeout: const Duration(seconds: 5),
      );
    });
  }

  Future<void> _uxStepGridModes() async {
    await _step('ux-grid-modes', () async {
      final modes = <String, String>{};
      for (final entry in {
        'mode-year': 'year',
        'mode-month': 'month',
        'mode-day': 'day',
      }.entries) {
        await _tapKey(entry.key);
        await _settle();
        final tiles = _photoTileElements();
        if (tiles.isEmpty) {
          throw JourneyFailure('${entry.value} grouping rendered no tiles');
        }
        modes[entry.value] = '${tiles.length} tiles';
      }
      _uxRecord('modes', modes);
      await _screenshot('ux-02-grid');
    });
    await _step('ux-sidebar-media-filters', () async {
      await _tapKey('sidebar-media-images');
      await _waitFor(
        () =>
            !_state.loading && _state.mediaKind == 'image' && _state.total == 6,
        reason: 'the Images destination did not show all six images',
      );
      await _tapKey('sidebar-media-videos');
      await _waitFor(
        () =>
            !_state.loading && _state.mediaKind == 'video' && _state.total == 0,
        reason: 'the Videos destination did not empty the grid',
      );
      await _waitFor(
        () => _textElements('No matching photos').isNotEmpty,
        reason: 'the empty Videos destination did not explain the empty result',
      );
      await _tapKey('sidebar-photos');
      await _uxWaitTotal(6, 'returning to Library did not restore the photos');
    });
  }

  Future<void> _uxStepSearch() async {
    await _step('ux-search-name-scope', () async {
      await _tapKey('library-search');
      await _waitForElement(
        'library-search-close',
        reason: 'the search destination did not appear',
      );
      await _tapKey('search-scope-name');
      await _tapKey('library-search');
      await _key('ctrl+a');
      await _type('alpha');
      await _waitFor(
        () => _state.search == 'alpha' && !_state.loading,
        reason: 'the debounced name search did not apply',
      );
      if (_state.total != 1) {
        throw JourneyFailure('name search returned ${_state.total} items');
      }
      if (_state.pages[0]!.single.name != 'alpha.png') {
        throw JourneyFailure('name search returned the wrong photo');
      }
      await _screenshot('ux-03-search');
      _uxRecord('search_name', {'query': 'alpha', 'total': _state.total});
      await _key('Escape');
      await _uxWaitGone('library-search-close', 'Escape did not close search');
      await _waitFor(
        () => _state.search.isEmpty && !_state.loading,
        reason: 'closing search left an invisible query',
      );
      await _uxWaitTotal(6, 'closing search did not restore the library');
    });
    await _step('ux-search-date-scope', () async {
      final alpha = await _uxWaitSourcePhoto('alpha.png');
      final date = DateTime.fromMillisecondsSinceEpoch(
        alpha.captureTimeMs ?? alpha.modifiedMs,
      );
      final digits =
          '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
      await _tapKey('library-search');
      await _waitForElement(
        'library-search-close',
        reason: 'search did not reopen',
      );
      await _tapKey('search-scope-date');
      await _tapKey('library-search');
      await _key('ctrl+a');
      await _type(digits);
      final formatted =
          '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
      await _waitFor(
        () => _state.search == formatted && !_state.loading,
        reason: 'the date scope did not format and apply "$digits"',
      );
      if (_state.total < 1) {
        throw JourneyFailure('date search returned no items');
      }
      _uxRecord('search_date', {'query': _state.search, 'total': _state.total});
      await _key('Escape');
      await _uxWaitGone(
        'library-search-close',
        'Escape did not close date search',
      );
      await _waitFor(
        () => _state.search.isEmpty && !_state.loading,
        reason: 'closing date search left an invisible query',
      );
      await _uxWaitTotal(6, 'closing date search did not restore the library');
    });
    await _step('ux-search-open-viewer', () async {
      await _tapKey('library-search');
      await _waitForElement(
        'library-search-close',
        reason: 'search did not reopen for the scoped viewer',
      );
      await _tapKey('search-scope-name');
      await _tapKey('library-search');
      await _key('ctrl+a');
      await _type('alpha');
      await _waitFor(
        () => _state.search == 'alpha' && !_state.loading && _state.total == 1,
        reason: 'the name search did not settle before opening the viewer',
      );
      final alpha = await _uxWaitSourcePhoto('alpha.png');
      await _tapKey('photo-${alpha.id}');
      await _waitForElement(
        'viewer',
        reason: 'the search result did not open in the viewer',
      );
      await _waitFor(
        () => _textOf(const ValueKey('viewer-position')) == '1 / 1',
        reason: 'the viewer ignored the one-result search scope',
      );
      await _key('Escape');
      await _uxWaitGone('viewer', 'Escape did not close the scoped viewer');
      await _key('Escape');
      await _uxWaitGone(
        'library-search-close',
        'Escape did not close the search after the viewer',
      );
      await _uxWaitTotal(
        6,
        'closing the scoped viewer did not restore the grid',
      );
      _uxRecord('search_viewer', {
        'query': 'alpha',
        'position': '1 / 1',
        'restored_total': _state.total,
      });
    });
  }

  Future<void> _uxStepSelectionAndFavorites() async {
    await _step('ux-select-all-and-favorite', () async {
      await _uxSelectAllViaMenu();
      await _tapKey('batch-favorite');
      await _waitFor(
        () => _state.favoritePending.isEmpty,
        reason: 'the batch favorite write never settled',
      );
      await _uxWaitFavorites(6);
      _uxRecord('favorite_all', 6);
      await _tapKey('exit-selection');
      await _uxWaitGone(
        'selection-count',
        'the selection remained after favoriting',
      );
    });
    await _step('ux-favorites-destination', () async {
      await _tapKey('sidebar-favorites');
      await _waitFor(
        () => !_state.loading && _state.favoritesOnly && _state.total == 6,
        reason: 'the Favorites destination did not show six photos',
      );
      final alpha = await _uxWaitSourcePhoto('alpha.png');
      await _waitForElement(
        'photo-${alpha.id}',
        reason: 'a favorite tile is missing',
      );
      await _screenshot('ux-04-favorites');
      await _tapKey('sidebar-photos');
      await _uxWaitTotal(6, 'leaving Favorites did not restore the library');
    });
    await _step('ux-batch-unfavorite', () async {
      await _uxSelectAllViaMenu();
      await _tapKey('batch-favorite');
      await _waitFor(
        () => _state.favoritePending.isEmpty,
        reason: 'the batch unfavorite write never settled',
      );
      await _uxWaitFavorites(0);
      _uxRecord('favorite_all_off', 0);
      await _tapKey('exit-selection');
      await _uxWaitGone(
        'selection-count',
        'the selection remained after unfavoriting',
      );
    });
  }

  Future<void> _uxStepAlbums() async {
    await _step('ux-create-album', () async {
      _uxSourcePicker.directoryResponse = _uxAlbumRoot;
      await _tapKey('sidebar-album-add');
      await _waitForElement(
        'album-name-field',
        reason: 'the new-album name dialog did not appear',
      );
      await _type('Trip');
      await _tapKey('album-create-confirm');
      final trip = _uxTripPath;
      await _uxWaitUntil(
        () => Directory(trip).existsSync(),
        reason: 'the album folder was not created on disk',
      );
      await _uxWaitAlbum(trip, 'the new album never reached the sidebar');
      _uxRecord('album_path', trip);
      _uxRecord('album_created', true);
    });
    await _step('ux-copy-to-album', () async {
      final trip = _uxTripPath;
      await _uxSelectAllViaMenu();
      await _tapKey('batch-add-to-album');
      await _uxTapText('Copy to album');
      await _waitForElement(
        'album-target-$trip',
        reason: 'the album target picker did not list the new album',
      );
      await _tapKey('album-target-$trip');
      await _uxWaitGone(
        'album-target-$trip',
        'the album picker did not close after copying',
      );
      await _uxWaitTotal(12, 'copying to the album did not add six rows');
      final names = await _uxDirectoryNames(trip);
      if (names.length != 6) {
        throw JourneyFailure(
          'copying to the album produced ${names.length} files, expected 6',
        );
      }
      for (final name in names) {
        final page = await _library!.listPhotos(
          search: name,
          searchScope: SearchScope.name,
          limit: 100,
        );
        LocalPhoto? source;
        for (final photo in page.items) {
          if (photo.name == name && photo.path.startsWith('$_uxSourceRoot/')) {
            source = photo;
            break;
          }
        }
        if (source == null || !await File(source.path).exists()) {
          throw JourneyFailure('copying to the album removed source $name');
        }
      }
      _uxRecord('album_copy_files', names.length);
      await _screenshot('ux-05-album-copy');
    });
    await _step('ux-move-to-album', () async {
      final trip = _uxTripPath;
      final before = await _uxWaitSourcePhoto('large.jpg');
      final source = File(before.path);
      final digest = await _uxFileFingerprint(before.path);
      await _uxRightTapKey('photo-${before.id}');
      await _waitForElement(
        'tile-menu-move-album',
        reason: 'the tile menu did not offer Move to album',
      );
      await _tapKey('tile-menu-move-album');
      await _waitForElement(
        'album-target-$trip',
        reason: 'the move-to-album picker did not open',
      );
      await _tapKey('album-target-$trip');
      await _uxWaitGone(
        'album-target-$trip',
        'the album picker did not close after moving',
      );
      await _uxWaitUntil(
        () => !source.existsSync(),
        reason: 'moving to the album left the source file in place',
      );
      await _uxWaitTotal(12, 'moving to the album changed the total row count');
      final names = await _uxDirectoryNames(trip);
      if (names.length != 7) {
        throw JourneyFailure(
          'moving to the album produced ${names.length} files, expected 7',
        );
      }
      final moved = names.where((name) => name.startsWith('large')).toList();
      if (moved.length != 2) {
        throw JourneyFailure(
          'move did not keep the copied and moved large files',
        );
      }
      final destination = File('$trip/${moved.last}');
      if (await _uxFileFingerprint(destination.path) != digest) {
        throw JourneyFailure('moving to the album altered the file bytes');
      }
      _uxRecord('album_move_file', destination.path);
      _uxRecord('album_move_id', before.id);
    });
    await _step('ux-set-album-cover', () async {
      final trip = _uxTripPath;
      final albumPhotos = await _uxPhotosInFolder(trip);
      if (albumPhotos.isEmpty) {
        throw JourneyFailure('the album has no photo to use as its cover');
      }
      // Prefer an album copy that predates the move: the freshly reparented
      // row is still being refreshed and can drop a context-menu gesture.
      final movedId = (facts['ux'] as Map<String, Object?>)['album_move_id'];
      final cover = albumPhotos.firstWhere(
        (photo) => photo.id != movedId,
        orElse: () => albumPhotos.first,
      );
      await _uxRightTapKey('photo-${cover.id}');
      await _waitForElement(
        'tile-menu-cover',
        reason: 'the tile menu did not offer Set as album cover',
      );
      await _tapKey('tile-menu-cover');
      await _uxWaitUntil(() async {
        final albums = await _library!.listAlbums();
        return albums
            .where((album) => album.path == trip)
            .any((album) => album.coverMediaId == cover.id);
      }, reason: 'the album cover preference was not stored');
      _uxRecord('album_cover_id', cover.id);
    });
    await _step('ux-rename-album-folder', () async {
      final trip = _uxTripPath;
      await _uxRightTapKey('sidebar-album-$trip', menuPrefix: 'album-menu-');
      await _waitForElement(
        'album-menu-rename',
        reason: 'the album context menu did not appear',
      );
      await _tapKey('album-menu-rename');
      await _waitForElement(
        'album-rename-field',
        reason: 'the rename-album dialog did not appear',
      );
      await _key('ctrl+a');
      await _type('Trips');
      await _tapKey('album-rename-confirm');
      await _uxWaitGone(
        'album-rename-field',
        'the album rename dialog did not close',
      );
      final renamed = _uxTripsPath;
      await _uxWaitUntil(
        () => Directory(renamed).existsSync() && !Directory(trip).existsSync(),
        reason: 'renaming the album did not move its folder on disk',
      );
      await _uxWaitAlbum(
        renamed,
        'the renamed album never reached the sidebar',
      );
      final paths = await _uxPhotoPathsInFolder(renamed);
      if (paths.isEmpty) {
        throw JourneyFailure('the renamed album lost its indexed photos');
      }
      _uxRecord('album_renamed', renamed);
    });
    await _step('ux-reorder-albums', () async {
      _uxSourcePicker.directoryResponse = _uxAlbumRoot;
      await _tapKey('sidebar-album-add');
      await _waitForElement(
        'album-name-field',
        reason: 'second album dialog missing',
      );
      await _type('Second');
      await _tapKey('album-create-confirm');
      await _uxWaitGone(
        'album-name-field',
        'the album create dialog did not close',
      );
      final second = '$_uxAlbumRoot/Second';
      await _uxWaitAlbum(second, 'the second album never appeared');
      final ordered = await _library!.listAlbums();
      final target = ordered.first.path == second
          ? ordered[1].path
          : ordered.first.path;
      await _uxDragKeys(
        'sidebar-album-$second',
        'sidebar-album-$target',
        hold: const Duration(milliseconds: 700),
      );
      await _uxWaitUntil(() async {
        final albums = await _library!.listAlbums();
        return albums.isNotEmpty && albums.first.path == second;
      }, reason: 'dragging the album did not persist the new order');
      _uxRecord('album_order_first', second);
      await _uxRightTapKey('sidebar-album-$second', menuPrefix: 'album-menu-');
      await _waitForElement('album-menu-remove', reason: 'album menu missing');
      await _tapKey('album-menu-remove');
      await _waitForElement(
        'album-remove-confirm',
        reason: 'removing an album did not ask for confirmation',
      );
      await _tapKey('album-remove-confirm');
      await _uxWaitUntil(
        () =>
            !Directory(second).existsSync() ||
            Directory(second).listSync().isEmpty,
        reason: 'removing the empty album unexpectedly deleted files',
      );
      await _uxWaitUntil(() async {
        final albums = await _library!.listAlbums();
        return albums.every((album) => album.path != second);
      }, reason: 'the removed album stayed in the library');
    });
    await _step('ux-album-navigation', () async {
      final trips = _uxTripsPath;
      final expected = await _uxPhotosInFolder(trips);
      if (expected.length != 7) {
        throw JourneyFailure(
          'the album holds ${expected.length} rows, expected 7',
        );
      }
      await _tapKey('sidebar-album-$trips');
      await _waitFor(
        () => _state.folder == trips && !_state.loading,
        reason: 'clicking the album did not scope the grid to it',
      );
      await _uxWaitTotal(7, 'the album destination did not show seven photos');
      final visible = <LocalPhoto>[
        for (final page in _state.pages.values) ...page,
      ];
      if (visible.length != 7) {
        throw JourneyFailure(
          'the album grid loaded ${visible.length} of 7 rows',
        );
      }
      for (final photo in visible) {
        if (!photo.path.startsWith('$trips/')) {
          throw JourneyFailure('the album grid leaked ${photo.path}');
        }
      }
      final first = visible.first;
      await _tapKey('photo-${first.id}');
      await _waitForElement(
        'viewer',
        reason: 'the album photo did not open in the viewer',
      );
      await _waitFor(
        () =>
            _textOf(const ValueKey('viewer-name')) == first.name &&
            _textOf(const ValueKey('viewer-position')) == '1 / 7',
        reason: 'the viewer did not start at the first album photo',
      );
      await _tapKey('viewer-next');
      await _waitFor(
        () =>
            _textOf(const ValueKey('viewer-name')) == visible[1].name &&
            _textOf(const ValueKey('viewer-position')) == '2 / 7',
        reason: 'Next left the album scope or skipped a photo',
      );
      await _key('Left');
      await _waitFor(
        () =>
            _textOf(const ValueKey('viewer-name')) == first.name &&
            _textOf(const ValueKey('viewer-position')) == '1 / 7',
        reason: 'ArrowLeft did not return to the previous album photo',
      );
      final previous = _elementByKey(const ValueKey('viewer-previous'))?.widget;
      if (previous is IconButton && previous.onPressed != null) {
        throw JourneyFailure('Previous stayed enabled at the album start');
      }
      await _key('Escape');
      await _uxWaitGone('viewer', 'Escape did not close the album viewer');
      if (_state.folder != trips) {
        throw JourneyFailure('closing the viewer left the album scope');
      }
      await _tapKey('sidebar-photos');
      await _uxWaitTotal(12, 'returning to Photos did not restore the library');
      _uxRecord('album_navigation', {
        'album_total': 7,
        'first': first.name,
        'second': visible[1].name,
      });
    });
  }

  Future<void> _uxStepRenameAndDetails() async {
    await _step('ux-grid-rename-photo', () async {
      final small = await _uxWaitSourcePhoto('small.png');
      final original = File(small.path);
      final digest = await _uxFileFingerprint(small.path);
      await _uxRightTapKey('photo-${small.id}');
      await _waitForElement(
        'tile-menu-rename',
        reason: 'tile menu has no rename',
      );
      await _tapKey('tile-menu-rename');
      await _waitForElement('rename-field', reason: 'rename dialog missing');
      await _key('ctrl+a');
      await _type('tiny.png');
      await _tapKey('rename-confirm');
      await _uxWaitGone('rename-field', 'the rename dialog did not close');
      final renamed = '$_uxSourceRoot/tiny.png';
      await _uxWaitUntil(
        () => File(renamed).existsSync() && !original.existsSync(),
        reason: 'renaming did not move the file on disk',
      );
      await _uxWaitSourcePhoto('tiny.png');
      if (await _uxFileFingerprint(renamed) != digest) {
        throw JourneyFailure('renaming changed the image bytes');
      }
      _uxRecord('renamed_file', renamed);
    });
    await _step('ux-tile-details-dialog', () async {
      final alpha = await _uxWaitSourcePhoto('alpha.png');
      await _uxRightTapKey('photo-${alpha.id}');
      await _waitForElement(
        'tile-menu-details',
        reason: 'the tile menu did not offer details',
      );
      await _tapKey('tile-menu-details');
      await _uxWaitUntil(
        () => _textElements(alpha.path).isNotEmpty,
        reason: 'the details dialog did not show the real path',
      );
      await _key('Escape');
      await _uxWaitUntil(
        () => _textElements(alpha.path).isEmpty,
        reason: 'Escape did not close the details dialog',
      );
      _uxRecord('details_path', alpha.path);
    });
  }

  Future<void> _uxStepExport() async {
    await _step('ux-batch-export-no-overwrite', () async {
      _uxSourcePicker.directoryResponse = _uxExportRoot;
      await _uxSelectAllViaMenu();
      await _tapKey('batch-export');
      await _uxWaitUntil(
        () async => (await _uxDirectoryNames(_uxExportRoot)).length == 12,
        reason: 'the first batch export did not copy twelve files',
      );
      await _tapKey('batch-export');
      await _uxWaitUntil(
        () async => (await _uxDirectoryNames(_uxExportRoot)).length == 24,
        reason: 'the second batch export overwrote instead of adding copies',
      );
      final names = await _uxDirectoryNames(_uxExportRoot);
      if (names.toSet().length != 24) {
        throw JourneyFailure('export produced duplicate destination names');
      }
      for (final name in names) {
        final file = File('$_uxExportRoot/$name');
        if (await file.length() == 0) {
          throw JourneyFailure('exported file $name is empty');
        }
      }
      _uxRecord('export_files', 24);
      await _tapKey('exit-selection');
      await _uxWaitGone(
        'selection-count',
        'the export selection did not clear',
      );
    });
  }

  Future<void> _uxStepTrashLifecycle() async {
    await _step('ux-trash-one-and-restore', () async {
      final oriented = await _uxWaitSourcePhoto('oriented.jpg');
      final source = File(oriented.path);
      await _uxRightTapKey('photo-${oriented.id}');
      await _waitForElement(
        'tile-menu-trash',
        reason: 'tile menu has no trash',
      );
      await _tapKey('tile-menu-trash');
      await _waitForElement(
        'confirm-action',
        reason: 'moving a photo to trash did not ask for confirmation',
      );
      await _tapKey('confirm-action');
      await _uxWaitUntil(
        () => !source.existsSync(),
        reason: 'the trashed source file remained on disk',
      );
      await _uxWaitTotal(11, 'trashing one photo did not update the grid');
      final trashed = await _uxTrashed();
      if (trashed.length != 1) {
        throw JourneyFailure(
          'the trash query returned ${trashed.length} items',
        );
      }
      final payload = File(trashed.single.path);
      if (!await payload.exists()) {
        throw JourneyFailure('the system trash payload is missing');
      }
      final info = File(
        '${payload.parent.parent.path}/info/${payload.uri.pathSegments.last}.trashinfo',
      );
      if (!await info.exists()) {
        throw JourneyFailure('the standard .trashinfo file is missing');
      }
      final text = await info.readAsString();
      if (!text.contains(oriented.path)) {
        throw JourneyFailure('.trashinfo does not record the original path');
      }
      _uxRecord('trash_payload', trashed.single.path);
      _uxRecord('trash_info', text.trim());
      await _screenshot('ux-06-trash');
    });
    await _step('ux-restore-from-trash', () async {
      final oriented = await _uxWaitPhotoNamed('oriented.jpg', trashed: true);
      final payload = File(oriented.path);
      await _tapKey('sidebar-trash');
      await _waitFor(
        () => !_state.loading && _state.trashed && _state.total == 1,
        reason: 'the Trash destination did not show the trashed photo',
      );
      await _uxRightTapKey('photo-${oriented.id}');
      await _waitForElement(
        'tile-menu-select',
        reason: 'trash tile menu missing',
      );
      await _tapKey('tile-menu-select');
      await _uxSelectAllIfNeeded();
      await _tapKey('batch-restore');
      await _waitFor(
        () => !_state.loading && _state.total == 0,
        reason: 'the trash still lists the restored photo',
      );
      if (!await File('$_uxSourceRoot/oriented.jpg').exists()) {
        throw JourneyFailure(
          'restore did not return the file to its original path',
        );
      }
      if (await payload.exists()) {
        throw JourneyFailure('restore left the payload in the system trash');
      }
      _uxRecord('restored_oriented', true);
      await _tapKey('sidebar-photos');
      await _uxWaitTotal(12, 'leaving Trash did not restore the grid');
    });
    await _step('ux-batch-purge', () async {
      final gamma = await _uxWaitTreePhoto('gamma.webp');
      final source = File(gamma.path);
      await _uxRightTapKey('photo-${gamma.id}');
      await _waitForElement(
        'tile-menu-trash',
        reason: 'tile menu has no trash',
      );
      await _tapKey('tile-menu-trash');
      await _waitForElement(
        'confirm-action',
        reason: 'trash confirmation missing',
      );
      await _tapKey('confirm-action');
      await _uxWaitTotal(11, 'trashing gamma did not update the grid');
      final trashed = await _uxTrashed();
      final payload = trashed.single.path;
      await _tapKey('sidebar-trash');
      await _waitFor(
        () => !_state.loading && _state.trashed && _state.total == 1,
        reason: 'Trash did not show gamma',
      );
      await _uxRightTapKey('photo-${trashed.single.id}');
      await _tapKey('tile-menu-select');
      await _uxSelectAllIfNeeded();
      await _tapKey('batch-purge');
      await _waitForElement(
        'confirm-action',
        reason: 'permanent deletion did not ask for confirmation',
      );
      await _tapKey('confirm-action');
      await _waitFor(
        () => !_state.loading && _state.total == 0,
        reason: 'permanent deletion did not empty the trash',
      );
      if (await source.exists() || await File(payload).exists()) {
        throw JourneyFailure('permanent deletion left bytes on disk');
      }
      _uxRecord('purged_gamma', true);
      await _tapKey('sidebar-photos');
      await _uxWaitTotal(11, 'leaving Trash did not update the grid');
    });
    await _step('ux-empty-trash', () async {
      final trips = _uxTripsPath;
      final albumPhotos = await _uxPhotosInFolder(trips);
      if (albumPhotos.isEmpty) {
        throw JourneyFailure('there is no album copy left to empty');
      }
      // Keep the moved photo in the album so the final check can prove the
      // move survived the whole journey, not just the copy step.
      final movedId = (facts['ux'] as Map<String, Object?>)['album_move_id'];
      final victim = albumPhotos.firstWhere(
        (photo) => photo.id != movedId,
        orElse: () => albumPhotos.first,
      );
      final source = File(victim.path);
      await _uxRightTapKey('photo-${victim.id}');
      await _waitForElement(
        'tile-menu-trash',
        reason: 'tile menu has no trash',
      );
      await _tapKey('tile-menu-trash');
      await _tapKey('confirm-action');
      await _uxWaitTotal(10, 'trashing an album copy did not update the grid');
      await _tapKey('sidebar-trash');
      await _waitFor(
        () => !_state.loading && _state.trashed && _state.total == 1,
        reason: 'Trash did not show the album copy',
      );
      await _tapKey('empty-trash');
      await _waitForElement(
        'confirm-action',
        reason: 'Empty trash did not ask for confirmation',
      );
      await _tapKey('confirm-action');
      await _waitFor(
        () => !_state.loading && _state.total == 0,
        reason: 'Empty trash did not finish',
      );
      if (await source.exists()) {
        throw JourneyFailure('Empty trash left the file on disk');
      }
      _uxRecord('empty_trash', true);
      await _tapKey('sidebar-photos');
      await _uxWaitTotal(10, 'leaving Trash did not update the grid');
    });
    await _step('ux-viewer-trash-undo', () async {
      final alpha = await _uxWaitSourcePhoto('alpha.png');
      final source = File(alpha.path);
      await _tapKey('photo-${alpha.id}');
      await _waitForElement('viewer', reason: 'the viewer did not open alpha');
      await _tapKey('viewer-trash');
      await _waitForElement(
        'viewer-confirm-trash',
        reason: 'viewer delete did not ask for confirmation',
      );
      await _tapKey('viewer-confirm-trash');
      await _uxWaitUntil(
        () => !source.existsSync(),
        reason: 'viewer delete did not move the file to trash',
      );
      await _uxWaitTotal(9, 'viewer delete did not update the library');
      await _uxWaitUntil(
        () => _textElements('Undo').isNotEmpty,
        reason: 'the trash toast did not offer Undo',
      );
      await _uxTapText('Undo');
      await _uxWaitUntil(
        () => source.existsSync(),
        reason: 'Undo did not restore the file',
      );
      await _uxWaitTotal(10, 'Undo did not restore the library row');
      await _tapKey('viewer-close');
      await _uxWaitGone('viewer', 'the viewer did not close after Undo');
      _uxRecord('viewer_undo', true);
    });
  }

  Future<void> _uxStepViewer() async {
    await _step('ux-viewer-favorite-and-zoom', () async {
      final alpha = await _uxWaitSourcePhoto('alpha.png');
      await _tapKey('photo-${alpha.id}');
      await _waitForElement('viewer', reason: 'the viewer did not open');
      if (_textOf(const ValueKey('viewer-name')) != 'alpha.png') {
        throw JourneyFailure('the viewer opened the wrong photo');
      }
      await _waitForElement(
        'viewer-strip-${alpha.id}',
        reason: 'the filmstrip did not show the current photo',
      );
      await _settle();
      _uxExpectCenteredFilmstrip(alpha);
      _uxRecord('filmstrip_offset_initial', _uxFilmstripOffset(alpha));
      await _screenshot('ux-07-viewer');
      await _tapKey('viewer-favorite');
      await _uxWaitUntil(
        () async => (await _uxWaitSourcePhoto('alpha.png')).favorite,
        reason: 'the viewer favorite button did not persist',
      );
      await _tapKey('viewer-zoom-in');
      await _waitFor(
        () => _textWithin(const ValueKey('viewer-zoom-reset')) == '125%',
        reason: 'one zoom-in click did not reach 125%',
      );
      await _tapKey('viewer-zoom-in');
      await _waitFor(
        () => _textWithin(const ValueKey('viewer-zoom-reset')) == '156%',
        reason: 'two zoom-in clicks did not reach 156%',
      );
      await _tapKey('viewer-zoom-reset');
      await _waitFor(
        () => _textWithin(const ValueKey('viewer-zoom-reset')) == '100%',
        reason: 'reset zoom did not return to 100%',
      );
      await _tapKey('viewer-zoom-in');
      await _tapKey('viewer-zoom-out');
      await _waitFor(
        () => _textWithin(const ValueKey('viewer-zoom-reset')) == '100%',
        reason: 'zoom in/out did not settle at 100%',
      );
      _uxRecord('viewer_zoom', 'visible percentages 156/100');
    });
    await _step('ux-viewer-rotate-changes-file', () async {
      final alpha = await _uxWaitSourcePhoto('alpha.png');
      final path = alpha.path;
      final before = await _uxFileFingerprint(path);
      final beforeSize = await _uxDecodeSize(path);
      await _uxTapEnabled('viewer-rotate-right');
      final rotated = await _uxWaitContentVersion(
        alpha.id,
        alpha.contentVersion,
      );
      final after = await _uxFileFingerprint(path);
      if (after == before) {
        throw JourneyFailure('Rotate right did not rewrite the source file');
      }
      final afterSize = await _uxDecodeSize(path);
      if (afterSize != (beforeSize.$2, beforeSize.$1)) {
        throw JourneyFailure(
          'Rotate right produced ${afterSize.$1}x${afterSize.$2} from '
          '${beforeSize.$1}x${beforeSize.$2}',
        );
      }
      _uxRecord('viewer_rotate', {
        'before': [beforeSize.$1, beforeSize.$2],
        'after': [afterSize.$1, afterSize.$2],
        'version': rotated.contentVersion,
      });
      await _key('shift+r');
      await _uxWaitContentVersion(rotated.id, rotated.contentVersion);
      final restored = await _uxDecodeSize(path);
      if (restored != beforeSize) {
        throw JourneyFailure('Shift+R did not restore the original axes');
      }
      await _key('r');
      final keyed = await _uxWaitContentVersion(
        rotated.id,
        rotated.contentVersion,
      );
      final keyedSize = await _uxDecodeSize(path);
      if (keyedSize != (beforeSize.$2, beforeSize.$1)) {
        throw JourneyFailure('R did not rotate the photo right');
      }
      await _uxTapEnabled('viewer-rotate-left');
      await _uxWaitContentVersion(keyed.id, keyed.contentVersion);
      if (await _uxDecodeSize(path) != beforeSize) {
        throw JourneyFailure('Rotate left did not restore the original axes');
      }
    });
    await _step('ux-viewer-details-and-rename', () async {
      final alpha = await _uxWaitSourcePhoto('alpha.png');
      await _tapKey('viewer-details');
      await _waitForElement(
        'viewer-details-panel',
        reason: 'the details panel did not open',
      );
      await _waitFor(
        () => _panelTexts().contains(alpha.path),
        reason: 'the details panel does not show the source path',
      );
      await _tapKey('viewer-details-rename');
      await _waitForElement(
        'viewer-rename-field',
        reason: 'the viewer rename dialog did not open',
      );
      await _key('ctrl+a');
      await _type('alpha2.png');
      await _tapKey('viewer-rename-confirm');
      await _uxWaitGone(
        'viewer-rename-field',
        'the viewer rename dialog did not close',
      );
      await _uxWaitUntil(
        () => File('$_uxSourceRoot/alpha2.png').existsSync(),
        reason: 'the viewer rename did not move the file',
      );
      await _waitFor(
        () => _textOf(const ValueKey('viewer-name')) == 'alpha2.png',
        reason: 'the viewer did not refresh the renamed title',
      );
      await _tapKey('viewer-details-close');
      await _uxWaitGone(
        'viewer-details-panel',
        'the details panel did not close',
      );
      _uxRecord('viewer_renamed', '$_uxSourceRoot/alpha2.png');
    });
    await _step('ux-viewer-filmstrip-and-arrows', () async {
      final beta = await _uxWaitSourcePhoto('beta.jpg');
      final alpha = await _uxWaitSourcePhoto('alpha2.png');
      await _tapKey('viewer-strip-${beta.id}');
      await _waitFor(
        () => _textOf(const ValueKey('viewer-name')) == 'beta.jpg',
        reason: 'clicking the filmstrip did not change the photo',
      );
      await _waitForElement(
        'viewer-strip-${beta.id}',
        reason: 'the filmstrip lost the selected thumbnail',
      );
      await _settle();
      _uxExpectCenteredFilmstrip(beta);
      final offsets = <String, double>{'beta': _uxFilmstripOffset(beta)};
      final flat = <LocalPhoto>[
        for (final page in _state.pages.values) ...page,
      ];
      final index = flat.indexWhere((photo) => photo.id == beta.id);
      if (index <= 0) {
        throw JourneyFailure('beta has no previous neighbour to test');
      }
      final previous = flat[index - 1];
      await _tapKey('viewer-previous');
      await _waitFor(
        () =>
            _textOf(const ValueKey('viewer-position')) ==
            '$index / ${_state.total}',
        reason: 'the previous button did not move by exactly one position',
      );
      await _waitForElement(
        'viewer-strip-${previous.id}',
        reason: 'the filmstrip did not follow the previous button',
      );
      await _settle();
      _uxExpectCenteredFilmstrip(previous);
      offsets['previous'] = _uxFilmstripOffset(previous);
      await _tapKey('viewer-next');
      await _waitFor(
        () => _textOf(const ValueKey('viewer-name')) == 'beta.jpg',
        reason: 'the next button did not return to beta',
      );
      await _settle();
      _uxExpectCenteredFilmstrip(beta);
      offsets['returned'] = _uxFilmstripOffset(beta);
      _uxRecord('filmstrip_offsets', offsets);
      _uxRecord('filmstrip', {
        'alpha': alpha.id,
        'beta': beta.id,
        'previous': previous.name,
      });
    });
    await _step('ux-viewer-immersive', () async {
      await _key('f');
      await _waitFor(
        () => _elementByKey(const ValueKey('viewer-immersive-exit')) != null,
        reason: 'F did not enable immersive mode',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2800));
      await _settle();
      if (_elementByKey(const ValueKey('viewer-header')) != null) {
        throw JourneyFailure('the chrome did not hide after the idle timeout');
      }
      await _uxMoveTo(_viewSize.center(Offset.zero));
      await _waitForElement(
        'viewer-header',
        reason: 'moving the pointer did not reveal the chrome',
      );
      await _key('Escape');
      await _waitFor(
        () => _elementByKey(const ValueKey('viewer-immersive-exit')) == null,
        reason: 'Escape did not leave immersive mode',
      );
      _uxRecord('immersive', true);
    });
    await _step('ux-viewer-fullscreen-preview', () async {
      await _key('shift+f');
      await _waitForElement(
        'viewer-fullscreen',
        reason: 'Shift+F did not open the fullscreen preview',
      );
      await _tapKey('viewer-fullscreen-close');
      await _uxWaitGone(
        'viewer-fullscreen',
        'the fullscreen preview did not close',
      );
      _uxRecord('fullscreen_preview', true);
    });
  }

  Future<void> _uxStepEditor() async {
    await _step('ux-editor-reset-and-close', () async {
      final beta = await _uxWaitSourcePhoto('beta.jpg');
      final before = await _uxFileFingerprint(beta.path);
      await _uxTapEnabled('viewer-edit');
      await _waitForElement('editor', reason: 'the editor did not open');
      await _tapKey('editor-rotate-right');
      await _tapKey('editor-flip-horizontal');
      await _uxScrollToKey('editor-crop-ratio', container: 'editor-controls');
      await _uxTapDropdown('editor-crop-ratio');
      await _uxTapMenuText('1:1');
      final stage = await _waitForElement(
        'editor-crop-stage',
        reason: 'the crop stage did not appear',
      );
      await _uxDragWithin(stage, 'editor-crop-stage', .2, .2, .8, .8);
      await _tapKey('editor-compare');
      await _tapKey('editor-reset');
      await _waitFor(
        () => _textElements('No changes yet').isNotEmpty,
        reason: 'Reset did not clear every adjustment',
      );
      await _tapKey('editor-close');
      await _uxWaitGone('editor', 'closing a reset editor did not work');
      if (await _uxFileFingerprint(beta.path) != before) {
        throw JourneyFailure('a reset editor changed the file');
      }
      _uxRecord('editor_reset', true);
    });
    await _step('ux-editor-discard-protection', () async {
      final beta = await _uxWaitSourcePhoto('beta.jpg');
      final before = await _uxFileFingerprint(beta.path);
      await _uxTapEnabled('viewer-edit');
      await _waitForElement('editor', reason: 'the editor did not reopen');
      await _tapKey('editor-rotate-right');
      await _tapKey('editor-close');
      await _waitForElement(
        'editor-discard',
        reason: 'closing dirty edits did not ask before discarding',
      );
      await _tapKey('editor-discard');
      await _uxWaitGone('editor', 'discarding did not close the editor');
      if (await _uxFileFingerprint(beta.path) != before) {
        throw JourneyFailure('discarding unsaved edits changed the file');
      }
      _uxRecord('editor_discard', true);
    });
    await _step('ux-editor-save-copy', () async {
      final beta = await _uxWaitSourcePhoto('beta.jpg');
      final before = await _uxFileFingerprint(beta.path);
      await _uxTapEnabled('viewer-edit');
      await _waitForElement(
        'editor',
        reason: 'the editor did not open for a copy',
      );
      await _tapKey('editor-rotate-right');
      await _tapKey('editor-flip-horizontal');
      await _uxScrollToKey('editor-crop-ratio', container: 'editor-controls');
      await _uxTapDropdown('editor-crop-ratio');
      await _uxTapMenuText('1:1');
      final stage = await _waitForElement(
        'editor-crop-stage',
        reason: 'the crop stage did not appear for the copy',
      );
      await _uxDragWithin(stage, 'editor-crop-stage', .2, .2, .8, .8);
      await _tapKey('editor-save-copy');
      await _uxWaitGone('editor', 'saving a copy did not close the editor');
      final sourceNames = await _uxDirectoryNames(_uxSourceRoot);
      final edited = sourceNames
          .where((name) => name.startsWith('beta_edited_'))
          .toList();
      if (edited.length != 1) {
        throw JourneyFailure(
          'save copy produced ${edited.length} edited files',
        );
      }
      final editedPath = '$_uxSourceRoot/${edited.single}';
      if (!await File(editedPath).exists()) {
        throw JourneyFailure('the edited copy is missing on disk');
      }
      if (await _uxFileFingerprint(beta.path) != before) {
        throw JourneyFailure('save copy changed the original beta.jpg');
      }
      final size = await _uxDecodeSize(editedPath);
      if (size.$1 != size.$2) {
        throw JourneyFailure('the 1:1 crop produced ${size.$1}x${size.$2}');
      }
      await _uxWaitSourcePhoto(edited.single);
      _uxRecord('edited_copy', {
        'path': editedPath,
        'width': size.$1,
        'height': size.$2,
        'original_unchanged': true,
      });
      await _screenshot('ux-07-editor-copy');
    });
    await _step('ux-editor-overwrite-and-backup', () async {
      final editedNames = (await _uxDirectoryNames(_uxSourceRoot))
          .where((name) => name.startsWith('beta_edited_'))
          .toList();
      final edited = await _uxWaitSourcePhoto(editedNames.single);
      final before = await _uxFileFingerprint(edited.path);
      final beforeSize = await _uxDecodeSize(edited.path);
      await _uxTapEnabled('viewer-edit');
      await _waitForElement(
        'editor',
        reason: 'the editor did not open the copy',
      );
      await _uxScrollToKey('editor-brightness', container: 'editor-controls');
      await _uxTapFraction('editor-brightness', .75, .5);
      await _waitFor(() {
        final widget = _elementByKey(const ValueKey('editor-brightness'))
            ?.widget;
        return widget is Slider && widget.value > 0;
      }, reason: 'the brightness slider did not move');
      await _uxScrollToKey('editor-saturation', container: 'editor-controls');
      await _uxTapFraction('editor-saturation', .65, .5);
      await _tapKey('editor-compare');
      await _tapKey('editor-compare');
      await _tapKey('editor-save');
      await _waitForElement(
        'editor-confirm-overwrite',
        reason: 'overwrite did not ask for confirmation',
      );
      await _tapKey('editor-confirm-overwrite');
      await _uxWaitUntil(
        () async => await _uxFileFingerprint(edited.path) != before,
        reason: 'overwrite did not rewrite the edited file',
        timeout: const Duration(seconds: 60),
      );
      await _uxWaitUntil(
        () => _textElements('Changes applied').isNotEmpty,
        reason: 'overwrite never reported success',
      );
      final afterSize = await _uxDecodeSize(edited.path);
      if (afterSize != beforeSize) {
        throw JourneyFailure('colour adjustments changed the image dimensions');
      }
      final backupDir = Directory('$_uxDataRoot/backups/${edited.id}');
      final backups = backupDir.existsSync()
          ? backupDir
                .listSync()
                .whereType<File>()
                .where((file) => file.path.endsWith('.bak'))
                .toList()
          : <File>[];
      if (backups.isEmpty) {
        throw JourneyFailure('overwrite did not keep a backup of the source');
      }
      _uxRecord('overwrite_backup', backups.first.path);
      await _tapKey('editor-close');
      await _uxWaitGone('editor', 'the editor did not close after overwrite');
    });
    await _step('ux-close-viewer', () async {
      await _tapKey('viewer-close');
      await _uxWaitGone('viewer', 'the viewer did not close');
      await _waitForElement(
        'local-photo-grid',
        reason: 'the grid did not return',
      );
    });
    await _step('ux-keyboard-grid-and-viewer', () async {
      await _waitForElement(
        'local-photo-grid',
        reason: 'the grid is missing before the keyboard journey',
      );
      final tiles = _photoTileElements();
      if (tiles.length < 2) {
        throw JourneyFailure('the grid has fewer than two tiles for traversal');
      }
      final firstKey = (tiles.first.widget.key! as ValueKey<String>).value;
      await _uxRightTapKey(firstKey);
      await _waitForElement(
        'tile-menu-select',
        reason: 'the keyboard focus anchor menu did not open',
      );
      await _key('Escape');
      await _uxWaitGone(
        'tile-menu-select',
        'Escape did not close the focus anchor menu',
      );
      await _waitFor(
        () => _uxFocusedPhotoKey() == firstKey,
        reason: 'closing the tile menu did not restore focus to its tile',
      );
      await _key('Right');
      String? nextKey;
      await _waitFor(() {
        final focused = _uxFocusedPhotoKey();
        if (focused != null && focused != firstKey) {
          nextKey = focused;
          return true;
        }
        return false;
      }, reason: 'ArrowRight did not move focus to another tile');
      final nextId = nextKey!.substring('photo-'.length);
      final target = await _uxPhotoById(nextId);
      if (target == null) {
        throw JourneyFailure('the focused tile $nextId has no library row');
      }
      final targetIndex = _state.indexOf(target.id);
      if (targetIndex == null) {
        throw JourneyFailure('the focused tile is not in the current query');
      }
      await _key('Return');
      await _waitForElement(
        'viewer',
        reason: 'Enter did not open the focused tile in the viewer',
      );
      await _waitFor(
        () =>
            _textOf(const ValueKey('viewer-name')) == target.name &&
            _textOf(const ValueKey('viewer-position')) ==
                '${targetIndex + 1} / ${_state.total}',
        reason: 'Enter opened a different photo than the focused tile',
      );
      final beforeFavorite = target.favorite;
      await _key('h');
      await _uxWaitUntil(
        () async =>
            (await _uxPhotoById(target.id))?.favorite == !beforeFavorite,
        reason: 'H did not toggle the viewer favorite',
      );
      await _key('h');
      await _uxWaitUntil(
        () async => (await _uxPhotoById(target.id))?.favorite == beforeFavorite,
        reason: 'a second H did not restore the viewer favorite',
      );
      await _key('i');
      await _waitForElement(
        'viewer-details-panel',
        reason: 'I did not open the details panel',
      );
      await _key('Escape');
      await _uxWaitGone(
        'viewer-details-panel',
        'Escape did not close the details panel first',
      );
      await _key('Escape');
      await _uxWaitGone('viewer', 'Escape did not close the viewer');
      _uxRecord('keyboard', {
        'anchor': firstKey,
        'moved_to': nextKey,
        'opened': target.name,
        'favorite_key': true,
        'details_key': true,
      });
    });
  }

  Future<void> _uxStepMediaKinds() async {
    final mediaRoot = _uxMediaRoot;
    final baseTotal = _state.total;
    await _step('ux-media-kinds-scan', () async {
      await _tapKey('sidebar-settings');
      await _waitForElement(
        'settings-close',
        reason: 'settings did not open for the media source',
      );
      await _tapKey('settings-category-2');
      await _uxScrollTop('settings-content');
      _uxSourcePicker.directoryResponse = mediaRoot;
      await _uxScrollToKey('add-folder', container: 'settings-content');
      final previous = _state.scanResult;
      await _tapKey('add-folder');
      final result = await _uxWaitForScan(previous, 'add media source');
      if (result.discovered != 4) {
        throw JourneyFailure(
          'the media source discovered ${result.discovered} files, expected 4',
        );
      }
      await _uxWaitTotal(
        baseTotal + 4,
        'the media source did not add four rows',
      );
      await _tapKey('settings-close');
      await _uxWaitGone(
        'settings-close',
        'settings did not close after adding media',
      );
      _uxRecord('media_scan', {
        'base_total': baseTotal,
        'discovered': result.discovered,
      });
    });
    await _step('ux-media-kind-filters', () async {
      await _tapKey('sidebar-media-images');
      await _waitFor(
        () => _state.mediaKind == 'image' && !_state.loading,
        reason: 'the Images filter did not apply',
      );
      await _uxWaitTotal(
        baseTotal + 3,
        'Images did not include motion/HEIC/GIF',
      );
      final images = _state.total;
      await _tapKey('sidebar-media-videos');
      await _waitFor(
        () => _state.mediaKind == 'video' && !_state.loading,
        reason: 'the Videos filter did not apply',
      );
      await _uxWaitTotal(1, 'Videos did not isolate the mp4 fixture');
      _uxRecord('media_filter', {'images': images, 'videos': _state.total});
    });
    await _step('ux-media-kind-video-playback', () async {
      final clip = await _uxWaitMediaPhoto('clip.mp4');
      if (clip.mediaKind != 'video') {
        throw JourneyFailure('clip.mp4 was indexed as ${clip.mediaKind}');
      }
      if (clip.durationMs == null || clip.durationMs! < 1000) {
        throw JourneyFailure(
          'the video row has no usable duration: ${clip.durationMs}',
        );
      }
      final durationLabel =
          '${(clip.durationMs! ~/ 60000).toString().padLeft(2, '0')}:'
          '${((clip.durationMs! ~/ 1000) % 60).toString().padLeft(2, '0')}';
      await _waitFor(
        () => _textElements(durationLabel).isNotEmpty,
        reason: 'the video tile did not show its $durationLabel duration',
      );
      await _tapKey('photo-${clip.id}');
      await _waitForElement('viewer', reason: 'the video did not open');
      await _waitForElement(
        'viewer-video',
        reason: 'the viewer did not mount the video stage',
      );
      await _uxWaitVideoPlaying(
        'viewer-video',
        true,
        'the video never started playing',
      );
      await _uxWaitUntil(() {
        final state = _uxVideoState('viewer-video');
        return state != null &&
            state.error == null &&
            state.position > Duration.zero;
      }, reason: 'video playback never advanced past the first frame');
      final position = _uxVideoState('viewer-video')!.position;
      await _key('space');
      await _uxWaitVideoPlaying(
        'viewer-video',
        false,
        'Space did not pause the video',
      );
      await _key('space');
      await _uxWaitVideoPlaying(
        'viewer-video',
        true,
        'a second Space did not resume the video',
      );
      await _tapKey('viewer-close');
      await _uxWaitGone('viewer', 'the video viewer did not close');
      _uxRecord('video_playback', {
        'duration_ms': clip.durationMs,
        'duration_label': durationLabel,
        'position_ms': position.inMilliseconds,
        'playing': true,
        'paused': true,
        'resumed': true,
      });
    });
    await _step('ux-media-kind-motion', () async {
      await _tapKey('sidebar-media-images');
      await _waitFor(
        () => _state.mediaKind == 'image' && !_state.loading,
        reason: 'the Images filter did not return',
      );
      final motion = await _uxWaitMediaPhoto('motion.jpg');
      await _tapKey('photo-${motion.id}');
      await _waitForElement('viewer', reason: 'the motion photo did not open');
      await _waitForElement(
        'viewer-motion-toggle',
        reason: 'the viewer did not detect the motion photo',
      );
      await _tapKey('viewer-motion-toggle');
      await _waitForElement(
        'viewer-motion-video',
        reason: 'Play motion photo did not mount the video stage',
      );
      final extracted = File(
        '$_uxDataRoot/cache/${motion.id}/${motion.contentVersion}/motion.mp4',
      );
      await _uxWaitUntil(
        () => extracted.existsSync() && extracted.lengthSync() > 0,
        reason: 'the motion video was not extracted into the cache',
      );
      await _uxWaitVideoPlaying(
        'viewer-motion-video',
        true,
        'the extracted motion video never played',
      );
      await _tapKey('viewer-motion-toggle');
      await _uxWaitGone(
        'viewer-motion-video',
        'Show photo did not return to the still image',
      );
      await _waitForElement(
        'viewer-image-${motion.id}-${motion.contentVersion}',
        reason: 'the still image did not return after the motion clip',
      );
      await _tapKey('viewer-close');
      await _uxWaitGone('viewer', 'the motion viewer did not close');
      _uxRecord('motion_photo', {
        'extracted': extracted.path,
        'bytes': extracted.lengthSync(),
        'played': true,
      });
    });
    await _step('ux-motion-auto-play-preference', () async {
      await _tapKey('sidebar-settings');
      await _waitForElement(
        'settings-close',
        reason: 'the settings did not open for the motion preference',
      );
      await _tapKey('settings-category-2');
      await _uxScrollToKey(
        'settings-auto-play-motion',
        container: 'settings-content',
      );
      await _tapKey('settings-auto-play-motion');
      await _waitFor(
        () => _uxPreferences.autoPlayMotionPhoto,
        reason: 'the motion auto-play switch did not turn on',
      );
      await _tapKey('settings-close');
      await _uxWaitGone('settings-close', 'the settings did not close');
      final motion = await _uxWaitMediaPhoto('motion.jpg');
      await _tapKey('photo-${motion.id}');
      await _waitForElement('viewer', reason: 'the motion photo did not reopen');
      await _waitForElement(
        'viewer-motion-video',
        reason: 'the motion clip did not start on its own',
      );
      await _uxWaitVideoPlaying(
        'viewer-motion-video',
        true,
        'the auto-played motion clip never played',
      );
      await _tapKey('viewer-motion-toggle');
      await _uxWaitGone(
        'viewer-motion-video',
        'Show photo did not stop the auto-played motion clip',
      );
      await _tapKey('viewer-close');
      await _uxWaitGone('viewer', 'the motion viewer did not close');
      await _tapKey('sidebar-settings');
      await _waitForElement(
        'settings-close',
        reason: 'the settings did not reopen to restore the motion preference',
      );
      await _tapKey('settings-category-2');
      await _uxScrollToKey(
        'settings-auto-play-motion',
        container: 'settings-content',
      );
      await _tapKey('settings-auto-play-motion');
      await _waitFor(
        () => !_uxPreferences.autoPlayMotionPhoto,
        reason: 'the motion auto-play switch did not turn off',
      );
      await _tapKey('settings-close');
      await _uxWaitGone('settings-close', 'the settings did not close');
      _uxRecord('motion_auto_play', true);
    });
    await _step('ux-media-kind-heic-and-gif', () async {
      final heic = await _uxWaitMediaPhoto('still.heic');
      await _tapKey('photo-${heic.id}');
      await _waitForElement('viewer', reason: 'the HEIC did not open');
      await _waitForElement(
        'viewer-heic',
        reason: 'the HEIC preview never rendered',
        timeout: const Duration(seconds: 90),
      );
      final preview = File(
        '$_uxDataRoot/cache/${heic.id}/${heic.contentVersion}/preview.jpg',
      );
      await _uxWaitUntil(
        () => preview.existsSync() && preview.lengthSync() > 0,
        reason: 'the HEIC preview was not written to the cache',
      );
      final previewSize = await _uxDecodeSize(preview.path);
      if (previewSize.$1 <= 0 || previewSize.$2 <= 0) {
        throw JourneyFailure('the HEIC preview decoded to an empty image');
      }
      await _tapKey('viewer-close');
      await _uxWaitGone('viewer', 'the HEIC viewer did not close');
      final gif = await _uxWaitMediaPhoto('loop.gif');
      await _tapKey('photo-${gif.id}');
      await _waitForElement('viewer', reason: 'the animated GIF did not open');
      await _waitForElement(
        'viewer-image-${gif.id}-${gif.contentVersion}',
        reason: 'the animated GIF never rendered in the viewer',
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_textElements('Image unavailable').isNotEmpty) {
        throw JourneyFailure('the animated GIF failed to decode in the viewer');
      }
      final details =
          await _container!.read(localLibraryProvider.notifier).localCommand({
            'op': 'metadata',
            'id': gif.id,
          }) as Map?;
      if (details?['animated'] != true) {
        throw JourneyFailure('the GIF was not flagged as animated');
      }
      final frames = Directory(
        '$_uxDataRoot/cache/${gif.id}/${gif.contentVersion}',
      ).listSync(recursive: true).whereType<File>();
      final decoded = frames
          .where((file) => file.path.contains('/frames/frame-'))
          .toList();
      if (decoded.isEmpty) {
        throw JourneyFailure('the animated GIF was not decoded into frames');
      }
      _uxRecord('gif_frames', decoded.length);
      await _tapKey('viewer-close');
      await _uxWaitGone('viewer', 'the GIF viewer did not close');
      _uxRecord('heic_preview', {
        'path': preview.path,
        'width': previewSize.$1,
        'height': previewSize.$2,
      });
      _uxRecord('gif_animated', true);
    });
    await _step('ux-media-kind-remove-source', () async {
      await _tapKey('sidebar-settings');
      await _waitForElement(
        'settings-close',
        reason: 'settings did not reopen to remove the media source',
      );
      await _tapKey('settings-category-2');
      await _uxScrollTop('settings-content');
      await _uxScrollToKey(
        'settings-remove-source-$mediaRoot',
        container: 'settings-content',
      );
      await _tapKey('settings-remove-source-$mediaRoot');
      await _waitForElement(
        'remove-source-confirm',
        reason: 'removing the media source did not ask for confirmation',
      );
      await _tapKey('remove-source-confirm');
      await _uxWaitTotal(
        baseTotal,
        'removing the media source did not restore the library',
      );
      final names = <String>[];
      for (final name in ['clip.mp4', 'loop.gif', 'motion.jpg', 'still.heic']) {
        final file = File('$mediaRoot/$name');
        if (!await file.exists() || await file.length() == 0) {
          throw JourneyFailure('removing the media source deleted $name');
        }
        names.add(name);
      }
      await _tapKey('settings-close');
      await _uxWaitGone(
        'settings-close',
        'settings did not close after removing the media source',
      );
      _uxRecord('media_source_removed', true);
      _uxRecord('media_files', names);
    });
  }

  Future<void> _uxStepSettingsCleanup() async {
    await _step('ux-remove-source-re-add', () async {
      await _tapKey('sidebar-settings');
      await _waitForElement(
        'settings-close',
        reason: 'settings did not reopen',
      );
      await _tapKey('settings-category-2');
      await _uxScrollTop('settings-content');
      await _uxScrollToKey(
        'settings-remove-source-$_uxSourceRoot',
        container: 'settings-content',
      );
      await _tapKey('settings-remove-source-$_uxSourceRoot');
      await _waitForElement(
        'remove-source-confirm',
        reason: 'remove confirmation missing',
      );
      await _tapKey('remove-source-confirm');
      final albumTotal = (await _uxPhotosInFolder(_uxTripsPath)).length;
      await _uxWaitTotal(
        albumTotal,
        'removing the source did not keep only the album rows',
      );
      for (final name in ['beta.jpg', 'tiny.png', 'oriented.jpg']) {
        if (!await File('$_uxSourceRoot/$name').exists()) {
          throw JourneyFailure('removing the source deleted $name');
        }
      }
      _uxSourcePicker.directoryResponse = _uxSourceRoot;
      await _uxScrollToKey('add-folder', container: 'settings-content');
      final previous = _state.scanResult;
      await _tapKey('add-folder');
      final result = await _uxWaitForScan(previous, 're-add source');
      await _uxWaitTotal(
        albumTotal + result.discovered,
        're-adding the source did not restore its rows',
      );
      _uxRecord('source_removed_readded', {
        'album_rows': albumTotal,
        'readded_discovered': result.discovered,
      });
      await _tapKey('settings-close');
      await _uxWaitGone(
        'settings-close',
        'settings did not close after re-adding',
      );
    });
    await _step('ux-remove-album-keeps-files', () async {
      final trips = _uxTripsPath;
      final files = await _uxDirectoryNames(trips);
      if (files.isEmpty) {
        throw JourneyFailure('the album has no files before removal');
      }
      await _uxRightTapKey('sidebar-album-$trips', menuPrefix: 'album-menu-');
      await _waitForElement('album-menu-remove', reason: 'album menu missing');
      await _tapKey('album-menu-remove');
      await _waitForElement(
        'album-remove-confirm',
        reason: 'remove confirmation missing',
      );
      await _tapKey('album-remove-confirm');
      await _uxWaitUntil(
        () => Directory(trips).existsSync(),
        reason: 'removing the album deleted the folder itself',
      );
      final remaining = await _uxDirectoryNames(trips);
      if (remaining.length != files.length) {
        throw JourneyFailure('removing the album deleted its files');
      }
      await _uxWaitUntil(() async {
        final albums = await _library!.listAlbums();
        return albums.every((album) => album.path != trips);
      }, reason: 'the removed album stayed in the library');
      _uxRecord('album_removed_files', remaining.length);
    });
    await _step('ux-remove-source-keeps-originals', () async {
      await _tapKey('sidebar-settings');
      await _waitForElement(
        'settings-close',
        reason: 'settings did not reopen',
      );
      await _tapKey('settings-category-2');
      await _uxScrollTop('settings-content');
      await _uxScrollToKey(
        'settings-remove-source-$_uxSourceRoot',
        container: 'settings-content',
      );
      await _tapKey('settings-remove-source-$_uxSourceRoot');
      await _waitForElement(
        'remove-source-confirm',
        reason: 'remove confirmation missing',
      );
      await _tapKey('remove-source-confirm');
      await _uxWaitTotal(
        0,
        'removing the last source did not empty the library',
      );
      final names = await _uxDirectoryNames(_uxSourceRoot);
      if (!names.contains('beta.jpg') || !names.contains('tiny.png')) {
        throw JourneyFailure('removing the source deleted original files');
      }
      _uxRecord('source_remove_kept', names);
    });
    await _step('ux-clear-cache-and-logs', () async {
      final usage = await _uxCacheUsage();
      if (usage <= 0) {
        throw JourneyFailure('the thumbnail cache was empty before clearing');
      }
      await _tapKey('settings-category-3');
      await _uxScrollTop('settings-content');
      await _uxScrollToKey(
        'settings-clear-cache',
        container: 'settings-content',
      );
      await _tapKey('settings-clear-cache');
      await _uxWaitUntil(
        () async => await _uxCacheUsage() == 0,
        reason: 'Clear cache left thumbnail bytes on disk',
      );
      final log = File('$_uxDataRoot/logs/local.log');
      final before = await log.exists() ? await log.readAsLines() : <String>[];
      final marker = before.isEmpty ? '' : before.last;
      await _uxScrollToKey('settings-log-level', container: 'settings-content');
      await _uxTapDropdown('settings-log-level');
      await _uxTapMenuText('debug');
      await _waitFor(
        () => _uxPreferences.logLevel == 'debug',
        reason: 'the log level dropdown did not apply debug',
      );
      await _uxScrollToKey(
        'settings-clear-logs',
        container: 'settings-content',
      );
      await _tapKey('settings-clear-logs');
      await _uxWaitUntil(
        () async =>
            !await log.exists() || (await log.readAsLines()).length <= 1,
        reason: 'Clear logs kept the previous log history',
      );
      final afterClear = await log.exists()
          ? await log.readAsLines()
          : <String>[];
      await _uxScrollToKey(
        'settings-thumbnail-workers',
        container: 'settings-content',
      );
      await _uxTapDropdown('settings-thumbnail-workers');
      await _uxTapMenuText('Fastest');
      await _waitFor(
        () => _uxPreferences.thumbnailWorkers == 4,
        reason: 'the thumbnail worker dropdown did not apply Fastest',
      );
      _uxRecord('cache_before', usage);
      _uxRecord('cache_after', 0);
      _uxRecord('logs_before_lines', before.length);
      _uxRecord('logs_before_marker', marker);
      _uxRecord('logs_after_clear', afterClear.length);
      _uxRecord('preferences_after_cleanup', {
        'theme': _uxPreferences.themeMode.name,
        'material': 'liquid_glass',
        'backgroundBlur': _uxPreferences.backgroundBlur,
        'followScroll': _uxPreferences.followScroll,
        'locale': _uxPreferences.locale?.languageCode ?? 'system',
        'reduceMotion': _uxPreferences.reduceMotion,
        'dayColumns': _uxPreferences.dayColumns,
        'thumbnailWorkers': _uxPreferences.thumbnailWorkers,
        'logLevel': _uxPreferences.logLevel,
        'order': _uxPreferences.order,
      });
      await _tapKey('settings-close');
      await _uxWaitGone('settings-close', 'settings did not close at the end');
      await _waitForElement(
        'open-settings',
        reason: 'the empty library did not return after removing every source',
      );
      await _screenshot('ux-08-empty-after-cleanup');
    });
  }

  Future<void> _uxStepFinalFacts() async {
    await _step('ux-final-facts', () async {
      _uxRecord('source_root', _uxSourceRoot);
      _uxRecord('album_root', _uxAlbumRoot);
      _uxRecord('trips_path', _uxTripsPath);
      _uxRecord('export_root', _uxExportRoot);
      _uxRecord('data_root', _uxDataRoot);
      _uxRecord('final_total', _state.total);
      _uxRecord('source_files', await _uxDirectoryNames(_uxSourceRoot));
      _uxRecord('album_files', await _uxDirectoryNames(_uxTripsPath));
      _uxRecord('export_names', await _uxDirectoryNames(_uxExportRoot));
      final trips = Directory(_uxTripsPath);
      if (!trips.existsSync()) {
        throw JourneyFailure('the removed album folder disappeared from disk');
      }
      final backupFiles = <String>[];
      final backups = Directory('$_uxDataRoot/backups');
      if (backups.existsSync()) {
        for (final entity in backups.listSync(recursive: true)) {
          if (entity is File && entity.path.endsWith('.bak')) {
            backupFiles.add(entity.path);
          }
        }
      }
      _uxRecord('backup_files', backupFiles);
      if (backupFiles.isEmpty) {
        throw JourneyFailure('no overwrite backup survived the journey');
      }
    });
  }

  // -------------------------------------------------------------- ui helpers

  Future<void> _uxSelectAllViaMenu() async {
    Element? first;
    await _uxWaitUntil(
      () {
        final tiles = _photoTileElements();
        if (tiles.isEmpty) return false;
        first = tiles.first;
        return true;
      },
      reason: 'there is no tile to select',
      timeout: const Duration(seconds: 20),
    );
    final key = (first!.widget.key! as ValueKey<String>).value;
    await _uxRightTapKey(key);
    await _waitForElement(
      'tile-menu-select',
      reason: 'the tile menu did not appear',
    );
    await _tapKey('tile-menu-select');
    await _waitForElement(
      'selection-count',
      reason: 'selection mode did not start',
    );
    await _uxSelectAllIfNeeded();
  }

  Future<void> _uxSelectAllIfNeeded() async {
    if (_state.total > 1) await _tapKey('select-all');
    await _waitFor(
      () =>
          _elementByKey(const ValueKey('selection-count')) != null &&
          (_textOf(const ValueKey('selection-count')) ?? '').contains(
            '${_state.total}',
          ),
      reason: 'Select all did not select the whole current query',
    );
  }

  Future<void> _uxTapEnabled(String key) async {
    await _waitFor(() {
      final widget = _elementByKey(ValueKey(key))?.widget;
      if (widget is IconButton) return widget.onPressed != null;
      if (widget is FilledButton) return widget.onPressed != null;
      if (widget is OutlinedButton) return widget.onPressed != null;
      if (widget is TextButton) return widget.onPressed != null;
      return false;
    }, reason: 'widget $key never became enabled');
    await _tapKey(key);
  }

  Future<void> _uxRightTapKey(
    String keyValue, {
    String menuPrefix = 'tile-menu-',
  }) async {
    for (var attempt = 1; attempt <= 2; attempt += 1) {
      final element = await _waitForElement(
        keyValue,
        reason: 'widget $keyValue is not mounted for a right click',
      );
      await _waitForStableRect(element, keyValue);
      final position = _centerOf(element, keyValue);
      _trace('right-tap', 'SEND', '$keyValue at ${position.dx},${position.dy}');
      await _input!.secondaryTap(position, _devicePixelRatio);
      _trace('right-tap', 'ACK', keyValue);
      await _settle();
      try {
        await _waitFor(
          () => _elementsWithKeyPrefix(menuPrefix).isNotEmpty,
          reason: 'the context menu for $keyValue did not open',
          timeout: const Duration(seconds: 4),
        );
        return;
      } on JourneyFailure {
        if (attempt == 2) rethrow;
        // A list refresh can replace the tile between the hit test and the
        // X11 click; a second real right-click is what the user would do.
        _trace('right-tap', 'RETRY', keyValue);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  Future<void> _uxMoveTo(Offset position) async {
    _trace('move', 'SEND', '${position.dx},${position.dy}');
    await _input!.moveTo(position, _devicePixelRatio);
    await _settle();
  }

  Future<void> _uxDragKeys(
    String fromKey,
    String toKey, {
    Duration hold = Duration.zero,
  }) async {
    final from = await _waitForElement(
      fromKey,
      reason: 'drag source $fromKey is not mounted',
    );
    final to = await _waitForElement(
      toKey,
      reason: 'drag target $toKey is not mounted',
    );
    await _input!.drag(
      _centerOf(from, fromKey),
      _centerOf(to, toKey),
      _devicePixelRatio,
      hold: hold,
    );
    await _settle();
  }

  Future<void> _uxDragWithin(
    Element stage,
    String label,
    double x1,
    double y1,
    double x2,
    double y2,
  ) async {
    final rect = _uxRectOf(stage);
    if (rect == null) throw JourneyFailure('$label has no render box');
    Offset point(double x, double y) =>
        Offset(rect.left + rect.width * x, rect.top + rect.height * y);
    await _input!.drag(point(x1, y1), point(x2, y2), _devicePixelRatio);
    await _settle();
  }

  Future<void> _uxTapFraction(String key, double x, double y) async {
    final element = await _waitForElement(
      key,
      reason: 'widget $key is not mounted',
    );
    final rect = _uxRectOf(element);
    if (rect == null) throw JourneyFailure('$key has no render box');
    await _input!.tap(
      Offset(rect.left + rect.width * x, rect.top + rect.height * y),
      _devicePixelRatio,
    );
    await _settle();
  }

  Future<void> _uxTapDropdown(String key) async {
    final root = await _waitForElement(
      key,
      reason: 'dropdown $key is not mounted',
    );
    Element? button;
    void visit(Element element) {
      if (button != null) return;
      if (element.widget.runtimeType.toString().startsWith('DropdownButton<')) {
        button = element;
        return;
      }
      element.visitChildren(visit);
    }

    visit(root);
    final target = button ?? root;
    final rect = _uxRectOf(target);
    if (rect == null) throw JourneyFailure('$key has no render box');
    await _input!.tap(rect.center, _devicePixelRatio);
    await _settle();
  }

  bool _hasScrollableAncestor(Element element) {
    var found = false;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget is Scrollable) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  bool _uxTextIsOnTop(Element element, Offset position) {
    final render = element.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return false;
    }
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      position,
      View.of(element).viewId,
    );
    return result.path.any((entry) => identical(entry.target, render));
  }

  /// Taps a dropdown menu entry. The closed field keeps every label in an
  /// offstage IndexedStack, so only the hit-testable copy inside the menu is
  /// safe to tap.
  Future<void> _uxTapMenuText(String text) async {
    Offset? position;
    await _waitFor(() {
      for (final match in _textElements(text).reversed) {
        if (!_hasScrollableAncestor(match)) continue;
        final center = _centerOf(match, text);
        if (_uxTextIsOnTop(match, center)) {
          position = center;
          return true;
        }
      }
      return false;
    }, reason: 'menu item "$text" did not appear');
    _trace(
      'tap-menu-text',
      'SEND',
      '"$text" at ${position!.dx},${position!.dy}',
    );
    await _input!.tap(position!, _devicePixelRatio);
    await _settle();
  }

  Future<void> _uxTapText(String text) async {
    Element? target;
    await _waitFor(() {
      final matches = _textElements(text);
      if (matches.isEmpty) return false;
      target = matches.last;
      return true;
    }, reason: 'text "$text" did not appear');
    await _waitForStableRect(target!, text);
    final position = _centerOf(target!, text);
    _trace('tap-text', 'SEND', '"$text" at ${position.dx},${position.dy}');
    await _input!.tap(position, _devicePixelRatio);
    await _settle();
  }

  List<Element> _textElements(String text) {
    final found = <Element>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Text && widget.data == text) found.add(element);
      if (widget is SelectableText && widget.data == text) found.add(element);
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return found;
  }

  Future<void> _uxScrollTop(String container) async {
    final element = await _waitForElement(
      container,
      reason: 'scroll container $container is missing',
    );
    final state = _uxScrollableState(element);
    if (state == null) {
      throw JourneyFailure('$container has no scrollable position');
    }
    state.position.jumpTo(0);
    await _settle();
  }

  ScrollableState? _uxScrollableState(Element root) {
    ScrollableState? state;
    void visit(Element element) {
      if (state != null) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        state = element.state as ScrollableState;
        return;
      }
      element.visitChildren(visit);
    }

    visit(root);
    return state;
  }

  Future<void> _uxScrollToKey(String key, {required String container}) async {
    final element = _elementByKey(ValueKey(key));
    if (element == null) {
      throw JourneyFailure('widget $key was not mounted before scrolling');
    }
    await Scrollable.ensureVisible(
      element,
      alignment: .5,
      duration: const Duration(milliseconds: 160),
    );
    await _settle();
    final rect = _uxRectOf(element);
    final viewport = _uxRectOf(
      _elementByKey(ValueKey(container)) ??
          (throw JourneyFailure('scroll container $container is missing')),
    );
    if (rect == null ||
        viewport == null ||
        rect.center.dy < viewport.top + 8 ||
        rect.center.dy > viewport.bottom - 8) {
      throw JourneyFailure('widget $key could not be scrolled into view');
    }
  }

  Future<void> _uxWaitGone(String key, String reason) async {
    await _waitFor(() => _elementByKey(ValueKey(key)) == null, reason: reason);
  }

  Future<void> _uxWaitUntil(
    FutureOr<bool> Function() predicate, {
    required String reason,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _trace('wait', 'TIMEOUT', '$reason after ${timeout.inSeconds}s');
    throw JourneyFailure(reason);
  }

  Rect? _uxRectOf(Element element) {
    final render = element.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return null;
    return render.localToGlobal(Offset.zero) & render.size;
  }

  /// Signed horizontal offset of a filmstrip thumbnail from the strip centre.
  double _uxFilmstripOffset(LocalPhoto photo) {
    final strip = _elementByKey(const ValueKey('viewer-filmstrip'));
    final thumb = _elementByKey(ValueKey('viewer-strip-${photo.id}'));
    if (strip == null || thumb == null) {
      throw JourneyFailure(
        'the filmstrip is missing the thumbnail for ${photo.name}',
      );
    }
    final stripRect = _uxRectOf(strip);
    final thumbRect = _uxRectOf(thumb);
    if (stripRect == null || thumbRect == null) {
      throw JourneyFailure('the filmstrip has no render box');
    }
    return thumbRect.center.dx - stripRect.center.dx;
  }

  void _uxExpectCenteredFilmstrip(LocalPhoto photo) {
    final offset = _uxFilmstripOffset(photo);
    if (offset.abs() > 2.5) {
      throw JourneyFailure(
        'the current filmstrip thumbnail ${photo.name} is '
        '${offset.toStringAsFixed(1)}px off centre',
      );
    }
  }

  String? _uxFocusedPhotoKey() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context is! Element) return null;
    String? found;
    context.visitAncestorElements((ancestor) {
      final key = ancestor.widget.key;
      if (key is ValueKey<String> && key.value.startsWith('photo-')) {
        found = key.value;
        return false;
      }
      return true;
    });
    return found;
  }

  LocalVideoStageState? _uxVideoState(String key) {
    final root = _elementByKey(ValueKey(key));
    if (root == null) return null;
    LocalVideoStageState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is LocalVideoStageState) {
        found = element.state as LocalVideoStageState;
        return;
      }
      element.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  Future<void> _uxWaitVideoPlaying(
    String key,
    bool playing,
    String reason,
  ) async {
    await _uxWaitUntil(
      () {
        final state = _uxVideoState(key);
        if (state == null || state.error != null) return false;
        return state.playing == playing;
      },
      reason: reason,
      timeout: const Duration(seconds: 30),
    );
  }

  // -------------------------------------------------------- library helpers

  Future<LocalPhoto> _uxWaitSourcePhoto(String name) async {
    LocalPhoto? found;
    await _uxWaitUntil(
      () async {
        final page = await _library!.listPhotos(
          search: name,
          searchScope: SearchScope.name,
          limit: 100,
        );
        for (final photo in page.items) {
          if (photo.name == name && photo.parent == _uxSourceRoot) {
            found = photo;
            return true;
          }
        }
        return false;
      },
      reason: 'source photo "$name" never appeared in the library',
      timeout: const Duration(seconds: 60),
    );
    return found!;
  }

  Future<LocalPhoto> _uxWaitMediaPhoto(String name) async {
    LocalPhoto? found;
    await _uxWaitUntil(
      () async {
        final page = await _library!.listPhotos(
          search: name,
          searchScope: SearchScope.name,
          limit: 100,
        );
        for (final photo in page.items) {
          if (photo.name == name && photo.parent == _uxMediaRoot) {
            found = photo;
            return true;
          }
        }
        return false;
      },
      reason: 'media photo "$name" never appeared in the library',
      timeout: const Duration(seconds: 60),
    );
    return found!;
  }

  Future<LocalPhoto?> _uxPhotoById(String id) async {
    final page = await _library!.listPhotos(limit: 200);
    for (final photo in page.items) {
      if (photo.id == id) return photo;
    }
    return null;
  }

  Future<LocalPhoto> _uxWaitTreePhoto(String name) async {
    LocalPhoto? found;
    await _uxWaitUntil(
      () async {
        final page = await _library!.listPhotos(
          search: name,
          searchScope: SearchScope.name,
          limit: 100,
        );
        for (final photo in page.items) {
          if (photo.name == name && photo.path.startsWith('$_uxSourceRoot/')) {
            found = photo;
            return true;
          }
        }
        return false;
      },
      reason: 'source-tree photo "$name" never appeared in the library',
      timeout: const Duration(seconds: 60),
    );
    return found!;
  }

  Future<LocalPhoto> _uxWaitPhotoNamed(
    String name, {
    bool trashed = false,
  }) async {
    LocalPhoto? found;
    await _uxWaitUntil(
      () async {
        final page = await _library!.listPhotos(
          search: name,
          searchScope: SearchScope.name,
          limit: 100,
          trashed: trashed,
        );
        for (final photo in page.items) {
          if (photo.name == name) {
            found = photo;
            return true;
          }
        }
        return false;
      },
      reason: 'photo "$name" never appeared in the library',
      timeout: const Duration(seconds: 60),
    );
    return found!;
  }

  Future<LocalPhoto> _uxWaitContentVersion(String id, int previous) async {
    LocalPhoto? found;
    await _uxWaitUntil(
      () async {
        final page = await _library!.listPhotos(limit: 200);
        for (final photo in page.items) {
          if (photo.id == id && photo.contentVersion > previous) {
            found = photo;
            return true;
          }
        }
        return false;
      },
      reason: 'the photo did not reach a newer content version',
      timeout: const Duration(seconds: 60),
    );
    return found!;
  }

  Future<List<LocalPhoto>> _uxTrashed() async {
    final page = await _library!.listPhotos(trashed: true, limit: 100);
    return page.items;
  }

  Future<List<LocalPhoto>> _uxPhotosInFolder(String folder) async {
    final page = await _library!.listPhotos(folder: folder, limit: 200);
    return page.items;
  }

  Future<List<String>> _uxPhotoPathsInFolder(String folder) async => [
    for (final photo in await _uxPhotosInFolder(folder)) photo.path,
  ];

  Future<void> _uxWaitFavorites(int expected) async {
    await _uxWaitUntil(() async {
      final page = await _library!.listPhotos(favoritesOnly: true, limit: 200);
      return page.total == expected;
    }, reason: 'the favorites-only query did not settle at $expected items');
  }

  Future<void> _uxWaitTotal(int expected, String reason) async {
    await _waitFor(
      () => !_state.loading && !_state.scanning && _state.total == expected,
      reason: '$reason (expected $expected, got ${_state.total})',
      timeout: const Duration(seconds: 60),
    );
  }

  Future<void> _uxWaitAlbum(String path, String reason) async {
    await _uxWaitUntil(() async {
      final albums = await _library!.listAlbums();
      return albums.any((album) => album.path == path);
    }, reason: reason);
    await _waitForElement(
      'sidebar-album-$path',
      reason: reason,
      timeout: const Duration(seconds: 10),
    );
  }

  Future<LocalScanResult> _uxWaitForScan(
    LocalScanResult? previous,
    String label,
  ) async {
    await _waitFor(
      () =>
          _state.scanning ||
          (!_state.loading &&
              _state.scanResult != null &&
              !identical(_state.scanResult, previous)),
      reason: '$label did not start a scan',
      timeout: const Duration(seconds: 30),
    );
    await _waitFor(
      () =>
          !_state.scanning &&
          _state.scanResult != null &&
          !identical(_state.scanResult, previous),
      reason: '$label did not finish its scan',
      timeout: const Duration(minutes: 3),
    );
    return _state.scanResult!;
  }

  Future<int> _uxCacheUsage() async {
    final value = await _container!
        .read(localLibraryProvider.notifier)
        .localCommand({'op': 'cacheUsage'});
    return (value as num).toInt();
  }

  Future<List<String>> _uxDirectoryNames(String path) async {
    final directory = Directory(path);
    if (!directory.existsSync()) return const [];
    return [
      for (final entity in directory.listSync())
        if (entity is File) entity.uri.pathSegments.last,
    ]..sort();
  }

  Future<int> _uxFileFingerprint(String path) async {
    final file = File(path);
    if (!await file.exists()) throw JourneyFailure('$path is missing');
    final bytes = await file.readAsBytes();
    var hash = 0x811c9dc5;
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  Future<(int, int)> _uxDecodeSize(String path) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final size = (image.width, image.height);
    image.dispose();
    codec.dispose();
    return size;
  }

  void _uxRecord(String key, Object? value) {
    final map = facts['ux'] as Map<String, Object?>;
    if (value is Future) throw StateError('record $key needs an awaited value');
    map[key] = value;
  }

  String get _uxTripPath => '$_uxAlbumRoot/Trip';
  String get _uxTripsPath => '$_uxAlbumRoot/Trips';
}
