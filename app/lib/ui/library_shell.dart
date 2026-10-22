import '../services/thumbnail_pipeline.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import '../services/window_controller.dart';
import 'glass_dialog.dart';
import 'glass_surface.dart';
import 'glass_theme.dart';
import 'local_album_actions.dart';
import 'local_library_controller.dart';
import 'local_library_pane.dart';
import 'local_settings_dialog.dart';
import 'runtime_controller.dart';
import 'strings.dart';

// These covers describe the whole media category, independently of the active
// folder/search/favorites query. Refresh only when the library itself changes.
final _mediaTypeAlbumProvider = FutureProvider.autoDispose
    .family<LocalPhotoPage?, String>((ref, kind) async {
      final identity = ref.watch(
        localLibraryProvider.select(
          (state) => (state.info?.libraryId, state.revision),
        ),
      );
      if (identity.$1 == null) return null;
      final gateway = ref.watch(coreGatewayProvider) as LocalLibraryGateway;
      return gateway.listPhotos(mediaKind: kind, limit: 1);
    });

final _favoriteCountProvider = FutureProvider.autoDispose<int?>((ref) async {
  final identity = ref.watch(
    localLibraryProvider.select(
      (state) => (state.info?.libraryId, state.revision),
    ),
  );
  if (identity.$1 == null) return null;
  final gateway = ref.watch(coreGatewayProvider) as LocalLibraryGateway;
  return (await gateway.listPhotos(favoritesOnly: true, limit: 1)).total;
});

class LibraryShell extends ConsumerStatefulWidget {
  const LibraryShell({super.key});

  @override
  ConsumerState<LibraryShell> createState() => _LibraryShellState();
}

enum _Destination { photos, favorites, search, trash }

class _LibraryShellState extends ConsumerState<LibraryShell> {
  static const double _sidebarWidth = 240;
  static const double _compactSidebarWidth = 72;
  _Destination _destination = _Destination.photos;
  final _contentNavigator = GlobalKey<NavigatorState>();
  final _navigationRevision = ValueNotifier(0);
  void _notifyNavigation() {
    _contentNavigator.currentState?.popUntil((route) => route.isFirst);
    _navigationRevision.value++;
  }

  @override
  void dispose() {
    _navigationRevision.dispose();
    super.dispose();
  }

  void _navigate(
    _Destination destination, {
    bool favorites = false,
    String? folder,
    String? kind,
    bool trash = false,
  }) {
    if (WindowController.instance.confirmClose != null) return;
    setState(() => _destination = destination);
    _notifyNavigation();
    unawaited(
      ref
          .read(localLibraryProvider.notifier)
          .showDestination(
            favorites: favorites,
            folder: folder,
            kind: kind,
            trash: trash,
          ),
    );
  }

  void _showPhotos() => _navigate(_Destination.photos);
  void _showFavorites() => _navigate(_Destination.favorites, favorites: true);
  void _showAlbum(LocalAlbum album) =>
      _navigate(_Destination.photos, folder: album.path);
  void _showMediaType(String? kind) =>
      _navigate(_Destination.photos, kind: kind);
  void _showSearch() => _navigate(_Destination.search);
  void _showTrash() => _navigate(_Destination.trash, trash: true);

  void _openShortcuts() {
    if (WindowController.instance.confirmClose != null) return;
    showDialog<void>(
      context: context,
      builder: (context) => const ShortcutReferenceDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(localLibraryProvider);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () =>
            _contentNavigator.currentState?.maybePop(),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _showSearch,
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            _openSettings,
        const SingleActivator(LogicalKeyboardKey.f1): _openShortcuts,
        const SingleActivator(LogicalKeyboardKey.slash, control: true):
            _openShortcuts,
      },
      child: Scaffold(
        key: const ValueKey('library-shell'),
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 700;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: compact ? _compactSidebarWidth : _sidebarWidth,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: GlassSurface(
                        key: const ValueKey('library-navigation'),
                        live: true,
                        radius: GlassTheme.panelRadius,
                        child: _Sidebar(
                          destination: _destination,
                          library: library,
                          onPhotos: _showPhotos,
                          onFavorites: _showFavorites,
                          onAlbum: _showAlbum,
                          onMediaType: _showMediaType,
                          onTrash: _showTrash,
                          onSettings: _openSettings,
                          compact: compact,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
                      child: ValueListenableBuilder<bool>(
                        valueListenable: WindowController.instance.fullscreen,
                        builder: (context, fullscreen, child) => ClipRRect(
                          key: const ValueKey('photo-panel-clip'),
                          borderRadius: BorderRadius.circular(
                            fullscreen ? 0 : GlassTheme.panelRadius,
                          ),
                          child: ColoredBox(
                            color:
                                (Theme.of(context).brightness == Brightness.dark
                                        ? Colors.black
                                        : Colors.white)
                                    .withValues(alpha: .10),
                            child: child,
                          ),
                        ),
                        child: Navigator(
                          key: _contentNavigator,
                          onGenerateRoute: (_) => MaterialPageRoute<void>(
                            builder: (_) => ValueListenableBuilder<int>(
                              valueListenable: _navigationRevision,
                              builder: (context, _, child) => LocalLibraryPane(
                                onOpenSettings: _openSettings,
                                onRequestSearch: _showSearch,
                                trashMode: _destination == _Destination.trash,
                                searchMode: _destination == _Destination.search,
                                onCloseSearch: _showPhotos,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _openSettings() {
    if (WindowController.instance.confirmClose != null) return;
    showDialog<void>(
      context: context,
      builder: (context) => LocalSettingsDialog(onShortcuts: _openShortcuts),
    );
  }
}

class _Sidebar extends ConsumerStatefulWidget {
  const _Sidebar({
    required this.destination,
    required this.library,
    required this.onPhotos,
    required this.onFavorites,
    required this.onAlbum,
    required this.onMediaType,
    required this.onTrash,
    required this.onSettings,
    required this.compact,
  });

  final _Destination destination;
  final LibraryViewState library;
  final VoidCallback onPhotos;
  final VoidCallback onFavorites;
  final ValueChanged<LocalAlbum> onAlbum;
  final ValueChanged<String?> onMediaType;
  final VoidCallback onTrash;
  final VoidCallback onSettings;
  final bool compact;

  @override
  ConsumerState<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<_Sidebar> {
  bool _albumsExpanded = true;
  bool _mediaTypesExpanded = true;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final library = widget.library;
    final compact = widget.compact;
    final favoriteCount = ref.watch(_favoriteCountProvider).asData?.value;
    Widget albumRow(int index) => _AlbumSidebarRow(
      album: library.albums[index],
      selected: library.folder == library.albums[index].path,
      onTap: () {
        widget.onAlbum(library.albums[index]);
      },
      onReorder: (path) async {
        final folders = library.albums.map((a) => a.path).toList();
        final from = folders.indexOf(path);
        if (from < 0) return;
        folders.removeAt(from);
        folders.insert(index.clamp(0, folders.length), path);
        await ref.read(localLibraryProvider.notifier).localCommand({
          'op': 'reorderAlbums',
          'ids': folders,
        });
        await ref.read(localLibraryProvider.notifier).refresh();
      },
    );
    final albumCount = _albumsExpanded ? library.albums.length : 0;
    final mediaTypes = [
      (kind: 'image', key: 'images', label: strings.images),
      (kind: 'video', key: 'videos', label: strings.videos),
      (kind: 'motion', key: 'motion', label: strings.motionPhotos),
    ];
    Widget mediaTypeRow(int index) {
      final type = mediaTypes[index];
      return _MediaTypeSidebarRow(
        key: ValueKey('sidebar-media-${type.key}'),
        kind: type.kind,
        label: type.label,
        selected: library.mediaKind == type.kind,
        onTap: () => widget.onMediaType(type.kind),
        compact: compact,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        _NavRow(
          key: const ValueKey('sidebar-photos'),
          icon: Icons.photo_library_outlined,
          label: strings.library,
          count: library.info?.count,
          selected:
              widget.destination == _Destination.photos &&
              !library.favoritesOnly &&
              library.folder == null &&
              library.mediaKind == null &&
              !library.trashed,
          onTap: widget.onPhotos,
          compact: compact,
        ),
        _NavRow(
          key: const ValueKey('sidebar-favorites'),
          icon: Icons.favorite_border,
          label: strings.albumFavorites,
          count: favoriteCount,
          selected: widget.destination == _Destination.favorites,
          onTap: widget.onFavorites,
          compact: compact,
        ),
        if (compact)
          _NavRow(
            key: const ValueKey('sidebar-albums'),
            icon: Icons.photo_album_outlined,
            label: strings.albums,
            selected: library.folder != null,
            compact: true,
            onTap: () => showModalBottomSheet<void>(
              context: context,
              builder: (context) => GlassSurface(
                role: GlassRole.overlay,
                radius: GlassTheme.dialogRadius,
                child: SafeArea(
                  child: SizedBox(
                    height: 440,
                    child: ListView.builder(
                      itemCount: library.albums.length,
                      itemBuilder: (context, index) => ListTile(
                        title: Text(library.albums[index].name),
                        subtitle: Text('${library.albums[index].count}'),
                        onTap: () {
                          Navigator.of(context).pop();
                          widget.onAlbum(library.albums[index]);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (compact)
          for (var index = 0; index < mediaTypes.length; index++)
            mediaTypeRow(index),
        Expanded(
          child: compact
              ? const SizedBox.shrink()
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount:
                      albumCount +
                      2 +
                      (_mediaTypesExpanded ? mediaTypes.length : 0),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _SectionHeader(
                        key: const ValueKey('sidebar-albums-header'),
                        label: strings.albums,
                        onAdd: () => unawaited(createLocalAlbum(context, ref)),
                        expanded: _albumsExpanded,
                        onTap: () =>
                            setState(() => _albumsExpanded = !_albumsExpanded),
                      );
                    }
                    if (index <= albumCount) return albumRow(index - 1);
                    if (index == albumCount + 1) {
                      return _SectionHeader(
                        key: const ValueKey('sidebar-media-types-header'),
                        label: strings.mediaTypes,
                        expanded: _mediaTypesExpanded,
                        onTap: () => setState(
                          () => _mediaTypesExpanded = !_mediaTypesExpanded,
                        ),
                      );
                    }
                    return mediaTypeRow(index - albumCount - 2);
                  },
                ),
        ),
        _NavRow(
          key: const ValueKey('sidebar-trash'),
          icon: Icons.delete_outline,
          label: strings.trash,
          selected: widget.destination == _Destination.trash,
          onTap: widget.onTrash,
          compact: compact,
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _NavRow(
            key: const ValueKey('sidebar-settings'),
            icon: Icons.settings_outlined,
            label: strings.settings,
            selected: false,
            onTap: widget.onSettings,
            compact: compact,
          ),
        ),
      ],
    );
  }
}

class _AlbumSidebarRow extends ConsumerStatefulWidget {
  const _AlbumSidebarRow({
    required this.album,
    required this.selected,
    required this.onTap,
    required this.onReorder,
  });
  final LocalAlbum album;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<String> onReorder;
  @override
  ConsumerState<_AlbumSidebarRow> createState() => _AlbumSidebarRowState();
}

class _AlbumSidebarRowState extends ConsumerState<_AlbumSidebarRow> {
  Future<void> _menu(TapUpDetails details) async {
    final strings = AppStrings.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showGlassMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(
          details.globalPosition.dx,
          details.globalPosition.dy,
          1,
          1,
        ),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          key: const ValueKey('album-menu-rename'),
          value: 'rename',
          child: Text(strings.rename),
        ),
        PopupMenuItem(
          key: const ValueKey('album-menu-remove'),
          value: 'remove',
          child: Text(strings.pick('从图库移除相册', 'Remove album from library')),
        ),
      ],
    );
    if (!mounted || action == null) return;
    final controller = ref.read(localLibraryProvider.notifier);
    try {
      if (action == 'rename') {
        final text = TextEditingController(text: widget.album.name);
        final name = await showDialog<String>(
          context: context,
          builder: (context) => GlassAlertDialog(
            title: Text(strings.pick('重命名相册', 'Rename album')),
            content: TextField(
              key: const ValueKey('album-rename-field'),
              controller: text,
              autofocus: true,
              onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(strings.cancel),
              ),
              FilledButton(
                key: const ValueKey('album-rename-confirm'),
                onPressed: () => Navigator.of(context).pop(text.text.trim()),
                child: Text(strings.rename),
              ),
            ],
          ),
        );
        text.dispose();
        if (name == null || name.isEmpty || name == widget.album.name) return;
        await controller.localCommand({
          'op': 'renameAlbum',
          'folder': widget.album.path,
          'name': name,
        });
      } else {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => GlassAlertDialog(
            title: Text(strings.pick('移除相册？', 'Remove album?')),
            content: Text(
              strings.pick(
                '从图库移除此文件夹及其子文件夹，原始文件会保留。',
                'Remove this folder and its subfolders from the library. Original files are kept.',
              ),
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(strings.cancel),
              ),
              TextButton(
                key: const ValueKey('album-remove-confirm'),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(strings.pick('移除', 'Remove')),
              ),
            ],
          ),
        );
        if (accepted != true) return;
        await controller.localCommand({
          'op': 'removeAlbum',
          'folder': widget.album.path,
        });
      }
      await controller.showDestination();
      await controller.refresh(force: true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(strings.actionFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = _AlbumNavigationRow(
      key: ValueKey('sidebar-album-${widget.album.path}'),
      label: widget.album.name,
      count: widget.album.count,
      coverMediaId: widget.album.coverMediaId,
      selected: widget.selected,
      onTap: widget.onTap,
    );
    return GestureDetector(
      onSecondaryTapUp: (details) => unawaited(_menu(details)),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (data) => data.data != widget.album.path,
        onAcceptWithDetails: (data) => widget.onReorder(data.data),
        builder: (context, candidates, rejected) => DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: candidates.isEmpty
                    ? Colors.transparent
                    : Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            ),
          ),
          child: LongPressDraggable<String>(
            data: widget.album.path,
            feedback: Material(
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(widget.album.name),
              ),
            ),
            childWhenDragging: Opacity(opacity: .4, child: row),
            child: row,
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    super.key,
    required this.label,
    required this.expanded,
    required this.onTap,
    this.onAdd,
  });
  final VoidCallback? onAdd;
  final String label;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          if (onAdd != null)
            IconButton(
              key: const ValueKey('sidebar-album-add'),
              tooltip: AppStrings.of(context).pick('新建相册', 'New album'),
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
            ),
          Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 18),
        ],
      ),
    ),
  );
}

class _MediaTypeSidebarRow extends ConsumerWidget {
  const _MediaTypeSidebarRow({
    super.key,
    required this.kind,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.compact,
  });
  final String kind, label;
  final bool selected, compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(_mediaTypeAlbumProvider(kind)).asData?.value;
    return _AlbumNavigationRow(
      label: label,
      count: page?.total,
      coverMediaId: page?.items.firstOrNull?.id,
      selected: selected,
      onTap: onTap,
      compact: compact,
    );
  }
}

/// Physical and logical albums use the same cover, spacing and selection ink.
class _AlbumNavigationRow extends ConsumerWidget {
  const _AlbumNavigationRow({
    super.key,
    required this.label,
    required this.count,
    required this.coverMediaId,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });
  final String label;
  final int? count;
  final String? coverMediaId;
  final bool selected, compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final revision = ref.watch(
      localLibraryProvider.select((state) => state.revision),
    );
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: _NavigationSurface(
        selected: selected,
        child: InkWell(
          borderRadius: BorderRadius.circular(GlassTheme.controlRadius),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(compact ? 4 : 8),
            child: Row(
              mainAxisAlignment: compact
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                _SidebarAlbumCover(mediaId: coverMediaId, revision: revision),
                if (!compact) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      '$count',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return compact ? Tooltip(message: label, child: row) : row;
  }
}

class _SidebarAlbumCover extends ConsumerStatefulWidget {
  const _SidebarAlbumCover({required this.mediaId, required this.revision});
  final String? mediaId;
  final int revision;

  @override
  ConsumerState<_SidebarAlbumCover> createState() => _SidebarAlbumCoverState();
}

class _SidebarAlbumCoverState extends ConsumerState<_SidebarAlbumCover> {
  MediaThumbnailHandle? _cover;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_SidebarAlbumCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaId != widget.mediaId ||
        oldWidget.revision != widget.revision) {
      _load();
    }
  }

  void _load() {
    _cover?.release();
    final gateway = ref.read(coreGatewayProvider);
    final id = widget.mediaId;
    _cover = id != null && gateway is LocalLibraryGateway
        ? MediaThumbnailHandle(gateway as LocalLibraryGateway, id, 256)
        : null;
  }

  @override
  void dispose() {
    _cover?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(GlassTheme.photoRadius),
      child: SizedBox(
        width: 32,
        height: 32,
        child: FutureBuilder<String>(
          key: ValueKey((widget.mediaId, widget.revision)),
          future: _cover?.future,
          initialData: _cover?.path,
          builder: (context, snapshot) => snapshot.hasData
              ? Image(
                  key: ValueKey('sidebar-cover-${widget.mediaId}'),
                  image: FileImage(File(snapshot.data!)),
                  fit: BoxFit.cover,
                  errorBuilder: (_, error, stack) => placeholder,
                )
              : placeholder,
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.compact,
    this.count,
  });

  final IconData icon;
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: _NavigationSurface(
        selected: selected,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(GlassTheme.controlRadius),
          child: Container(
            height: 44,
            padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
            child: Row(
              mainAxisAlignment: compact
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: selected ? scheme.primary : null),
                if (!compact) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      '$count',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return compact ? Tooltip(message: label, child: row) : row;
  }
}

/// Selection is lightweight ink and tint inside the sidebar's single material.
class _NavigationSurface extends StatelessWidget {
  const _NavigationSurface({required this.selected, required this.child});
  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final glass = GlassTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: selected ? glass.selection : Colors.transparent,
          borderRadius: BorderRadius.circular(GlassTheme.controlRadius),
        ),
        child: Stack(
          children: [
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(GlassTheme.controlRadius),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
            if (selected)
              Positioned(
                left: 0,
                top: 12,
                bottom: 12,
                width: 3,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ShortcutReferenceDialog extends StatelessWidget {
  const ShortcutReferenceDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final sections = <(String, List<(String, String)>)>[
      (
        strings.shortcutGlobal,
        [
          ('Ctrl+F', strings.search),
          ('Ctrl+,', strings.settings),
          ('F1 / Ctrl+/', strings.keyboardShortcuts),
        ],
      ),
      (
        strings.shortcutBrowse,
        [
          (
            strings.pick('方向键', 'Arrow keys'),
            strings.pick('移动焦点', 'Move focus'),
          ),
          ('Enter', strings.pick('打开查看器', 'Open the viewer')),
          ('Space', strings.pick('进入 / 切换多选', 'Enter / toggle selection')),
          ('Ctrl+A', strings.selectAll),
          ('Delete', strings.moveToTrash),
          ('Esc', strings.exitSelection),
        ],
      ),
      (
        strings.shortcutViewer,
        [
          ('← / →', strings.pick('上一张 / 下一张', 'Previous / next')),
          ('+ / - / 0', strings.pick('放大 / 缩小 / 复位', 'Zoom in / out / reset')),
          ('F', strings.immersive),
          ('Shift+F', strings.fullscreen),
          ('I', strings.details),
          ('H', strings.markFavorite),
          ('R / Shift+R', strings.pick('右转 / 左转', 'Rotate right / left')),
          ('E', strings.edit),
          ('Delete', strings.moveToTrash),
          ('Esc', strings.close),
        ],
      ),
    ];
    return GlassAlertDialog(
      title: Text(strings.keyboardShortcuts),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (title, rows) in sections) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 0, 6),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                for (final (keys, description) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 150,
                          child: Text(
                            keys,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Expanded(child: Text(description)),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('shortcuts-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.close),
        ),
      ],
    );
  }
}
