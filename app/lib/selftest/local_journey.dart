import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../platform/file_selector_source_picker.dart';
import '../services/core_gateway.dart';
import '../services/local_library_gateway.dart';
import '../ui/library_shell.dart';
import '../ui/local_library_controller.dart';
import '../ui/runtime_controller.dart';
import '../ui/strings.dart';
import 'journey_input.dart';
import 'launch_options.dart';

const String _recordPrefix = 'PHOTO_CLIENT_LOCAL ';
const String _readyPrefix = 'PHOTO_CLIENT_LOCAL_READY ';

/// Drives the shipped UI over real FFI, SQLite, files and a real window.
///
/// Nothing here substitutes sample data for the library: every value asserted
/// comes from the native gateway or the rendered tree. Only the modal source
/// dialog is replaced when `--source` is supplied, because a GTK file chooser
/// cannot be answered from inside this process; `--input=x11` keeps pointer and
/// keyboard events on the real X11 path.
final class LocalJourney {
  LocalJourney({required this.gateway, required this.options});

  final CoreGateway gateway;
  final LaunchOptions options;
  final List<Map<String, Object?>> steps = [];
  final Map<String, Object?> facts = {};
  final List<String> screenshots = [];
  final GlobalKey _shotKey = GlobalKey();
  ProviderContainer? _container;
  JourneyInput? _input;
  LocalLibraryGateway? _library;

  LibraryViewState get _state => _container!.read(localLibraryProvider);
  RuntimeViewState get _runtime => _container!.read(runtimeProvider);

  double get _devicePixelRatio =>
      ui.PlatformDispatcher.instance.views.first.devicePixelRatio;

  ui.Size get _viewSize =>
      ui.PlatformDispatcher.instance.views.first.physicalSize /
      _devicePixelRatio;

  static Future<int> run(CoreGateway gateway, LaunchOptions options) async {
    final journey = LocalJourney(gateway: gateway, options: options);
    return journey._execute();
  }

  Future<int> _execute() async {
    final started = DateTime.now();
    var result = 'PASS';
    String? failure;
    try {
      if (options.journeyPhase == 'probe-open') {
        await _probeOpen();
        return 0;
      }
      await _launchUi();
      switch (options.journeyPhase) {
        case 'provision':
          await _provisionJourney();
        case 'reopen':
          await _reopenJourney();
        case 'missing':
          await _missingSourceJourney();
        case 'changed':
          await _changedSourceJourney();
        case 'bulk':
          await _bulkJourney();
        case 'cancel':
          await _cancelJourney();
        case 'picker-probe':
          await _pickerProbeJourney();
        case 'hold':
          await _holdJourney();
        default:
          throw JourneyFailure(
            'Unsupported journey phase: ${options.journeyPhase}',
          );
      }
    } catch (error) {
      result = 'FAIL';
      failure = error is JourneyFailure ? error.message : '$error';
      steps.add({'id': 'journey', 'status': 'FAIL', 'detail': failure});
    }
    final record = <String, Object?>{
      'result': result,
      'phase': options.journeyPhase,
      'input': _input?.mode ?? 'none',
      'started_at': started.toUtc().toIso8601String(),
      'elapsed_ms': DateTime.now().difference(started).inMilliseconds,
      'window': {
        'width': _viewSize.width.round(),
        'height': _viewSize.height.round(),
        'device_pixel_ratio': _devicePixelRatio,
      },
      'steps': steps,
      'facts': facts,
      'screenshots': screenshots,
      'failure': ?failure,
    };
    await _shutdown();
    stdout.writeln('$_recordPrefix${jsonEncode(record)}');
    await stdout.flush();
    return result == 'PASS' ? 0 : 1;
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> _launchUi() async {
    final picker = options.sources.isEmpty
        ? const FileSelectorSourcePicker()
        : ScriptedSourcePicker(options.sources);
    stderr.writeln('JOURNEY phase=runApp');
    runApp(
      RepaintBoundary(
        key: _shotKey,
        child: PhotoClientApp(gateway: gateway, sourcePicker: picker),
      ),
    );
    await SchedulerBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 30),
      onTimeout: () => stderr.writeln('JOURNEY first-frame-timeout'),
    );
    stderr.writeln('JOURNEY phase=first-frame');
    final element = _elementOfWidget<LibraryShell>();
    if (element == null) throw JourneyFailure('LibraryShell was never mounted');
    _container = ProviderScope.containerOf(element);
    _library = _container!.read(coreGatewayProvider) as LocalLibraryGateway;
    _input = createJourneyInput(options.inputMode, options.evidenceDir);
    await _step('runtime-ready', () async {
      await _waitFor(
        () => _runtime.phase == ConnectionPhase.ready,
        reason:
            'native runtime did not reach ready (problem: ${_runtime.problem})',
      );
      final snapshot = _runtime.snapshot;
      if (snapshot == null) throw JourneyFailure('runtime snapshot missing');
      facts['profile_id'] = snapshot.profileId;
      facts['profile_digest'] = snapshot.profileDigest;
      facts['session_id'] = snapshot.sessionId;
    });
    await _step('library-open', () async {
      await _waitFor(
        () => _state.info != null && !_state.loading,
        reason: 'local library did not open (problem: ${_state.problem})',
      );
      final info = _state.info!;
      facts['library_id'] = info.libraryId;
      facts['opened_count'] = info.count;
      facts['opened_revision'] = info.revision;
      // Only journeys that reuse a provisioned library may expect a count
      // before their own scan runs.
      _expectLibraryIdentity(
        expectCount: const {
          'reopen',
          'missing',
          'changed',
        }.contains(options.journeyPhase),
      );
    });
  }

  void _expectLibraryIdentity({bool expectCount = true}) {
    final info = _state.info;
    if (info == null) throw JourneyFailure('library info missing');
    final expectedId = options.expectLibraryId;
    if (expectedId != null && info.libraryId != expectedId) {
      throw JourneyFailure(
        'library identity changed across restart: expected $expectedId, got ${info.libraryId}',
      );
    }
    final expectedCount = options.expectCount;
    if (expectCount && expectedCount != null && info.count != expectedCount) {
      throw JourneyFailure(
        'library count changed across restart: expected $expectedCount, got ${info.count}',
      );
    }
  }

  Future<void> _shutdown() async {
    try {
      await _input?.dispose();
    } catch (_) {
      // Evidence files stay behind for inspection; shutdown must still run.
    }
    final container = _container;
    if (container == null) return;
    stderr.writeln('JOURNEY shutdown=controller-start');
    try {
      await container
          .read(runtimeProvider.notifier)
          .shutdown()
          .timeout(
            const Duration(seconds: 25),
            onTimeout: () {
              stderr.writeln('JOURNEY shutdown=controller-timeout');
            },
          );
    } catch (error) {
      stderr.writeln('JOURNEY shutdown=controller-error $error');
    }
    stderr.writeln('JOURNEY shutdown=controller-done');
    stderr.writeln('JOURNEY shutdown=gateway-start');
    try {
      await container
          .read(coreGatewayProvider)
          .shutdown()
          .timeout(
            const Duration(seconds: 25),
            onTimeout: () {
              stderr.writeln('JOURNEY shutdown=gateway-timeout');
            },
          );
    } catch (error) {
      stderr.writeln('JOURNEY shutdown=gateway-error $error');
    }
    stderr.writeln('JOURNEY shutdown=gateway-done');
  }

  // ------------------------------------------------------------------- phases

  Future<void> _probeOpen() async {
    final started = DateTime.now();
    var result = 'PASS';
    String? reason;
    String? detail;
    final local = gateway as LocalLibraryGateway;
    try {
      await gateway.initialize();
      final info = await local.openLibrary();
      detail = 'opened ${info.libraryId} with ${info.count} items';
      if (options.expectRejected) {
        result = 'FAIL';
        reason =
            'expected a second instance on the same data root to be rejected';
      }
    } catch (error) {
      detail = '$error';
      final rejected =
          detail.contains('LibraryAlreadyOpen') ||
          detail.contains('AnotherLibraryAlreadyOpen');
      if (!rejected) {
        result = 'FAIL';
        reason = 'open failed for an unexpected reason';
      } else if (!options.expectRejected) {
        result = 'FAIL';
        reason = 'the data root was locked although no other instance holds it';
      } else {
        facts['rejection'] = 'LibraryAlreadyOpen';
      }
    }
    facts['detail'] = detail;
    try {
      await gateway.shutdown();
    } catch (_) {}
    stdout.writeln(
      '$_recordPrefix${jsonEncode({
        'result': result,
        'phase': 'probe-open',
        'input': 'none',
        'started_at': started.toUtc().toIso8601String(),
        'elapsed_ms': DateTime.now().difference(started).inMilliseconds,
        'steps': [
          {'id': 'data-root-lock', 'status': result, 'detail': reason ?? detail},
        ],
        'facts': facts,
        'screenshots': <String>[],
        'failure': ?reason,
      })}',
    );
    await stdout.flush();
    exit(result == 'PASS' ? 0 : 1);
  }

  /// Opens the shipped GTK dialogs through the real file_selector plugin.
  ///
  /// An external helper answers the dialogs with real X11 keystrokes; this
  /// process only reports what the platform returned.
  Future<void> _pickerProbeJourney() async {
    await _step('picker-dialog-directory', () async {
      const picker = FileSelectorSourcePicker();
      stdout.writeln(
        '$_readyPrefix${jsonEncode({'phase': 'picker-probe', 'waiting_for': 'directory-dialog'})}',
      );
      await stdout.flush();
      final directory = await picker.chooseDirectory();
      facts['picker_directory'] = directory;
      if (directory == null) {
        throw JourneyFailure('the real directory dialog returned no path');
      }
      if (!Directory(directory).existsSync()) {
        throw JourneyFailure('the dialog returned a path that does not exist');
      }
    });
    await _step('picker-dialog-files', () async {
      const picker = FileSelectorSourcePicker();
      stdout.writeln(
        '$_readyPrefix${jsonEncode({'phase': 'picker-probe', 'waiting_for': 'file-dialog'})}',
      );
      await stdout.flush();
      final files = await picker.chooseFiles();
      facts['picker_files'] = files;
      if (files.isEmpty) {
        throw JourneyFailure('the real file dialog returned no files');
      }
      for (final path in files) {
        if (!File(path).existsSync()) {
          throw JourneyFailure('the dialog returned a missing file: $path');
        }
      }
    });
  }

  Future<void> _holdJourney() async {
    final seconds = options.holdSeconds;
    stdout.writeln(
      '$_readyPrefix${jsonEncode({'phase': 'hold', 'library_id': facts['library_id'], 'count': facts['opened_count'], 'hold_seconds': seconds})}',
    );
    await stdout.flush();
    await Future<void>.delayed(Duration(seconds: seconds));
  }

  Future<void> _provisionJourney() async {
    await _step('scan-real-source', () async {
      final opened = _state.info!.count;
      if (options.sources.isEmpty) {
        throw JourneyFailure('--source is required to provision a library');
      }
      if (opened > 0) {
        facts['scan_skipped_existing_items'] = opened;
        return;
      }
      await _tapKey('add-folder');
      await _waitFor(
        () => _state.scanning || _state.scanResult != null,
        reason: 'the real add-folder button did not start a scan',
      );
      await _waitFor(
        () => !_state.scanning && _state.scanResult != null,
        reason: 'scan did not finish',
        timeout: const Duration(minutes: 5),
      );
      final result = _state.scanResult!;
      facts['scan'] = {
        'source': options.sources.single,
        'discovered': result.discovered,
        'skipped': result.skipped,
        'failed': result.failed,
        'cancelled': result.cancelled,
      };
      if (result.discovered == 0) {
        throw JourneyFailure('the real scan discovered no photos');
      }
      await _waitFor(
        () => _state.total > 0,
        reason: 'scanned photos are not queryable',
      );
    });
    await _step('grid-is-database-driven', () async {
      final state = _state;
      facts['total'] = state.total;
      facts['page_size'] = LocalLibraryController.pageSize;
      facts['first_page_items'] = state.pages[0]?.length ?? 0;
      if (state.total != state.info!.count) {
        throw JourneyFailure(
          'grid total ${state.total} disagrees with the library count ${state.info!.count}',
        );
      }
      final tiles = _elementsWithKeyPrefix('photo-');
      facts['tiles_in_tree'] = tiles.length;
      if (tiles.isEmpty) throw JourneyFailure('no grid tile was rendered');
      final first = state.pages[0]!.first;
      facts['first_photo'] = {
        'id': first.id,
        'name': first.name,
        'path': first.path,
        'parent': first.parent,
        'size_bytes': first.sizeBytes,
        'width': first.width,
        'height': first.height,
        'content_version': first.contentVersion,
        'favorite': first.favorite,
      };
      if (_elementByKey(ValueKey('photo-${first.id}')) == null) {
        throw JourneyFailure('the first database row has no rendered tile');
      }
    });
    await _step('thumbnail-decoded', () async {
      final first = _state.pages[0]!.first;
      final tile = _elementByKey(ValueKey('photo-${first.id}'));
      if (tile == null) {
        throw JourneyFailure('tile for ${first.id} is not mounted');
      }
      final image = await _waitForRenderedImage(tile, 'grid thumbnail');
      facts['grid_thumbnail'] = {'width': image.width, 'height': image.height};
      if (image.width == 0 || image.height == 0) {
        throw JourneyFailure('grid thumbnail decoded to an empty image');
      }
      final longest = image.width > image.height ? image.width : image.height;
      if (longest > 1024) {
        throw JourneyFailure(
          'grid thumbnail $longest px exceeds the cache class bound',
        );
      }
    });
    await _step('thumbnail-cache-classes', () async {
      final first = _state.pages[0]!.first;
      final paths = <String, String>{};
      for (final sizeClass in kThumbnailSizeClasses) {
        paths['$sizeClass'] = await _library!.thumbnail(
          first.id,
          sizeClass: sizeClass,
        );
      }
      facts['thumbnail_classes'] = {
        'media_id': first.id,
        'name': first.name,
        'content_version': first.contentVersion,
        'source_width': first.width,
        'source_height': first.height,
        'paths': paths,
      };
      if (paths.values.toSet().length != kThumbnailSizeClasses.length) {
        throw JourneyFailure('cache classes did not produce distinct files');
      }
    });
    await _screenshot('01-grid');
    await _step('viewer-opens-real-file', () async {
      final first = _state.pages[0]!.first;
      await _tapKey('photo-${first.id}');
      await _waitForElement('viewer', reason: 'the viewer did not open');
      final name = _textOf(const ValueKey('viewer-name'));
      facts['viewer'] = {
        'opened_name': name,
        'expected_name': first.name,
        'path': first.path,
      };
      if (name != first.name) {
        throw JourneyFailure('viewer shows $name instead of ${first.name}');
      }
      final viewer = _elementByKey(const ValueKey('viewer'))!;
      final image = await _waitForRenderedImage(viewer, 'viewer image');
      final details = Map<String, Object?>.from(facts['viewer']! as Map);
      details['decoded_width'] = image.width;
      details['decoded_height'] = image.height;
      facts['viewer'] = details;
      _expectDecodedMatchesRecord(image, first);
    });
    await _step('viewer-keyboard-and-button-navigation', () async {
      final items = _state.pages[0]!;
      if (items.length < 2) {
        throw JourneyFailure(
          'navigation needs at least two photos in the fixture',
        );
      }
      final start = _textOf(const ValueKey('viewer-name'));
      await _key('Right');
      await _waitFor(
        () => _textOf(const ValueKey('viewer-name')) == items[1].name,
        reason: 'ArrowRight did not move to the next database row',
      );
      final navigation = <String, Object?>{
        'start': start,
        'after_right': _textOf(const ValueKey('viewer-name')),
      };
      await _tapKey('viewer-previous');
      await _waitFor(
        () => _textOf(const ValueKey('viewer-name')) == items[0].name,
        reason: 'the previous button did not return to the anchor photo',
      );
      navigation['after_previous'] = _textOf(const ValueKey('viewer-name'));
      facts['navigation'] = navigation;
    });
    await _step('viewer-wheel-zoom', () async {
      final element = _viewerImageElement();
      if (element == null) {
        throw JourneyFailure('the viewer image is not mounted');
      }
      final before = _viewerScale();
      await _input!.scroll(
        _centerOf(element, 'viewer image'),
        3,
        _devicePixelRatio,
      );
      await _settle();
      await _waitFor(
        () => _viewerScale() > before + .05,
        reason: 'real wheel input did not zoom the viewer',
      );
      facts['wheel_zoom'] = {
        'scale_before': before,
        'scale_after': _viewerScale(),
        'label': _textOf(const ValueKey('viewer-zoom-level')),
      };
      if (_textOf(const ValueKey('viewer-zoom-level')) == '100%') {
        throw JourneyFailure('the zoom indicator ignored the real wheel zoom');
      }
    });
    await _step('viewer-zoom-buttons', () async {
      await _tapKey('viewer-zoom-reset');
      await _waitFor(
        () => (_viewerScale() - 1).abs() < .01,
        reason: 'the reset control did not return the viewer to 100%',
      );
      await _tapKey('viewer-zoom-in');
      await _waitFor(
        () => _textOf(const ValueKey('viewer-zoom-level')) == '125%',
        reason: 'zoom in did not reach 125%',
      );
      await _tapKey('viewer-zoom-out');
      await _waitFor(
        () => _textOf(const ValueKey('viewer-zoom-level')) == '100%',
        reason: 'zoom out did not return to 100%',
      );
      await _tapKey('viewer-zoom-in');
      await _tapKey('viewer-zoom-in');
      await _waitFor(
        () => _viewerScale() > 1.5,
        reason: 'repeated zoom in did not enlarge the image',
      );
      facts['zoom_buttons'] = {
        'scale': _viewerScale(),
        'label': _textOf(const ValueKey('viewer-zoom-level')),
      };
    });
    await _step('viewer-pan-by-real-drag', () async {
      final element = _viewerImageElement();
      if (element == null) {
        throw JourneyFailure('the viewer image is not mounted');
      }
      final center = _centerOf(element, 'viewer image');
      final before = _viewerMatrix()!.getTranslation();
      await _input!.drag(
        center,
        center + const Offset(-90, -60),
        _devicePixelRatio,
      );
      await _settle();
      final after = _viewerMatrix()!.getTranslation();
      final moved = (after - before).length;
      facts['pan'] = {
        'before': [before.x, before.y],
        'after': [after.x, after.y],
        'moved': moved,
        'scale': _viewerScale(),
      };
      if (moved < 5) {
        throw JourneyFailure('a real drag did not pan the zoomed image');
      }
      await _tapKey('viewer-zoom-reset');
      await _waitFor(
        () => (_viewerScale() - 1).abs() < .01,
        reason: 'reset after panning failed',
      );
    });
    await _step('viewer-immersive-toggle', () async {
      await _tapKey('viewer-immersive');
      await _waitFor(
        () =>
            _elementByKey(const ValueKey('viewer-immersive-exit')) != null &&
            _elementByKey(const ValueKey('viewer-name')) == null,
        reason: 'immersive mode did not hide the viewer chrome',
      );
      await _screenshot('05-immersive');
      await _tapKey('viewer-immersive-exit');
      await _waitFor(
        () => _elementByKey(const ValueKey('viewer-name')) != null,
        reason: 'immersive mode did not restore the viewer chrome',
      );
    });
    await _step('viewer-metadata-is-real', () async {
      final photo = _state.pages[0]!.first;
      await _tapKey('viewer-details');
      await _waitFor(
        () => _dialogTexts().contains(photo.path),
        reason: 'the details dialog does not show the real source path',
      );
      final texts = _dialogTexts();
      facts['details'] = texts;
      if (!texts.contains('${photo.sizeBytes} B')) {
        throw JourneyFailure('details dialog is missing the real file size');
      }
      if (photo.width != null &&
          !texts.contains('${photo.width} × ${photo.height}')) {
        throw JourneyFailure('details dialog is missing the real dimensions');
      }
      final dialog = _elementOfWidget<AlertDialog>();
      if (dialog == null) {
        throw JourneyFailure('the details dialog disappeared');
      }
      await _tapText(AppStrings.of(dialog).close);
      await _waitFor(
        () => _dialogTexts().isEmpty,
        reason: 'the details dialog did not close',
      );
    });
    await _step('favorite-persists-in-database', () async {
      final photo = _state.pages[0]!.first;
      await _tapKey('viewer-favorite');
      await _waitFor(
        () => _state.favoritePending.isEmpty && _state.pages[0]!.first.favorite,
        reason: 'the favorite toggle did not reach the UI state',
      );
      final favorites = await _library!.listPhotos(
        limit: 100,
        favoritesOnly: true,
      );
      facts['favorite'] = {
        'id': photo.id,
        'query_total': favorites.total,
        'query_ids': [for (final item in favorites.items) item.id],
      };
      if (favorites.total != 1 || favorites.items.single.id != photo.id) {
        throw JourneyFailure(
          'a fresh favorites-only query did not return exactly the marked photo',
        );
      }
      if (!favorites.items.single.favorite) {
        throw JourneyFailure('the native query reports favorite=false');
      }
    });
    await _screenshot('02-viewer-favorite');
    await _step('escape-returns-to-grid', () async {
      await _key('Escape');
      await _waitFor(
        () => _elementByKey(const ValueKey('viewer')) == null,
        reason: 'Escape did not close the viewer',
      );
      if (_elementsWithKeyPrefix('photo-').isEmpty) {
        throw JourneyFailure(
          'the grid did not return after closing the viewer',
        );
      }
    });
    await _step('favorites-filter', () async {
      await _tapKey('filter-favorites');
      await _waitFor(
        () => _state.favoritesOnly && !_state.loading,
        reason: 'the favorites filter did not activate',
      );
      facts['favorites_filter_total'] = _state.total;
      if (_state.total != 1) {
        throw JourneyFailure('favorites filter returned ${_state.total} items');
      }
      await _screenshot('03-favorites-filter');
      await _tapKey('filter-favorites');
      await _waitFor(
        () => !_state.favoritesOnly && _state.total > 1,
        reason: 'clearing the favorites filter did not restore the library',
      );
    });
    await _step('search-uses-current-query-only', () async {
      if (_input!.mode != 'x11') {
        facts['search'] = 'NOT RUN: typing needs real X11 input';
        return;
      }
      final target = _state.pages[0]!.first.name;
      final query = target.split('.').first;
      await _tapKey('library-search');
      await _type(query);
      await _waitFor(
        () => _state.search == query && !_state.loading,
        reason: 'the debounced search did not apply "$query"',
      );
      final names = [
        for (final page in _state.pages.values)
          for (final item in page) item.name,
      ];
      facts['search'] = {'query': query, 'total': _state.total, 'names': names};
      if (names.isEmpty) throw JourneyFailure('search produced no results');
      for (final name in names) {
        if (!name.toLowerCase().contains(query.toLowerCase())) {
          throw JourneyFailure('search result $name does not match "$query"');
        }
      }
      await _screenshot('04-search');
      for (var index = 0; index < query.length; index += 1) {
        await _key('BackSpace');
      }
      await _waitFor(
        () => _state.search.isEmpty && _state.total > 1,
        reason: 'clearing the search did not restore the full library',
      );
    });
    await _step('library-summary-text', () async {
      final text = _textOf(const ValueKey('library-info'));
      facts['library_info_text'] = text;
      if (text == null || !text.contains('${_state.info!.count}')) {
        throw JourneyFailure(
          'the library summary does not report the real count',
        );
      }
    });
  }

  Future<void> _reopenJourney() async {
    await _step('restart-keeps-identity-and-favorite', () async {
      _expectLibraryIdentity();
      final expectedPath = options.expectFavoritePath;
      if (expectedPath == null) {
        throw JourneyFailure('--expect-favorite-path is required for reopen');
      }
      final favorites = await _library!.listPhotos(
        limit: 100,
        favoritesOnly: true,
      );
      facts['favorites_after_restart'] = {
        'total': favorites.total,
        'items': [
          for (final item in favorites.items)
            {'id': item.id, 'path': item.path, 'favorite': item.favorite},
        ],
      };
      if (favorites.total != 1 || favorites.items.single.path != expectedPath) {
        throw JourneyFailure(
          'the favorite did not survive the restart: expected $expectedPath',
        );
      }
      if (_state.scanResult != null) {
        throw JourneyFailure('reopen must not rescan to restore state');
      }
      facts['favorite_id'] = favorites.items.single.id;
    });
    await _step('restart-favorites-filter', () async {
      await _tapKey('filter-favorites');
      await _waitFor(
        () => _state.favoritesOnly && _state.total == 1,
        reason: 'the favorites filter did not restore the marked photo',
      );
    });
    await _step('restart-viewer-still-decodes', () async {
      final photo = _state.pages[0]!.single;
      await _tapKey('photo-${photo.id}');
      await _waitForElement('viewer', reason: 'the viewer did not reopen');
      final viewer = _elementByKey(const ValueKey('viewer'))!;
      final image = await _waitForRenderedImage(viewer, 'viewer image');
      facts['restart_viewer'] = {
        'name': _textOf(const ValueKey('viewer-name')),
        'decoded_width': image.width,
        'decoded_height': image.height,
      };
      _expectDecodedMatchesRecord(image, photo);
    });
    await _screenshot('10-restart-favorite');
  }

  Future<void> _missingSourceJourney() async {
    final missing = options.missingPath;
    if (missing == null) {
      throw JourneyFailure('--missing-path is required for the missing phase');
    }
    await _step('missing-source-keeps-history', () async {
      await _waitFor(
        () => _state.pages.values
            .expand((page) => page)
            .any((photo) => photo.path == missing),
        reason: 'a deleted source file disappeared from the index',
      );
      facts['missing_path'] = missing;
    });
    await _step('missing-source-viewer-degrades', () async {
      final photo = _state.pages.values
          .expand((page) => page)
          .firstWhere((item) => item.path == missing);
      await _tapKey('photo-${photo.id}');
      await _waitForElement('viewer', reason: 'the viewer did not open');
      await _waitFor(
        () => _subtreeHasIcon(
          _elementByKey(const ValueKey('viewer'))!,
          Icons.broken_image_outlined,
        ),
        reason: 'a missing source did not produce the unavailable placeholder',
        timeout: const Duration(seconds: 30),
      );
      facts['missing_viewer'] = {
        'name': _textOf(const ValueKey('viewer-name')),
        'placeholder': 'broken_image_outlined',
      };
      await _screenshot('20-missing-source');
    });
    await _step('missing-source-does-not-block-others', () async {
      await _key('Escape');
      await _waitFor(
        () => _elementByKey(const ValueKey('viewer')) == null,
        reason: 'Escape did not close the viewer',
      );
      final healthy = _state.pages[0]!.firstWhere(
        (photo) => photo.path != missing,
      );
      await _tapKey('photo-${healthy.id}');
      await _waitForElement('viewer', reason: 'the healthy photo did not open');
      final image = await _waitForRenderedImage(
        _elementByKey(const ValueKey('viewer'))!,
        'healthy viewer image',
      );
      facts['healthy_after_missing'] = {
        'name': _textOf(const ValueKey('viewer-name')),
        'decoded_width': image.width,
        'decoded_height': image.height,
      };
      await _screenshot('21-healthy-after-missing');
    });
  }

  Future<void> _changedSourceJourney() async {
    final changed = options.changedPath;
    if (changed == null) {
      throw JourneyFailure('--changed-path is required for the changed phase');
    }
    await _step('rescan-does-not-duplicate', () async {
      final before = _state.total;
      await _tapKey('add-folder');
      await _waitFor(
        () => _state.scanning || _state.scanResult != null,
        reason: 'the rescan never started',
      );
      await _waitFor(
        () => !_state.scanning && _state.scanResult != null,
        reason: 'the rescan did not finish',
        timeout: const Duration(minutes: 5),
      );
      final result = _state.scanResult!;
      facts['rescan'] = {
        'before_total': before,
        'after_total': _state.total,
        'discovered': result.discovered,
        'skipped': result.skipped,
        'failed': result.failed,
        'cancelled': result.cancelled,
      };
      if (_state.total != before) {
        throw JourneyFailure(
          'a rescan changed the photo count from $before to ${_state.total}',
        );
      }
    });
    await _step('changed-source-bumps-content-version', () async {
      final page = await _library!.listPhotos(limit: 200);
      LocalPhoto? photo;
      for (final item in page.items) {
        if (item.path == changed) photo = item;
      }
      if (photo == null) {
        throw JourneyFailure('the externally changed source is not indexed');
      }
      final changedFacts = <String, Object?>{
        'path': photo.path,
        'name': photo.name,
        'content_version': photo.contentVersion,
        'width': photo.width,
        'height': photo.height,
        'size_bytes': photo.sizeBytes,
      };
      if (photo.contentVersion < 2) {
        throw JourneyFailure(
          'an externally rewritten source kept content_version '
          '${photo.contentVersion}',
        );
      }
      await _tapKey('photo-${photo.id}');
      await _waitForElement('viewer', reason: 'the changed photo did not open');
      final viewer = _elementByKey(const ValueKey('viewer'))!;
      final image = await _waitForRenderedImage(viewer, 'changed viewer image');
      changedFacts['decoded_width'] = image.width;
      changedFacts['decoded_height'] = image.height;
      _expectDecodedMatchesRecord(image, photo);
      final thumbnail = await _library!.thumbnail(photo.id, sizeClass: 512);
      changedFacts['thumbnail_path'] = thumbnail;
      if (!thumbnail.contains('/${photo.contentVersion}/')) {
        throw JourneyFailure(
          'the thumbnail cache did not move to content_version '
          '${photo.contentVersion}: $thumbnail',
        );
      }
      facts['changed'] = changedFacts;
      await _screenshot('40-changed-source');
    });
  }

  Future<void> _bulkJourney() async {
    await _step('bulk-scan-and-visible-window-decoding', () async {
      if (_state.info!.count == 0) {
        await _tapKey('add-folder');
        await _waitFor(
          () => _state.scanning || _state.scanResult != null,
          reason: 'the bulk scan never started',
        );
      }
      await _waitFor(
        () => !_state.scanning && !_state.selecting,
        reason: 'the bulk scan did not finish',
        timeout: const Duration(minutes: 10),
      );
      final expected = options.expectCount;
      if (expected != null) {
        // The post-scan forced refresh lands a moment after `scanning` clears.
        await _waitFor(
          () => _state.total == expected,
          reason:
              'the bulk library holds ${_state.total} items instead of $expected',
          timeout: const Duration(seconds: 60),
        );
      }
      final result = _state.scanResult;
      facts['bulk_scan'] = {
        'discovered': result?.discovered,
        'skipped': result?.skipped,
        'failed': result?.failed,
        'cancelled': result?.cancelled,
      };
      facts['total'] = _state.total;
      final first = _state.pages[0]!.first;
      final tile = await _waitForElement(
        'photo-${first.id}',
        reason: 'the bulk grid rendered no tile',
      );
      final image = await _waitForRenderedImage(tile, 'bulk thumbnail');
      facts['bulk_visible'] = {
        'tiles_in_tree': _elementsWithKeyPrefix('photo-').length,
        'page_size': LocalLibraryController.pageSize,
        'first_tile': first.name,
        'thumbnail_width': image.width,
        'thumbnail_height': image.height,
      };
    });
    await _screenshot('30-bulk-grid');
  }

  Future<void> _cancelJourney() async {
    await _step('cancel-during-scan-keeps-library-usable', () async {
      await _tapKey('add-folder');
      var controlSeen = false;
      try {
        final cancel = await _waitForElement(
          'cancel-scan',
          reason: 'no cancel control appeared',
          timeout: const Duration(seconds: 15),
        );
        controlSeen = true;
        await _input!.tap(_centerOf(cancel, 'cancel-scan'), _devicePixelRatio);
        await _settle();
      } on JourneyFailure {
        controlSeen = false;
      }
      await _waitFor(
        () => !_state.scanning && _state.scanResult != null,
        reason: 'the scan did not settle after the cancel request',
        timeout: const Duration(minutes: 10),
      );
      final result = _state.scanResult!;
      facts['cancel_scan'] = {
        'control_seen': controlSeen,
        'cancel_requested': _state.cancelRequested,
        'cancelled': result.cancelled,
        'discovered': result.discovered,
        'skipped': result.skipped,
        'failed': result.failed,
        'total_after_cancel': _state.total,
      };
      await _tapKey('refresh-library');
      await _waitFor(
        () => !_state.loading,
        reason: 'the library did not refresh after a cancelled scan',
      );
    });
    await _step('rescan-after-cancel-reconciles', () async {
      final expected = options.expectCount;
      if (expected == null) {
        throw JourneyFailure('--expect-count is required for the cancel phase');
      }
      if (_state.search.isNotEmpty || _state.folder != null) {
        throw JourneyFailure(
          'the cancel phase must run unfiltered but saw search='
          '"${_state.search}" folder=${_state.folder}',
        );
      }
      if (_state.favoritesOnly) {
        // A click can land on the favourites chip while the scan row reflows;
        // restore the unfiltered view with real input and record it.
        facts['cancel_misclick_recovered'] = true;
        await _tapKey('filter-favorites');
        await _waitFor(
          () => !_state.favoritesOnly,
          reason: 'could not restore the unfiltered view after a misclick',
        );
      }
      String controllerState() =>
          'problem=${_state.problem} scanning=${_state.scanning} '
          'selecting=${_state.selecting} loading=${_state.loading} '
          'total=${_state.total} info=${_state.info?.count} '
          'revision=${_state.revision} search="${_state.search}" '
          'favorites=${_state.favoritesOnly} folder=${_state.folder} '
          'extent=${_state.extent} pages=${_state.pages.keys.toList()} '
          'page0=${_state.pages[0]?.length}';
      await _tapKey('add-folder');
      await Future<void>.delayed(const Duration(seconds: 3));
      facts['rescan_probe_after_tap'] = controllerState();
      try {
        await _waitFor(
          () => !_state.scanning && _state.total == expected,
          reason:
              'a rescan after cancel did not reconcile to $expected items '
              '(${controllerState()})',
          timeout: const Duration(minutes: 4),
        );
      } on JourneyFailure {
        // A stale UI must not hide a healthy database: verify via the gateway.
        final page = await _library!.listPhotos(limit: 1);
        final mirrored = await _library!.listPhotos(
          limit: 1,
          favoritesOnly: _state.favoritesOnly,
          search: _state.search,
          folder: _state.folder,
        );
        facts['rescan_native_total'] = page.total;
        facts['rescan_native_mirrored_total'] = mirrored.total;
        if (page.total != expected) rethrow;
        await _tapKey('refresh-library');
        await _waitFor(
          () => _state.total == expected,
          reason:
              'the UI did not reconcile after an explicit refresh '
              '(${controllerState()})',
          timeout: const Duration(minutes: 2),
        );
        facts['rescan_reconciled_via'] =
            'explicit refresh after native total matched';
      }
      final result = _state.scanResult;
      facts['rescan_after_cancel'] = {
        'total': _state.total,
        'discovered': result?.discovered,
        'cancelled': result?.cancelled,
      };
      final ids = {
        for (final page in _state.pages.values)
          for (final item in page) item.id,
      };
      facts['distinct_ids_after_rescan'] = ids.length;
      if (ids.length !=
          _state.pages.values.fold<int>(
            0,
            (total, page) => total + page.length,
          )) {
        throw JourneyFailure(
          'a rescan produced duplicate rows in one page set',
        );
      }
    });
    await _screenshot('31-after-cancel');
  }

  // ------------------------------------------------------------------- inputs

  /// Real input travels through an external helper, so the layout may reflow
  /// between measuring and clicking. Only click a widget that has held still.
  Future<void> _tapKey(String keyValue) async {
    var element = await _waitForElement(
      keyValue,
      reason: 'widget $keyValue is not mounted',
    );
    var position = _centerOf(element, keyValue);
    for (var attempt = 0; attempt < 25; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final current = _elementByKey(ValueKey(keyValue));
      if (current == null) {
        element = await _waitForElement(
          keyValue,
          reason: 'widget $keyValue unmounted while stabilising',
        );
        position = _centerOf(element, keyValue);
        continue;
      }
      final next = _centerOf(current, keyValue);
      final settled =
          (next - position).distance < 1 && _hitMatches(next, current);
      position = next;
      if (settled) break;
    }
    final target = _elementByKey(ValueKey(keyValue));
    if (target == null || !_hitMatches(position, target)) {
      throw JourneyFailure(
        'widget $keyValue kept moving under real input; refusing a blind click',
      );
    }
    stderr.writeln(
      'JOURNEY tap=$keyValue at=${position.dx.toStringAsFixed(1)},'
      '${position.dy.toStringAsFixed(1)} dpr=$_devicePixelRatio',
    );
    await _input!.tap(position, _devicePixelRatio);
    await _settle();
  }

  Future<void> _tapText(String label) async {
    final element = await _waitForTextButton(
      label,
      reason: 'no button labelled "$label" is mounted',
    );
    await _input!.tap(_centerOf(element, label), _devicePixelRatio);
    await _settle();
  }

  Future<void> _key(String keyName) async {
    await _input!.key(keyName);
    await _settle();
  }

  Future<void> _type(String text) async {
    await _input!.type(text);
    await _settle();
  }

  Future<void> _settle() async {
    for (var index = 0; index < 2; index += 1) {
      await SchedulerBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          stderr.writeln('JOURNEY settle-timeout index=$index');
        },
      );
    }
  }

  /// Framework hit test at the exact point the helper will click, so a reflow
  /// between measuring and clicking cannot redirect the real input.
  bool _hitMatches(Offset position, Element element) {
    final target = element.findRenderObject();
    if (target == null) return false;
    final result = HitTestResult();
    GestureBinding.instance.hitTestInView(
      result,
      position,
      ui.PlatformDispatcher.instance.views.first.viewId,
    );
    return result.path.any((entry) => entry.target == target);
  }

  Offset _centerOf(Element element, String label) {
    final render = element.findRenderObject();
    if (render is! RenderBox || !render.hasSize) {
      throw JourneyFailure('widget $label has no laid-out render box');
    }
    return render.localToGlobal(render.size.center(Offset.zero));
  }

  Future<void> _screenshot(String name) async {
    final directory = options.evidenceDir;
    if (directory == null) return;
    await _step('screenshot-$name', () async {
      await SchedulerBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 20),
        onTimeout: () => stderr.writeln('JOURNEY screenshot-frame-timeout'),
      );
      final context = _shotKey.currentContext;
      if (context == null || !context.mounted) {
        throw JourneyFailure('the journey root is not mounted');
      }
      final boundary = context.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        throw JourneyFailure('the journey root is not a repaint boundary');
      }
      final image = await boundary.toImage(pixelRatio: _devicePixelRatio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        throw JourneyFailure('screenshot $name produced no bytes');
      }
      final file = File('$directory/$name.png');
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      screenshots.add(file.uri.pathSegments.last);
      final detail = <String, Object?>{
        'file': file.uri.pathSegments.last,
        'width': image.width,
        'height': image.height,
      };
      image.dispose();
      final input = _input;
      if (input != null && await input.capture(name)) {
        detail['x11_file'] = '$name-x11.png';
        screenshots.add('$name-x11.png');
      }
      facts['screenshot_$name'] = detail;
    });
  }

  Element? _viewerImageElement() {
    final viewer = _elementByKey(const ValueKey('viewer'));
    if (viewer == null) return null;
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget is InteractiveViewer) {
        found = element;
        return;
      }
      element.visitChildren(visit);
    }

    visit(viewer);
    return found;
  }

  Matrix4? _viewerMatrix() {
    final widget = _viewerImageElement()?.widget;
    if (widget is InteractiveViewer) {
      return widget.transformationController?.value;
    }
    return null;
  }

  double _viewerScale() => _viewerMatrix()?.getMaxScaleOnAxis() ?? 0;

  // ------------------------------------------------------------------- checks

  /// ResizeImage only downscales, so compare aspect ratio and bounds rather
  /// than exact pixels; an exact match is still recorded when it holds.
  void _expectDecodedMatchesRecord(ui.Image image, LocalPhoto photo) {
    final width = photo.width;
    final height = photo.height;
    if (width == null || height == null || width == 0 || height == 0) return;
    final exact = image.width == width && image.height == height;
    final rotated = image.width == height && image.height == width;
    if (!exact && !rotated) {
      final expected = width / height;
      final decoded = image.width == 0
          ? 0.0
          : image.height == 0
          ? 0.0
          : image.width / image.height;
      final reduced =
          (decoded - expected).abs() / expected < .02 &&
          image.width <= width &&
          image.height <= height;
      if (!reduced) {
        throw JourneyFailure(
          'decoded ${image.width}×${image.height} is unrelated to the indexed '
          '$width×$height for ${photo.name}',
        );
      }
    }
    facts['decoded_exact_size'] = exact;
    facts['decoded_axes_swapped'] = rotated && !exact;
  }

  Future<void> _step(String id, Future<void> Function() body) async {
    final started = Stopwatch()..start();
    stderr.writeln('JOURNEY step=$id phase=start');
    try {
      await body();
      started.stop();
      stderr.writeln(
        'JOURNEY step=$id phase=pass ms=${started.elapsedMilliseconds}',
      );
      steps.add({
        'id': id,
        'status': 'PASS',
        'ms': started.elapsedMilliseconds,
      });
    } catch (error) {
      started.stop();
      final detail = error is JourneyFailure ? error.message : '$error';
      stderr.writeln(
        'JOURNEY step=$id phase=fail ms=${started.elapsedMilliseconds} detail=$detail',
      );
      steps.add({
        'id': id,
        'status': 'FAIL',
        'ms': started.elapsedMilliseconds,
        'detail': detail,
      });
      rethrow;
    }
  }

  Future<void> _waitFor(
    bool Function() predicate, {
    required String reason,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    stderr.writeln('JOURNEY wait-timeout reason=$reason');
    throw JourneyFailure(reason);
  }

  Future<Element> _waitForElement(
    String keyValue, {
    required String reason,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final key = ValueKey(keyValue);
    Element? found;
    await _waitFor(
      () {
        found = _elementByKey(key);
        return found != null;
      },
      reason: reason,
      timeout: timeout,
    );
    return found!;
  }

  Future<Element> _waitForTextButton(
    String label, {
    required String reason,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    Element? found;
    await _waitFor(
      () {
        found = _buttonElementWithLabel(label);
        return found != null;
      },
      reason: reason,
      timeout: timeout,
    );
    return found!;
  }

  Future<ui.Image> _waitForRenderedImage(Element root, String label) async {
    ui.Image? image;
    await _waitFor(
      () {
        image = _renderedImage(root);
        return image != null;
      },
      reason: '$label was never decoded',
      timeout: const Duration(seconds: 60),
    );
    return image!;
  }

  // ------------------------------------------------------------- tree queries

  Element? _elementByKey(Key key) {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget.key == key) {
        found = element;
        return;
      }
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return found;
  }

  Element? _elementOfWidget<T extends Widget>() {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget is T) {
        found = element;
        return;
      }
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return found;
  }

  List<Element> _elementsWithKeyPrefix(String prefix) {
    final found = <Element>[];
    void visit(Element element) {
      final key = element.widget.key;
      if (key is ValueKey<String> && key.value.startsWith(prefix)) {
        found.add(element);
      }
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return found;
  }

  ui.Image? _renderedImage(Element root) {
    ui.Image? found;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is RawImage && widget.image != null) {
        found = widget.image;
        return;
      }
      element.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  bool _subtreeHasIcon(Element root, IconData icon) {
    var found = false;
    void visit(Element element) {
      if (found) return;
      final widget = element.widget;
      if (widget is Icon && widget.icon == icon) {
        found = true;
        return;
      }
      element.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  String? _textOf(Key key) {
    final widget = _elementByKey(key)?.widget;
    if (widget is Text) return widget.data;
    if (widget is SelectableText) return widget.data;
    return null;
  }

  List<String> _dialogTexts() {
    final dialog = _elementOfWidget<AlertDialog>();
    if (dialog == null) return const [];
    final texts = <String>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Text && widget.data != null) texts.add(widget.data!);
      if (widget is SelectableText && widget.data != null) {
        texts.add(widget.data!);
      }
      element.visitChildren(visit);
    }

    visit(dialog);
    return texts;
  }

  Element? _buttonElementWithLabel(String label) {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is TextButton) {
        final texts = <String>[];
        void collect(Element child) {
          final text = child.widget;
          if (text is Text && text.data != null) texts.add(text.data!);
          child.visitChildren(collect);
        }

        collect(element);
        if (texts.any((value) => value.toLowerCase() == label.toLowerCase())) {
          found = element;
          return;
        }
      }
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return found;
  }
}

/// Replaces only the modal dialog; scanning and indexing stay on the real path.
final class ScriptedSourcePicker implements LocalSourcePicker {
  const ScriptedSourcePicker(this.sources);
  final List<String> sources;

  @override
  Future<List<String>> chooseFiles() async => sources;

  @override
  Future<String?> chooseDirectory() async =>
      sources.isEmpty ? null : sources.first;
}

final class JourneyFailure implements Exception {
  JourneyFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
