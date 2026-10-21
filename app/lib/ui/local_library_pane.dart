import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'glass_surface.dart';
import 'local_library_controller.dart';
import 'local_photo_viewer.dart';
import 'mode_selector.dart';
import 'photos_grid.dart';
import 'presentation_preferences.dart';
import 'runtime_controller.dart';
import 'strings.dart';
import 'local_album_actions.dart';

/// The Photos page: glass header (search + selection chrome), a quiet two-line
/// overview, a date-sectioned square-tile grid, and the floating Year/Month/Day
/// capsule. See photoViewer/docs/modules/ui-design.md "Photos Page".
class LocalLibraryPane extends ConsumerStatefulWidget {
  const LocalLibraryPane({
    super.key,
    this.onOpenSettings,
    this.onRequestSearch,
    this.trashMode = false,
    this.searchMode = false,
    this.searchDetail = false,
    this.onCloseSearch,
  });

  /// Supplied by the shell once Settings owns source management; null keeps
  /// the empty-state button honestly disabled.
  final VoidCallback? onOpenSettings;

  /// Asks the shell to switch to the dedicated search destination. When null
  /// the pane falls back to an inline search field.
  final VoidCallback? onRequestSearch;
  final bool trashMode;
  final bool searchMode;
  final bool searchDetail;
  final VoidCallback? onCloseSearch;

  @override
  ConsumerState<LocalLibraryPane> createState() => _LocalLibraryPaneState();
}

class _LocalLibraryPaneState extends ConsumerState<LocalLibraryPane> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _scheduledPages = <int>{};
  late final FocusNode _searchFocus = FocusNode(onKeyEvent: _onSearchKey);
  int _epoch = -1;
  bool _searchOpen = false;
  GroupMode _mode = GroupMode.day;
  bool _selectionMode = false;
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
  double _withinRow = 0, _gridWidth = 0;
  List<_GridSectionGeometry> _geometry = [];
  void _changeMode(GroupMode value) {
    if (value == _mode) return;
    _captureAnchor();
    setState(() {
      _pendingRank = _visibleRank;
      _mode = value;
    });
  }

  void _captureAnchor() {
    if (!_scroll.hasClients || _geometry.isEmpty) return;
    final y = _scroll.offset;
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
    ref.read(localLibraryProvider.notifier).noteViewport(_visibleRank);
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_nearEnd);
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
  }

  void _nearEnd() {
    _captureAnchor();
    if (_scroll.hasClients && _scroll.position.extentAfter < 600) {
      unawaited(ref.read(localLibraryProvider.notifier).loadNext());
    }
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
        widget.searchMode &&
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? true)) {
      _closeSearch();
      return true;
    }
    return false;
  }

  @override
  void didUpdateWidget(LocalLibraryPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchMode && !oldWidget.searchMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
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
  }

  void _closeSearch() {
    if (!mounted) return;
    // Leaving a search must not leave an invisible filter behind.
    ref.read(localLibraryProvider.notifier).clearSearch();
    if (widget.searchMode) {
      widget.onCloseSearch?.call();
      return;
    }
    setState(() => _searchOpen = false);
  }

  void _exitSelection() {
    if (!_selectionMode && _selected.isEmpty) return;
    setState(() {
      _selectionMode = false;
      _selected.clear();
      _selectionSnapshots.clear();
    });
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
      builder: (context) => AlertDialog(
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
    try {
      final controller = ref.read(localLibraryProvider.notifier);
      await controller.localCommand({
        'op': 'albumCover',
        'folder': photo.parent,
        'id': photo.id,
      });
      await controller.refresh();
    } catch (_) {
      if (mounted) _notify(AppStrings.of(context).actionFailed);
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
    final controller = TextEditingController(text: photo.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.renamePhoto),
        content: TextField(
          key: const ValueKey('rename-field'),
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: photo.name),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('rename-confirm'),
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(strings.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == photo.name) return;
    try {
      await ref.read(localLibraryProvider.notifier).renamePhoto(photo.id, name);
    } catch (_) {
      _notify(strings.actionFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
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
        : strings.library;
    return Column(
      children: [
        _Header(
          glass: preferences.glass,
          title: title,
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
          selectedPhotos: _selectionMode ? _selectedPhotos(state) : const [],
          onBatchFavorite: () => _batchFavorite(state),
          onBatchTrash: _batchTrash,
          onBatchExport: () => unawaited(_exportPhotos(_selected.toList())),
          onBatchRestore: _batchRestore,
          onBatchPurge: _batchPurge,
          onBatchAddToAlbum: (move) => _addToAlbum(move: move),
          onEmptyTrash: _emptyTrash,
          emptyTrashEnabled: state.extent > 0 || state.hasNext,
          strings: strings,
        ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: _body(strings, state, controller, gateway, preferences),
              ),
              if (hasContent && !widget.searchMode)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: ModeSelector(
                      mode: _mode,
                      glass: preferences.glass,
                      onChanged: _changeMode,
                    ),
                  ),
                ),
            ],
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
      if (widget.searchMode && !_selectionMode)
        const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
    };
    return CallbackShortcuts(
      bindings: bindings,
      child: Focus(
        // Tab skips this wrapper, but it holds initial focus so Ctrl+A works
        // before any tile is focused; key events from tiles bubble up here.
        autofocus: true,
        skipTraversal: true,
        child: _scrollBody(strings, state, controller, gateway, preferences),
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
        controller: _scroll,
        slivers: [SliverFillRemaining(hasScrollBody: false, child: status)],
      );
    }
    final sections = widget.searchMode
        ? _searchSections(state, strings)
        : _sections(state);
    return NotificationListener<ScrollNotification>(
      onNotification: (event) {
        if (event.metrics.pixels <= 0 &&
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
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              child: _overviewOpen || state.scanning
                  ? _overview(strings, state, controller)
                  : const SizedBox.shrink(),
            ),
          ),
          SliverLayoutBuilder(
            builder: (context, constraints) {
              final available = (constraints.crossAxisExtent - 40).clamp(
                1.0,
                double.infinity,
              );
              final columns = _mode == GroupMode.day && !widget.searchMode
                  ? preferences.dayColumns
                  : (available /
                            gridMaxCrossAxisExtent(
                              widget.searchMode ? GroupMode.year : _mode,
                            ))
                        .ceil()
                        .clamp(1, 100);
              final side = (available - 8 * (columns - 1)) / columns;
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
              final header = MediaQuery.textScalerOf(context).scale(22) + 34;
              final layout = <_GridSectionGeometry>[];
              var top = 0.0;
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
                    stride: side + 8,
                    header: header,
                  ),
                );
                top += header + (count / columns).ceil() * (side + 8);
                fallbackRank += count;
              }
              _geometry = layout;
              double? target = _pendingOffset;
              if (target == null && _pendingRank != null) {
                for (final group in layout) {
                  if (_pendingRank! >= group.start &&
                      _pendingRank! < group.start + group.count) {
                    target =
                        group.top +
                        group.header +
                        ((_pendingRank! - group.start) ~/ columns) *
                            (side + 8) +
                        _withinRow;
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
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 90),
                sliver: SliverVariedExtentList.builder(
                  itemCount: rows,
                  itemExtentBuilder: (row, _) =>
                      resolve(row).$2 < 0 ? header : side + 8,
                  itemBuilder: (context, row) {
                    final (section, localRow) = resolve(row);
                    if (localRow < 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
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
                                      fontWeight: FontWeight.w700,
                                      fontSize: 22,
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
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          for (var column = 0; column < columns; column++) ...[
                            if (column > 0) const SizedBox(width: 8),
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
    return PhotoTile(
      key: ValueKey('photo-${item.photo.id}'),
      photo: item.photo,
      gateway: gateway,
      selected: _selected.contains(item.photo.id),
      multiSelect: _selectionMode,
      onOpen: () => unawaited(_openViewer(item.photo, item.index)),
      onExport: () => unawaited(_exportPhotos([item.photo.id])),
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
    if (state.scanning && state.extent == 0) {
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
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 2),
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
            child: state.scanning
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

class _Header extends StatelessWidget {
  const _Header({
    required this.glass,
    required this.title,
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
    required this.selectedPhotos,
    required this.onBatchFavorite,
    required this.onBatchTrash,
    required this.onBatchExport,
    required this.onBatchRestore,
    required this.onBatchPurge,
    required this.onBatchAddToAlbum,
    required this.onEmptyTrash,
    required this.emptyTrashEnabled,
    required this.strings,
  });

  final bool glass;
  final String title;
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
  final VoidCallback onExitSelection;
  final List<LocalPhoto> selectedPhotos;
  final VoidCallback onBatchFavorite;
  final VoidCallback onBatchTrash;
  final VoidCallback onBatchExport;
  final VoidCallback onBatchRestore;
  final VoidCallback onBatchPurge;
  final ValueChanged<bool> onBatchAddToAlbum;
  final VoidCallback onEmptyTrash;
  final bool emptyTrashEnabled;
  final AppStrings strings;

  bool get _showField => searchOpen || searchMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassSurface(
      enabled: glass,
      radius: 0,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      if (_showField)
                        Flexible(
                          child: _SearchField(
                            controller: searchController,
                            scope: scope,
                            focusNode: searchFocus,
                            onChanged: onSearchChanged,
                            onClose: onCloseSearch,
                            glass: glass,
                            strings: strings,
                          ),
                        )
                      else
                        _RoundSearchButton(
                          onPressed: onOpenSearch,
                          tooltip: strings.search,
                        ),
                      if (_showField && !trashMode) ...[
                        const SizedBox(width: 10),
                        _ScopeSelector(
                          scope: scope,
                          onChanged: onScopeChanged,
                          glass: glass,
                        ),
                      ],
                      if (selectionMode) ...[
                        const SizedBox(width: 10),
                        Flexible(
                          child: TextButton(
                            key: const ValueKey('select-all'),
                            onPressed: allLoadedSelected
                                ? onDeselectAll
                                : onSelectAll,
                            child: Text(
                              allLoadedSelected
                                  ? strings.deselectAll
                                  : strings.selectAll,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        Flexible(
                          child: TextButton(
                            key: const ValueKey('exit-selection'),
                            onPressed: onExitSelection,
                            child: Text(
                              strings.exitSelection,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (!_showField || trashMode)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _trailing(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _trailing(BuildContext context) {
    if (selectionMode && selectionCount > 0) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
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
              glass: glass,
              icon: Icons.restore_from_trash_outlined,
              onPressed: selectedPhotos.isEmpty ? null : onBatchRestore,
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: strings.deletePermanently,
            child: _GlassActionButton(
              key: const ValueKey('batch-purge'),
              glass: glass,
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
            onSelected: onBatchAddToAlbum,
            itemBuilder: (context) => [
              PopupMenuItem<bool>(
                value: false,
                child: Text(strings.copyToAlbum),
              ),
              PopupMenuItem<bool>(
                value: true,
                child: Text(strings.moveToAlbum),
              ),
            ],
            child: _GlassActionButton(
              glass: glass,
              icon: Icons.add,
              onPressed: selectedPhotos.isEmpty ? null : null,
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
            glass: glass,
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
            glass: glass,
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
  const _ScopeSelector({
    required this.scope,
    required this.onChanged,
    required this.glass,
  });

  final SearchScope scope;
  final ValueChanged<SearchScope> onChanged;
  final bool glass;

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
      enabled: glass,
      radius: 18,
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
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: .16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
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
    return AlertDialog(
      title: Text(strings.chooseAlbum),
      content: SizedBox(
        width: 360,
        child: albums.isEmpty
            ? Text(strings.noAlbums)
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final album in albums)
                      ListTile(
                        key: ValueKey('album-target-${album.path}'),
                        leading: const Icon(Icons.photo_album_outlined),
                        title: Text(album.name),
                        subtitle: Text(strings.photosCountLabel(album.count)),
                        onTap: () => Navigator.of(context).pop(album.path),
                      ),
                  ],
                ),
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

/// Circular icon-only search button: bare at rest, glass capsule only on
/// hover/focus (the `.round-search-button` rule).
class _RoundSearchButton extends StatelessWidget {
  const _RoundSearchButton({required this.onPressed, required this.tooltip});

  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final capsule = dark
        ? Colors.white.withValues(alpha: .14)
        : Colors.black.withValues(alpha: .07);
    return IconButton(
      key: const ValueKey('library-search'),
      tooltip: tooltip,
      onPressed: onPressed,
      icon: const Icon(Icons.search),
      style:
          IconButton.styleFrom(
            minimumSize: const Size(40, 40),
            padding: const EdgeInsets.all(8),
            shape: const CircleBorder(),
          ).copyWith(
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) =>
                  states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.focused)
                  ? capsule
                  : Colors.transparent,
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
    required this.glass,
    required this.strings,
  });

  final SearchScope scope;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClose;
  final bool glass;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      key: const ValueKey('library-search'),
      enabled: glass,
      radius: 20,
      child: SizedBox(
        height: 40,
        width: 280,
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
                  border: InputBorder.none,
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
    );
  }
}

/// Always-on glass toolbar button: the capsule is present at rest so the
/// revealed batch-action set stands out.
class _GlassActionButton extends StatelessWidget {
  const _GlassActionButton({
    super.key,
    required this.glass,
    required this.icon,
    required this.onPressed,
    this.color,
    this.badge = false,
  });

  final bool glass;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      enabled: glass,
      radius: 19,
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
  });
  final double top, stride, header;
  final int start, count, columns;
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
