import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'glass_surface.dart';
import 'local_library_controller.dart';
import 'local_photo_image.dart';
import 'presentation_preferences.dart';
import 'runtime_controller.dart';
import 'strings.dart';

/// Media-stage viewer per photoViewer/docs/modules/ui-design.md "Viewer Page":
/// a full-bleed dark stage with floating glass chrome — header (date, position,
/// name, hover-only item actions), a bare bottom-right prev/next pair, a low
/// raised glass filmstrip, immersive folding via F/I, and an overlay details
/// panel that never squeezes the stage.
class LocalPhotoViewer extends ConsumerStatefulWidget {
  const LocalPhotoViewer({
    super.key,
    required this.photo,
    required this.initialIndex,
  });
  final LocalPhoto photo;
  final int initialIndex;
  @override
  ConsumerState<LocalPhotoViewer> createState() => _LocalPhotoViewerState();
}

class _LocalPhotoViewerState extends ConsumerState<LocalPhotoViewer> {
  // InteractiveViewer's child fills the viewport, so it clamps scale at 1.0
  // (fit); declaring a lower floor would leave zoom-out enabled but inert.
  static const double _minScale = 1;
  static const double _maxScale = 8;
  static const double _stripExtent = 72;
  static const double _stripThumb = 60;
  static const double _stripHeight = 84;
  static const double _headerInset = 70;

  late LocalPhoto _photo = widget.photo;
  final _transform = TransformationController();
  final _strip = ScrollController();
  final _scheduledPages = <int>{};
  bool _navigating = false;
  bool _immersive = false;
  bool _detailsOpen = false;
  Size _viewport = Size.zero;
  String? _stripCentered;
  int _stripEpoch = -1;

  @override
  void dispose() {
    _transform.dispose();
    _strip.dispose();
    super.dispose();
  }

  double get _scale => _transform.value.getMaxScaleOnAxis();

  /// Zoom about the viewport centre so keyboard zoom matches the pointer
  /// gesture bounds enforced by [InteractiveViewer].
  void _applyZoom(double factor) {
    final current = _scale;
    final target = (current * factor).clamp(_minScale, _maxScale);
    final relative = target / current;
    if ((relative - 1).abs() < 1e-3 || _viewport.isEmpty) return;
    final focal = _transform.toScene(_viewport.center(Offset.zero));
    setState(() {
      _transform.value = _transform.value.clone()
        ..translateByDouble(focal.dx, focal.dy, 0, 1)
        ..multiply(Matrix4.diagonal3Values(relative, relative, 1))
        ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
    });
  }

  void _resetZoom() => setState(() => _transform.value = Matrix4.identity());

  Future<void> _jumpTo(int target) async {
    if (_navigating) return;
    final library = ref.read(localLibraryProvider);
    if (target < 0 || target >= library.total) return;
    setState(() => _navigating = true);
    final photo = await ref
        .read(localLibraryProvider.notifier)
        .photoAt(target);
    if (!mounted) return;
    setState(() {
      _navigating = false;
      if (photo != null) {
        _photo = photo;
        _transform.value = Matrix4.identity();
      }
    });
  }

  Future<void> _move(int delta) async {
    final index = ref.read(localLibraryProvider).indexOf(_photo.id);
    if (index == null) return;
    await _jumpTo(index + delta);
  }

  void _toggleImmersive() => setState(() {
    _immersive = !_immersive;
    // Immersion folds every chrome region away; inspection does not survive it.
    if (_immersive) _detailsOpen = false;
  });

  void _escape() {
    // Escape leaves immersive first and only pops the page on a second press.
    if (_immersive) {
      setState(() => _immersive = false);
      return;
    }
    Navigator.of(context).maybePop();
  }

  void _centerStripOn(int index) {
    if (!_strip.hasClients || !_strip.position.hasContentDimensions) return;
    final position = _strip.position;
    final target =
        ((index + .5) * _stripExtent - position.viewportDimension / 2).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    if ((target - position.pixels).abs() < 1) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _strip.jumpTo(target);
    } else {
      unawaited(
        _strip.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  /// Day-precision date for the passive header label: today / yesterday for
  /// the last two local days, a locale calendar date otherwise.
  String _dateLabel(BuildContext context, AppStrings strings, int modifiedMs) {
    final date = DateTime.fromMillisecondsSinceEpoch(modifiedMs).toLocal();
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(date.year, date.month, date.day))
        .inDays;
    if (days == 0) return strings.today;
    if (days == 1) return strings.yesterday;
    return MaterialLocalizations.of(context).formatFullDate(date);
  }

  /// Hover-only glass (`.viewer-chrome` rule): bare icon at rest, glass
  /// capsule on hover/focus/press.
  ButtonStyle get _chromeStyle => IconButton.styleFrom(
    foregroundColor: Colors.white,
    disabledForegroundColor: Colors.white,
    backgroundColor: Colors.transparent,
    minimumSize: const Size(34, 34),
    padding: const EdgeInsets.all(7),
    shape: const StadiumBorder(),
  ).copyWith(
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed)
          ? Colors.white.withValues(alpha: .18)
          : Colors.transparent,
    ),
    overlayColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: .10)),
  );

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final preferences = ref.watch(presentationProvider);
    final library = ref.watch(localLibraryProvider);
    final index = library.indexOf(_photo.id);
    final photo = index == null ? _photo : library.photoAt(index) ?? _photo;
    _photo = photo;
    final controller = ref.read(localLibraryProvider.notifier);
    final gateway = ref.read(coreGatewayProvider) as LocalLibraryGateway;
    final canPrevious = !_navigating && index != null && index > 0;
    final canNext = !_navigating && index != null && index + 1 < library.total;

    if (_stripEpoch != library.queryEpoch) {
      _stripEpoch = library.queryEpoch;
      _scheduledPages.clear();
      _stripCentered = null;
    }
    if (index != null &&
        (_stripCentered != photo.id || !_strip.hasClients)) {
      _stripCentered = photo.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _centerStripOn(index);
      });
    }

    // The stage is always dark media chrome; pin the dark glass material so
    // header, filmstrip, and details panel match regardless of app theme.
    // Shrink-wrap tap targets keep the compact hover-glass button geometry.
    return Theme(
      data: photoTheme(Brightness.dark).copyWith(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _escape,
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(1),
          const SingleActivator(LogicalKeyboardKey.keyF): _toggleImmersive,
          const SingleActivator(LogicalKeyboardKey.keyI): _toggleImmersive,
          const SingleActivator(LogicalKeyboardKey.equal): () =>
              _applyZoom(1.25),
          const SingleActivator(LogicalKeyboardKey.add): () =>
              _applyZoom(1.25),
          const SingleActivator(LogicalKeyboardKey.minus): () =>
              _applyZoom(.8),
          const SingleActivator(LogicalKeyboardKey.digit0): _resetZoom,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            key: const ValueKey('viewer'),
            backgroundColor: const Color(0xff10131a),
            body: Stack(
              fit: StackFit.expand,
              children: [
                _stage(context, strings, photo),
                ..._notices(strings, library, index),
                if (!_immersive) ...[
                  Positioned(
                    top: 8,
                    left: 8,
                    right: 8,
                    child: _header(
                      strings: strings,
                      photo: photo,
                      index: index,
                      library: library,
                      controller: controller,
                      glass: preferences.glass,
                    ),
                  ),
                  Positioned(
                    bottom: 12,
                    left: 12,
                    right: 12,
                    child: _filmstrip(
                      library: library,
                      index: index,
                      gateway: gateway,
                      glass: preferences.glass,
                    ),
                  ),
                  Positioned(
                    right: 16,
                    bottom: _stripHeight + 28,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _navArrow(
                          key: const ValueKey('viewer-previous'),
                          tooltip: strings.previous,
                          icon: Icons.chevron_left,
                          enabled: canPrevious,
                          onPressed: () => _move(-1),
                        ),
                        const SizedBox(width: 4),
                        _navArrow(
                          key: const ValueKey('viewer-next'),
                          tooltip: strings.next,
                          icon: Icons.chevron_right,
                          enabled: canNext,
                          onPressed: () => _move(1),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_detailsOpen && index != null)
                  _detailsPanel(strings, photo, preferences.glass),
                // Above the image layer so the exit control stays hit-testable.
                if (_immersive)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton(
                      key: const ValueKey('viewer-immersive-exit'),
                      style: _chromeStyle,
                      tooltip: strings.exitImmersive,
                      icon: const Icon(Icons.fullscreen_exit),
                      onPressed: _toggleImmersive,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stage(BuildContext context, AppStrings strings, LocalPhoto photo) =>
      LayoutBuilder(
        builder: (context, constraints) {
          _viewport = constraints.biggest;
          final decodeWidth = math.min(
            4096,
            math.max(
              256,
              (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                  .ceil(),
            ),
          );
          return InteractiveViewer(
            key: ValueKey(
              'viewer-image-${photo.id}-${photo.contentVersion}',
            ),
            transformationController: _transform,
            minScale: _minScale,
            maxScale: _maxScale,
            child: SizedBox.expand(
              child: Image(
                image: ResizeImage.resizeIfNeeded(
                  decodeWidth,
                  null,
                  LocalPhotoImage(photo.path, photo),
                ),
                fit: BoxFit.contain,
                semanticLabel: photo.name,
                errorBuilder: (context, error, stack) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.broken_image_outlined,
                        size: 48,
                        color: Colors.white70,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        strings.imageUnavailable,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );

  List<Widget> _notices(
    AppStrings strings,
    LibraryViewState library,
    int? index,
  ) {
    final notices = <String>[
      if (library.problem == LibraryProblem.favorite)
        strings.libraryError('favorite'),
      if (index == null) strings.libraryUpdated,
    ];
    if (notices.isEmpty) return const [];
    return [
      Positioned(
        top: _immersive ? 12 : _headerInset + 8,
        left: 16,
        right: 16,
        child: IgnorePointer(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final notice in notices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Text(notice, textAlign: TextAlign.center),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _header({
    required AppStrings strings,
    required LocalPhoto photo,
    required int? index,
    required LibraryViewState library,
    required LocalLibraryController controller,
    required bool glass,
  }) => GlassSurface(
    key: const ValueKey('viewer-header'),
    enabled: glass,
    radius: 18,
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('viewer-close'),
              style: _chromeStyle,
              tooltip: strings.back,
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 10),
            // Passive day-precision date label — never a hover/glass action.
            Flexible(
              child: Text(
                _dateLabel(context, strings, photo.modifiedMs),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // The position counter sits last in the start cluster so growth
            // pushes rightward instead of shifting the date.
            if (index != null && library.total > 0)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    strings.positionLabel(index + 1, library.total),
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .62),
                      fontSize: 13,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Text(
                    photo.name,
                    key: const ValueKey('viewer-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('viewer-favorite'),
              style: _chromeStyle,
              tooltip: photo.favorite
                  ? strings.unmarkFavorite
                  : strings.markFavorite,
              isSelected: photo.favorite,
              selectedIcon: const Icon(
                Icons.favorite,
                color: Color(0xffff5c72),
              ),
              icon: const Icon(Icons.favorite_border),
              onPressed: library.favoritePending.contains(photo.id)
                  ? null
                  : () => controller.setFavorite(photo),
            ),
            // Honest placeholders: no editor or trash backend exists yet.
            Opacity(
              opacity: .38,
              child: IconButton(
                key: const ValueKey('viewer-edit'),
                style: _chromeStyle,
                tooltip: strings.pick('编辑（暂不可用）', 'Edit (not available yet)'),
                icon: const Icon(Icons.edit_outlined),
                onPressed: null,
              ),
            ),
            Opacity(
              opacity: .38,
              child: IconButton(
                key: const ValueKey('viewer-trash'),
                style: _chromeStyle,
                tooltip: strings.pick(
                  '移到回收站（暂不可用）',
                  'Move to trash (not available yet)',
                ),
                icon: const Icon(Icons.delete_outline),
                onPressed: null,
              ),
            ),
            IconButton(
              key: const ValueKey('viewer-details'),
              style: _chromeStyle,
              tooltip: strings.details,
              isSelected: _detailsOpen,
              selectedIcon: const Icon(Icons.info),
              icon: const Icon(Icons.info_outline),
              onPressed: () =>
                  setState(() => _detailsOpen = !_detailsOpen),
            ),
            IconButton(
              key: const ValueKey('viewer-immersive'),
              style: _chromeStyle,
              tooltip: strings.immersive,
              icon: const Icon(Icons.fullscreen),
              onPressed: _toggleImmersive,
            ),
          ],
        ),
      ),
    ),
  );

  /// Bare bottom-right pair: no capsule container, each arrow draws its own
  /// glass only on hover/focus; the arrow with nowhere to go dims to 0.32
  /// opacity while keeping its geometry.
  Widget _navArrow({
    required Key key,
    required String tooltip,
    required IconData icon,
    required bool enabled,
    required VoidCallback onPressed,
  }) => Opacity(
    opacity: enabled ? 1 : .32,
    child: IconButton(
      key: key,
      style: _chromeStyle,
      tooltip: tooltip,
      iconSize: 26,
      icon: Icon(icon),
      onPressed: enabled ? onPressed : null,
    ),
  );

  Widget _filmstrip({
    required LibraryViewState library,
    required int? index,
    required LocalLibraryGateway gateway,
    required bool glass,
  }) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: GlassSurface(
        key: const ValueKey('viewer-filmstrip'),
        enabled: glass,
        radius: 18,
        child: SizedBox(
          height: _stripHeight,
          child: ListView.builder(
            controller: _strip,
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemExtent: _stripExtent,
            itemCount: library.total,
            itemBuilder: (context, i) {
              final photo = library.photoAt(i);
              if (photo == null) {
                final page = i ~/ LocalLibraryController.pageSize;
                if (_scheduledPages.add(page)) {
                  scheduleMicrotask(() {
                    if (mounted) {
                      unawaited(
                        ref
                            .read(localLibraryProvider.notifier)
                            .ensurePage(page),
                      );
                    }
                  });
                }
                return const Center(
                  child: SizedBox(
                    width: _stripThumb,
                    height: _stripThumb,
                    child: Icon(Icons.photo_outlined, color: Colors.white24),
                  ),
                );
              }
              // A loaded page can be evicted later; allow another request.
              _scheduledPages.remove(i ~/ LocalLibraryController.pageSize);
              final active = i == index;
              // Active reads larger through scale/outline only — never
              // through margin or padding changes that shift allocation.
              return Center(
                child: Tooltip(
                  message: photo.name,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => unawaited(_jumpTo(i)),
                      child: AnimatedScale(
                        scale: active ? 1.14 : 1,
                        duration: const Duration(milliseconds: 150),
                        child: Container(
                          width: _stripThumb,
                          height: _stripThumb,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: active
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.white.withValues(alpha: .22),
                              width: active ? 2 : 1,
                            ),
                          ),
                          child: _FilmstripThumb(photo: photo, gateway: gateway),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );

  /// Overlay glass side panel sliding over the stage's right side; the media
  /// stays visible behind it and the stage is never re-laid-out.
  Widget _detailsPanel(AppStrings strings, LocalPhoto photo, bool glass) {
    final modified = DateTime.fromMillisecondsSinceEpoch(
      photo.modifiedMs,
    ).toLocal();
    final localizations = MaterialLocalizations.of(context);
    return Positioned(
      top: _headerInset,
      bottom: 8,
      right: 8,
      left: 8,
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) =>
                Transform.translate(offset: Offset((1 - t) * 380, 0), child: child),
            child: SizedBox(
              width: 340,
              child: GlassSurface(
                key: const ValueKey('viewer-details-panel'),
                enabled: glass,
                radius: 18,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              strings.details,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          TextButton(
                            key: const ValueKey('viewer-details-close'),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              backgroundColor: Colors.white.withValues(
                                alpha: .12,
                              ),
                              shape: const StadiumBorder(),
                            ),
                            onPressed: () =>
                                setState(() => _detailsOpen = false),
                            child: Text(strings.close),
                          ),
                        ],
                      ),
                    ),
                    Divider(
                      height: 1,
                      color: Colors.white.withValues(alpha: .14),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _detailRow(strings.filePath, photo.path),
                            _detailRow(
                              strings.fileSize,
                              '${photo.sizeBytes} B',
                            ),
                            _detailRow(
                              strings.modified,
                              '${localizations.formatFullDate(modified)} '
                                  '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(modified))}',
                            ),
                            _detailRow(
                              strings.dimensions,
                              photo.width != null && photo.height != null
                                  ? '${photo.width} × ${photo.height}'
                                  : strings.unknown,
                            ),
                          ],
                        ),
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

  Widget _detailRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: .62),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 4),
        SelectableText(value, style: const TextStyle(color: Colors.white)),
      ],
    ),
  );
}

class _FilmstripThumb extends StatefulWidget {
  const _FilmstripThumb({required this.photo, required this.gateway});
  final LocalPhoto photo;
  final LocalLibraryGateway gateway;
  @override
  State<_FilmstripThumb> createState() => _FilmstripThumbState();
}

class _FilmstripThumbState extends State<_FilmstripThumb> {
  Future<String>? _future;
  String? _identity;

  @override
  Widget build(BuildContext context) {
    final photo = widget.photo;
    final identity = '${photo.id}:${photo.contentVersion}';
    if (_identity != identity) {
      _identity = identity;
      _future = widget.gateway.thumbnail(
        photo.id,
        sizeClass: thumbnailSizeClassFor(
          _LocalPhotoViewerState._stripThumb *
              MediaQuery.devicePixelRatioOf(context),
        ),
      );
    }
    return ColoredBox(
      color: Colors.white.withValues(alpha: .06),
      child: FutureBuilder<String>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: Colors.white38,
                size: 20,
              ),
            );
          }
          final path = snapshot.data;
          if (path == null) {
            return const Center(
              child: Icon(Icons.photo_outlined, color: Colors.white24, size: 20),
            );
          }
          final target = (_LocalPhotoViewerState._stripThumb *
                  MediaQuery.devicePixelRatioOf(context))
              .ceil()
              .clamp(64, 1024);
          return Image(
            image: ResizeImage.resizeIfNeeded(
              target,
              null,
              LocalPhotoImage(path, photo),
            ),
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            errorBuilder: (context, error, stack) => const Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: Colors.white38,
                size: 20,
              ),
            ),
          );
        },
      ),
    );
  }
}
