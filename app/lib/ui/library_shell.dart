import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'glass_surface.dart';
import 'local_library_controller.dart';
import 'local_library_pane.dart';
import 'presentation_preferences.dart';
import 'strings.dart';
import 'local_settings_dialog.dart';
import 'local_album_actions.dart';
import 'runtime_controller.dart';
import '../services/window_controller.dart';

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
    final preferences = ref.watch(presentationProvider);
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
                    child: GlassSurface(
                      enabled: preferences.glass,
                      radius: 0,
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
                  Expanded(
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        _NavRow(
          key: const ValueKey('sidebar-photos'),
          icon: Icons.photo_library_outlined,
          label: strings.library,
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
              builder: (context) => SafeArea(
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
        if (compact) ...[
          _NavRow(
            key: const ValueKey('sidebar-media-images'),
            icon: Icons.image_outlined,
            label: strings.images,
            selected: library.mediaKind == 'image',
            compact: true,
            onTap: () => widget.onMediaType('image'),
          ),
          _NavRow(
            key: const ValueKey('sidebar-media-videos'),
            icon: Icons.videocam_outlined,
            label: strings.videos,
            selected: library.mediaKind == 'video',
            compact: true,
            onTap: () => widget.onMediaType('video'),
          ),
        ],
        Expanded(
          child: compact
              ? const SizedBox.shrink()
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: albumCount + 2 + (_mediaTypesExpanded ? 2 : 0),
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
                    final video = index == albumCount + 3;
                    return _NavRow(
                      key: ValueKey(
                        video ? 'sidebar-media-videos' : 'sidebar-media-images',
                      ),
                      icon: video
                          ? Icons.videocam_outlined
                          : Icons.image_outlined,
                      label: video ? strings.videos : strings.images,
                      selected:
                          library.mediaKind == (video ? 'video' : 'image'),
                      onTap: () =>
                          widget.onMediaType(video ? 'video' : 'image'),
                      compact: false,
                      indent: true,
                    );
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
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: compact ? Alignment.center : Alignment.centerRight,
            child: IconButton(
              key: const ValueKey('sidebar-settings'),
              tooltip: strings.settings,
              icon: const Icon(Icons.settings_outlined),
              onPressed: widget.onSettings,
            ),
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
  Future<String>? _cover;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(_AlbumSidebarRow old) {
    super.didUpdateWidget(old);
    if (old.album.coverMediaId != widget.album.coverMediaId) _load();
  }

  void _load() {
    final id = widget.album.coverMediaId;
    final gateway = ref.read(coreGatewayProvider);
    _cover = id != null && gateway is LocalLibraryGateway
        ? (gateway as LocalLibraryGateway).thumbnail(id, sizeClass: 256)
        : null;
  }

  Future<void> _menu(TapUpDetails details) async {
    final strings = AppStrings.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
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
          builder: (context) => AlertDialog(
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
          builder: (context) => AlertDialog(
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
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: widget.selected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: .12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: ValueKey('sidebar-album-${widget.album.path}'),
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: FutureBuilder<String>(
                      future: _cover,
                      builder: (context, snapshot) => snapshot.hasData
                          ? Image(
                              image: FileImage(File(snapshot.data!)),
                              fit: BoxFit.cover,
                              errorBuilder: (_, error, stack) =>
                                  const Icon(Icons.photo_album_outlined),
                            )
                          : const Icon(Icons.photo_album_outlined),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${widget.album.count}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
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

class _NavRow extends StatelessWidget {
  const _NavRow({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.compact,
    this.indent = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = InkWell(
      onTap: onTap,
      child: Container(
        height: 42,
        margin: EdgeInsets.fromLTRB(indent ? 12 : 8, 1, 8, 1),
        padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: .14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
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
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return compact ? Tooltip(message: label, child: row) : row;
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
    return AlertDialog(
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
