import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'glass_surface.dart';
import 'local_library_controller.dart';
import 'local_library_pane.dart';
import 'mobile_settings_page.dart';
import 'local_settings_dialog.dart';
import 'mobile_albums_page.dart';
import 'strings.dart';
import 'photos_grid.dart';
import 'mobile_settings_surface.dart';

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
  GroupMode _groupMode = GroupMode.day;
  PhotoViewMode _photoViewMode = PhotoViewMode.date;
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
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const FractionallySizedBox(
        heightFactor: .96,
        child: MobileSettingsPage(),
      ),
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(localLibraryProvider);
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final showAlbums = _tab == _MobileTab.albums && !_albumDetail;
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
            Stack(
              fit: StackFit.expand,
              children: [
                _MobileTabPage(
                  visible: !showAlbums,
                  child: LocalLibraryPane(
                    mobile: true,
                    groupMode: _groupMode,
                    viewMode: _photoViewMode,
                    onViewModeChanged: (mode) =>
                        setState(() => _photoViewMode = mode),
                    trashMode: state.trashed,
                    onOpenSettings: _openSettings,
                    onBack: _tab == _MobileTab.albums && _albumDetail
                        ? _showAlbums
                        : null,
                    searchRequest: _searchRequest,
                    closeSearchRequest: _closeSearchRequest,
                    onSearchVisibilityChanged: _onSearchVisibilityChanged,
                  ),
                ),
                _MobileTabPage(
                  visible: showAlbums,
                  child: MobileAlbumsPage(
                    onOpenSmartAlbum: _openSmartAlbum,
                    onOpenAlbum: _openAlbum,
                    onSearch: _openSearch,
                    onOpenSettings: _openSettings,
                    onAdd: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const LocalSettingsDialog(
                          mobileCategory: MobileSettingsCategory.sources,
                        ),
                      ),
                    ),
                  ),
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
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final diameter = _mobileNavigationHeight(context);
                      final capsuleWidth =
                          (constraints.maxWidth - 2 * (diameter + 10)).clamp(
                            120.0,
                            228.0,
                          );
                      return SizedBox(
                        height: diameter,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: capsuleWidth,
                              child: _MobileNavigationBar(
                                tab: _tab,
                                onPhotos: _showPhotos,
                                onAlbums: _showAlbums,
                              ),
                            ),
                            if (_tab == _MobileTab.photos &&
                                _photoViewMode == PhotoViewMode.date)
                              Positioned(
                                left:
                                    (constraints.maxWidth - capsuleWidth) / 2 -
                                    diameter -
                                    10,
                                child: _MobileGroupModeButton(
                                  mode: _groupMode,
                                  onChanged: (mode) =>
                                      setState(() => _groupMode = mode),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

double _mobileNavigationHeight(BuildContext context) =>
    60 + (MediaQuery.textScalerOf(context).scale(11) - 11);

/// Both pages stay mounted so switching tabs retains scroll and selection.
/// After the fade, the hidden page also leaves layout and accessibility.
class _MobileTabPage extends StatefulWidget {
  const _MobileTabPage({required this.visible, required this.child});
  final bool visible;
  final Widget child;

  @override
  State<_MobileTabPage> createState() => _MobileTabPageState();
}

class _MobileTabPageState extends State<_MobileTabPage> {
  late bool _hidden = !widget.visible;

  @override
  void didUpdateWidget(_MobileTabPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) _hidden = false;
  }

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: _hidden,
    child: IgnorePointer(
      ignoring: !widget.visible,
      child: ExcludeSemantics(
        excluding: !widget.visible,
        child: ExcludeFocus(
          excluding: !widget.visible,
          child: AnimatedOpacity(
            opacity: widget.visible ? 1 : 0,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            onEnd: () {
              if (widget.visible || _hidden) return;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !widget.visible) setState(() => _hidden = true);
              });
            },
            child: TickerMode(enabled: widget.visible, child: widget.child),
          ),
        ),
      ),
    ),
  );
}

class _MobileGroupModeButton extends StatelessWidget {
  const _MobileGroupModeButton({required this.mode, required this.onChanged});

  final GroupMode mode;
  final ValueChanged<GroupMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    String label(GroupMode mode) => switch (mode) {
      GroupMode.day => strings.modeDay,
      GroupMode.month => strings.modeMonth,
      GroupMode.year => strings.modeYear,
    };
    final next = switch (mode) {
      GroupMode.day => GroupMode.month,
      GroupMode.month => GroupMode.year,
      GroupMode.year => GroupMode.day,
    };
    final tooltip = strings.pick(
      '当前${label(mode)}视图，点击切换到${label(next)}视图',
      '${label(mode)} view. Switch to ${label(next)} view',
    );
    final diameter = _mobileNavigationHeight(context);
    return GlassSurface(
      role: GlassRole.chrome,
      live: true,
      radius: diameter / 2,
      child: SizedBox.square(
        dimension: diameter,
        child: IconButton(
          key: const ValueKey('mobile-group-mode'),
          tooltip: tooltip,
          onPressed: () => onChanged(next),
          style: IconButton.styleFrom(shape: const CircleBorder()),
          icon: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label(mode),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
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
  });

  final _MobileTab tab;
  final VoidCallback onPhotos, onAlbums;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final diameter = _mobileNavigationHeight(context);
    return GlassSurface(
      key: const ValueKey('mobile-navigation'),
      role: GlassRole.chrome,
      live: true,
      radius: diameter / 2,
      child: SizedBox(
        height: diameter,
        child: Stack(
          children: [
            // The selected half is a stadium with the capsule's own radius, so
            // its outer cap reaches the glass rim instead of floating inset.
            Positioned.fill(
              child: AnimatedAlign(
                key: const ValueKey('mobile-navigation-indicator'),
                alignment: tab == _MobileTab.photos
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                child: FractionallySizedBox(
                  widthFactor: .5,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: mobileAccentColor(context).withValues(alpha: .07),
                      borderRadius: BorderRadius.circular(diameter / 2),
                    ),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                _MobileNavItem(
                  key: const ValueKey('mobile-nav-photos'),
                  icon: Icons.photo_outlined,
                  selectedIcon: Icons.photo_rounded,
                  label: strings.library,
                  selected: tab == _MobileTab.photos,
                  onTap: onPhotos,
                ),
                _MobileNavItem(
                  key: const ValueKey('mobile-nav-albums'),
                  icon: Icons.photo_library_outlined,
                  selectedIcon: Icons.photo_library_rounded,
                  label: strings.albums,
                  selected: tab == _MobileTab.albums,
                  onTap: onAlbums,
                ),
              ],
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
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon, selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? mobileAccentColor(context) : scheme.onSurface;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(begin: scheme.onSurface, end: color),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              builder: (context, color, _) => SizedBox.expand(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 160),
                      child: Icon(
                        selected ? selectedIcon : icon,
                        key: ValueKey(selected),
                        size: 23,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: color,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
