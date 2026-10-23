import 'thumbnail_image.dart';
import '../services/thumbnail_pipeline.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'backdrop_viewport.dart';
import 'cloud_sync_controller.dart';
import 'glass_dialog.dart';
import 'glass_surface.dart';
import 'glass_theme.dart';
import 'library_activity_progress.dart';
import 'local_album_actions.dart';
import 'local_library_controller.dart';
import 'local_photo_viewer.dart';
import 'mode_selector.dart';
import 'photos_grid.dart';
import 'presentation_preferences.dart';
import 'runtime_controller.dart';
import 'strings.dart';

/// An unframed heading with independent circular actions above the photo grid.
/// Date sections stay quiet; the short grouping lens floats over the photos.
class LocalLibraryPane extends ConsumerStatefulWidget {
  const LocalLibraryPane({
    super.key,
    this.onOpenSettings,
    this.onRequestSearch,
    this.onBack,
    this.trashMode = false,
    this.searchMode = false,
    this.searchDetail = false,
    this.onCloseSearch,
    this.mobile = false,
    this.groupMode,
    this.searchRequest = 0,
    this.closeSearchRequest = 0,
    this.onSearchVisibilityChanged,
  });

  /// Supplied by the shell once Settings owns source management; null keeps
  /// the empty-state button honestly disabled.
  final VoidCallback? onOpenSettings;

  /// Asks the shell to switch to the dedicated search destination. When null
  /// the pane falls back to an inline search field.
  final VoidCallback? onRequestSearch;

  /// Returns from a phone album detail to the albums page. Desktop keeps the
  /// sidebar and leaves this null.
  final VoidCallback? onBack;
  final bool trashMode;
  final bool searchMode;
  final bool searchDetail;
  final VoidCallback? onCloseSearch;

  /// Phones draw edge to edge under a floating bottom bar instead of the
  /// desktop workspace; only presentation changes, the query is shared.
  final bool mobile;

  /// The phone shell owns its single cycling mode button.
  final GroupMode? groupMode;

  /// Monotonic counters let the mobile shell open or close the inline search
  /// without exposing the pane's private state.
  final int searchRequest;
  final int closeSearchRequest;
  final ValueChanged<bool>? onSearchVisibilityChanged;

  @override
  ConsumerState<LocalLibraryPane> createState() => _LocalLibraryPaneState();
}

class _LocalLibraryPaneState extends ConsumerState<LocalLibraryPane> {
  double get _headerExtent =>
      _libraryHeaderHeight(context, mobile: widget.mobile) +
      ((_selectionMode || widget.trashMode) ? 52 : 0) +
      ((_searchOpen || widget.searchMode)
          ? _librarySearchHeight(context, widget.trashMode)
          : 0);
  int _prewarmSizeClass = 512;
  final _scroll = ScrollController();
  ThumbnailPool? _decodedPool;
  Timer? _decodedPrefetchTimer;
  int _decodedPrefetchGeneration = 0;
  final _search = TextEditingController();
  final _scheduledPages = <int>{};
  late final FocusNode _searchFocus = FocusNode(onKeyEvent: _onSearchKey);
  int _epoch = -1;
  bool _searchOpen = false;
  GroupMode _mode = GroupMode.day;
  bool _selectionMode = false;
  bool _choosingCover = false, _coverSaving = false;
  final _selected = <String>{};
  final _selectionSnapshots = <String, LocalPhoto>{};
  bool _selectingAll = false;
  bool _overviewOpen = false;
  bool _viewerOpening = false;
  final _scrollPositions = <String, double>{};
  String? _queryIdentity;
  double? _pendingOffset;
  int? _pendingRank;
  int _visibleRank = 0, _renderedRevision = -1;
  double _withinRow = 0, _anchorStride = 1, _gridWidth = 0;
  List<_GridSectionGeometry> _geometry = [];
  void _changeMode(GroupMode value) {
    if (value == _mode) return;
    _captureAnchor();
    setState(() {
      _pendingRank = _visibleRank;
      _mode = value;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _trackBackdrop();
    });
  }

  void _captureAnchor() {
    if (!_scroll.hasClients || _geometry.isEmpty) return;
    final y = _scroll.positions.last.pixels + _headerExtent;
    var group = _geometry.first;
    for (final candidate in _geometry) {
      if (candidate.top > y) break;
      group = candidate;
    }
    final row = ((y - group.top - group.header) / group.stride).floor().clamp(
      0,
      (group.count / group.columns).ceil() - 1,
    );
    _visibleRank = (group.start + row * group.columns).clamp(
      group.start,
      group.start + group.count - 1,
    );
    _withinRow = y - (group.top + group.header + row * group.stride);
    _anchorStride = group.stride;
    ref.read(localLibraryProvider.notifier).noteViewport(_visibleRank);
    final gateway = ref.read(coreGatewayProvider);
    if (gateway is LocalLibraryGateway) {
      ThumbnailPool.forGateway(gateway as LocalLibraryGateway).viewport(
        ref.read(localLibraryProvider).photoAt(_visibleRank)?.id,
        _prewarmSizeClass,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _mode = widget.groupMode ?? GroupMode.day;
    final gateway = ref.read(coreGatewayProvider);
    if (gateway is LocalLibraryGateway && gateway is ThumbnailPipelineGateway) {
      _decodedPool = ThumbnailPool.forGateway(gateway as LocalLibraryGateway);
      _decodedPool!.cacheReady.addListener(_queueDecodedPrefetch);
      _decodedPool!.epoch.addListener(_queueDecodedPrefetch);
    }
    _scroll.addListener(_nearEnd);
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
  }

  void _nearEnd() {
    _captureAnchor();
    _trackBackdrop();
    _queueDecodedPrefetch();
    if (_scroll.hasClients && _scroll.positions.last.extentAfter < 600) {
      unawaited(ref.read(localLibraryProvider.notifier).loadNext());
    }
  }

  void _queueDecodedPrefetch() {
    if (_decodedPool == null) return;
    _decodedPrefetchGeneration++;
    if (!mounted ||
        _geometry.isEmpty ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      _decodedPrefetchTimer?.cancel();
      _decodedPrefetchTimer = null;
      return;
    }
    _decodedPrefetchTimer ??= Timer(const Duration(milliseconds: 200), () {
      _decodedPrefetchTimer = null;
      unawaited(_prefetchDecoded(_decodedPrefetchGeneration));
    });
  }

  Future<void> _prefetchDecoded(int generation) async {
    final gateway = ref.read(coreGatewayProvider);
    if (gateway is! ThumbnailPipelineGateway ||
        _decodedPool == null ||
        _geometry.isEmpty) {
      return;
    }
    final library = ref.read(localLibraryProvider);
    if (library.loading || library.trashed) return;
    final group = _geometry.lastWhere(
      (g) => g.start <= _visibleRank,
      orElse: () => _geometry.first,
    );
    final side = group.stride - 8;
    final pixels = side * MediaQuery.devicePixelRatioOf(context);
    final target = thumbnailDecodeWidth(pixels);
    final rows =
        ((_scroll.hasClients ? _scroll.position.viewportDimension : 600) /
                group.stride)
            .ceil();
    final visible = rows * group.columns;
    final count = (visible * 2).clamp(1, 64);
    final candidates = <String, ({LocalPhoto photo, int size})>{};
    for (
      var rank = _visibleRank + visible;
      rank < _visibleRank + visible + count && rank < library.total;
      rank++
    ) {
      final photo = library.photoAt(rank);
      if (photo == null) continue;
      final size = thumbnailSizeClassForCover(pixels, photo);
      final path = _decodedPool!.cachedPath(photo, size);
      if (path != null &&
          ThumbnailImage.isRetained(
            ThumbnailImage.file(path, photo, width: target),
          )) {
        continue;
      }
      candidates['${photo.id}:${photo.contentVersion}:$size'] = (
        photo: photo,
        size: size,
      );
    }
    if (candidates.isEmpty) return;
    try {
      final paths = await (gateway as ThumbnailPipelineGateway)
          .thumbnailCommand({
            'op': 'thumbnailCachedPaths',
            'items': [
              for (final value in candidates.values)
                {
                  'id': value.photo.id,
                  'version': value.photo.contentVersion,
                  'size': value.size,
                },
            ],
          });
      if (paths is! List) return;
      for (final value in paths) {
        if (!mounted ||
            generation != _decodedPrefetchGeneration ||
            !(ModalRoute.of(context)?.isCurrent ?? true)) {
          return;
        }
        if (value is! Map || value['path'] is! String) continue;
        final candidate =
            candidates['${value['id']}:${value['version']}:${value['size']}'];
        if (candidate == null) continue;
        final path = value['path'] as String;
        var failed = false;
        await precacheImage(
          ThumbnailImage.file(
            path,
            candidate.photo,
            width: target,
            use: ThumbnailUse.background,
          ),
          context,
          onError: (_, _) => failed = true,
        );
        if (!mounted || generation != _decodedPrefetchGeneration) return;
        if (!failed) {
          _decodedPool!.rememberCached(candidate.photo, candidate.size, path);
        } else {
          await (gateway as ThumbnailPipelineGateway).thumbnailCommand({
            'op': 'thumbnailInvalidate',
            'id': candidate.photo.id,
            'path': path,
            'version': candidate.photo.contentVersion,
            'size': candidate.size,
          });
          _decodedPool!.activity.value++;
        }
        // At most one decoded lookahead image is in flight, with a frame-sized
        // yield. No original is decoded or generated by this prefetch path.
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    } catch (_) {
      /* Lookahead never interrupts foreground browsing. */
    }
  }

  void _trackBackdrop() {
    if (!ref.read(presentationProvider).followScroll) return;
    if (!_scroll.hasClients ||
        _geometry.isEmpty ||
        !mounted ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    final position = _scroll.positions.last;
    final library = ref.read(localLibraryProvider);
    if (library.trashed || library.extent == 0) return;
    int? rank;
    if (position.pixels > 1) {
      final y =
          position.pixels + (_headerExtent + position.viewportDimension) / 2;
      var group = _geometry.first;
      for (final candidate in _geometry) {
        if (candidate.top > y) break;
        group = candidate;
      }
      final row = ((y - group.top - group.header) / group.stride).floor().clamp(
        0,
        (group.count / group.columns).ceil() - 1,
      );
      final index = (row * group.columns + group.columns ~/ 2).clamp(
        0,
        group.count - 1,
      );
      rank = group.items == null
          ? group.start + index
          : group.items![index].index;
    }
    ref
        .read(backdropViewportProvider.notifier)
        .track(queryEpoch: library.queryEpoch, rank: rank);
  }

  /// Lazily (re)request the pages around a tile that is actually being built,
  /// i.e. visible or within the viewport cache extent. The one-page lookahead
  /// fills evicted holes adjacent to visible content and chains inward as the
  /// reloaded tiles rebuild, without ever touching the whole extent per build.
  void _ensureNear(int index) {
    final page = index ~/ LocalLibraryController.pageSize;
    for (final candidate in [page - 1, page, page + 1]) {
      if (candidate < 0 || !_scheduledPages.add(candidate)) continue;
      scheduleMicrotask(() async {
        if (!mounted) return;
        await ref.read(localLibraryProvider.notifier).ensurePage(candidate);
        if (!mounted) return;
        final state = ref.read(localLibraryProvider);
        if (state.pages.containsKey(candidate)) {
          // Loaded: drop the marker so a later eviction can request again.
          _scheduledPages.remove(candidate);
        } else if (state.problem == null) {
          // No-op (e.g. no cursor yet): allow a later build to retry.
          _scheduledPages.remove(candidate);
        }
        // A failed load keeps the marker: never retry-loop a broken page.
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _decodedPrefetchGeneration++;
    _decodedPrefetchTimer?.cancel();
    _decodedPool?.cacheReady.removeListener(_queueDecodedPrefetch);
    _decodedPool?.epoch.removeListener(_queueDecodedPrefetch);
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // The focused text field consumes Escape via the default text-editing
  // shortcut before focus handlers see it, so close the search destination at
  // the hardware boundary while its route is still the visible one.
  bool _onGlobalKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        (_choosingCover || _selectionMode || widget.searchMode) &&
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? true)) {
      if (_choosingCover) {
        _cancelCover();
      } else if (_selectionMode) {
        _exitSelection();
      } else {
        _closeSearch();
      }
      return true;
    }
    return false;
  }

  @override
  void didUpdateWidget(LocalLibraryPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.groupMode != null && widget.groupMode != oldWidget.groupMode) {
      _changeMode(widget.groupMode!);
    }
    if (widget.searchMode && !oldWidget.searchMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
    if (widget.closeSearchRequest != oldWidget.closeSearchRequest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _closeSearch();
      });
    }
    if (widget.searchRequest != oldWidget.searchRequest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_searchOpen) _openSearch();
      });
    }
  }

  KeyEventResult _onSearchKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _closeSearch();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _openSearch() {
    final request = widget.onRequestSearch;
    if (request != null) {
      request();
      return;
    }
    setState(() {
      _searchOpen = true;
      _searchFocus.requestFocus();
    });
    widget.onSearchVisibilityChanged?.call(true);
  }

  void _closeSearch() {
    if (!mounted) return;
    // Leaving a search must not leave an invisible filter behind.
    ref.read(localLibraryProvider.notifier).clearSearch();
    if (widget.searchMode) {
      widget.onCloseSearch?.call();
      return;
    }
    if (_searchOpen) setState(() => _searchOpen = false);
    widget.onSearchVisibilityChanged?.call(false);
  }

  void _exitSelection() {
    if (!_selectionMode && _selected.isEmpty) return;
    setState(() {
      _selectionMode = false;
      _selected.clear();
      _selectionSnapshots.clear();
    });
  }

  void _startSelection() => setState(() {
    _choosingCover = false;
    _selectionMode = true;
    _selected.clear();
    _selectionSnapshots.clear();
  });

  void _chooseCover() {
    if (ref.read(localLibraryProvider).folder == null) return;
    _exitSelection();
    setState(() => _choosingCover = true);
  }

  void _cancelCover() => setState(() => _choosingCover = false);

  Future<void> _showSort() async {
    // Let the menu finish its current frame before pushing a dialog route.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final strings = AppStrings.of(context);
    final order = ref.read(presentationProvider).order;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text(strings.pick('排序', 'Sort')),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (value, label) in [
                ('date_desc', strings.pick('日期：从新到旧', 'Date: newest first')),
                ('date_asc', strings.pick('日期：从旧到新', 'Date: oldest first')),
                ('name_asc', strings.pick('名称：升序', 'Name: ascending')),
                ('name_desc', strings.pick('名称：降序', 'Name: descending')),
              ])
                ListTile(
                  key: ValueKey('library-sort-$value'),
                  selected: order == value,
                  leading: Icon(order == value ? Icons.check : Icons.sort),
                  title: Text(label),
                  onTap: () => Navigator.of(context).pop(value),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('library-sort-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(strings.cancel),
          ),
        ],
      ),
    );
    if (mounted && chosen != null) {
      ref.read(presentationProvider.notifier).setOrder(chosen);
    }
  }

  void _enterSelection(String id) => setState(() {
    _selectionMode = true;
    _selected.add(id);
    _rememberSelection(id);
  });

  void _toggleSelection(String id) => setState(() {
    _selectionMode = true;
    if (!_selected.remove(id)) {
      _selected.add(id);
      _rememberSelection(id);
    } else {
      _selectionSnapshots.remove(id);
    }
  });

  void _rememberSelection(String id) {
    final state = ref.read(localLibraryProvider);
    final index = state.indexOf(id);
    if (index != null) {
      final photo = state.photoAt(index);
      if (photo != null) _selectionSnapshots[id] = photo;
    }
  }

  Future<void> _selectAll(LibraryViewState state) async {
    if (_selectingAll) return;
    _selectingAll = true;
    final epoch = state.queryEpoch;
    try {
      final photos = await ref
          .read(localLibraryProvider.notifier)
          .selectQuery();
      if (!mounted || ref.read(localLibraryProvider).queryEpoch != epoch) {
        return;
      }
      setState(() {
        _selectionMode = true;
        _selected.clear();
        _selectionSnapshots.clear();
        for (final photo in photos) {
          _selected.add(photo.id);
          _selectionSnapshots[photo.id] = photo;
        }
      });
      if (state.total > photos.length && photos.length == 2000) {
        _notify(
          AppStrings.of(context).pick(
            '已选择前 2,000 项（全选上限）',
            'Selected the first 2,000 items (selection limit)',
          ),
        );
      }
    } catch (_) {
      if (mounted) _notify(AppStrings.of(context).actionFailed);
    } finally {
      _selectingAll = false;
    }
  }

  void _deselectAll() => setState(() {
    _selected.clear();
    _selectionSnapshots.clear();
  });
  bool _allLoadedSelected(LibraryViewState state) =>
      _selected.isNotEmpty &&
      _selected.length >= (state.total > 2000 ? 2000 : state.total);
  List<LocalPhoto> _selectedPhotos(LibraryViewState state) => [
    for (final id in _selected)
      if (state.indexOf(id) case final int index)
        state.photoAt(index)!
      else if (_selectionSnapshots[id] case final LocalPhoto photo)
        photo,
  ];

  /// Smart heart: all favorited → unfavorite all; otherwise favorite every
  /// not-yet-favorited photo (a mixed set resolves toward favorited).
  void _batchFavorite(LibraryViewState state) {
    final controller = ref.read(localLibraryProvider.notifier);
    final photos = _selectedPhotos(state);
    if (photos.isEmpty) return;
    final allFavorite = photos.every((photo) => photo.favorite);
    for (final photo in photos) {
      if (allFavorite || !photo.favorite) {
        unawaited(controller.setFavorite(photo));
      }
    }
  }

  void _promptCloudSignIn() {
    final strings = AppStrings.of(context);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(strings.cloudSignedOut),
          behavior: SnackBarBehavior.floating,
          action: widget.onOpenSettings == null
              ? null
              : SnackBarAction(
                  label: strings.openSettings,
                  onPressed: widget.onOpenSettings!,
                ),
        ),
      );
  }

  Future<void> _batchUploadCloud() async {
    final strings = AppStrings.of(context);
    final cloud = ref.read(cloudSyncProvider);
    if (!cloud.loggedIn) {
      _promptCloudSignIn();
      return;
    }
    final state = ref.read(localLibraryProvider);
    final ids = [
      for (final id in _selectedIds(state))
        if (!cloud.isBound(id)) id,
    ];
    if (ids.isEmpty) {
      _notify(strings.cloudUploadNone);
      return;
    }
    setState(() {
      _selectionMode = false;
      _selected.clear();
      _selectionSnapshots.clear();
    });
    final controller = ref.read(cloudSyncProvider.notifier);
    final result = await controller.queueUpload(ids);
    if (!mounted) return;
    if (result == null) {
      _notify(
        strings.cloudError(ref.read(cloudSyncProvider).errorCode ?? 'Internal'),
      );
      return;
    }
    _notify(
      strings.cloudUploadResult(result.queued, result.skipped, result.rejected),
    );
    await controller.syncNow();
  }

  Future<void> _uploadToCloud(LocalPhoto photo) async {
    final strings = AppStrings.of(context);
    final cloud = ref.read(cloudSyncProvider);
    if (!cloud.loggedIn) {
      _promptCloudSignIn();
      return;
    }
    if (cloud.isBound(photo.id)) {
      _notify(strings.cloudUploadNone);
      return;
    }
    final controller = ref.read(cloudSyncProvider.notifier);
    final result = await controller.queueUpload([photo.id]);
    if (!mounted) return;
    if (result == null) {
      _notify(
        strings.cloudError(ref.read(cloudSyncProvider).errorCode ?? 'Internal'),
      );
      return;
    }
    _notify(
      strings.cloudUploadResult(result.queued, result.skipped, result.rejected),
    );
    await controller.syncNow();
  }

  // --- Destructive / structural batch operations -------------------------

  void _notify(String message, {Future<void> Function()? undo}) {
    if (!mounted) return;
    // A full-width toast sits over the sidebar's Trash row; keep it centred so
    // side navigation stays clickable while Undo is offered.
    final width = MediaQuery.sizeOf(context).width;
    final side = width < 392 ? 16.0 : (width - 360) / 2;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          persist: false,
          margin: EdgeInsets.fromLTRB(side, 8, side, 84),
          duration: Duration(seconds: undo == null ? 3 : 6),
          action: undo == null
              ? null
              : SnackBarAction(
                  label: AppStrings.of(context).pick('撤销', 'Undo'),
                  onPressed: () => unawaited(
                    undo().catchError((Object error) {
                      if (mounted) _notify(AppStrings.of(context).actionFailed);
                    }),
                  ),
                ),
        ),
      );
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final strings = AppStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('confirm-action'),
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _runBatch(
    Future<int> Function() operation,
    String Function(int) message, {
    Future<void> Function()? undo,
  }) async {
    final strings = AppStrings.of(context);
    setState(() {
      _selectionMode = false;
      _selected.clear();
      _selectionSnapshots.clear();
    });
    try {
      final count = await operation();
      _notify(message(count), undo: undo);
    } catch (_) {
      _notify(strings.actionFailed);
    }
  }

  String _folderLabel(String path) {
    final trimmed = path.replaceAll(RegExp(r'/+$'), '');
    final name = trimmed.split('/').where((p) => p.isNotEmpty).lastOrNull;
    return name == null || name.isEmpty ? path : name;
  }

  List<String> _selectedIds(LibraryViewState state) =>
      _selected.toList(growable: false);

  Future<void> _batchTrash() async {
    final state = ref.read(localLibraryProvider);
    final ids = _selectedIds(state);
    if (ids.isEmpty) return;
    final strings = AppStrings.of(context);
    final ok = await _confirm(
      title: strings.confirmTrashTitle(ids.length),
      body: strings.confirmTrashBody,
      confirmLabel: strings.moveToTrash,
      danger: true,
    );
    if (!ok) return;
    await _runBatch(
      () => ref.read(localLibraryProvider.notifier).trashPhotos(ids),
      strings.trashedCount,
      undo: () async {
        await ref.read(localLibraryProvider.notifier).restorePhotos(ids);
      },
    );
  }

  Future<void> _batchRestore() async {
    final state = ref.read(localLibraryProvider);
    final ids = _selectedIds(state);
    if (ids.isEmpty) return;
    final strings = AppStrings.of(context);
    await _runBatch(
      () => ref.read(localLibraryProvider.notifier).restorePhotos(ids),
      strings.restoredCount,
    );
  }

  Future<void> _batchPurge() async {
    final state = ref.read(localLibraryProvider);
    final ids = _selectedIds(state);
    if (ids.isEmpty) return;
    final strings = AppStrings.of(context);
    final ok = await _confirm(
      title: strings.confirmPurgeTitle(ids.length),
      body: strings.confirmPurgeBody,
      confirmLabel: strings.deletePermanently,
      danger: true,
    );
    if (!ok) return;
    await _runBatch(
      () => ref.read(localLibraryProvider.notifier).purgePhotos(ids),
      strings.purgedCount,
    );
  }

  Future<void> _emptyTrash() async {
    final strings = AppStrings.of(context);
    final ok = await _confirm(
      title: strings.confirmEmptyTrashTitle,
      body: strings.confirmEmptyTrashBody,
      confirmLabel: strings.emptyTrash,
      danger: true,
    );
    if (!ok) return;
    await _runBatch(
      ref.read(localLibraryProvider.notifier).emptyTrash,
      strings.purgedCount,
    );
  }

  Future<void> _addToAlbum({required bool move}) async {
    final state = ref.read(localLibraryProvider);
    final ids = _selectedIds(state);
    if (ids.isEmpty) return;
    final strings = AppStrings.of(context);
    final target = await _pickAlbumTarget(state.albums);
    if (target == null || !mounted) return;
    await _runBatch(
      () => ref
          .read(localLibraryProvider.notifier)
          .addPhotosToAlbum(ids, target, moveFiles: move),
      strings.addedToAlbumCount,
    );
  }

  Future<String?> _pickAlbumTarget(List<LocalAlbum> albums) async {
    final selection = await showDialog<String>(
      context: context,
      builder: (context) => _AlbumPickerDialog(albums: albums),
    );
    if (selection != _AlbumPickerDialog.newAlbumSentinel) return selection;
    if (!mounted) return null;
    return createLocalAlbum(context, ref);
  }

  Future<void> _trashOne(LocalPhoto photo) async {
    final strings = AppStrings.of(context);
    final ok = await _confirm(
      title: strings.confirmTrashTitle(1),
      body: strings.confirmTrashBody,
      confirmLabel: strings.moveToTrash,
      danger: true,
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(localLibraryProvider.notifier).trashPhotos([photo.id]);
      _notify(
        strings.trashedCount(1),
        undo: () async {
          await ref.read(localLibraryProvider.notifier).restorePhotos([
            photo.id,
          ]);
        },
      );
    } catch (_) {
      _notify(strings.actionFailed);
    }
  }

  Future<void> _addOneToAlbum(LocalPhoto photo, {required bool move}) async {
    final strings = AppStrings.of(context);
    final target = await _pickAlbumTarget(
      ref.read(localLibraryProvider).albums,
    );
    if (target == null || !mounted) return;
    try {
      await ref
          .read(localLibraryProvider.notifier)
          .addPhotosToAlbum([photo.id], target, moveFiles: move);
      _notify(strings.addedToAlbumCount(1));
    } catch (_) {
      _notify(strings.actionFailed);
    }
  }

  Future<void> _restoreOne(LocalPhoto photo) async {
    try {
      await ref.read(localLibraryProvider.notifier).restorePhotos([photo.id]);
      if (mounted) _notify(AppStrings.of(context).restoredCount(1));
    } catch (_) {
      if (mounted) _notify(AppStrings.of(context).actionFailed);
    }
  }

  Future<void> _purgeOne(LocalPhoto photo) async {
    final strings = AppStrings.of(context);
    if (!await _confirm(
      title: strings.confirmPurgeTitle(1),
      body: strings.confirmPurgeBody,
      confirmLabel: strings.deletePermanently,
      danger: true,
    )) {
      return;
    }
    try {
      await ref.read(localLibraryProvider.notifier).purgePhotos([photo.id]);
      if (mounted) _notify(strings.purgedCount(1));
    } catch (_) {
      if (mounted) _notify(strings.actionFailed);
    }
  }

  Future<void> _exportPhotos(List<String> ids) async {
    final picker = ref.read(sourcePickerProvider);
    if (picker == null || ids.isEmpty) return;
    final directory = await picker.chooseDirectory();
    if (directory == null) return;
    try {
      final count = await ref.read(localLibraryProvider.notifier).localCommand({
        'op': 'export',
        'ids': ids,
        'directory': directory,
      }) as int?;
      if (mounted) {
        _notify(
          AppStrings.of(context)
              .pick('已导出 ${count ?? 0} 个副本', 'Exported ${count ?? 0} copies'),
        );
      }
    } catch (_) {
      if (mounted) _notify(AppStrings.of(context).actionFailed);
    }
  }

  Future<void> _setCover(LocalPhoto photo) async {
    if (_coverSaving) return;
    final folder = ref.read(localLibraryProvider).folder ?? photo.parent;
    final epoch = ref.read(localLibraryProvider).queryEpoch;
    setState(() => _coverSaving = true);
    try {
      final controller = ref.read(localLibraryProvider.notifier);
      await controller.localCommand({
        'op': 'albumCover',
        'folder': folder,
        'id': photo.id,
      });
      await controller.refresh(force: true);
      if (mounted && ref.read(localLibraryProvider).queryEpoch == epoch) {
        ref.read(backdropViewportProvider.notifier).reset();
        setState(() => _choosingCover = false);
        _notify(AppStrings.of(context).pick('相册封面已更新', 'Album cover updated'));
      }
    } catch (_) {
      if (mounted) _notify(AppStrings.of(context).actionFailed);
    } finally {
      if (mounted) setState(() => _coverSaving = false);
    }
  }

  Future<void> _openViewer(LocalPhoto photo, int rank) async {
    if (_viewerOpening) return;
    _viewerOpening = true;
    final controller = ref.read(localLibraryProvider.notifier);
    final oldKind = ref.read(localLibraryProvider).mediaKind;
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final scoped = widget.searchMode && oldKind != photo.mediaKind;
    try {
      if (scoped) {
        controller.setMediaKind(photo.mediaKind);
        await controller.refresh(force: true);
        rank =
            (await controller.localCommand({
              'op': 'rank',
              'filter': controller.filterFor(ref.read(localLibraryProvider)),
              'id': photo.id,
            }) as int?) ??
            ref.read(localLibraryProvider).indexOf(photo.id) ??
            0;
      }
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => LocalPhotoViewer(photo: photo, initialIndex: rank),
        ),
      );
    } finally {
      _viewerOpening = false;
      if (mounted && scoped) {
        controller.setMediaKind(oldKind);
        await controller.refresh(force: true);
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _scroll.hasClients) {
              _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
            }
          });
        }
      }
    }
  }

  Future<void> _moreSearch(String kind) async {
    final controller = ref.read(localLibraryProvider.notifier);
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    controller.setMediaKind(kind);
    await controller.refresh(force: true);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            const LocalLibraryPane(searchMode: true, searchDetail: true),
      ),
    );
    if (!mounted) return;
    controller.setMediaKind(null);
    await controller.refresh(force: true);
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
        }
      });
    }
  }

  Future<void> _renamePhoto(LocalPhoto photo) async {
    final strings = AppStrings.of(context);
    var name = photo.name;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text(strings.renamePhoto),
        content: TextFormField(
          key: const ValueKey('rename-field'),
          initialValue: photo.name,
          autofocus: true,
          decoration: InputDecoration(hintText: photo.name),
          onChanged: (value) => name = value.trim(),
          onFieldSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('rename-confirm'),
            onPressed: () => Navigator.of(context).pop(name),
            child: Text(strings.save),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || result == photo.name) return;
    try {
      await ref
          .read(localLibraryProvider.notifier)
          .renamePhoto(photo.id, result);
    } catch (_) {
      _notify(strings.actionFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(presentationProvider.select((value) => value.followScroll), (
      before,
      after,
    ) {
      if (before == false && after) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _trackBackdrop();
        });
      }
    });
    final strings = AppStrings.of(context);
    final preferences = ref.watch(presentationProvider);
    final runtime = ref.watch(runtimeProvider);
    if (runtime.phase != ConnectionPhase.ready) {
      // The runtime is an implementation detail: users see library loading and
      // a retry, never a "core" status they cannot act on.
      final failed =
          runtime.phase == ConnectionPhase.failed ||
          runtime.phase == ConnectionPhase.stopped;
      return _StatusPage(
        titleKey: const ValueKey('library-runtime'),
        title: failed ? strings.libraryFailed : strings.loadingLibrary,
        body: failed ? strings.libraryFailedBody : null,
        spinner: !failed,
        action: failed
            ? FilledButton.icon(
                key: const ValueKey('retry-runtime'),
                onPressed: () =>
                    ref.read(runtimeProvider.notifier).initialize(),
                icon: const Icon(Icons.refresh),
                label: Text(strings.retry),
              )
            : null,
      );
    }
    final state = ref.watch(localLibraryProvider);
    final controller = ref.read(localLibraryProvider.notifier);
    final gateway = ref.read(coreGatewayProvider) as LocalLibraryGateway;
    final queryKey =
        '${state.favoritesOnly}|${state.folder}|${state.mediaKind}|${state.trashed}|${state.search}|${state.searchScope}';
    if (_epoch != state.queryEpoch) {
      if (_queryIdentity != null && _scroll.hasClients) {
        _scrollPositions[_queryIdentity!] = _scroll.offset;
        while (_scrollPositions.length > 32) {
          _scrollPositions.remove(_scrollPositions.keys.first);
        }
      }
      _epoch = state.queryEpoch;
      _scheduledPages.clear();
      _selectionMode = false;
      _choosingCover = false;
      _selected.clear();
      _selectionSnapshots.clear();
      _pendingOffset = _scrollPositions[queryKey] ?? 0;
      _pendingRank = null;
      if (_search.text != state.search) _search.text = state.search;
    } else if (_renderedRevision >= 0 &&
        _renderedRevision != state.revision &&
        state.anchorRank != _visibleRank) {
      _pendingRank = state.anchorRank;
    }
    _queryIdentity = queryKey;
    _renderedRevision = state.revision;
    final hasContent = state.extent > 0 || state.hasNext;
    final title = widget.searchMode
        ? strings.search
        : widget.trashMode
        ? strings.trash
        : state.favoritesOnly
        ? strings.albumFavorites
        : state.folder != null
        ? _folderLabel(state.folder!)
        : state.mediaKind == 'image'
        ? strings.images
        : state.mediaKind == 'video'
        ? strings.videos
        : state.mediaKind == 'motion'
        ? strings.motionPhotos
        : strings.library;
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.mobile ? 0 : 20),
            child: _body(strings, state, controller, gateway, preferences),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: _headerExtent + 24,
          child: IgnorePointer(
            child: ListenableBuilder(
              listenable: _scroll,
              builder: (context, _) {
                final progress = _scroll.hasClients
                    ? (_scroll.positions.last.pixels / 48).clamp(0.0, 1.0)
                    : 0.0;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Theme.of(context).scaffoldBackgroundColor
                            .withValues(alpha: progress * .65),
                        Colors.transparent,
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        _Header(
          title: title,
          itemCount: state.loading ? null : state.extent,
          mobile: widget.mobile,
          onBack: widget.onBack,
          trashMode: widget.trashMode,
          searchMode: widget.searchMode,
          scope: state.searchScope,
          onScopeChanged: controller.setSearchScope,
          searchOpen: _searchOpen,
          searchController: _search,
          searchFocus: _searchFocus,
          onOpenSearch: _openSearch,
          onCloseSearch: _closeSearch,
          onSearchChanged: controller.setSearch,
          selectionMode: _selectionMode,
          selectionCount: _selected.length,
          allLoadedSelected: hasContent && _allLoadedSelected(state),
          onSelectAll: () => _selectAll(state),
          onDeselectAll: _deselectAll,
          onExitSelection: _exitSelection,
          onStartSelection: _startSelection,
          onChooseCover:
              state.folder != null &&
                  hasContent &&
                  !widget.trashMode &&
                  !widget.searchMode
              ? _chooseCover
              : null,
          onSort: _showSort,
          onOpenSettings: widget.onOpenSettings,
          hasContent: hasContent,
          choosingCover: _choosingCover,
          onCancelCover: _cancelCover,
          selectedPhotos: _selectionMode ? _selectedPhotos(state) : const [],
          onBatchFavorite: () => _batchFavorite(state),
          onBatchTrash: _batchTrash,
          onBatchExport: () => unawaited(_exportPhotos(_selected.toList())),
          onBatchRestore: _batchRestore,
          onBatchPurge: _batchPurge,
          onBatchAddToAlbum: (move) => _addToAlbum(move: move),
          onBatchUploadCloud: _batchUploadCloud,
          onEmptyTrash: _emptyTrash,
          emptyTrashEnabled: state.extent > 0 || state.hasNext,
          strings: strings,
        ),
        if (hasContent && !widget.searchMode && !widget.mobile)
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: ModeSelector(mode: _mode, onChanged: _changeMode),
            ),
          ),
      ],
    );
  }

  Widget _body(
    AppStrings strings,
    LibraryViewState state,
    LocalLibraryController controller,
    LocalLibraryGateway gateway,
    PresentationPreferences preferences,
  ) {
    final bindings = <ShortcutActivator, VoidCallback>{
      // A focused search field owns its own text editing shortcuts.
      if (!_searchOpen && !widget.searchMode)
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
            _selectAll(state),
      if (!_searchFocus.hasFocus)
        const SingleActivator(LogicalKeyboardKey.delete): () =>
            unawaited(widget.trashMode ? _batchPurge() : _batchTrash()),
      if (_selectionMode)
        const SingleActivator(LogicalKeyboardKey.escape): _exitSelection,
      if (_choosingCover)
        const SingleActivator(LogicalKeyboardKey.escape): _cancelCover,
      if (widget.searchMode && !_selectionMode && !_choosingCover)
        const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
    };
    return CallbackShortcuts(
      bindings: bindings,
      child: Focus(
        // Tab skips this wrapper, but it holds initial focus so Ctrl+A works
        // before any tile is focused; key events from tiles bubble up here.
        autofocus: true,
        skipTraversal: true,
        child: widget.mobile
            ? RefreshIndicator(
                key: const ValueKey('mobile-photos-refresh'),
                edgeOffset: _headerExtent,
                onRefresh: () => controller.refresh(force: true),
                child: _scrollBody(
                  strings,
                  state,
                  controller,
                  gateway,
                  preferences,
                ),
              )
            : _scrollBody(strings, state, controller, gateway, preferences),
      ),
    );
  }

  Widget _scrollBody(
    AppStrings strings,
    LibraryViewState state,
    LocalLibraryController controller,
    LocalLibraryGateway gateway,
    PresentationPreferences preferences,
  ) {
    final status = _statusPage(strings, state, controller);
    if (status != null) {
      return CustomScrollView(
        key: const ValueKey('local-photo-grid'),
        physics: widget.mobile ? const AlwaysScrollableScrollPhysics() : null,
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(child: SizedBox(height: _headerExtent)),
          SliverFillRemaining(hasScrollBody: false, child: status),
        ],
      );
    }
    final sections = widget.searchMode
        ? _searchSections(state, strings)
        : _sections(state);
    return NotificationListener<ScrollNotification>(
      onNotification: (event) {
        if (!widget.mobile &&
            event.metrics.pixels <= 0 &&
            event is OverscrollNotification &&
            event.overscroll < 0 &&
            !_overviewOpen) {
          setState(() => _overviewOpen = true);
        }
        if (event is ScrollUpdateNotification &&
            (event.scrollDelta ?? 0) > 0 &&
            _overviewOpen) {
          setState(() => _overviewOpen = false);
        }
        return false;
      },
      child: CustomScrollView(
        key: const ValueKey('local-photo-grid'),
        physics: widget.mobile ? const AlwaysScrollableScrollPhysics() : null,
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(child: SizedBox(height: _headerExtent)),
          SliverToBoxAdapter(
            child: AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              child: _overviewOpen || (state.scanning && state.scanVisible)
                  ? _overview(strings, state, controller)
                  : const SizedBox.shrink(),
            ),
          ),
          SliverLayoutBuilder(
            builder: (context, constraints) {
              final available = constraints.crossAxisExtent.clamp(
                1.0,
                double.infinity,
              );
              final columns = widget.mobile
                  ? mobileGridColumns(
                      widget.searchMode ? GroupMode.day : _mode,
                      preferences.dayColumns,
                    )
                  : _mode == GroupMode.day && !widget.searchMode
                  ? preferences.dayColumns
                  : (available /
                            gridMaxCrossAxisExtent(
                              widget.searchMode ? GroupMode.year : _mode,
                            ))
                        .ceil()
                        .clamp(1, 100);
              final spacing = widget.mobile
                  ? switch (_mode) {
                      GroupMode.year => 2.0,
                      GroupMode.month => 3.0,
                      GroupMode.day => 4.0,
                    }
                  : 8.0;
              final side = (available - spacing * (columns - 1)) / columns;
              // Keep the old Month/Day medium prewarm, while dense Year tiles
              // use Small. Foreground requests still choose by physical crop.
              _prewarmSizeClass = _mode == GroupMode.year ? 256 : 512;
              if (!widget.trashMode) {
                ThumbnailPool.forGateway(
                  gateway,
                ).viewport(state.photoAt(_visibleRank)?.id, _prewarmSizeClass);
              }
              final previewCounts = {
                for (final section in sections)
                  section: widget.searchMode && !widget.searchDetail
                      ? math.min(
                          section.totalCount ?? section.items.length,
                          columns * 2,
                        )
                      : section.totalCount ?? section.items.length,
              };
              final offsets = <int>[];
              var rows = 0;
              for (final section in sections) {
                offsets.add(rows);
                rows += 1 + (previewCounts[section]! / columns).ceil();
              }
              (PhotoSection, int) resolve(int row) {
                var low = 0, high = offsets.length;
                while (low + 1 < high) {
                  final mid = (low + high) ~/ 2;
                  if (offsets[mid] <= row) {
                    low = mid;
                  } else {
                    high = mid;
                  }
                }
                return (sections[low], row - offsets[low] - 1);
              }

              if (_gridWidth != 0 &&
                  (_gridWidth - available).abs() > 1 &&
                  _pendingOffset == null) {
                _captureAnchor();
                _pendingRank = _visibleRank;
              }
              _gridWidth = available;
              final header = MediaQuery.textScalerOf(context).scale(16) + 32;
              final layout = <_GridSectionGeometry>[];
              var top = _headerExtent;
              var fallbackRank = 0;
              for (final section in sections) {
                final count = previewCounts[section]!;
                if (count == 0) continue;
                layout.add(
                  _GridSectionGeometry(
                    top: top,
                    start:
                        section.startIndex ??
                        (section.items.isNotEmpty
                            ? section.items.first.index
                            : fallbackRank),
                    count: count,
                    columns: columns,
                    stride: side + spacing,
                    header: header,
                    items: section.startIndex == null ? section.items : null,
                  ),
                );
                top += header + (count / columns).ceil() * (side + spacing);
                fallbackRank += count;
              }
              _geometry = layout;
              _queueDecodedPrefetch();
              double? target = _pendingOffset;
              if (target == null && _pendingRank != null) {
                for (final group in layout) {
                  if (_pendingRank! >= group.start &&
                      _pendingRank! < group.start + group.count) {
                    target =
                        group.top +
                        group.header +
                        ((_pendingRank! - group.start) ~/ columns) *
                            (side + spacing) +
                        (_withinRow < 0
                            ? _withinRow
                            : _withinRow / _anchorStride * group.stride) -
                        _headerExtent;
                    break;
                  }
                }
              }
              if (target != null) {
                final destination = target;
                _pendingOffset = null;
                _pendingRank = null;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _scroll.hasClients) {
                    _scroll.jumpTo(
                      destination.clamp(0, _scroll.position.maxScrollExtent),
                    );
                    _captureAnchor();
                  }
                });
              }
              return SliverPadding(
                padding: EdgeInsets.only(
                  bottom: widget.mobile
                      ? 100 + MediaQuery.paddingOf(context).bottom
                      : 90,
                ),
                sliver: SliverVariedExtentList.builder(
                  itemCount: rows,
                  itemExtentBuilder: (row, _) =>
                      resolve(row).$2 < 0 ? header : side + spacing,
                  itemBuilder: (context, row) {
                    final (section, localRow) = resolve(row);
                    if (localRow < 0) {
                      return Padding(
                        padding: EdgeInsets.fromLTRB(
                          widget.mobile ? 16 : 4,
                          8,
                          widget.mobile ? 16 : 4,
                          8,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                section.label ??
                                    (widget.searchMode
                                        ? ''
                                        : sectionLabel(
                                            context,
                                            section,
                                            _mode,
                                          )),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 16,
                                    ),
                              ),
                            ),
                            if (widget.searchMode &&
                                !widget.searchDetail &&
                                (section.totalCount ?? section.items.length) >
                                    previewCounts[section]!)
                              TextButton(
                                onPressed: () => unawaited(
                                  _moreSearch(
                                    section.label == strings.videos
                                        ? 'video'
                                        : 'image',
                                  ),
                                ),
                                child: Text(strings.pick('更多', 'More')),
                              ),
                          ],
                        ),
                      );
                    }
                    return Padding(
                      padding: EdgeInsets.only(bottom: spacing),
                      child: Row(
                        children: [
                          for (var column = 0; column < columns; column++) ...[
                            if (column > 0) SizedBox(width: spacing),
                            Expanded(
                              child:
                                  localRow * columns + column >=
                                      previewCounts[section]!
                                  ? const SizedBox.shrink()
                                  : _gridTile(
                                      section,
                                      localRow * columns + column,
                                      state,
                                      controller,
                                      gateway,
                                    ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          ),
          if (!controller.indexed && (state.hasNext || state.loadingNext))
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: state.loadingNext
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          key: const ValueKey('load-next-page'),
                          onPressed: controller.loadNext,
                          child: Text(strings.loadMore),
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _gridTile(
    PhotoSection section,
    int tileIndex,
    LibraryViewState state,
    LocalLibraryController controller,
    LocalLibraryGateway gateway,
  ) {
    final rank = section.startIndex == null
        ? section.items[tileIndex].index
        : section.startIndex! + tileIndex;
    _ensureNear(rank);
    final photo = section.startIndex == null
        ? section.items[tileIndex].photo
        : state.photoAt(rank);
    if (photo == null) {
      return SizedBox(
        key: ValueKey('photo-placeholder-$rank'),
        child: const Center(child: Icon(Icons.photo_outlined)),
      );
    }
    final item = SectionItem(photo, rank);
    final cloudBound = ref.watch(cloudSyncProvider).isBound(item.photo.id);
    return PhotoTile(
      key: ValueKey('photo-${item.photo.id}'),
      photo: item.photo,
      gateway: gateway,
      radius: widget.mobile ? 4 : GlassTheme.photoRadius,
      compact: widget.mobile && !widget.searchMode && _mode != GroupMode.day,
      selected: _selected.contains(item.photo.id),
      multiSelect: _selectionMode,
      cloudBound: cloudBound,
      onOpen: () => unawaited(
        _choosingCover
            ? _setCover(item.photo)
            : _openViewer(item.photo, item.index),
      ),
      onExport: () => unawaited(_exportPhotos([item.photo.id])),
      onUploadToCloud: widget.trashMode || cloudBound
          ? null
          : () => unawaited(_uploadToCloud(item.photo)),
      onSetCover: widget.trashMode
          ? null
          : () => unawaited(_setCover(item.photo)),
      onSelectToggle: () => _toggleSelection(item.photo.id),
      onEnterSelection: () => _enterSelection(item.photo.id),
      onToggleFavorite: () => unawaited(controller.setFavorite(item.photo)),
      onShowDetails: () => showPhotoDetails(context, item.photo),
      onRename: widget.trashMode ? null : () => _renamePhoto(item.photo),
      onRestore: widget.trashMode
          ? () => unawaited(_restoreOne(item.photo))
          : null,
      onPurge: widget.trashMode ? () => unawaited(_purgeOne(item.photo)) : null,
      onMoveToTrash: widget.trashMode ? null : () => _trashOne(item.photo),
      onCopyToAlbum: widget.trashMode
          ? null
          : () => _addOneToAlbum(item.photo, move: false),
      onMoveToAlbum: widget.trashMode
          ? null
          : () => _addOneToAlbum(item.photo, move: true),
    );
  }

  /// Group the loaded paged window into date sections, newest bucket first.
  /// Never schedules loads across the whole extent: with a bounded DTO cache,
  /// eagerly requesting every missing page would evict and reload endlessly.
  /// Page loading is driven by [_ensureNear] from visible tiles instead.
  List<PhotoSection> _sections(LibraryViewState state) {
    if (state.groups.isNotEmpty) {
      final sections = <PhotoSection>[];
      var start = 0;
      for (final group in state.groups) {
        final date = DateTime.fromMillisecondsSinceEpoch(group.time);
        final bucket = bucketOf(date, _mode);
        if (sections.isNotEmpty && sections.last.bucket == bucket) {
          sections.last.totalCount = sections.last.totalCount! + group.count;
        } else {
          sections.add(
            PhotoSection(
              bucket: bucket,
              date: date,
              startIndex: start,
              totalCount: group.count,
            ),
          );
        }
        start += group.count;
      }
      return sections;
    }
    final grouped = <int, PhotoSection>{};
    for (var index = 0; index < state.extent; index += 1) {
      final photo = state.photoAt(index);
      if (photo == null) continue;
      // A loaded page can be evicted later; allow another request on return.
      _scheduledPages.remove(index ~/ LocalLibraryController.pageSize);
      final date = DateTime.fromMillisecondsSinceEpoch(
        photo.captureTimeMs ?? photo.modifiedMs,
      );
      final bucket = bucketOf(date, _mode);
      grouped
          .putIfAbsent(bucket, () => PhotoSection(bucket: bucket, date: date))
          .items
          .add(SectionItem(photo, index));
    }
    final ordered = grouped.values.toList()
      ..sort((a, b) => b.bucket.compareTo(a.bucket));
    return ordered;
  }

  /// Search results split by media type (matching photoViewer's search page);
  /// the date-bucket mode selector does not apply here.
  List<PhotoSection> _searchSections(
    LibraryViewState state,
    AppStrings strings,
  ) {
    final now = DateTime.now();
    if (state.groups.isNotEmpty && state.search.isNotEmpty) {
      var start = 0;
      return [
        for (var i = 0; i < state.groups.length; i++)
          (() {
            final count = state.groups[i].count;
            final section = PhotoSection(
              bucket: i,
              date: now,
              label: state.groups[i].time == -1
                  ? strings.videos
                  : strings.images,
              startIndex: start,
              totalCount: count,
            );
            start += count;
            return section;
          })(),
      ];
    }
    final images = PhotoSection(bucket: 1, date: now, label: strings.images);
    final videos = PhotoSection(bucket: 0, date: now, label: strings.videos);
    for (var index = 0; index < state.extent; index += 1) {
      final photo = state.photoAt(index);
      if (photo == null) continue;
      _scheduledPages.remove(index ~/ LocalLibraryController.pageSize);
      (photo.mediaKind == 'video' ? videos : images).items.add(
        SectionItem(photo, index),
      );
    }
    return [
      if (images.items.isNotEmpty) images,
      if (videos.items.isNotEmpty) videos,
    ];
  }

  /// Three distinct empty states, never one "no photos" sentence: indexing,
  /// scan failed (with retry), and empty library (Open Settings).
  Widget? _statusPage(
    AppStrings strings,
    LibraryViewState state,
    LocalLibraryController controller,
  ) {
    if (widget.searchMode && state.search.isEmpty) {
      return _StatusPage(title: strings.searchPrompt);
    }
    if (state.scanning && state.scanVisible && state.extent == 0) {
      return _StatusPage(
        title: strings.scanning,
        spinner: true,
        action: TextButton(
          onPressed: state.cancelRequested ? null : controller.cancelScan,
          child: Text(strings.cancel),
        ),
      );
    }
    if (state.problem == LibraryProblem.scan) {
      return _StatusPage(
        titleKey: const ValueKey('library-error'),
        title: strings.scanFailed,
        body: strings.libraryError('scan'),
        action: FilledButton(
          key: const ValueKey('retry-library'),
          onPressed: state.loading
              ? null
              : () {
                  _scheduledPages.clear();
                  unawaited(controller.retryScan());
                },
          child: Text(strings.retryScan),
        ),
      );
    }
    if (state.problem != null && state.extent == 0) {
      final problem = state.problem!;
      return _StatusPage(
        titleKey: const ValueKey('library-error'),
        title: strings.libraryError(problem.name),
        action: FilledButton(
          key: const ValueKey('retry-library'),
          onPressed: state.loading
              ? null
              : () {
                  _scheduledPages.clear();
                  unawaited(controller.refresh());
                },
          child: Text(strings.refresh),
        ),
      );
    }
    if (state.loading && state.extent == 0) {
      return _StatusPage(title: strings.loadingLibrary, spinner: true);
    }
    if (widget.trashMode) {
      if (state.extent == 0 && !state.hasNext) {
        return _StatusPage(
          title: strings.trashEmpty,
          titleKey: const ValueKey('trash-empty'),
        );
      }
      return null;
    }
    if (widget.searchMode && state.extent == 0 && !state.hasNext) {
      return _StatusPage(
        title: state.search.isEmpty ? strings.searchPrompt : strings.noMatches,
        body: state.search.isEmpty ? null : strings.noMatchesBody,
      );
    }
    if (state.extent == 0 && !state.hasNext) {
      final filtered =
          state.favoritesOnly ||
          state.search.isNotEmpty ||
          state.folder != null ||
          state.mediaKind != null;
      if (filtered) {
        return _StatusPage(
          title: strings.noMatches,
          body: strings.noMatchesBody,
        );
      }
      return _StatusPage(
        title: strings.emptyLibrary,
        action: FilledButton(
          key: const ValueKey('open-settings'),
          onPressed: widget.onOpenSettings,
          child: Text(strings.openSettings),
        ),
      );
    }
    return null;
  }

  /// Quiet backgroundless two-line overview: full-library count plus a
  /// scan/status line.
  Widget _overview(
    AppStrings strings,
    LibraryViewState state,
    LocalLibraryController controller,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.photosCountLabel(state.total),
            key: const ValueKey('library-info'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          DefaultTextStyle(
            style: theme.textTheme.bodySmall ?? const TextStyle(),
            child: state.scanning && state.scanVisible
                ? Row(
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(strings.indexing),
                      const SizedBox(width: 4),
                      TextButton(
                        key: const ValueKey('cancel-scan'),
                        onPressed: state.cancelRequested
                            ? null
                            : controller.cancelScan,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          state.cancelRequested
                              ? strings.cancellingScan
                              : strings.cancelScan,
                        ),
                      ),
                    ],
                  )
                : state.scanResult != null
                ? Text(
                    strings.scanSummary(
                      state.scanResult!.discovered,
                      state.scanResult!.skipped,
                      state.scanResult!.failed,
                      state.scanResult!.cancelled,
                    ),
                  )
                : Text(
                    strings.pick(
                      '修订 ${state.revision}',
                      'Revision ${state.revision}',
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

double _librarySearchHeight(BuildContext context, bool trashMode) =>
    MediaQuery.sizeOf(context).width < 1000 && !trashMode ? 100 : 52;

double _libraryHeaderHeight(BuildContext context, {bool mobile = false}) {
  final scale = MediaQuery.textScalerOf(context);
  if (mobile) {
    return math.max(104, scale.scale(32) * 1.2 + scale.scale(13) * 1.4 + 38) +
        MediaQuery.paddingOf(context).top;
  }
  return math.max(92, scale.scale(24) * 1.2 + scale.scale(12) * 1.4 + 35);
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.itemCount,
    required this.mobile,
    this.onBack,
    required this.trashMode,
    required this.searchMode,
    required this.scope,
    required this.onScopeChanged,
    required this.searchOpen,
    required this.searchController,
    required this.searchFocus,
    required this.onOpenSearch,
    required this.onCloseSearch,
    required this.onSearchChanged,
    required this.selectionMode,
    required this.selectionCount,
    required this.allLoadedSelected,
    required this.onSelectAll,
    required this.onDeselectAll,
    required this.onExitSelection,
    required this.onStartSelection,
    required this.onChooseCover,
    required this.onSort,
    required this.onOpenSettings,
    required this.hasContent,
    required this.choosingCover,
    required this.onCancelCover,
    required this.selectedPhotos,
    required this.onBatchFavorite,
    required this.onBatchTrash,
    required this.onBatchExport,
    required this.onBatchRestore,
    required this.onBatchPurge,
    required this.onBatchAddToAlbum,
    required this.onBatchUploadCloud,
    required this.onEmptyTrash,
    required this.emptyTrashEnabled,
    required this.strings,
  });

  final String title;
  final int? itemCount;
  final bool mobile;
  final VoidCallback? onBack;
  final bool trashMode;
  final bool searchMode;
  final SearchScope scope;
  final ValueChanged<SearchScope> onScopeChanged;
  final bool searchOpen;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final VoidCallback onOpenSearch;
  final VoidCallback onCloseSearch;
  final ValueChanged<String> onSearchChanged;
  final bool selectionMode;
  final int selectionCount;
  final bool allLoadedSelected;
  final VoidCallback onSelectAll;
  final VoidCallback onDeselectAll;
  final VoidCallback onExitSelection, onStartSelection, onSort, onCancelCover;
  final VoidCallback? onChooseCover, onOpenSettings;
  final bool hasContent, choosingCover;
  final List<LocalPhoto> selectedPhotos;
  final VoidCallback onBatchFavorite;
  final VoidCallback onBatchTrash;
  final VoidCallback onBatchExport;
  final VoidCallback onBatchRestore;
  final VoidCallback onBatchPurge;
  final ValueChanged<bool> onBatchAddToAlbum;
  final VoidCallback onBatchUploadCloud;
  final VoidCallback onEmptyTrash;
  final bool emptyTrashEnabled;
  final AppStrings strings;

  bool get _showField => searchOpen || searchMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topInset = mobile ? MediaQuery.paddingOf(context).top : 0.0;
    final mainHeight =
        _libraryHeaderHeight(context, mobile: mobile) - 16 - topInset;
    final countText = itemCount == null
        ? null
        : strings.pick(
            '${MaterialLocalizations.of(context).formatDecimal(itemCount!)} 项',
            '${MaterialLocalizations.of(context).formatDecimal(itemCount!)} items',
          );
    final subtitle = choosingCover
        ? strings.pick('选择一张照片作为相册封面', 'Choose a photo for the album cover')
        : mobile && !searchMode && countText != null
        ? '${MaterialLocalizations.of(context).formatFullDate(DateTime.now())} · $countText'
        : countText;
    final leading = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(
            fontSize: mobile ? 32 : 24,
            height: mobile ? 1.15 : 1.2,
            fontWeight: mobile ? FontWeight.w700 : FontWeight.w600,
            letterSpacing: mobile ? -.8 : -.5,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 3),
          Text(
            subtitle,
            key: const ValueKey('library-header-count'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    final actions = <Widget>[
      if (_showField)
        _PageIconSurface(
          child: IconButton(
            key: const ValueKey('library-search-close'),
            tooltip: strings.close,
            onPressed: onCloseSearch,
            icon: const Icon(Icons.close),
            style: IconButton.styleFrom(
              fixedSize: const Size(48, 48),
              shape: const CircleBorder(),
            ),
          ),
        )
      else
        _RoundSearchButton(onPressed: onOpenSearch, tooltip: strings.search),
      if (choosingCover) ...[
        const SizedBox(width: 8),
        TextButton(
          key: const ValueKey('cancel-cover-selection'),
          onPressed: onCancelCover,
          child: Text(strings.cancel),
        ),
      ] else ...[
        const SizedBox(width: 8),
        if (mobile)
          _PageIconSurface(
            child: IconButton(
              key: const ValueKey('library-options'),
              tooltip: strings.settings,
              onPressed: onOpenSettings,
              icon: const Icon(Icons.more_vert),
              style: IconButton.styleFrom(
                fixedSize: const Size(48, 48),
                shape: const CircleBorder(),
              ),
            ),
          )
        else
          _PageMenuButton(
            onChooseCover: onChooseCover,
            onSort: onSort,
            onStartSelection: hasContent && !selectionMode
                ? onStartSelection
                : null,
          ),
      ],
    ];
    return Padding(
      key: const ValueKey('library-header'),
      padding: mobile
          ? EdgeInsets.fromLTRB(20, topInset + 8, 12, 8)
          : const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: SizedBox(
        height:
            mainHeight +
            ((selectionMode || trashMode) ? 52 : 0) +
            (_showField ? _librarySearchHeight(context, trashMode) : 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: mainHeight,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showActivity = !mobile && constraints.maxWidth >= 480;
                  return Row(
                    children: [
                      if (mobile && onBack != null)
                        IconButton(
                          key: const ValueKey('mobile-album-back'),
                          tooltip: strings.pick('返回相册', 'Back to albums'),
                          onPressed: onBack,
                          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                          style: IconButton.styleFrom(
                            fixedSize: const Size(40, 48),
                            padding: EdgeInsets.zero,
                          ),
                        ),
                      Expanded(child: leading),
                      if (showActivity)
                        Expanded(
                          child: Center(child: const LibraryActivityProgress()),
                        ),
                      if (mobile)
                        ...actions
                      else
                        Expanded(
                          flex: 1,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: actions,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            if (_showField)
              SizedBox(
                height: _librarySearchHeight(context, trashMode),
                child: MediaQuery.sizeOf(context).width < 1000 && !trashMode
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(height: 48, child: _searchInput()),
                          SizedBox(
                            height: 48,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: _ScopeSelector(
                                  scope: scope,
                                  onChanged: onScopeChanged,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: _searchInput()),
                          if (!trashMode) ...[
                            const SizedBox(width: 12),
                            _ScopeSelector(
                              scope: scope,
                              onChanged: onScopeChanged,
                            ),
                          ],
                        ],
                      ),
              ),
            if (selectionMode || trashMode)
              SizedBox(
                height: 52,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (selectionMode) ...[
                        TextButton(
                          key: const ValueKey('exit-selection'),
                          onPressed: onExitSelection,
                          child: Text(strings.exitSelection),
                        ),
                        TextButton(
                          key: const ValueKey('select-all'),
                          onPressed: allLoadedSelected
                              ? onDeselectAll
                              : onSelectAll,
                          child: Text(
                            allLoadedSelected
                                ? strings.deselectAll
                                : strings.selectAll,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      if (_hasTrailing) _trailing(context),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _searchInput() => _SearchField(
    controller: searchController,
    scope: scope,
    focusNode: searchFocus,
    onChanged: onSearchChanged,
    onClose: null,
    strings: strings,
    expand: mobile,
  );

  bool get _hasTrailing => (selectionMode && selectionCount > 0) || trashMode;

  Widget _trailing(BuildContext context) {
    if (selectionMode && selectionCount > 0) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              strings.selectedCountLabel(selectionCount),
              key: const ValueKey('selection-count'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          _batchActions(context),
        ],
      );
    }
    if (trashMode) {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: TextButton.icon(
          key: const ValueKey('empty-trash'),
          onPressed: emptyTrashEnabled ? onEmptyTrash : null,
          icon: const Icon(Icons.delete_forever_outlined, size: 18),
          label: Text(strings.emptyTrash),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _batchActions(BuildContext context) {
    if (trashMode) {
      return Row(
        children: [
          Tooltip(
            message: strings.restore,
            child: _GlassActionButton(
              key: const ValueKey('batch-restore'),
              icon: Icons.restore_from_trash_outlined,
              onPressed: selectedPhotos.isEmpty ? null : onBatchRestore,
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: strings.deletePermanently,
            child: _GlassActionButton(
              key: const ValueKey('batch-purge'),
              icon: Icons.delete_forever_outlined,
              color: Theme.of(context).colorScheme.error,
              onPressed: selectedPhotos.isEmpty ? null : onBatchPurge,
            ),
          ),
        ],
      );
    }
    final allFavorite =
        selectedPhotos.isNotEmpty &&
        selectedPhotos.every((photo) => photo.favorite);
    final mixed = !allFavorite && selectedPhotos.any((photo) => photo.favorite);
    return Row(
      children: [
        IconButton(
          key: const ValueKey('batch-upload-cloud'),
          tooltip: strings.cloudUpload,
          onPressed: selectedPhotos.isEmpty ? null : onBatchUploadCloud,
          icon: const Icon(Icons.cloud_upload_outlined),
        ),
        IconButton(
          key: const ValueKey('batch-export'),
          tooltip: strings.pick('导出副本', 'Export copies'),
          onPressed: selectedPhotos.isEmpty ? null : onBatchExport,
          icon: const Icon(Icons.file_upload_outlined),
        ),
        Tooltip(
          message: strings.addToAlbum,
          child: PopupMenuButton<bool>(
            key: const ValueKey('batch-add-to-album'),
            tooltip: strings.addToAlbum,
            enabled: selectedPhotos.isNotEmpty,
            color: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            menuPadding: EdgeInsets.zero,
            clipBehavior: Clip.none,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(GlassTheme.panelRadius),
            ),
            onSelected: onBatchAddToAlbum,
            itemBuilder: (context) => [
              GlassMenuEntry<bool>(
                items: [
                  PopupMenuItem<bool>(
                    value: false,
                    child: Text(strings.copyToAlbum),
                  ),
                  PopupMenuItem<bool>(
                    value: true,
                    child: Text(strings.moveToAlbum),
                  ),
                ],
              ),
            ],
            icon: const Icon(Icons.add),
            iconSize: 20,
            style: IconButton.styleFrom(
              minimumSize: const Size(38, 38),
              padding: EdgeInsets.zero,
              backgroundColor: GlassTheme.of(context).inset,
              shape: const CircleBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: mixed
              ? strings.pick('收藏 / 取消收藏', 'Favorite / Unfavorite')
              : allFavorite
              ? strings.unmarkFavorite
              : strings.markFavorite,
          child: _GlassActionButton(
            key: const ValueKey('batch-favorite'),
            icon: allFavorite || mixed ? Icons.favorite : Icons.favorite_border,
            color: allFavorite ? const Color(0xb3e5534b) : null,
            badge: mixed,
            onPressed: selectedPhotos.isEmpty ? null : onBatchFavorite,
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: strings.moveToTrash,
          child: _GlassActionButton(
            key: const ValueKey('batch-trash'),
            icon: Icons.delete_outline,
            onPressed: selectedPhotos.isEmpty ? null : onBatchTrash,
          ),
        ),
      ],
    );
  }
}

/// All / Name / Date segmented scope control for the search field.
class _ScopeSelector extends StatelessWidget {
  const _ScopeSelector({required this.scope, required this.onChanged});

  final SearchScope scope;
  final ValueChanged<SearchScope> onChanged;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final entries = <(SearchScope, String)>[
      (SearchScope.all, strings.searchAll),
      (SearchScope.name, strings.searchByName),
      (SearchScope.date, strings.searchByDate),
    ];
    return GlassSurface(
      key: const ValueKey('search-scope'),
      radius: GlassTheme.controlRadius,
      role: GlassRole.raised,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (value, label) in entries)
            _ScopeChip(
              key: ValueKey('search-scope-${value.name}'),
              label: label,
              selected: scope == value,
              onTap: () => onChanged(value),
            ),
        ],
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(GlassTheme.controlRadius),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(GlassTheme.controlRadius),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 3),
            AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              width: 16,
              height: 2,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: selected ? scheme.primary : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Destination chooser for copy/move-to-album. Returns a folder path, or
/// [newAlbumSentinel] to ask the caller to run the directory picker.
class _AlbumPickerDialog extends StatelessWidget {
  const _AlbumPickerDialog({required this.albums});

  static const String newAlbumSentinel = '__photo_client_new_album__';
  final List<LocalAlbum> albums;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return GlassAlertDialog(
      title: Text(strings.chooseAlbum),
      content: SizedBox(
        width: 480,
        child: albums.isEmpty
            ? Text(strings.noAlbums)
            : LayoutBuilder(
                builder: (context, constraints) {
                  final columns = (constraints.maxWidth / 192).ceil().clamp(
                    1,
                    3,
                  );
                  final tileWidth =
                      (constraints.maxWidth - (columns - 1) * 12) / columns;
                  final rowHeight = tileWidth + 56;
                  final rows = (albums.length / columns).ceil();
                  return SizedBox(
                    height: math.min(
                      rows * rowHeight + (rows - 1) * 12,
                      math.min(400, MediaQuery.sizeOf(context).height * .45),
                    ),
                    child: GridView.builder(
                      primary: false,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: rowHeight,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                      ),
                      itemCount: albums.length,
                      itemBuilder: (context, index) =>
                          _AlbumTargetTile(album: albums[index]),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('album-picker-new'),
          onPressed: () =>
              Navigator.of(context).pop(_AlbumPickerDialog.newAlbumSentinel),
          child: Text(strings.newAlbum),
        ),
        TextButton(
          key: const ValueKey('album-picker-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
      ],
    );
  }
}

/// Cover cards reuse one modal material; the grid adds no per-photo shaders.
class _AlbumTargetTile extends ConsumerStatefulWidget {
  const _AlbumTargetTile({required this.album});
  final LocalAlbum album;

  @override
  ConsumerState<_AlbumTargetTile> createState() => _AlbumTargetTileState();
}

class _AlbumTargetTileState extends ConsumerState<_AlbumTargetTile> {
  MediaThumbnailHandle? _cover;
  @override
  void dispose() {
    _cover?.release();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final gateway = ref.read(coreGatewayProvider);
    final id = widget.album.coverMediaId;
    if (gateway is LocalLibraryGateway && id != null) {
      _cover = MediaThumbnailHandle(gateway as LocalLibraryGateway, id, 256);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: GlassTheme.of(context).inset,
      borderRadius: BorderRadius.circular(GlassTheme.controlRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('album-target-${widget.album.path}'),
        onTap: () => Navigator.of(context).pop(widget.album.path),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: FutureBuilder<String>(
                future: _cover?.future,
                initialData: _cover?.path,
                builder: (context, snapshot) {
                  final fallback = Center(
                    child: Icon(
                      Icons.photo_album_outlined,
                      size: 32,
                      color: scheme.onSurfaceVariant,
                    ),
                  );
                  return snapshot.hasData
                      ? Image.file(
                          File(snapshot.data!),
                          fit: BoxFit.cover,
                          cacheWidth: 256,
                          errorBuilder: (_, error, stack) => fallback,
                        )
                      : fallback;
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
              child: Text(
                widget.album.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Text(
                AppStrings.of(context).photosCountLabel(widget.album.count),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _PageAction { cover, sort, select }

class _PageMenuButton extends StatelessWidget {
  const _PageMenuButton({
    required this.onChooseCover,
    required this.onSort,
    required this.onStartSelection,
  });
  final VoidCallback? onChooseCover, onStartSelection;
  final VoidCallback onSort;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return _PageIconSurface(
      child: PopupMenuButton<_PageAction>(
        key: const ValueKey('library-options'),
        tooltip: strings.pick('更多选项', 'More options'),
        icon: const Icon(Icons.more_vert),
        style: IconButton.styleFrom(
          fixedSize: const Size(48, 48),
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
        ),
        color: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        menuPadding: EdgeInsets.zero,
        clipBehavior: Clip.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassTheme.panelRadius),
        ),
        onSelected: (action) {
          switch (action) {
            case _PageAction.cover:
              onChooseCover?.call();
            case _PageAction.sort:
              onSort();
            case _PageAction.select:
              onStartSelection?.call();
          }
        },
        itemBuilder: (context) => [
          GlassMenuEntry<_PageAction>(
            items: [
              PopupMenuItem(
                key: const ValueKey('library-menu-cover'),
                value: _PageAction.cover,
                enabled: onChooseCover != null,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: onChooseCover != null,
                  leading: const Icon(Icons.photo_album_outlined),
                  title: Text(strings.pick('设置相册封面', 'Set album cover')),
                  subtitle: onChooseCover == null
                      ? Text(
                          strings.pick(
                            '进入有照片的相册后可用',
                            'Open an album with photos to use this',
                          ),
                        )
                      : null,
                ),
              ),
              PopupMenuItem(
                key: const ValueKey('library-menu-sort'),
                value: _PageAction.sort,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.sort),
                  title: Text(strings.pick('排序', 'Sort')),
                ),
              ),
              PopupMenuItem(
                key: const ValueKey('library-menu-select'),
                value: _PageAction.select,
                enabled: onStartSelection != null,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: onStartSelection != null,
                  leading: const Icon(Icons.checklist),
                  title: Text(strings.pick('多选', 'Select photos')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PageIconSurface extends StatelessWidget {
  const _PageIconSurface({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 48,
    child: GlassSurface(
      role: GlassRole.raised,
      live: true,
      radius: 24,
      child: child,
    ),
  );
}

/// A standalone circular glass control beside the unframed page heading.
class _RoundSearchButton extends StatelessWidget {
  const _RoundSearchButton({required this.onPressed, required this.tooltip});

  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return _PageIconSurface(
      child: IconButton(
        key: const ValueKey('library-search'),
        tooltip: tooltip,
        onPressed: onPressed,
        icon: const Icon(Icons.search),
        style: IconButton.styleFrom(
          fixedSize: const Size(48, 48),
          padding: const EdgeInsets.all(8),
          shape: const CircleBorder(),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    this.scope = SearchScope.all,
    required this.focusNode,
    required this.onChanged,
    required this.onClose,
    required this.strings,
    this.expand = false,
  });

  final SearchScope scope;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClose;
  final AppStrings strings;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      key: const ValueKey('library-search'),
      radius: GlassTheme.controlRadius,
      child: ConstrainedBox(
        constraints: expand
            ? const BoxConstraints()
            : const BoxConstraints(maxWidth: 280),
        child: SizedBox(
          height: 40,
          width: expand ? double.infinity : 280,
          child: Row(
            children: [
              const SizedBox(width: 12),
              const Icon(Icons.search, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: controller,
                  keyboardType: scope == SearchScope.date
                      ? TextInputType.datetime
                      : TextInputType.text,
                  inputFormatters: scope == SearchScope.date
                      ? [const _DateQueryFormatter()]
                      : null,
                  focusNode: focusNode,
                  autofocus: true,
                  onChanged: onChanged,
                  onSubmitted: (_) => onClose?.call(),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: strings.searchHint,
                  ),
                ),
              ),
              if (onClose != null)
                IconButton(
                  key: const ValueKey('library-search-close'),
                  tooltip: strings.close,
                  icon: const Icon(Icons.close, size: 18),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(36, 36),
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: onClose,
                ),
              const SizedBox(width: 2),
            ],
          ),
        ),
      ),
    );
  }
}

/// Always-on glass toolbar button: the capsule is present at rest so the
/// revealed batch-action set stands out.
class _GlassActionButton extends StatelessWidget {
  const _GlassActionButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.color,
    this.badge = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      role: GlassRole.raised,
      radius: GlassTheme.controlRadius,
      child: SizedBox(
        width: 38,
        height: 38,
        child: Stack(
          alignment: Alignment.center,
          children: [
            IconButton(
              icon: Icon(icon),
              color: color,
              onPressed: onPressed,
              iconSize: 20,
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                minimumSize: const Size(38, 38),
                padding: EdgeInsets.zero,
              ),
            ),
            if (badge)
              Positioned(
                right: 3,
                bottom: 3,
                child: IgnorePointer(
                  child: Icon(
                    Icons.arrow_drop_down,
                    size: 12,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusPage extends StatelessWidget {
  const _StatusPage({
    required this.title,
    this.titleKey,
    this.body,
    this.spinner = false,
    this.action,
  });

  final String title;
  final Key? titleKey;
  final String? body;
  final bool spinner;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (spinner)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(),
              )
            else
              Icon(
                Icons.photo_library_outlined,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            const SizedBox(height: 16),
            Text(
              title,
              key: titleKey,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

class _GridSectionGeometry {
  const _GridSectionGeometry({
    required this.top,
    required this.start,
    required this.count,
    required this.columns,
    required this.stride,
    required this.header,
    this.items,
  });
  final double top, stride, header;
  final int start, count, columns;
  final List<SectionItem>? items;
}

class _DateQueryFormatter extends TextInputFormatter {
  const _DateQueryFormatter();
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.composing.isCollapsed ||
        !RegExp(r'^[0-9/年月日.\-]*$').hasMatch(newValue.text)) {
      return newValue;
    }
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length > 8) return newValue;
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i == 4 || i == 6) buffer.write('/');
      buffer.write(digits[i]);
    }
    final text = buffer.toString();
    final before = newValue.text
        .substring(
          0,
          newValue.selection.extentOffset.clamp(0, newValue.text.length),
        )
        .replaceAll(RegExp(r'[^0-9]'), '')
        .length;
    final cursor = (before + (before > 4 ? 1 : 0) + (before > 6 ? 1 : 0)).clamp(
      0,
      text.length,
    );
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }
}
