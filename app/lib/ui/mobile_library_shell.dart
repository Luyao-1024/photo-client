import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'glass_surface.dart';
import 'glass_theme.dart';
import 'local_library_controller.dart';
import 'local_library_pane.dart';
import 'local_settings_dialog.dart';
import 'mobile_albums_page.dart';
import 'strings.dart';

enum _MobileTab { photos, albums }

/// The phone workspace: the photo grid and a dedicated albums page under one
/// floating navigation bar. The desktop sidebar is never built here.
class MobileLibraryShell extends ConsumerStatefulWidget {
  const MobileLibraryShell({super.key});

  @override
  ConsumerState<MobileLibraryShell> createState() => _MobileLibraryShellState();
}

class _MobileLibraryShellState extends ConsumerState<MobileLibraryShell> {
  _MobileTab _tab = _MobileTab.photos;
  bool _albumDetail = false;
  int _searchRequest = 0;
  int _closeSearchRequest = 0;
  bool _searchVisible = false;

  LocalLibraryController get _controller =>
      ref.read(localLibraryProvider.notifier);

  void _closeSearch() {
    if (!_searchVisible) return;
    setState(() {
      _searchVisible = false;
      _closeSearchRequest++;
    });
  }

  void _openSettings() {
    showDialog<void>(
      context: context,
      builder: (context) => const LocalSettingsDialog(),
    );
  }

  void _showPhotos() {
    _closeSearch();
    setState(() {
      _tab = _MobileTab.photos;
      _albumDetail = false;
    });
    unawaited(_controller.showDestination());
  }

  void _showAlbums() {
    _closeSearch();
    final wasDetail = _albumDetail;
    setState(() {
      _tab = _MobileTab.albums;
      _albumDetail = false;
    });
    if (wasDetail) unawaited(_controller.showDestination());
  }

  void _openAlbum(LocalAlbum album) {
    _closeSearch();
    setState(() {
      _tab = _MobileTab.albums;
      _albumDetail = true;
    });
    unawaited(_controller.showDestination(folder: album.path));
  }

  void _openSmartAlbum(MobileSmartAlbum album) {
    _closeSearch();
    setState(() {
      _tab = _MobileTab.albums;
      _albumDetail = true;
    });
    switch (album) {
      case MobileSmartAlbum.favorites:
        unawaited(_controller.showDestination(favorites: true));
      case MobileSmartAlbum.images:
        unawaited(_controller.showDestination(kind: 'image'));
      case MobileSmartAlbum.videos:
        unawaited(_controller.showDestination(kind: 'video'));
      case MobileSmartAlbum.motion:
        unawaited(_controller.showDestination(kind: 'motion'));
      case MobileSmartAlbum.trash:
        unawaited(_controller.showDestination(trash: true));
    }
  }

  void _openSearch() {
    setState(() {
      _tab = _MobileTab.photos;
      _albumDetail = false;
      _searchVisible = true;
      _searchRequest++;
    });
    // Search always starts from the whole library, not from a folder or trash.
    unawaited(_controller.showDestination());
  }

  void _onSearchVisibilityChanged(bool visible) {
    if (_searchVisible == visible || !mounted) return;
    setState(() => _searchVisible = visible);
  }

  Future<void> _showMore() async {
    final strings = AppStrings.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        top: false,
        child: GlassSurface(
          role: GlassRole.overlay,
          radius: GlassTheme.dialogRadius,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  key: const ValueKey('mobile-more-refresh'),
                  leading: const Icon(Icons.refresh),
                  title: Text(strings.refresh),
                  onTap: () => Navigator.of(context).pop('refresh'),
                ),
                ListTile(
                  key: const ValueKey('mobile-more-settings'),
                  leading: const Icon(Icons.settings_outlined),
                  title: Text(strings.settings),
                  onTap: () => Navigator.of(context).pop('settings'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'refresh':
        await _controller.refresh(force: true);
      case 'settings':
        _openSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(localLibraryProvider);
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final filtered =
        state.trashed ||
        state.favoritesOnly ||
        state.folder != null ||
        state.mediaKind != null;
    return PopScope(
      canPop: _tab == _MobileTab.photos && !_searchVisible && !filtered,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_searchVisible) {
          _closeSearch();
        } else if (_tab == _MobileTab.albums) {
          if (_albumDetail) {
            _showAlbums();
          } else {
            _showPhotos();
          }
        } else if (filtered) {
          _showPhotos();
        }
      },
      child: Scaffold(
        key: const ValueKey('mobile-library-shell'),
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            IndexedStack(
              sizing: StackFit.expand,
              index: _tab == _MobileTab.albums && !_albumDetail ? 1 : 0,
              children: [
                LocalLibraryPane(
                  mobile: true,
                  trashMode: state.trashed,
                  onOpenSettings: _openSettings,
                  onBack: _tab == _MobileTab.albums && _albumDetail
                      ? _showAlbums
                      : null,
                  searchRequest: _searchRequest,
                  closeSearchRequest: _closeSearchRequest,
                  onSearchVisibilityChanged: _onSearchVisibilityChanged,
                ),
                MobileAlbumsPage(
                  onOpenSmartAlbum: _openSmartAlbum,
                  onOpenAlbum: _openAlbum,
                  onSearch: _openSearch,
                  onOpenSettings: _openSettings,
                  onAdd: _openSettings,
                ),
              ],
            ),
            if (!keyboardVisible && !_searchVisible)
              Positioned(
                left: 16,
                right: 16,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.only(bottom: 10),
                  child: _MobileNavigationBar(
                    tab: _tab,
                    onPhotos: _showPhotos,
                    onAlbums: _showAlbums,
                    onMore: () => unawaited(_showMore()),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MobileNavigationBar extends StatelessWidget {
  const _MobileNavigationBar({
    required this.tab,
    required this.onPhotos,
    required this.onAlbums,
    required this.onMore,
  });

  final _MobileTab tab;
  final VoidCallback onPhotos, onAlbums, onMore;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return GlassSurface(
      key: const ValueKey('mobile-navigation'),
      role: GlassRole.overlay,
      radius: 30,
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            _MobileNavItem(
              key: const ValueKey('mobile-nav-photos'),
              icon: Icons.grid_view_rounded,
              label: strings.library,
              selected: tab == _MobileTab.photos,
              onTap: onPhotos,
            ),
            _MobileNavItem(
              key: const ValueKey('mobile-nav-albums'),
              icon: Icons.photo_library_outlined,
              label: strings.albums,
              selected: tab == _MobileTab.albums,
              onTap: onAlbums,
            ),
            _MobileNavItem(
              key: const ValueKey('mobile-nav-more'),
              icon: Icons.menu,
              label: strings.pick('更多', 'More'),
              selected: false,
              onTap: onMore,
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileNavItem extends StatelessWidget {
  const _MobileNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glass = GlassTheme.of(context);
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              margin: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                color: selected ? glass.selection : Colors.transparent,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 22, color: color),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
