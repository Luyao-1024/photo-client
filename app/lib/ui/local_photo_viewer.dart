import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'glass_surface.dart';
import 'local_library_controller.dart';
import 'local_photo_editor.dart';
import 'local_photo_image.dart';
import 'presentation_preferences.dart';
import 'runtime_controller.dart';
import 'strings.dart';
import 'local_video_stage.dart';
import '../services/window_controller.dart';

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
  static const double _stripPadding = 16;
  static const double _headerInset = 70;

  /// Edge items need half a viewport of leading/trailing space so the first
  /// and last thumbnails can also reach the centre of the strip.
  static double _stripInsetFor(double viewport) =>
      math.max(_stripPadding, (viewport - _stripExtent) / 2);

  late LocalPhoto _photo = widget.photo;
  final _transform = TransformationController();
  final _strip = ScrollController();
  final _scheduledPages = <int>{};
  bool _navigating = false;
  bool _immersive = false;
  bool _chromeHidden = false;
  Timer? _idleTimer;
  bool _editing = false, _showMotion = false;
  final _editorKey = GlobalKey<LocalPhotoEditorState>();
  final _videoKey = GlobalKey<LocalVideoStageState>();
  Future<Map<String, dynamic>>? _details;
  String? _detailsIdentity;
  Future<String?>? _preview;
  Future<Object?>? _motionVideo;
  late int _resolvedIndex = widget.initialIndex;
  Timer? _decodeDebounce;
  bool _editAllowed = false;
  bool _bounding = false;
  @override
  void initState() {
    super.initState();
    _transform.addListener(_boundTransform);
  }

  void _boundTransform() {
    if (_bounding || _viewport.isEmpty) return;
    final photo = _photo;
    var w = photo.width?.toDouble() ?? _viewport.width;
    var h = photo.height?.toDouble() ?? _viewport.height;
    if (photo.orientation >= 5) {
      final swap = w;
      w = h;
      h = swap;
    }
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(w, h),
      _viewport,
    ).destination;
    final origin = Offset(
      (_viewport.width - fitted.width) / 2,
      (_viewport.height - fitted.height) / 2,
    );
    final matrix = _transform.value.clone();
    final scale = matrix.getMaxScaleOnAxis();
    double bound(double value, double length, double size, double offset) {
      final scaled = size * scale;
      return scaled <= length
          ? (length - scaled) / 2 - offset * scale
          : value.clamp(length - (offset + size) * scale, -offset * scale);
    }

    final x = bound(
          matrix.storage[12],
          _viewport.width,
          fitted.width,
          origin.dx,
        ),
        y = bound(
          matrix.storage[13],
          _viewport.height,
          fitted.height,
          origin.dy,
        );
    if ((x - matrix.storage[12]).abs() < .01 &&
        (y - matrix.storage[13]).abs() < .01) {
      return;
    }
    matrix.storage[12] = x;
    matrix.storage[13] = y;
    _bounding = true;
    _transform.value = matrix;
    _bounding = false;
  }

  bool _detailsOpen = false;
  Size _viewport = Size.zero;
  String? _stripCentered;
  int _stripEpoch = -1;

  @override
  void dispose() {
    _idleTimer?.cancel();
    _decodeDebounce?.cancel();
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
    final photo = await ref.read(localLibraryProvider.notifier).photoAt(target);
    if (!mounted) return;
    if (photo != null) {
      // Move the strip before the highlight changes so the first painted
      // frame after navigation already has the current thumbnail centred.
      _centerStripOn(target);
    }
    setState(() {
      _navigating = false;
      if (photo != null) {
        _photo = photo;
        _resolvedIndex = target;
        _transform.value = Matrix4.identity();
      }
    });
  }

  Future<void> _move(int delta) async {
    final index =
        ref.read(localLibraryProvider).indexOf(_photo.id) ?? _resolvedIndex;
    await _jumpTo(index + delta);
  }

  void _toggleImmersive() {
    _idleTimer?.cancel();
    setState(() {
      _immersive = !_immersive;
      _chromeHidden = false;
      if (_immersive) _detailsOpen = false;
    });
    if (_immersive) _armIdle();
  }

  void _armIdle() {
    _idleTimer?.cancel();
    if (!_immersive || _editing) return;
    _idleTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && _immersive && !_editing) {
        setState(() => _chromeHidden = true);
      }
    });
  }

  void _pointerMoved() {
    if (!_immersive) return;
    if (_chromeHidden) setState(() => _chromeHidden = false);
    _armIdle();
  }

  LocalPhoto get _currentPhoto {
    final library = ref.read(localLibraryProvider);
    final index = library.indexOf(_photo.id);
    return index == null ? _photo : library.photoAt(index) ?? _photo;
  }

  void _toggleDetails() => setState(() => _detailsOpen = !_detailsOpen);

  void _toast(String text, {Future<void> Function()? undo}) {
    if (!mounted) return;
    // Keep the toast clear of the zoom/rotate row on the left and the nav pair
    // on the right instead of spanning the whole stage.
    final width = MediaQuery.sizeOf(context).width;
    final side = width < 392 ? 16.0 : (width - 360) / 2;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          // SnackBars with an action default to persistent in this SDK; an
          // undo toast must still expire so it cannot cover the chrome.
          persist: false,
          margin: EdgeInsets.fromLTRB(side, 8, side, _stripHeight + 28),
          duration: Duration(seconds: undo == null ? 3 : 6),
          action: undo == null
              ? null
              : SnackBarAction(
                  label: AppStrings.of(context).pick('撤销', 'Undo'),
                  onPressed: () => unawaited(
                    undo().catchError((Object error) {
                      if (mounted) _toast(AppStrings.of(context).actionFailed);
                    }),
                  ),
                ),
        ),
      );
  }

  void _toggleFavorite() => unawaited(_favoriteCurrent());
  Future<void> _favoriteCurrent() async {
    final photo = _currentPhoto;
    final library = ref.read(localLibraryProvider);
    if (library.favoritePending.contains(photo.id)) return;
    final controller = ref.read(localLibraryProvider.notifier);
    await controller.setFavorite(photo);
    if (!mounted ||
        ref.read(localLibraryProvider).problem == LibraryProblem.favorite) {
      return;
    }
    _toast(
      AppStrings.of(context).pick(
        photo.favorite ? '已取消收藏' : '已收藏',
        photo.favorite ? 'Removed from favorites' : 'Added to favorites',
      ),
      undo: () => controller.setFavorite(photo.withFavorite(!photo.favorite)),
    );
  }

  Future<void> _openEditor() async {
    if (_editing) {
      await _editorKey.currentState?.requestClose();
      return;
    }
    final photo = _currentPhoto;
    if (photo.mediaKind != 'image' ||
        !['image/jpeg', 'image/png', 'image/webp'].contains(photo.mimeType)) {
      return;
    }
    final details = await _details;
    if (!mounted) return;
    if (details?['motion_offset'] != null ||
        details?['animated'] == true ||
        details?['hdr'] == true) {
      return;
    }
    _idleTimer?.cancel();
    setState(() => _editing = true);
  }

  Future<void> _openFullscreen() async {
    if (_currentPhoto.mediaKind == 'video' || _showMotion) {
      await _videoKey.currentState?.enterFullscreen();
      return;
    }
    final window = WindowController.instance;
    await window.setFullscreen(true);
    if (!mounted) {
      await window.setFullscreen(false);
      return;
    }
    try {
      await Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => _FullscreenPreview(photo: _currentPhoto),
        ),
      );
    } finally {
      await window.setFullscreen(false);
    }
  }

  /// Move to trash, then continue on the neighbour the user would expect:
  /// the photo now occupying this slot, otherwise the previous one.
  Future<void> _deleteCurrent() async {
    final library = ref.read(localLibraryProvider);
    final photo = _currentPhoto;
    final index = library.indexOf(photo.id) ?? 0;
    final strings = AppStrings.of(context);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.confirmTrashTitle(1)),
        content: Text(strings.confirmTrashBody),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const ValueKey('viewer-confirm-trash'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(strings.moveToTrash),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      await ref.read(localLibraryProvider.notifier).trashPhotos([photo.id]);
    } catch (_) {
      if (mounted) _toast(strings.actionFailed);
      return;
    }
    if (!mounted) return;
    _toast(
      strings.trashedCount(1),
      undo: () async {
        await ref.read(localLibraryProvider.notifier).restorePhotos([photo.id]);
      },
    );
    final after = ref.read(localLibraryProvider);
    if (after.total == 0) {
      Navigator.of(context).maybePop();
      return;
    }
    final targetIndex = index.clamp(0, after.total - 1);
    final next = await ref
        .read(localLibraryProvider.notifier)
        .photoAt(targetIndex);
    if (!mounted) return;
    if (next == null) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _photo = next;
      _resolvedIndex = targetIndex;
      _transform.value = Matrix4.identity();
    });
  }

  Future<void> _renameCurrent() async {
    final strings = AppStrings.of(context);
    final photo = _currentPhoto;
    final controller = TextEditingController(text: photo.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.renamePhoto),
        content: TextField(
          key: const ValueKey('viewer-rename-field'),
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
            key: const ValueKey('viewer-rename-confirm'),
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(strings.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == photo.name) return;
    try {
      final updated = await ref
          .read(localLibraryProvider.notifier)
          .renamePhoto(photo.id, name);
      if (!mounted) return;
      setState(() => _photo = updated);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(strings.actionFailed)));
    }
  }

  void _escape() {
    // Escape leaves immersive first and only pops the page on a second press.
    if (_editing) {
      unawaited(_editorKey.currentState?.requestClose());
      return;
    }
    if (_detailsOpen) {
      setState(() => _detailsOpen = false);
      return;
    }
    if (_immersive) {
      _idleTimer?.cancel();
      setState(() {
        _immersive = false;
        _chromeHidden = false;
      });
      return;
    }
    Navigator.of(context).maybePop();
  }

  void _centerStripOn(int index, {bool animate = false}) {
    if (!_strip.hasClients || !_strip.position.hasContentDimensions) return;
    final position = _strip.position;
    final inset = _stripInsetFor(position.viewportDimension);
    final target =
        (inset + (index + .5) * _stripExtent - position.viewportDimension / 2)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 1) return;
    if (!animate || MediaQuery.disableAnimationsOf(context)) {
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
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(date.year, date.month, date.day)).inDays;
    if (days == 0) return strings.today;
    if (days == 1) return strings.yesterday;
    return MaterialLocalizations.of(context).formatFullDate(date);
  }

  /// Hover-only glass (`.viewer-chrome` rule): bare icon at rest, glass
  /// capsule on hover/focus/press.
  ButtonStyle get _chromeStyle =>
      IconButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white.withValues(alpha: .28),
        backgroundColor: Colors.transparent,
        minimumSize: const Size(48, 48),
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
        overlayColor: WidgetStatePropertyAll(
          Colors.white.withValues(alpha: .10),
        ),
      );

  ButtonStyle get _compactChromeStyle => _chromeStyle.copyWith(
    minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
    padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
    iconSize: const WidgetStatePropertyAll(20),
  );

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final preferences = ref.watch(presentationProvider);
    final library = ref.watch(localLibraryProvider);
    final index =
        library.indexOf(_photo.id) ??
        (library.total > 0 ? _resolvedIndex.clamp(0, library.total - 1) : null);
    final photo = library.indexOf(_photo.id) == null
        ? _photo
        : index == null
        ? _photo
        : library.photoAt(index) ?? _photo;
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
    if (index != null && (_stripCentered != photo.id || !_strip.hasClients)) {
      _stripCentered = photo.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _centerStripOn(index);
      });
    }

    final identity = '${photo.id}:${photo.contentVersion}';
    if (_detailsIdentity != identity) {
      _detailsIdentity = identity;
      _editAllowed = false;
      _showMotion = false;
      _details = controller
          .localCommand({'op': 'metadata', 'id': photo.id})
          .then(
            (value) => value is Map
                ? Map<String, dynamic>.from(value)
                : <String, dynamic>{},
          )
          .catchError((Object error) => <String, dynamic>{});
      _details!.then((data) {
        if (mounted && _detailsIdentity == identity) {
          setState(
            () => _editAllowed =
                photo.mediaKind == 'image' &&
                [
                  'image/jpeg',
                  'image/png',
                  'image/webp',
                ].contains(photo.mimeType) &&
                data['animated'] != true &&
                data['hdr'] != true &&
                data['motion_offset'] == null,
          );
        }
      });
      _motionVideo = null;
      _preview = photo.mimeType == 'image/heic'
          ? controller
                .localCommand({'op': 'preview', 'id': photo.id})
                .then((value) => value as String?)
          : null;
    }

    // The stage is always dark media chrome; pin the dark glass material so
    // header, filmstrip, and details panel match regardless of app theme.
    // Shrink-wrap tap targets keep the compact hover-glass button geometry.
    return Theme(
      data: photoTheme(Brightness.dark)
          .copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _escape,
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(1),
          const SingleActivator(LogicalKeyboardKey.keyF): _toggleImmersive,
          const SingleActivator(LogicalKeyboardKey.keyR): () =>
              unawaited(_rotateCurrent(90)),
          const SingleActivator(LogicalKeyboardKey.keyR, shift: true): () =>
              unawaited(_rotateCurrent(-90)),
          const SingleActivator(LogicalKeyboardKey.space): () =>
              _videoKey.currentState?.togglePlayback(),
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
              _escape,
          const SingleActivator(LogicalKeyboardKey.keyF, shift: true):
              _openFullscreen,
          const SingleActivator(LogicalKeyboardKey.keyI): _toggleDetails,
          const SingleActivator(LogicalKeyboardKey.keyH): _toggleFavorite,
          const SingleActivator(LogicalKeyboardKey.keyE): () =>
              unawaited(_openEditor()),
          const SingleActivator(LogicalKeyboardKey.delete): () =>
              unawaited(_deleteCurrent()),
          const SingleActivator(LogicalKeyboardKey.equal): () =>
              _applyZoom(1.25),
          const SingleActivator(LogicalKeyboardKey.add): () => _applyZoom(1.25),
          const SingleActivator(LogicalKeyboardKey.minus): () => _applyZoom(.8),
          const SingleActivator(LogicalKeyboardKey.digit0): _resetZoom,
        },
        child: Focus(
          autofocus: true,
          child: PopScope(
            canPop: !_editing && !_detailsOpen && !_immersive,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) _escape();
            },
            child: MouseRegion(
              onHover: (_) => _pointerMoved(),
              onEnter: (_) => _pointerMoved(),
              child: Scaffold(
                key: const ValueKey('viewer'),
                backgroundColor: const Color(0xff10131a),
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    _stage(context, strings, photo),
                    ..._notices(strings, library, index),
                    if (!_editing && !_chromeHidden)
                      Positioned(
                        left: 16,
                        bottom: _stripHeight + 80,
                        child: FutureBuilder<Map<String, dynamic>>(
                          future: _details,
                          builder: (context, snapshot) =>
                              snapshot.data?['motion_offset'] == null
                              ? const SizedBox.shrink()
                              : TextButton.icon(
                                  key: const ValueKey('viewer-motion-toggle'),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    backgroundColor: Colors.black.withValues(
                                      alpha: .35,
                                    ),
                                  ),
                                  onPressed: () => setState(
                                    () => _showMotion = !_showMotion,
                                  ),
                                  icon: Icon(
                                    _showMotion
                                        ? Icons.photo_outlined
                                        : Icons.play_circle_outline,
                                  ),
                                  label: Text(
                                    strings.pick(
                                      _showMotion ? '查看照片' : '播放动态照片',
                                      _showMotion
                                          ? 'Show photo'
                                          : 'Play motion photo',
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    if (!_chromeHidden &&
                        !_editing &&
                        photo.mediaKind == 'image' &&
                        !_showMotion)
                      Positioned(
                        left: 16,
                        bottom: _stripHeight + 28,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: const ValueKey('viewer-zoom-out'),
                              tooltip: strings.pick('缩小', 'Zoom out'),
                              style: _chromeStyle,
                              onPressed: _scale <= _minScale + .001
                                  ? null
                                  : () => _applyZoom(.8),
                              icon: const Icon(Icons.remove, size: 20),
                            ),
                            IconButton(
                              key: const ValueKey('viewer-zoom-in'),
                              tooltip: strings.pick('放大', 'Zoom in'),
                              style: _chromeStyle,
                              onPressed: _scale >= _maxScale - .001
                                  ? null
                                  : () => _applyZoom(1.25),
                              icon: const Icon(Icons.add, size: 20),
                            ),
                            TextButton(
                              key: const ValueKey('viewer-zoom-reset'),
                              onPressed: _resetZoom,
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                              ),
                              child: Text('${(_scale * 100).round()}%'),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              key: const ValueKey('viewer-rotate-left'),
                              tooltip: strings.rotateLeft,
                              style: _chromeStyle,
                              onPressed: _editAllowed
                                  ? () => unawaited(_rotateCurrent(-90))
                                  : null,
                              icon: const Icon(Icons.rotate_left, size: 20),
                            ),
                            IconButton(
                              key: const ValueKey('viewer-rotate-right'),
                              tooltip: strings.rotateRight,
                              style: _chromeStyle,
                              onPressed: _editAllowed
                                  ? () => unawaited(_rotateCurrent(90))
                                  : null,
                              icon: const Icon(Icons.rotate_right, size: 20),
                            ),
                          ],
                        ),
                      ),
                    if (!_chromeHidden) ...[
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
                    if (_editing)
                      Positioned.fill(
                        child: LocalPhotoEditor(
                          key: _editorKey,
                          photo: photo,
                          onClosed: (saved) {
                            setState(() {
                              _editing = false;
                              if (saved != null) _photo = saved;
                            });
                            _armIdle();
                          },
                        ),
                      ),
                    // Above the image layer so the exit control stays hit-testable.
                    if (_chromeHidden)
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
        ),
      ),
    );
  }

  Future<void> _rotateCurrent(int degrees) async {
    final photo = _currentPhoto;
    if (photo.mediaKind != 'image' ||
        !['image/jpeg', 'image/png', 'image/webp'].contains(photo.mimeType)) {
      return;
    }
    try {
      final saved = await ref
          .read(localLibraryProvider.notifier)
          .saveEdited(
            photo.id,
            EditOptions(
              rotationDegrees: degrees,
              expectedContentVersion: photo.contentVersion,
            ),
          );
      if (mounted) setState(() => _photo = saved);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.of(context).actionFailed)),
        );
      }
    }
  }

  Widget _stage(BuildContext context, AppStrings strings, LocalPhoto photo) {
    if (photo.mediaKind == 'video') {
      return KeyedSubtree(
        key: ValueKey(photo.id),
        child: KeyedSubtree(
          key: const ValueKey('viewer-video'),
          child: LocalVideoStage(
            key: _videoKey,
            path: photo.path,
            bottomInset: _chromeHidden ? 0 : _stripHeight + 20,
          ),
        ),
      );
    }
    if (_showMotion) {
      return FutureBuilder<Object?>(
        future: _motionVideo ??= ref
            .read(localLibraryProvider.notifier)
            .localCommand({'op': 'motionVideo', 'id': photo.id}),
        builder: (context, snapshot) => snapshot.data is String
            ? KeyedSubtree(
                key: const ValueKey('viewer-motion-video'),
                child: LocalVideoStage(
                  key: _videoKey,
                  path: snapshot.data as String,
                  bottomInset: _chromeHidden ? 0 : _stripHeight + 20,
                ),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }
    if (photo.mimeType == 'image/heic') {
      return FutureBuilder<String?>(
        future: _preview,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(
              child: snapshot.hasError
                  ? Text(
                      strings.imageUnavailable,
                      style: const TextStyle(color: Colors.white),
                    )
                  : const CircularProgressIndicator(),
            );
          }
          return InteractiveViewer(
            key: const ValueKey('viewer-heic'),
            transformationController: _transform,
            minScale: _minScale,
            maxScale: _maxScale,
            onInteractionEnd: (_) {
              _decodeDebounce?.cancel();
              _decodeDebounce = Timer(const Duration(milliseconds: 150), () {
                if (mounted) setState(() {});
              });
            },
            child: Center(
              child: Image.file(File(snapshot.data!), fit: BoxFit.contain),
            ),
          );
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        final decodeWidth = math.min(
          4096,
          math.max(
            256,
            (constraints.maxWidth *
                    MediaQuery.devicePixelRatioOf(context) *
                    _scale.clamp(1.0, 4.0))
                .ceil(),
          ),
        );
        return InteractiveViewer(
          key: ValueKey('viewer-image-${photo.id}-${photo.contentVersion}'),
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
  }

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
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Six 48px controls overflow the chrome on a narrow rail; tighten
            // them instead of dropping actions the window can still show.
            final compact = constraints.maxWidth < 320;
            final actionStyle = compact ? _compactChromeStyle : _chromeStyle;
            // Only the name may flex: a loose flex date would keep its share
            // of the free space and leave the actions stranded mid-header.
            final chromeWidth = compact ? 40.0 : 48.0;
            final metaMax = math.max(
              0.0,
              constraints.maxWidth - chromeWidth * 6 - 10 - 40,
            );
            return Row(
              children: [
                IconButton(
                  key: const ValueKey('viewer-close'),
                  style: actionStyle,
                  tooltip: strings.back,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 10),
                if (metaMax >= 40)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: math.min(300, metaMax),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Passive day-precision date label — never a hover/glass
                        // action.
                        Flexible(
                          child: Text(
                            _dateLabel(
                              context,
                              strings,
                              photo.captureTimeMs ?? photo.modifiedMs,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        // The position counter sits last in the start cluster
                        // so growth pushes rightward instead of shifting the
                        // date.
                        if (index != null && library.total > 0)
                          Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: Text(
                              strings.positionLabel(index + 1, library.total),
                              key: const ValueKey('viewer-position'),
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: .62),
                                fontSize: 13,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                      ],
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
                  style: actionStyle,
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
                IconButton(
                  key: const ValueKey('viewer-edit'),
                  style: actionStyle,
                  tooltip: strings.edit,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _editAllowed
                      ? () => unawaited(_openEditor())
                      : null,
                ),
                IconButton(
                  key: const ValueKey('viewer-trash'),
                  style: actionStyle,
                  tooltip: strings.moveToTrash,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => unawaited(_deleteCurrent()),
                ),
                IconButton(
                  key: const ValueKey('viewer-details'),
                  style: actionStyle,
                  tooltip: strings.details,
                  isSelected: _detailsOpen,
                  selectedIcon: const Icon(Icons.info),
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => setState(() => _detailsOpen = !_detailsOpen),
                ),
                IconButton(
                  key: const ValueKey('viewer-immersive'),
                  style: actionStyle,
                  tooltip: strings.immersive,
                  icon: const Icon(Icons.fullscreen),
                  onPressed: _toggleImmersive,
                ),
              ],
            );
          },
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final inset = _stripInsetFor(constraints.maxWidth);
              return ListView.builder(
                controller: _strip,
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                padding: EdgeInsets.symmetric(horizontal: inset),
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
                        child: Icon(
                          Icons.photo_outlined,
                          color: Colors.white24,
                        ),
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
                          key: ValueKey('viewer-strip-${photo.id}'),
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => unawaited(_jumpTo(i)),
                          child: AnimatedScale(
                            scale: active ? 1.14 : 1,
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 150),
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
                              child: _FilmstripThumb(
                                photo: photo,
                                gateway: gateway,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
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
    final modified = DateTime.fromMillisecondsSinceEpoch(photo.modifiedMs)
        .toLocal();
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
            builder: (context, t, child) => Transform.translate(
              offset: Offset((1 - t) * 380, 0),
              child: child,
            ),
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
                          IconButton(
                            key: const ValueKey('viewer-details-rename'),
                            tooltip: strings.rename,
                            icon: const Icon(Icons.drive_file_rename_outline),
                            color: Colors.white,
                            onPressed: () => unawaited(_renameCurrent()),
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
                            FutureBuilder<Map<String, dynamic>>(
                              future: _details,
                              builder: (context, snapshot) {
                                final data = snapshot.data ?? {};
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (data['motion_offset'] != null)
                                      TextButton.icon(
                                        key: const ValueKey(
                                          'viewer-details-motion-toggle',
                                        ),
                                        icon: const Icon(
                                          Icons.play_circle_outline,
                                        ),
                                        onPressed: () => setState(
                                          () => _showMotion = !_showMotion,
                                        ),
                                        label: Text(
                                          strings.pick(
                                            _showMotion ? '查看照片' : '播放动态照片',
                                            _showMotion
                                                ? 'Show photo'
                                                : 'Play motion photo',
                                          ),
                                        ),
                                      ),
                                    for (final (key, label) in [
                                      (
                                        'duration_ms',
                                        strings.pick('时长', 'Duration'),
                                      ),
                                      (
                                        'camera_make',
                                        strings.pick('相机品牌', 'Camera make'),
                                      ),
                                      (
                                        'camera_model',
                                        strings.pick('相机型号', 'Camera model'),
                                      ),
                                      ('lens', strings.pick('镜头', 'Lens')),
                                      (
                                        'exposure',
                                        strings.pick('曝光时间', 'Exposure'),
                                      ),
                                      (
                                        'aperture',
                                        strings.pick('光圈', 'Aperture'),
                                      ),
                                      ('iso', 'ISO'),
                                      (
                                        'focal_length',
                                        strings.pick('焦距', 'Focal length'),
                                      ),
                                    ])
                                      if (data[key] != null)
                                        _detailRow(
                                          label,
                                          key == 'duration_ms'
                                              ? '${((data[key] as num) / 1000).toStringAsFixed(1)} s'
                                              : '${data[key]}',
                                        ),
                                  ],
                                );
                              },
                            ),
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
                            _detailRow(
                              strings.captureTime,
                              _formatStamp(localizations, photo.captureTimeMs),
                            ),
                            _detailRow(
                              strings.mediaType,
                              photo.mediaKind == 'video'
                                  ? strings.videos
                                  : strings.images,
                            ),
                            _detailRow(
                              strings.state,
                              photo.state == 'trashed'
                                  ? strings.trashed
                                  : strings.active,
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

  String _formatStamp(MaterialLocalizations localizations, int? ms) {
    if (ms == null) return AppStrings.of(context).unknown;
    final date = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${localizations.formatFullDate(date)} '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
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

/// Shift+F opens a chrome-free preview in its own route, mirroring the
/// original viewer's separate fullscreen window.
class _FullscreenPreview extends ConsumerStatefulWidget {
  const _FullscreenPreview({required this.photo});
  final LocalPhoto photo;
  @override
  ConsumerState<_FullscreenPreview> createState() => _FullscreenPreviewState();
}

class _FullscreenPreviewState extends ConsumerState<_FullscreenPreview> {
  Future<String?>? _preview;
  final _video = GlobalKey<LocalVideoStageState>();
  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    if (widget.photo.mimeType == 'image/heic') {
      _preview = ref
          .read(localLibraryProvider.notifier)
          .localCommand({'op': 'preview', 'id': widget.photo.id})
          .then((value) => value as String?);
    }
  }

  void _close() => Navigator.of(context).maybePop();
  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final photo = widget.photo;
    Widget image(String path) => InteractiveViewer(
      maxScale: 8,
      child: Center(
        child: Image(
          image: LocalPhotoImage(path, photo),
          fit: BoxFit.contain,
          semanticLabel: photo.name,
          errorBuilder: (context, error, stack) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  strings.imageUnavailable,
                  style: const TextStyle(color: Colors.white),
                ),
                TextButton(
                  onPressed: () {
                    LocalPhotoImage(path, photo).evict();
                    setState(_reload);
                  },
                  child: Text(strings.retry),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.space): () =>
            _video.currentState?.togglePlayback(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const ValueKey('viewer-fullscreen'),
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (photo.mediaKind == 'video')
                LocalVideoStage(key: _video, path: photo.path)
              else if (photo.mimeType == 'image/heic')
                FutureBuilder<String?>(
                  future: _preview,
                  builder: (context, snapshot) => snapshot.hasData
                      ? image(snapshot.data!)
                      : Center(
                          child: snapshot.hasError
                              ? Text(
                                  strings.imageUnavailable,
                                  style: const TextStyle(color: Colors.white),
                                )
                              : const CircularProgressIndicator(),
                        ),
                )
              else
                image(photo.path),
              Positioned(
                top: 8,
                right: 8,
                child: SafeArea(
                  child: IconButton(
                    key: const ValueKey('viewer-fullscreen-close'),
                    tooltip: strings.close,
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.white.withValues(alpha: .14),
                    ),
                    icon: const Icon(Icons.fullscreen_exit),
                    onPressed: _close,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
              child: Icon(
                Icons.photo_outlined,
                color: Colors.white24,
                size: 20,
              ),
            );
          }
          final target =
              (_LocalPhotoViewerState._stripThumb *
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
