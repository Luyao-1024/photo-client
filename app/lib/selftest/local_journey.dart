import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../platform/file_selector_source_picker.dart';
import '../services/core_gateway.dart';
import '../services/local_library_gateway.dart';
import '../ui/cloud_sync_controller.dart';
import '../ui/library_shell.dart';
import '../ui/local_library_controller.dart';
import '../ui/local_video_stage.dart';
import '../ui/local_animated_stage.dart';
import '../ui/presentation_preferences.dart';
import '../ui/runtime_controller.dart';
import 'journey_input.dart';
import 'launch_options.dart';

part 'ux_journey.dart';
part 'cloud_journey.dart';

const String _recordPrefix = 'PHOTO_CLIENT_LOCAL ';
const String _readyPrefix = 'PHOTO_CLIENT_LOCAL_READY ';
const String _stepPrefix = 'PHOTO_CLIENT_LOCAL_STEP ';

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
  File? _traceFile;
  UxSourcePicker? _uxPicker;

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
    final tracePath = options.evidenceDir;
    if (tracePath != null) {
      _traceFile = File('$tracePath/journey-trace.jsonl');
    }
    _trace('journey', 'START', options.journeyPhase);
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
        case 'hold':
          await _holdJourney();
        case 'ux':
          await _uxJourney();
        case 'ux-media':
          await _uxMediaJourney();
        case 'cloud-upload':
          await _cloudUploadJourney();
        case 'cloud-download':
          await _cloudDownloadJourney();
        case 'cloud-offline':
          await _cloudOfflineJourney();
        case 'cloud-reconnect':
          await _cloudReconnectJourney();
        case 'cloud-reconcile':
          await _cloudReconcileJourney();
        case 'cloud-clear':
          await _cloudClearJourney();
        case 'cache-clear':
          await _cacheClearJourney();
        case 'cloud-downlink':
          await _cloudDownlinkJourney();
        default:
          throw JourneyFailure(
            'Unsupported journey phase: ${options.journeyPhase}',
          );
      }
    } catch (error) {
      result = 'FAIL';
      failure = error is JourneyFailure ? error.message : '$error';
      steps.add({'id': 'journey', 'status': 'FAIL', 'detail': failure});
      _trace('journey', 'FAIL', failure);
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
    _trace('shutdown', 'START');
    await _shutdown();
    _trace('shutdown', 'DONE');
    stdout.writeln('$_recordPrefix${jsonEncode(record)}');
    _trace('record', 'WRITTEN');
    await stdout.flush();
    _trace('record', 'FLUSHED');
    return result == 'PASS' ? 0 : 1;
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> _launchUi() async {
    final LocalSourcePicker picker;
    if (options.journeyPhase.startsWith('ux')) {
      final evidence = options.evidenceDir;
      if (evidence == null) {
        throw JourneyFailure('the ux phase needs --evidence-dir');
      }
      picker = _uxPicker = UxSourcePicker(
        evidenceRoot: evidence,
        sourceDirectory: options.sources.isEmpty ? '' : options.sources.first,
      );
    } else {
      picker = options.sources.isEmpty
          ? const FileSelectorSourcePicker()
          : ScriptedSourcePicker(options.sources);
    }
    runApp(
      RepaintBoundary(
        key: _shotKey,
        child: PhotoClientApp(gateway: gateway, sourcePicker: picker),
      ),
    );
    await SchedulerBinding.instance.endOfFrame;
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
      _expectLibraryIdentity();
    });
  }

  void _expectLibraryIdentity() {
    final info = _state.info;
    if (info == null) throw JourneyFailure('library info missing');
    final expectedId = options.expectLibraryId;
    if (expectedId != null && info.libraryId != expectedId) {
      throw JourneyFailure(
        'library identity changed across restart: expected $expectedId, got ${info.libraryId}',
      );
    }
    final expectedCount = options.expectCount;
    if (expectedCount != null && info.count != expectedCount) {
      throw JourneyFailure(
        'library count changed across restart: expected $expectedCount, got ${info.count}',
      );
    }
  }

  Future<void> _shutdown() async {
    _trace('shutdown-input', 'START');
    try {
      await _input?.dispose();
    } catch (_) {
      // Evidence files stay behind for inspection; shutdown must still run.
    }
    _trace('shutdown-input', 'DONE');
    try {
      await _container?.read(presentationProvider.notifier).flush();
    } catch (_) {
      // Preference writes are recorded by the journey; shutdown still runs.
    }
    try {
      await _container?.read(runtimeProvider.notifier).shutdown();
    } catch (_) {
      // A rejected native session must not hide the journey record.
    }
    _trace('shutdown-runtime', 'DONE');
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
    _trace('probe-shutdown', 'START');
    try {
      await gateway.shutdown();
    } catch (_) {}
    _trace('probe-shutdown', 'DONE');
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
      // Settings now owns source management: open the dialog, pick the
      // scripted folder, then close the dialog before watching the real scan.
      await _tapKey('sidebar-settings');
      await _waitForElement(
        'settings-category-2',
        reason: 'the settings dialog did not offer the photos category',
      );
      await _tapKey('settings-category-2');
      await _waitForElement(
        'add-folder',
        reason: 'the settings dialog did not offer add-folder',
      );
      await _tapKey('add-folder');
      await _key('Escape');
      await _waitFor(
        () => _elementByKey(const ValueKey('add-folder')) == null,
        reason: 'Escape did not close the settings dialog',
      );
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
      // Reopen must pin the library provision leaves behind, not the empty
      // one library-open observed before the scan.
      facts['opened_count'] = state.info!.count;
      facts['opened_revision'] = state.info!.revision;
      final tiles = _photoTileElements();
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
    await _step('viewer-metadata-is-real', () async {
      final photo = _state.pages[0]!.first;
      await _tapKey('viewer-details');
      await _waitFor(
        () => _panelTexts().contains(photo.path),
        reason: 'the details panel does not show the real source path',
      );
      final texts = _panelTexts();
      facts['details'] = texts;
      if (!texts.contains('${photo.sizeBytes} B')) {
        throw JourneyFailure('details panel is missing the real file size');
      }
      if (photo.width != null &&
          !texts.contains('${photo.width} × ${photo.height}')) {
        throw JourneyFailure('details panel is missing the real dimensions');
      }
      // The panel slides in over ~220ms; wait until it rests at its final
      // position so the real pointer tap aims at the live close control.
      Offset? previous;
      await _waitFor(() {
        final render = _elementByKey(const ValueKey('viewer-details-panel'))
            ?.findRenderObject();
        if (render is! RenderBox || !render.hasSize) return false;
        final position = render.localToGlobal(Offset.zero);
        final stable = previous != null && (position - previous!).distance < .5;
        previous = position;
        return stable;
      }, reason: 'the details panel never came to rest');
      await _tapKey('viewer-details-close');
      await _waitFor(
        () => _elementByKey(const ValueKey('viewer-details-panel')) == null,
        reason: 'the details panel did not close',
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
      if (_photoTileElements().isEmpty) {
        throw JourneyFailure(
          'the grid did not return after closing the viewer',
        );
      }
    });
    await _step('favorites-filter', () async {
      await _tapKey('sidebar-favorites');
      await _waitFor(
        () => _state.favoritesOnly && !_state.loading,
        reason: 'the favorites album did not activate',
      );
      facts['favorites_filter_total'] = _state.total;
      if (_state.total != 1) {
        throw JourneyFailure('favorites filter returned ${_state.total} items');
      }
      await _screenshot('03-favorites-filter');
      await _tapKey('sidebar-photos');
      await _waitFor(
        () => !_state.favoritesOnly && _state.total > 1,
        reason: 'leaving the favorites album did not restore the library',
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
      await _key('Escape');
      await _waitForElement(
        'library-header-count',
        reason: 'the library header did not render after clearing search',
      );
    });
    await _step('library-summary-text', () async {
      final text = _textOf(const ValueKey('library-header-count'));
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
      await _tapKey('sidebar-favorites');
      await _waitFor(
        () => _state.favoritesOnly && _state.total == 1,
        reason: 'the favorites album did not restore the marked photo',
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

  // ------------------------------------------------------------------- inputs

  Future<void> _tapKey(String keyValue) async {
    final element = await _waitForElement(
      keyValue,
      reason: 'widget $keyValue is not mounted',
    );
    await _waitForStableRect(element, keyValue);
    final position = _centerOf(element, keyValue);
    _trace('tap', 'SEND', '$keyValue at ${position.dx},${position.dy}');
    await _input!.tap(position, _devicePixelRatio);
    _trace('tap', 'ACK', keyValue);
    await _settle();
  }

  Future<void> _key(String keyName) async {
    _trace('key', 'SEND', keyName);
    await _input!.key(keyName);
    _trace('key', 'ACK', keyName);
    await _settle();
  }

  Future<void> _type(String text) async {
    _trace('type', 'SEND', '$text (${text.length} characters)');
    await _input!.type(text);
    _trace('type', 'ACK', text);
    await _settle();
  }

  Future<void> _settle() async {
    for (var index = 0; index < 2; index += 1) {
      // A quiet window may never schedule a frame on its own; ask for one and
      // bound the wait so a stalled renderer is reported instead of hanging.
      SchedulerBinding.instance.scheduleFrame();
      var stalled = false;
      await SchedulerBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          stalled = true;
        },
      );
      if (stalled) _trace('settle', 'STALL', 'no frame within 10s');
    }
  }

  /// Dialog and panel entrances translate their subtree, and a closing route
  /// keeps its barrier over the window for a few frames. Wait until the rect
  /// stops moving and the control is the topmost hit at its centre, so neither
  /// a moving target nor a dismissed barrier swallows the click.
  Future<void> _waitForStableRect(Element element, String label) async {
    Rect? previous;
    await _waitFor(
      () {
        final rect = _uxRectOf(element);
        final render = element.findRenderObject();
        if (rect == null || render is! RenderBox || !render.attached) {
          return false;
        }
        final result = HitTestResult();
        WidgetsBinding.instance.hitTestInView(
          result,
          rect.center,
          View.of(element).viewId,
        );
        if (!result.path.any((entry) => identical(entry.target, render))) {
          previous = null;
          return false;
        }
        final stable =
            previous != null && (rect.center - previous!.center).distance < .5;
        previous = rect;
        return stable;
      },
      reason: 'widget $label never came to rest',
      timeout: const Duration(seconds: 3),
    );
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
      await SchedulerBinding.instance.endOfFrame;
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
      facts['screenshot_$name'] = {
        'file': file.uri.pathSegments.last,
        'width': image.width,
        'height': image.height,
      };
      image.dispose();
    });
  }

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
    _trace(id, 'START');
    try {
      await body();
      started.stop();
      steps.add({
        'id': id,
        'status': 'PASS',
        'ms': started.elapsedMilliseconds,
      });
      _trace(id, 'PASS', '${started.elapsedMilliseconds}ms');
    } catch (error) {
      started.stop();
      steps.add({
        'id': id,
        'status': 'FAIL',
        'ms': started.elapsedMilliseconds,
        'detail': error is JourneyFailure ? error.message : '$error',
      });
      _trace(id, 'FAIL', error is JourneyFailure ? error.message : '$error');
      rethrow;
    }
  }

  /// Progress lines keep a stalled journey diagnosable: the JSON record is only
  /// written on exit, so a hang would otherwise leave an empty log. The copy in
  /// the evidence directory is written synchronously because a wedged isolate
  /// never flushes the buffered stdout sink. Stdout writes must never flush per
  /// line: a flush binds the sink, and the next write would then throw.
  void _trace(String id, String status, [Object? detail]) {
    final line =
        '${jsonEncode({'id': id, 'status': status, 'at': DateTime.now().toUtc().toIso8601String(), if (detail != null) 'detail': '$detail'})}\n';
    final target = _traceFile;
    if (target != null) {
      target.writeAsStringSync(line, mode: FileMode.append, flush: true);
    }
    try {
      stdout.write('$_stepPrefix$line');
    } catch (_) {
      // Instrumentation must never fail the journey it observes.
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
    _trace('wait', 'TIMEOUT', '$reason after ${timeout.inSeconds}s');
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

  /// Photo tiles are keyed `photo-<media id>`. The window chrome owns keys
  /// that start with the same prefix, so a tile is only a key that carries a
  /// media id.
  List<Element> _photoTileElements() =>
      _elementsWithKeyPrefix('photo-').where((element) {
        final key = element.widget.key;
        return key is ValueKey<String> &&
            RegExp(
              r'^photo-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
            ).hasMatch(key.value);
      }).toList();

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

  /// Reads the first text rendered inside a keyed control, e.g. a TextButton.
  String? _textWithin(Key key) {
    final root = _elementByKey(key);
    if (root == null) return null;
    String? text;
    void visit(Element element) {
      if (text != null) return;
      final widget = element.widget;
      if (widget is Text && widget.data != null) {
        text = widget.data;
        return;
      }
      element.visitChildren(visit);
    }

    visit(root);
    return text;
  }

  List<String> _panelTexts() {
    final panel = _elementByKey(const ValueKey('viewer-details-panel'));
    if (panel == null) return const [];
    final texts = <String>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Text && widget.data != null) texts.add(widget.data!);
      if (widget is SelectableText && widget.data != null) {
        texts.add(widget.data!);
      }
      element.visitChildren(visit);
    }

    visit(panel);
    return texts;
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
