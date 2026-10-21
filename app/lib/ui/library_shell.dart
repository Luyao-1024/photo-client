import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'glass_surface.dart';
import 'local_library_controller.dart';
import 'local_library_pane.dart';
import 'presentation_preferences.dart';
import 'strings.dart';

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

  void _showPhotos() {
    setState(() => _destination = _Destination.photos);
    final controller = ref.read(localLibraryProvider.notifier);
    controller
      ..setTrashed(false)
      ..setFavorites(false)
      ..setFolder(null)
      ..setMediaKind(null);
  }

  void _showFavorites() {
    setState(() => _destination = _Destination.favorites);
    final controller = ref.read(localLibraryProvider.notifier);
    controller
      ..setTrashed(false)
      ..setFolder(null)
      ..setMediaKind(null)
      ..setFavorites(true);
  }

  void _showAlbum(LocalAlbum album) {
    setState(() => _destination = _Destination.photos);
    final controller = ref.read(localLibraryProvider.notifier);
    controller
      ..setTrashed(false)
      ..setFavorites(false)
      ..setMediaKind(null)
      ..setFolder(album.path);
  }

  void _showMediaType(String? kind) {
    setState(() => _destination = _Destination.photos);
    final controller = ref.read(localLibraryProvider.notifier);
    controller
      ..setTrashed(false)
      ..setFavorites(false)
      ..setFolder(null)
      ..setMediaKind(kind);
  }

  void _showSearch() {
    setState(() => _destination = _Destination.search);
    final controller = ref.read(localLibraryProvider.notifier);
    controller
      ..setTrashed(false)
      ..setFavorites(false)
      ..setFolder(null)
      ..setMediaKind(null);
  }

  void _showTrash() {
    setState(() => _destination = _Destination.trash);
    ref.read(localLibraryProvider.notifier).setTrashed(true);
  }

  void _openShortcuts() {
    showDialog<void>(
      context: context,
      builder: (context) => const _ShortcutReferenceDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(presentationProvider);
    final library = ref.watch(localLibraryProvider);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _showSearch,
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            _openSettings,
        const SingleActivator(LogicalKeyboardKey.f1): _openShortcuts,
        const SingleActivator(LogicalKeyboardKey.slash, control: true):
            _openShortcuts,
      },
      child: Scaffold(
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
                    child: LocalLibraryPane(
                      onOpenSettings: _openSettings,
                      onRequestSearch: _showSearch,
                      trashMode: _destination == _Destination.trash,
                      searchMode: _destination == _Destination.search,
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
    showDialog<void>(
      context: context,
      builder: (context) => const _SettingsDialog(),
    );
  }
}

class _Sidebar extends StatefulWidget {
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
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  bool _albumsExpanded = true;
  bool _mediaTypesExpanded = true;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final library = widget.library;
    final compact = widget.compact;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compact)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Text(
              strings.appTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          )
        else
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
          selected:
              widget.destination == _Destination.favorites ||
              library.favoritesOnly,
          onTap: widget.onFavorites,
          compact: compact,
        ),
        if (!compact) ...[
          _SectionHeader(
            key: const ValueKey('sidebar-albums-header'),
            label: strings.albums,
            expanded: _albumsExpanded,
            onTap: () => setState(() => _albumsExpanded = !_albumsExpanded),
          ),
          if (_albumsExpanded)
            for (final album in library.albums)
              _NavRow(
                key: ValueKey('sidebar-album-${album.path}'),
                icon: Icons.photo_album_outlined,
                label: '${album.name}  ${album.count}',
                selected: library.folder == album.path,
                onTap: () => widget.onAlbum(album),
                compact: false,
                indent: true,
              ),
          _SectionHeader(
            key: const ValueKey('sidebar-media-types-header'),
            label: strings.mediaTypes,
            expanded: _mediaTypesExpanded,
            onTap: () =>
                setState(() => _mediaTypesExpanded = !_mediaTypesExpanded),
          ),
          if (_mediaTypesExpanded) ...[
            _NavRow(
              key: const ValueKey('sidebar-media-images'),
              icon: Icons.image_outlined,
              label: strings.images,
              selected: library.mediaKind == 'image',
              onTap: () => widget.onMediaType('image'),
              compact: false,
              indent: true,
            ),
            _NavRow(
              key: const ValueKey('sidebar-media-videos'),
              icon: Icons.videocam_outlined,
              label: strings.videos,
              selected: library.mediaKind == 'video',
              onTap: () => widget.onMediaType('video'),
              compact: false,
              indent: true,
            ),
          ],
        ] else ...[
          _NavRow(
            key: const ValueKey('sidebar-media-images'),
            icon: Icons.image_outlined,
            label: strings.images,
            selected: library.mediaKind == 'image',
            onTap: () => widget.onMediaType('image'),
            compact: true,
          ),
          _NavRow(
            key: const ValueKey('sidebar-media-videos'),
            icon: Icons.videocam_outlined,
            label: strings.videos,
            selected: library.mediaKind == 'video',
            onTap: () => widget.onMediaType('video'),
            compact: true,
          ),
        ],
        const Spacer(),
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    super.key,
    required this.label,
    required this.expanded,
    required this.onTap,
  });
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

class _SettingsDialog extends ConsumerWidget {
  const _SettingsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppStrings.of(context);
    final preferences = ref.watch(presentationProvider);
    final controller = ref.read(presentationProvider.notifier);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 720),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                strings.settings,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              Text(
                strings.theme,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final (mode, label) in [
                    (ThemeMode.system, strings.system),
                    (ThemeMode.light, strings.light),
                    (ThemeMode.dark, strings.dark),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: preferences.themeMode == mode,
                      onSelected: (_) => controller.setTheme(mode),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                strings.language,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final (locale, label) in [
                    (const Locale('zh', 'CN'), '简体中文'),
                    (const Locale('en'), 'English'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected:
                          Localizations.localeOf(context).languageCode ==
                          locale.languageCode,
                      onSelected: (_) => controller.setLocale(locale),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                strings.glass,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: preferences.glass,
                onChanged: (value) => controller.setGlass(value),
                title: Text(strings.glassOn),
              ),
              const SizedBox(height: 16),
              Text(
                strings.scanFolders,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Builder(
                builder: (context) {
                  final picker = ref.watch(sourcePickerProvider);
                  final library = ref.read(localLibraryProvider.notifier);
                  final libraryState = ref.watch(localLibraryProvider);
                  final busy = libraryState.scanning || libraryState.selecting;
                  return Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('add-folder'),
                        onPressed: picker == null || busy
                            ? null
                            : () => library.importSources(
                                picker,
                                directory: true,
                              ),
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: Text(strings.addFolder),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('add-files'),
                        onPressed: picker == null || busy
                            ? null
                            : () => library.importSources(
                                picker,
                                directory: false,
                              ),
                        icon: const Icon(Icons.note_add_outlined),
                        label: Text(strings.addFiles),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const ValueKey('settings-shortcuts'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _ShortcutReferenceDialog(),
                ),
                icon: const Icon(Icons.keyboard_outlined),
                label: Text(strings.keyboardShortcuts),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShortcutReferenceDialog extends StatelessWidget {
  const _ShortcutReferenceDialog();

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
