import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'glass_surface.dart';
import 'local_library_controller.dart';
import 'local_library_pane.dart';
import 'presentation_preferences.dart';
import 'runtime_controller.dart';
import 'strings.dart';

/// Prototype shell: a fixed-width glass sidebar rail (Photos / Albums group /
/// Trash / footer gear) beside a content stage. See
/// photoViewer/docs/modules/ui-design.md "Window Shell And Sidebar".
class LibraryShell extends ConsumerStatefulWidget {
  const LibraryShell({super.key});

  @override
  ConsumerState<LibraryShell> createState() => _LibraryShellState();
}

enum _Destination { photos, favorites, trash }

class _LibraryShellState extends ConsumerState<LibraryShell> {
  static const double _sidebarWidth = 240;
  static const double _compactSidebarWidth = 72;
  _Destination _destination = _Destination.photos;

  void _select(_Destination destination) {
    setState(() => _destination = destination);
    final controller = ref.read(localLibraryProvider.notifier);
    switch (destination) {
      case _Destination.photos:
        controller.setFavorites(false);
      case _Destination.favorites:
        controller.setFavorites(true);
      case _Destination.trash:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(presentationProvider);
    return Scaffold(
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
                      onSelect: _select,
                      onSettings: _openSettings,
                      compact: compact,
                    ),
                  ),
                ),
                Expanded(
                  child: switch (_destination) {
                    _Destination.trash => _TrashPlaceholder(),
                    // Settings owns source management, so the empty-library
                    // state's Open Settings button must reach the dialog.
                    _ => LocalLibraryPane(onOpenSettings: _openSettings),
                  },
                ),
              ],
            );
          },
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

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.destination,
    required this.onSelect,
    required this.onSettings,
    this.compact = false,
  });
  final _Destination destination;
  final ValueChanged<_Destination> onSelect;
  final VoidCallback onSettings;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
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
          selected: destination == _Destination.photos,
          onTap: () => onSelect(_Destination.photos),
          compact: compact,
        ),
        if (!compact)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text(
              strings.albums,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              _NavRow(
                key: const ValueKey('sidebar-favorites'),
                icon: Icons.favorite_border,
                label: strings.albumFavorites,
                selected: destination == _Destination.favorites,
                onTap: () => onSelect(_Destination.favorites),
                compact: compact,
              ),
            ],
          ),
        ),
        _NavRow(
          key: const ValueKey('sidebar-trash'),
          icon: Icons.delete_outline,
          label: strings.trash,
          selected: destination == _Destination.trash,
          onTap: () => onSelect(_Destination.trash),
          compact: compact,
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              key: const ValueKey('sidebar-settings'),
              tooltip: strings.settings,
              icon: const Icon(Icons.settings_outlined),
              onPressed: onSettings,
            ),
          ),
        ),
      ],
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
    this.compact = false,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = compact
        ? Tooltip(
            message: label,
            child: Icon(icon, size: 20),
          )
        : Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label, overflow: TextOverflow.ellipsis),
              ),
            ],
          );
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 0 : 12,
          vertical: 10,
        ),
        alignment: compact ? Alignment.center : null,
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: .18) : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: content,
      ),
    );
  }
}

class _TrashPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.delete_outline, size: 48),
          const SizedBox(height: 12),
          Text(strings.trash),
          const SizedBox(height: 8),
          Text(strings.trashEmpty, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _SettingsDialog extends ConsumerWidget {
  const _SettingsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppStrings.of(context);
    final preferences = ref.watch(presentationProvider);
    final controller = ref.read(presentationProvider.notifier);
    final runtime = ref.watch(runtimeProvider);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(strings.settings, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 20),
              Text(strings.theme, style: Theme.of(context).textTheme.titleMedium),
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
              Text(strings.language, style: Theme.of(context).textTheme.titleMedium),
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
              Text(strings.glass, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SwitchListTile(
                value: preferences.glass,
                onChanged: (value) => controller.setGlass(value),
                title: Text(strings.glassOn),
              ),
              const SizedBox(height: 16),
              Text(strings.scanFolders, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Builder(
                builder: (context) {
                  final picker = ref.watch(sourcePickerProvider);
                  final library = ref.read(localLibraryProvider.notifier);
                  final libraryState = ref.watch(localLibraryProvider);
                  // A second concurrent import would race the running scan.
                  final busy =
                      libraryState.scanning || libraryState.selecting;
                  return Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('add-folder'),
                        onPressed: picker == null || busy
                            ? null
                            : () => library.importSources(picker, directory: true),
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: Text(strings.addFolder),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('add-files'),
                        onPressed: picker == null || busy
                            ? null
                            : () => library.importSources(picker, directory: false),
                        icon: const Icon(Icons.note_add_outlined),
                        label: Text(strings.addFiles),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              Text(strings.connection, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                _connectionLabel(strings, runtime.phase),
                key: const ValueKey('connection-status'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _connectionLabel(AppStrings strings, ConnectionPhase phase) =>
    switch (phase) {
      ConnectionPhase.connecting => strings.connecting,
      ConnectionPhase.ready => strings.ready,
      ConnectionPhase.failed => strings.failed,
      ConnectionPhase.stopped => strings.stopped,
    };
