import '../services/media_metadata_cache.dart';
import 'thumbnail_image.dart';
import 'progressive_image.dart';
import '../services/thumbnail_pipeline.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassMaterializeTransition;

import '../services/local_library_gateway.dart';
import '../services/window_controller.dart';
import 'glass_dialog.dart';
import 'glass_surface.dart';
import 'glass_theme.dart';
import 'library_layout.dart';
import 'local_animated_stage.dart';
import 'local_library_controller.dart';
import 'local_photo_editor.dart';
import 'local_photo_image.dart';
import 'local_video_stage.dart';
import 'photo_theme.dart';
import 'presentation_preferences.dart';
import 'runtime_controller.dart';
import 'strings.dart';
import 'viewer_filmstrip_visibility.dart';
import 'viewer_filmstrip_layout.dart';

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

class _LocalPhotoViewerState extends ConsumerState<LocalPhotoViewer>
    with SingleTickerProviderStateMixin {
  // InteractiveViewer's child fills the viewport, so it clamps scale at 1.0
  // (fit); declaring a lower floor would leave zoom-out enabled but inert.
  static const double _minScale = 1;
  static const double _maxScale = 8;
  // One square preview per photo on both platforms: following the source
  // aspect made wide photos look much larger than tall ones. The phone keeps
  // the compact 48dp tile and tighter 8dp gap; desktop uses 60dp and 12dp.
  double get _stripThumb => _mobileLayout ? 48 : 60;
  double get _stripGap => _mobileLayout ? 8 : ViewerFilmstripLayout.defaultGap;
  double get _stripHeight => _mobileLayout ? 64 : 84;
  double get _navigationBottom => _stripHeight + 28;
  double get _videoControlsInset => _stripHeight + 20;
  static const double _headerInset = 70;

  double get _bottomSafeInset =>
      _mobileLayout ? MediaQuery.paddingOf(context).bottom : 0;

  ViewerFilmstripLayout? _stripLayout;
  (int, int, double)? _stripLayoutKey;

  void _updateStripLayout(LibraryViewState library) {
    final key = (library.queryEpoch, library.revision, _stripThumb);
    if (_stripLayoutKey != key || _stripLayout?.count != library.total) {
      _stripLayoutKey = key;
      _stripLayout = ViewerFilmstripLayout(
        count: library.total,
        height: _stripThumb,
        gap: _stripGap,
      );
      _stripCentered = null;
    }
  }

  late LocalPhoto _photo = widget.photo;
  final _transform = TransformationController();
  final _strip = ScrollController();
  final _scheduledPages = <int>{};
  bool _navigating = false;
  int _navGeneration = 0, _prefetchGeneration = 0;
  String? _prefetchIdentity;
  int? _pendingIndex;
  ThumbnailHandle? _navigationThumbnail;
  final _neighborThumbnails = <int, ThumbnailHandle>{};
  bool _immersive = false;
  bool _chromeHidden = false;
  bool _editing = false, _showMotion = false, _animated = false;
  bool _hasMotion = false, _motionHeld = false;
  bool _playbackActive = false;
  bool _videoControlsVisible = false;
  final _editorKey = GlobalKey<LocalPhotoEditorState>();
  // Keyed per media identity: during the stage cross-fade the outgoing video
  // is still mounted, so a single shared key would be registered twice.
  final _videoKeys = <String, GlobalKey<LocalVideoStageState>>{};
  GlobalKey<LocalVideoStageState> get _videoKey => _videoKeys.putIfAbsent(
    '${_photo.id}:${_photo.contentVersion}:${_showMotion ? 'motion' : 'video'}',
    () => GlobalKey<LocalVideoStageState>(),
  );
  Future<Map<String, dynamic>>? _details;
  String? _detailsIdentity;
  Future<String?>? _preview;
  Future<Object?>? _motionVideo;
  Future<List<AnimatedFrame>>? _animatedFrames;
  late int _resolvedIndex = widget.initialIndex;
  Timer? _decodeDebounce;
  bool _editAllowed = false;
  bool _bounding = false;
  // Wheel and pinch zoom bypass _applyZoom's setState, so the label needs its
  // own rebuild whenever the rendered percentage actually changes.
  int _zoomPercent = 100;
  final _swipe = ValueNotifier<double>(0);
  late final AnimationController _swipeReturn;
  double _swipeFrom = 0, _swipeTo = 0;
  int? _swipeCommitIndex;
  int? _swipePointer;
  Offset? _swipeStart;
  bool _swipeHorizontal = false;
  VelocityTracker? _swipeVelocity;
  int _navDirection = 1;
  // A swipe hand-off replaces the whole stage pager in one frame: the driven
  // offset already shows the incoming photo edge to edge, so an AnimatedSwitcher
  // reverse-fade underneath it would flash the outgoing photo back on screen.
  int _stageEpoch = 0;
  @override
  void initState() {
    super.initState();
    _transform.addListener(_boundTransform);
    _swipeReturn =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 180),
          )
          ..addListener(() {
            final t = Curves.easeOutCubic.transform(_swipeReturn.value);
            _swipe.value = _swipeFrom + (_swipeTo - _swipeFrom) * t;
          })
          ..addStatusListener((status) {
            if (status != AnimationStatus.completed) return;
            final commit = _swipeCommitIndex;
            _swipeCommitIndex = null;
            if (commit != null) _commitSwipe(commit);
          });
  }

  void _boundTransform() {
    final percent = (_scale * 100).round();
    if (percent != _zoomPercent) {
      _zoomPercent = percent;
      // Touch layouts hide the percentage label; let the gesture own the
      // transform without rebuilding the chrome on every pinch frame.
      if (mounted && !_mobileLayout) setState(() {});
    }
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
  bool _stripPendingCenter = false;
  String? _stripWarmKey;
  Future<void>? _stripWarmFuture;
  int _stripWarmGeneration = 0;
  final _stripWarmRequests = <ThumbnailHandle>{};

  @override
  void dispose() {
    _navGeneration++;
    _prefetchGeneration++;
    _stripWarmGeneration++;
    for (final request in _stripWarmRequests) {
      request.release();
    }
    _navigationThumbnail?.release();
    for (final request in _neighborThumbnails.values) {
      request.release();
    }
    _swipePointer = null;
    _swipeReturn.dispose();
    _swipe.dispose();
    _decodeDebounce?.cancel();
    _transform.dispose();
    _strip.dispose();
    super.dispose();
  }

  double get _scale => _transform.value.getMaxScaleOnAxis();

  bool get _mobileLayout =>
      ref.read(libraryLayoutProvider) == LibraryLayout.mobile;

  /// Top edge just below the touch header, including its status-bar inset.
  double get _mobileHeaderBottom => MediaQuery.paddingOf(context).top + 66;

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
    if (_editing) return;
    final library = ref.read(localLibraryProvider);
    if (target < 0 || target >= library.total) return;
    final current = library.indexOf(_photo.id) ?? _resolvedIndex;
    _navDirection = target >= current ? 1 : -1;
    final generation = ++_navGeneration;
    _pendingIndex = target;
    _navigationThumbnail?.release();
    _navigationThumbnail = null;
    setState(() => _navigating = true);
    final photo = await ref.read(localLibraryProvider.notifier).photoAt(target);
    if (!mounted || generation != _navGeneration || _editing) return;
    if (photo != null) {
      final gateway = ref.read(coreGatewayProvider) as LocalLibraryGateway;
      final pool = ThumbnailPool.forGateway(gateway);
      final thumbnail = pool.acquire(
        photo,
        pool.bestAvailableSize(photo) ?? 512,
      );
      _navigationThumbnail = thumbnail;
      try {
        // Decode the target original while waiting for its thumbnail so the
        // cross-fade starts with both the foreground and blurred fill ready.
        final original = boundedViewerImage(
          photo.path,
          photo,
          MediaQuery.sizeOf(context),
          MediaQuery.devicePixelRatioOf(context),
        );
        await Future.wait([
          thumbnail.future.then<void>((path) async {
            if (!mounted || generation != _navGeneration) return;
            await precacheImage(
              ThumbnailImage.file(path, photo),
              context,
              onError: (_, _) {},
            );
          }),
          precacheImage(original, context, onError: (_, _) {}),
        ]).timeout(const Duration(milliseconds: 400));
      } catch (_) {
        /* A failed preview must not trap navigation. */
      }
      if (!mounted || generation != _navGeneration || _editing) return;
      _centerStripOn(target);
    }
    _navigationThumbnail?.release();
    _navigationThumbnail = null;
    setState(() {
      _navigating = false;
      _pendingIndex = null;
      _videoControlsVisible = false;
      if (photo != null &&
          ref.read(localLibraryProvider).queryEpoch == library.queryEpoch) {
        _photo = photo;
        _resolvedIndex = target;
        _transform.value = Matrix4.identity();
      }
    });
  }

  Future<void> _move(int delta) async {
    final index =
        _pendingIndex ??
        ref.read(localLibraryProvider).indexOf(_photo.id) ??
        _resolvedIndex;
    await _jumpTo(index + delta);
  }

  void _toggleMobileChrome() {
    if (_editing) return;
    if (_detailsOpen) {
      setState(() => _detailsOpen = false);
      return;
    }
    setState(() => _chromeHidden = !_chromeHidden);
  }

  bool _swipeAllowed(LocalPhoto photo) {
    if (!_mobileLayout || _editing || _detailsOpen || _navigating) {
      return false;
    }
    if (_showMotion) return false;
    if (photo.mediaKind == 'video' && _videoControlsVisible) {
      // Let the seek bar own horizontal drags while the player chrome is up.
      return false;
    }
    return _scale <= _minScale + .01;
  }

  void _videoControlsChanged(bool visible) {
    if (!mounted || _videoControlsVisible == visible) return;
    setState(() => _videoControlsVisible = visible);
  }

  /// One-finger horizontal swipe. It deliberately uses a raw [Listener] so a
  /// zoomed [InteractiveViewer] keeps its pan gesture; navigation is disabled
  /// while the image is scaled above fit.
  void _swipeDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse) return;
    final photo = _currentPhoto;
    if (!_swipeAllowed(photo)) return;
    if (_swipePointer != null) {
      // A second finger means pinch, never a page turn.
      _cancelSwipe();
      return;
    }
    _swipePointer = event.pointer;
    // Catching a settling page continues from where it is on screen instead of
    // teleporting back to centre.
    _swipeStart = event.localPosition - Offset(_swipe.value, 0);
    _swipeHorizontal = false;
    _swipeVelocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.localPosition);
    _swipeReturn.stop();
    _swipeCommitIndex = null;
    _swipeTo = _swipe.value;
  }

  void _swipeMove(PointerMoveEvent event) {
    if (event.pointer != _swipePointer) return;
    final start = _swipeStart;
    if (start == null) return;
    final delta = event.localPosition - start;
    if (!_swipeHorizontal) {
      if (delta.dx.abs() > 14 && delta.dx.abs() > delta.dy.abs() * 1.15) {
        _swipeHorizontal = true;
      } else if (delta.dy.abs() > 14) {
        _cancelSwipe();
        return;
      }
    }
    if (!_swipeHorizontal) return;
    _swipeVelocity?.addPosition(event.timeStamp, event.localPosition);
    final width = MediaQuery.sizeOf(context).width;
    final library = ref.read(localLibraryProvider);
    final index = library.indexOf(_photo.id) ?? _resolvedIndex;
    final beyondStart = delta.dx > 0 && index <= 0;
    final beyondEnd = delta.dx < 0 && index + 1 >= library.total;
    // Rubber-band at the ends instead of dragging a blank page halfway in.
    final limit = beyondStart || beyondEnd ? width * .12 : width;
    _swipe.value = delta.dx.clamp(-limit, limit);
  }

  void _swipeUp(PointerUpEvent event) {
    if (event.pointer != _swipePointer) return;
    final horizontal = _swipeHorizontal;
    final dx = _swipe.value;
    _swipeVelocity?.addPosition(event.timeStamp, event.localPosition);
    final velocity = _swipeVelocity?.getVelocity().pixelsPerSecond.dx ?? 0;
    _swipePointer = null;
    _swipeStart = null;
    _swipeVelocity = null;
    _swipeHorizontal = false;
    if (!horizontal) {
      _settleSwipe();
      return;
    }
    final width = MediaQuery.sizeOf(context).width;
    final library = ref.read(localLibraryProvider);
    final index = library.indexOf(_photo.id) ?? _resolvedIndex;
    final fast = velocity.abs() >= 350;
    final forward = fast ? velocity < 0 : dx < 0;
    final target = index + (forward ? 1 : -1);
    final commit =
        (fast || dx.abs() >= math.max(56.0, width * .16)) &&
        target >= 0 &&
        target < library.total &&
        library.photoAt(target) != null;
    if (!commit) {
      _settleSwipe();
      return;
    }
    // Finish the page turn from wherever the finger left it; the neighbour
    // preview then hands over to the real stage without another load pause.
    _animateSwipe(forward ? -width : width, commitIndex: target);
  }

  void _cancelSwipe() {
    _swipePointer = null;
    _swipeStart = null;
    _swipeVelocity = null;
    _swipeHorizontal = false;
    _settleSwipe();
  }

  void _animateSwipe(double target, {int? commitIndex}) {
    _swipeFrom = _swipe.value;
    _swipeTo = target;
    _swipeCommitIndex = commitIndex;
    final width = math.max(MediaQuery.sizeOf(context).width, 1.0);
    final remaining = ((target - _swipeFrom).abs() / width).clamp(0.0, 1.0);
    _swipeReturn.duration = Duration(
      milliseconds: (110 + 130 * remaining).round(),
    );
    _swipeReturn.forward(from: 0);
  }

  void _settleSwipe() {
    if (_swipe.value.abs() < .5) {
      _swipeReturn.stop();
      _swipeCommitIndex = null;
      _swipeFrom = 0;
      _swipeTo = 0;
      _swipe.value = 0;
      return;
    }
    _animateSwipe(0);
  }

  /// The settle animation landed exactly on the neighbouring page, so swap the
  /// stage identity in place. The incoming photo object and its thumbnail are
  /// already resident; the original decodes progressively after this frame.
  void _commitSwipe(int target) {
    if (!mounted) return;
    final library = ref.read(localLibraryProvider);
    final photo = library.photoAt(target);
    if (photo == null) {
      _settleSwipe();
      return;
    }
    final current = library.indexOf(_photo.id) ?? _resolvedIndex;
    _navGeneration++;
    _prefetchGeneration++;
    _prefetchIdentity = null;
    _pendingIndex = null;
    _navigating = false;
    _navigationThumbnail?.release();
    _navigationThumbnail = null;
    _swipe.value = 0;
    // Move the strip by the same tile that the follow translation consumed in
    // this frame, so clearing that translation does not flick it back.
    _centerStripOn(target);
    setState(() {
      _stageEpoch++;
      _navDirection = target >= current ? 1 : -1;
      _photo = photo;
      _resolvedIndex = target;
      _videoControlsVisible = false;
      _transform.value = Matrix4.identity();
    });
  }

  Future<void> _prefetchNeighbors(int index, String identity) async {
    final generation = ++_prefetchGeneration;
    for (final request in _neighborThumbnails.values) {
      request.release();
    }
    _neighborThumbnails.clear();
    final gateway = ref.read(coreGatewayProvider) as LocalLibraryGateway;
    final controller = ref.read(localLibraryProvider.notifier);
    for (final delta in [-1, 1]) {
      final target = index + delta;
      if (target < 0 || target >= ref.read(localLibraryProvider).total) {
        continue;
      }
      final photo = await controller.photoAt(target);
      if (!mounted ||
          _editing ||
          generation != _prefetchGeneration ||
          identity != _detailsIdentity) {
        return;
      }
      if (photo == null) continue;
      final pool = ThumbnailPool.forGateway(gateway);
      final handle = pool.acquire(
        photo,
        pool.bestAvailableSize(photo) ?? 512,
        priority: 1,
      );
      _neighborThumbnails[target] = handle;
      if (gateway is ThumbnailPipelineGateway && photo.mediaKind == 'image') {
        unawaited(
          (gateway as ThumbnailPipelineGateway)
              .thumbnailCommand({
                'op': 'thumbnailPrefetchSource',
                'id': photo.id,
                'version': photo.contentVersion,
              })
              .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
      }
      unawaited(
        handle.future.then<void>((path) async {
          if (mounted && !_editing && generation == _prefetchGeneration) {
            await precacheImage(
              ThumbnailImage.file(path, photo),
              context,
              onError: (_, _) {},
            );
          }
        }, onError: (Object _, StackTrace _) {}),
      );
    }
  }

  void _toggleImmersive() {
    setState(() {
      _immersive = !_immersive;
      // Immersive browsing hides the chrome until the user leaves it on
      // purpose — a click on the stage, or F/Escape. Pointer movement
      // deliberately does not bring the chrome back.
      _chromeHidden = _immersive;
      if (_immersive) _detailsOpen = false;
    });
  }

  LocalPhoto get _currentPhoto {
    final library = ref.read(localLibraryProvider);
    final index = library.indexOf(_photo.id);
    return index == null ? _photo : library.photoAt(index) ?? _photo;
  }

  void _toggleDetails() => setState(() => _detailsOpen = !_detailsOpen);

  Future<void> _showMobileActions() async {
    final strings = AppStrings.of(context);
    final motion = _hasMotion && !_showMotion;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .5),
      builder: (sheetContext) {
        Widget tile({
          required Key key,
          required IconData icon,
          required String label,
          required String value,
          bool enabled = true,
          Color? color,
        }) => ListTile(
          key: key,
          enabled: enabled,
          leading: Icon(
            icon,
            color: enabled ? (color ?? Colors.white70) : Colors.white24,
          ),
          title: Text(
            label,
            style: TextStyle(
              color: enabled ? (color ?? Colors.white) : Colors.white38,
            ),
          ),
          onTap: enabled ? () => Navigator.of(sheetContext).pop(value) : null,
        );
        return SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: 8),
          child: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: GlassSurface(
                  key: const ValueKey('viewer-more-sheet'),
                  role: GlassRole.overlay,
                  radius: GlassTheme.panelRadius,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (motion)
                        tile(
                          key: const ValueKey('viewer-more-motion'),
                          icon: Icons.play_circle_outline,
                          label: strings.pick('播放动态照片', 'Play motion photo'),
                          value: 'motion',
                        ),
                      tile(
                        key: const ValueKey('viewer-more-edit'),
                        icon: Icons.edit_outlined,
                        label: strings.edit,
                        value: 'edit',
                        enabled: _editAllowed,
                      ),
                      tile(
                        key: const ValueKey('viewer-more-details'),
                        icon: Icons.info_outline,
                        label: strings.details,
                        value: 'details',
                      ),
                      const Divider(height: 1),
                      tile(
                        key: const ValueKey('viewer-more-trash'),
                        icon: Icons.delete_outline,
                        label: strings.moveToTrash,
                        value: 'trash',
                        color: const Color(0xffff6b6b),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'motion':
        setState(() {
          _videoControlsVisible = false;
          _showMotion = true;
        });
      case 'edit':
        unawaited(_openEditor());
      case 'details':
        setState(() => _detailsOpen = true);
      case 'trash':
        unawaited(_deleteCurrent());
    }
  }

  void _toast(String text, {Future<void> Function()? undo}) {
    if (!mounted) return;
    // Keep the toast clear of the bottom chrome instead of spanning the
    // whole stage.
    final width = MediaQuery.sizeOf(context).width;
    final side = width < 392 ? 16.0 : (width - 360) / 2;
    final bottom = _stripHeight + 28 + _bottomSafeInset;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          // SnackBars with an action default to persistent in this SDK; an
          // undo toast must still expire so it cannot cover the chrome.
          persist: false,
          margin: EdgeInsets.fromLTRB(side, 8, side, bottom),
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

  void _startMotionHold() {
    if (!_hasMotion || _showMotion) return;
    _motionHeld = true;
    setState(() {
      _videoControlsVisible = false;
      _showMotion = true;
    });
  }

  /// Live-photo style hold: releasing ends the clip once it is actually
  /// playing. A release while the embedded video is still being extracted
  /// lets that requested clip finish instead of aborting it unseen.
  void _endMotionHold() {
    if (!_motionHeld) return;
    _motionHeld = false;
    if (!_showMotion || !_playbackActive) return;
    setState(() {
      _showMotion = false;
      _playbackActive = false;
      _videoControlsVisible = false;
    });
  }

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
    if (!mounted ||
        _currentPhoto.id != photo.id ||
        _currentPhoto.contentVersion != photo.contentVersion) {
      return;
    }
    if (details?['motion_offset'] != null ||
        details?['animated'] == true ||
        details?['hdr'] == true) {
      return;
    }
    _navGeneration++;
    _prefetchGeneration++;
    _prefetchIdentity = null;
    _pendingIndex = null;
    _navigating = false;
    _navigationThumbnail?.release();
    _navigationThumbnail = null;
    for (final handle in _neighborThumbnails.values) {
      handle.release();
    }
    _neighborThumbnails.clear();
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
      builder: (context) => GlassAlertDialog(
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
      _videoControlsVisible = false;
      _transform.value = Matrix4.identity();
    });
  }

  Future<void> _renameCurrent() async {
    final strings = AppStrings.of(context);
    final photo = _currentPhoto;
    var name = photo.name;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text(strings.renamePhoto),
        content: TextFormField(
          key: const ValueKey('viewer-rename-field'),
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
            key: const ValueKey('viewer-rename-confirm'),
            onPressed: () => Navigator.of(context).pop(name),
            child: Text(strings.save),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || result == photo.name) return;
    try {
      final updated = await ref
          .read(localLibraryProvider.notifier)
          .renamePhoto(photo.id, result);
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
    final layout = _stripLayout;
    if (layout == null || index < 0 || index >= layout.count) return;
    // A varied-extent list can still estimate its far end from the first
    // visible items. Our measured target is exact for the declared item widths;
    // do not truncate it to a stale estimate before the destination lays out.
    final target = math.max(
      position.minScrollExtent,
      layout.centeredOffset(index, position.viewportDimension),
    );
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
    // Captured above the forced dark stage theme so the fill veil follows the
    // app's light/dark setting instead of always reading as night mode.
    final scheme = Theme.of(context).colorScheme;
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
    final mobile = ref.watch(libraryLayoutProvider) == LibraryLayout.mobile;
    final canPrevious = !_navigating && index != null && index > 0;
    final canNext = !_navigating && index != null && index + 1 < library.total;

    if (_stripEpoch != library.queryEpoch) {
      _stripEpoch = library.queryEpoch;
      _scheduledPages.clear();
      _stripCentered = null;
    }
    _updateStripLayout(library);
    if (index != null && (_stripCentered != photo.id || !_strip.hasClients)) {
      _stripCentered = photo.id;
      _stripPendingCenter = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _centerStripOn(index);
          _stripPendingCenter = false;
        }
      });
    }

    final identity = '${photo.id}:${photo.contentVersion}';
    if (_detailsIdentity != identity) {
      _detailsIdentity = identity;
      _editAllowed = false;
      _showMotion = false;
      _hasMotion = false;
      _motionHeld = false;
      _playbackActive = false;
      _videoControlsVisible = false;
      _animated = photo.mimeType == 'image/gif';
      _details = MediaMetadataCache.load(
        gateway,
        photo,
        () => controller.localCommand({
          'op': 'metadata',
          'id': photo.id,
          'version': photo.contentVersion,
        }),
      ).catchError((Object error) => <String, dynamic>{});
      _details!.then((data) {
        if (mounted && _detailsIdentity == identity) {
          final motion = data['motion_offset'] != null;
          final autoPlay = ref.read(presentationProvider).autoPlayMotionPhoto;
          setState(() {
            if (data.isNotEmpty) _animated = data['animated'] == true;
            _hasMotion = motion;
            _editAllowed =
                data.isNotEmpty &&
                photo.mediaKind == 'image' &&
                [
                  'image/jpeg',
                  'image/png',
                  'image/webp',
                ].contains(photo.mimeType) &&
                data['animated'] != true &&
                data['hdr'] != true &&
                data['motion_offset'] == null;
            // The pre-refactor client could start the clip right away when the
            // preference was on.
            _videoControlsVisible = false;
            if (motion && autoPlay) _showMotion = true;
          });
        }
      });
      _motionVideo = null;
      _animatedFrames = null;
      _preview = photo.mimeType == 'image/heic'
          ? controller
                .localCommand({'op': 'preview', 'id': photo.id})
                .then((value) => value as String?)
          : null;
    }

    final prefetchIdentity = '$identity:${library.queryEpoch}';
    if (!_editing && index != null && _prefetchIdentity != prefetchIdentity) {
      _prefetchIdentity = prefetchIdentity;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !_editing &&
            _detailsIdentity == identity &&
            _prefetchIdentity == prefetchIdentity) {
          unawaited(_prefetchNeighbors(index, identity));
        }
      });
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
            child: Scaffold(
              key: const ValueKey('viewer'),
              backgroundColor: const Color(0xff10131a),
              body: Stack(
                fit: StackFit.expand,
                children: [
                  KeyedSubtree(
                    key: ValueKey('viewer-stage-epoch-$_stageEpoch'),
                    child: AnimatedSwitcher(
                      key: const ValueKey('viewer-stage-switcher'),
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      // Fade the incoming stage over an opaque outgoing one.
                      // Fading both toward zero would dim the composite and
                      // briefly expose the dark scaffold (a visible blink).
                      transitionBuilder: (child, animation) => AnimatedBuilder(
                        animation: animation,
                        builder: (context, child) {
                          final outgoing =
                              animation.status == AnimationStatus.reverse;
                          // Touch pages slide with the swipe; desktop keeps its
                          // existing cross-fade.
                          final shift = mobile
                              ? (outgoing ? -1.0 : 1.0) *
                                    _navDirection *
                                    .10 *
                                    (1 - animation.value)
                              : 0.0;
                          return Opacity(
                            opacity: outgoing ? 1 : animation.value,
                            child: FractionalTranslation(
                              translation: Offset(shift, 0),
                              child: child,
                            ),
                          );
                        },
                        child: child,
                      ),
                      // The photo, its blurred fill, and its frame all live in
                      // one stage, so both media and backdrop cross-fade.
                      layoutBuilder: (current, previous) => Stack(
                        fit: StackFit.expand,
                        children: [...previous, ?current],
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(
                          'viewer-stage-${photo.id}-${photo.contentVersion}',
                        ),
                        child: Builder(
                          builder: (context) {
                            final videoStage =
                                photo.mediaKind == 'video' || _showMotion;
                            Widget stage = GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              // Tap reveals/hides the touch chrome; desktop
                              // keeps click-to-leave-immersive. Video taps
                              // belong to the player's own touch controls.
                              onTap: mobile
                                  ? (videoStage ? null : _toggleMobileChrome)
                                  : (_immersive ? _toggleImmersive : null),
                              onLongPressStart: _hasMotion
                                  ? (_) => _startMotionHold()
                                  : null,
                              onLongPressEnd: _hasMotion
                                  ? (_) => _endMotionHold()
                                  : null,
                              child: _stage(context, strings, photo, scheme),
                            );
                            if (mobile) {
                              final previous = index != null && index > 0
                                  ? library.photoAt(index - 1)
                                  : null;
                              final next =
                                  index != null && index + 1 < library.total
                                  ? library.photoAt(index + 1)
                                  : null;
                              Widget? neighbour(LocalPhoto? photo, Key key) =>
                                  photo == null
                                  ? null
                                  : _NeighborPreview(
                                      key: key,
                                      photo: photo,
                                      gateway: gateway,
                                      scheme: scheme,
                                    );
                              stage = Listener(
                                behavior: HitTestBehavior.opaque,
                                onPointerDown: _swipeDown,
                                onPointerMove: _swipeMove,
                                onPointerUp: _swipeUp,
                                onPointerCancel: (_) => _cancelSwipe(),
                                child: _SwipeStage(
                                  offset: _swipe,
                                  previous: neighbour(
                                    previous,
                                    const ValueKey(
                                      'viewer-swipe-preview-previous',
                                    ),
                                  ),
                                  next: neighbour(
                                    next,
                                    const ValueKey('viewer-swipe-preview-next'),
                                  ),
                                  stage: stage,
                                ),
                              );
                            }
                            return stage;
                          },
                        ),
                      ),
                    ),
                  ),
                  ..._notices(strings, library, index),
                  // Zoom lives in the stage's top-right corner, just below
                  // the header; touch layouts use pinch instead.
                  if (!mobile)
                    Positioned(
                      top: _headerInset + 8,
                      right: 16,
                      child: _RevealRegion(
                        revealed:
                            !_chromeHidden &&
                            !_editing &&
                            !_detailsOpen &&
                            photo.mediaKind == 'image' &&
                            !_showMotion,
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
                              child: Text('$_zoomPercent%'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Positioned(
                    key: const ValueKey('viewer-header-position'),
                    // Keep the floating glass below the status bar instead of
                    // stretching into it with the safe area inside the pill.
                    top: mobile ? MediaQuery.paddingOf(context).top + 8 : 8,
                    left: mobile ? 12 : 8,
                    right: mobile ? 12 : 8,
                    child: _RevealRegion(
                      revealed: !_chromeHidden,
                      foldOffset: const Offset(0, -.35),
                      glass: true,
                      child: _header(
                        strings: strings,
                        photo: photo,
                        index: index,
                        library: library,
                        controller: controller,
                        mobile: mobile,
                      ),
                    ),
                  ),
                  Positioned(
                    key: const ValueKey('viewer-filmstrip-position'),
                    bottom: 12 + _bottomSafeInset,
                    left: 12,
                    right: 12,
                    child: _RevealRegion(
                      revealed: !_chromeHidden,
                      foldOffset: const Offset(0, .35),
                      glass: true,
                      child: _filmstrip(
                        library: library,
                        index: index,
                        gateway: gateway,
                      ),
                    ),
                  ),
                  if (!mobile)
                    Positioned(
                      key: const ValueKey('viewer-navigation-position'),
                      right: 16,
                      bottom: _navigationBottom,
                      child: _RevealRegion(
                        revealed: !_chromeHidden,
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
                    ),
                  if (_detailsOpen && index != null)
                    _detailsPanel(strings, photo),
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
                        },
                      ),
                    ),
                  // No exit control on screen: immersive browsing leaves only
                  // through a click on the stage (or the F/Escape keys).
                ],
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

  Widget _stage(
    BuildContext context,
    AppStrings strings,
    LocalPhoto photo,
    ColorScheme scheme,
  ) {
    final gateway = ref.read(coreGatewayProvider) as LocalLibraryGateway;
    ImageProvider? fillPlaceholder() {
      final pool = ThumbnailPool.forGateway(gateway);
      final size = pool.bestAvailableSize(photo);
      final path = size == null ? null : pool.cachedPath(photo, size);
      return path == null ? null : ThumbnailImage.file(path, photo);
    }

    final videoInset = _chromeHidden
        ? 0.0
        : _videoControlsInset + _bottomSafeInset;
    void playbackChanged(bool active) {
      if (mounted &&
          _detailsIdentity == '${photo.id}:${photo.contentVersion}' &&
          _playbackActive != active) {
        setState(() => _playbackActive = active);
      }
    }

    Widget thumbnail() => ViewerThumbnail(photo: photo, gateway: gateway);
    // Videos sit on the same decorative backdrop and frame as stills so the
    // stage reads consistently and letterboxing never shows bare scaffolding.
    Widget videoStage(Widget child) => Stack(
      fit: StackFit.expand,
      children: [
        _VideoFillBackdrop(photo: photo, gateway: gateway, scheme: scheme),
        _PhotoStageFrame(photo: photo, scheme: scheme, child: child),
      ],
    );
    Widget still() => ProgressiveImage(
      key: ValueKey('viewer-still-${photo.id}-${photo.contentVersion}'),
      image: boundedViewerImage(
        photo.path,
        photo,
        MediaQuery.sizeOf(context),
        MediaQuery.devicePixelRatioOf(context),
      ),
      placeholder: thumbnail(),
      semanticLabel: photo.name,
    );
    if (photo.mediaKind == 'video') {
      return KeyedSubtree(
        key: ValueKey(photo.id),
        child: KeyedSubtree(
          key: const ValueKey('viewer-video'),
          child: videoStage(
            LocalVideoStage(
              key: _videoKey,
              path: photo.path,
              placeholder: thumbnail(),
              bottomInset: videoInset,
              onPlaybackActiveChanged: playbackChanged,
              onControlsVisibilityChanged: _videoControlsChanged,
            ),
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
                child: videoStage(
                  LocalVideoStage(
                    key: _videoKey,
                    path: snapshot.data as String,
                    placeholder: still(),
                    bottomInset: videoInset,
                    onPlaybackActiveChanged: playbackChanged,
                    onControlsVisibilityChanged: _videoControlsChanged,
                    onCompleted: () {
                      if (mounted &&
                          _detailsIdentity ==
                              '${photo.id}:${photo.contentVersion}') {
                        setState(() {
                          _showMotion = false;
                          _videoControlsVisible = false;
                        });
                      }
                    },
                  ),
                ),
              )
            : still(),
      );
    }
    if (_animated) {
      return FutureBuilder<List<AnimatedFrame>>(
        future: _animatedFrames ??= ref
            .read(localLibraryProvider.notifier)
            .localCommand({'op': 'animatedFrames', 'id': photo.id})
            .then(
              (value) => (value as List)
                  .map(
                    (entry) => AnimatedFrame.fromJson(
                      Map<String, dynamic>.from(entry as Map),
                    ),
                  )
                  .toList(),
            ),
        builder: (context, snapshot) {
          final frames = snapshot.data;
          if (frames == null || frames.isEmpty) return still();
          final image = boundedViewerImage(
            photo.path,
            photo,
            MediaQuery.sizeOf(context),
            MediaQuery.devicePixelRatioOf(context),
            scale: _scale,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              _PhotoFillBackdrop(image: image, scheme: scheme),
              InteractiveViewer(
                key: ValueKey(
                  'viewer-image-${photo.id}-${photo.contentVersion}',
                ),
                transformationController: _transform,
                minScale: _minScale,
                maxScale: _maxScale,
                child: SizedBox.expand(
                  child: _PhotoStageFrame(
                    photo: photo,
                    scheme: scheme,
                    child: AnimatedImageStage(
                      frames: frames,
                      placeholder: thumbnail(),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }
    if (photo.mimeType == 'image/heic') {
      return FutureBuilder<String?>(
        future: _preview,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return thumbnail();
          final image = LocalPhotoImage(snapshot.data!, photo);
          return Stack(
            fit: StackFit.expand,
            children: [
              _PhotoFillBackdrop(image: image, scheme: scheme),
              InteractiveViewer(
                key: const ValueKey('viewer-heic'),
                transformationController: _transform,
                minScale: _minScale,
                maxScale: _maxScale,
                onInteractionEnd: (_) {
                  _decodeDebounce?.cancel();
                  _decodeDebounce = Timer(
                    const Duration(milliseconds: 150),
                    () {
                      if (mounted) setState(() {});
                    },
                  );
                },
                child: Center(
                  child: _PhotoStageFrame(
                    photo: photo,
                    scheme: scheme,
                    child: ProgressiveImage(
                      image: image,
                      placeholder: thumbnail(),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        final image = boundedViewerImage(
          photo.path,
          photo,
          constraints.biggest,
          MediaQuery.devicePixelRatioOf(context),
          scale: _scale,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            _PhotoFillBackdrop(
              image: image,
              scheme: scheme,
              placeholder: fillPlaceholder(),
            ),
            InteractiveViewer(
              key: ValueKey('viewer-image-${photo.id}-${photo.contentVersion}'),
              transformationController: _transform,
              minScale: _minScale,
              maxScale: _maxScale,
              child: SizedBox.expand(
                child: _PhotoStageFrame(
                  photo: photo,
                  scheme: scheme,
                  child: ProgressiveImage(
                    placeholder: thumbnail(),
                    image: image,
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
              ),
            ),
          ],
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
        top: _immersive
            ? 12
            : (_mobileLayout ? _mobileHeaderBottom + 4 : _headerInset + 8),
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
    required bool mobile,
  }) {
    if (mobile) {
      return GlassSurface(
        key: const ValueKey('viewer-header'),
        role: GlassRole.raised,
        live: true,
        radius: GlassTheme.panelRadius,
        child: SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: _mobileHeader(
              strings: strings,
              photo: photo,
              index: index,
              library: library,
              controller: controller,
            ),
          ),
        ),
      );
    }
    return _headerDesktop(
      strings: strings,
      photo: photo,
      index: index,
      library: library,
      controller: controller,
    );
  }

  Widget _headerDesktop({
    required AppStrings strings,
    required LocalPhoto photo,
    required int? index,
    required LibraryViewState library,
    required LocalLibraryController controller,
  }) => GlassSurface(
    key: const ValueKey('viewer-header'),
    role: GlassRole.raised,
    live: true,
    radius: GlassTheme.panelRadius,
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Close plus five actions (seven controls once the motion play
            // control appears) overflow the chrome on a narrow rail; tighten
            // them instead of dropping actions the window can still show.
            final compact = constraints.maxWidth < 320;
            final actionStyle = compact ? _compactChromeStyle : _chromeStyle;
            final motionToggle = _hasMotion && !_showMotion;
            // Only the name may flex: a loose flex date would keep its share
            // of the free space and leave the actions stranded mid-header.
            final chromeWidth = compact ? 40.0 : 48.0;
            final metaMax = math.max(
              0.0,
              constraints.maxWidth -
                  chromeWidth * (motionToggle ? 7 : 6) -
                  10 -
                  40,
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
                if (motionToggle)
                  IconButton(
                    key: const ValueKey('viewer-motion-toggle'),
                    style: actionStyle,
                    tooltip: strings.pick('播放动态照片', 'Play motion photo'),
                    icon: const Icon(Icons.play_circle_outline),
                    onPressed: () => setState(() {
                      _videoControlsVisible = false;
                      _showMotion = true;
                    }),
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

  Widget _mobileHeader({
    required AppStrings strings,
    required LocalPhoto photo,
    required int? index,
    required LibraryViewState library,
    required LocalLibraryController controller,
  }) {
    final actionStyle = _compactChromeStyle;
    final motionToggle = _hasMotion && !_showMotion;
    final date = _dateLabel(
      context,
      strings,
      photo.captureTimeMs ?? photo.modifiedMs,
    );
    final position = index != null && library.total > 0
        ? strings.positionLabel(index + 1, library.total)
        : null;
    return Row(
      children: [
        IconButton(
          key: const ValueKey('viewer-close'),
          style: actionStyle,
          tooltip: strings.back,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                photo.name,
                key: const ValueKey('viewer-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                position == null ? date : '$date · $position',
                key: const ValueKey('viewer-mobile-meta'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: .62),
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        if (motionToggle)
          IconButton(
            key: const ValueKey('viewer-motion-toggle'),
            style: actionStyle,
            tooltip: strings.pick('播放动态照片', 'Play motion photo'),
            icon: const Icon(Icons.play_circle_outline),
            onPressed: () => setState(() {
              _videoControlsVisible = false;
              _showMotion = true;
            }),
          ),
        IconButton(
          key: const ValueKey('viewer-favorite'),
          style: actionStyle,
          tooltip: photo.favorite
              ? strings.unmarkFavorite
              : strings.markFavorite,
          isSelected: photo.favorite,
          selectedIcon: const Icon(Icons.favorite, color: Color(0xffff5c72)),
          icon: const Icon(Icons.favorite_border),
          onPressed: library.favoritePending.contains(photo.id)
              ? null
              : () => controller.setFavorite(photo),
        ),
        IconButton(
          key: const ValueKey('viewer-more'),
          style: actionStyle,
          tooltip: strings.pick('更多', 'More'),
          icon: const Icon(Icons.more_horiz),
          onPressed: () => unawaited(_showMobileActions()),
        ),
      ],
    );
  }

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

  Future<void> _prepareFilmstrip(
    LibraryViewState library,
    int? index,
    LocalLibraryGateway gateway,
    double width,
  ) {
    final layout = _stripLayout!;
    final inset = layout.leadingInset(width);
    final offset = !_stripPendingCenter && _strip.hasClients
        ? _strip.offset
        : layout.count == 0
        ? 0.0
        : math.max(0.0, layout.centeredOffset(index ?? 0, width));
    // Prepare only the visible strip and its neighbours.
    final first = layout.indexAt(offset - inset);
    final last = layout.count == 0
        ? 0
        : layout.indexAt(offset + width - inset) + 1;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final pool = ThumbnailPool.forGateway(gateway);
    final key =
        '${library.queryEpoch}:${library.revision}:${pool.epoch.value}:'
        '${layout.height}:${layout.count}:$first:$last:$dpr:'
        '${[for (var i = first; i < last; i++) '${library.photoAt(i)?.id}:${library.photoAt(i)?.contentVersion}'].join(',')}';
    if (_stripWarmKey == key) return _stripWarmFuture!;
    _stripWarmKey = key;
    final generation = ++_stripWarmGeneration;
    for (final request in _stripWarmRequests.toList()) {
      request.release();
    }
    _stripWarmRequests.clear();
    return _stripWarmFuture = Future<void>.microtask(() async {
      await Future.wait([
        for (
          var i = math.max(0, first - 1);
          i < math.min(library.total, last + 1);
          i++
        )
          () async {
            ThumbnailHandle? request;
            try {
              final photo =
                  library.photoAt(i) ??
                  await ref.read(localLibraryProvider.notifier).photoAt(i);
              if (!mounted ||
                  generation != _stripWarmGeneration ||
                  photo == null) {
                return;
              }
              final size = layout.sizeAt(i);
              request = pool.acquire(
                photo,
                thumbnailSizeClassFor(size.longestSide * dpr),
              );
              _stripWarmRequests.add(request);
              final path = await request.future;
              if (!mounted || generation != _stripWarmGeneration) return;
              // A stale decoder must not pin strip preparation forever; the
              // strip already reveals itself after a short deadline.
              await precacheImage(
                ThumbnailImage.file(
                  path,
                  photo,
                  width: thumbnailDecodeWidth(size.width * dpr),
                ),
                context,
                onError: (_, _) {},
              ).timeout(
                const Duration(milliseconds: 400),
                onTimeout: () {},
              );
            } catch (_) {
              // Failed cells settle to their existing unavailable-thumbnail tile.
            } finally {
              if (request != null) {
                request.release();
                _stripWarmRequests.remove(request);
              }
            }
          }(),
      ]);
    });
  }

  Widget _filmstrip({
    required LibraryViewState library,
    required int? index,
    required LocalLibraryGateway gateway,
  }) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: LayoutBuilder(
        builder: (context, constraints) => ViewerFilmstripVisibility(
          ready: _prepareFilmstrip(
            library,
            index,
            gateway,
            constraints.maxWidth,
          ),
          // Touch users cannot hover to recover a hidden strip. The phone
          // keeps it available until the user folds the viewer chrome.
          playbackActive: !_mobileLayout && _playbackActive,
          child: GlassSurface(
            key: const ValueKey('viewer-filmstrip'),
            role: GlassRole.raised,
            radius: GlassTheme.panelRadius,
            child: SizedBox(
              height: _stripHeight,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final layout = _stripLayout!;
                  final list = ListView.builder(
                    controller: _strip,
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: EdgeInsets.only(
                      left: layout.leadingInset(constraints.maxWidth),
                      right: layout.trailingInset(constraints.maxWidth),
                    ),
                    itemExtentBuilder: (index, _) => layout.extentAt(index),
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
                        return Center(
                          child: SizedBox(
                            width: _stripThumb,
                            height: _stripThumb,
                            child: const Icon(
                              Icons.photo_outlined,
                              color: Colors.white24,
                            ),
                          ),
                        );
                      }
                      // A loaded page can be evicted later; allow another request.
                      _scheduledPages.remove(
                        i ~/ LocalLibraryController.pageSize,
                      );
                      final active = i == index;
                      final size = layout.sizeAt(i);
                      // Selection changes paint scale only. Width, spacing and
                      // centre offsets remain stable throughout navigation.
                      return Center(
                        child: Tooltip(
                          message: photo.name,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              key: ValueKey('viewer-strip-${photo.id}'),
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => unawaited(_jumpTo(i)),
                              child: Semantics(
                                selected: active,
                                child: SizedBox(
                                  width: size.width,
                                  height: size.height,
                                  child: Center(
                                    child: AnimatedScale(
                                      scale: active
                                          ? ViewerFilmstripLayout.activeScale
                                          : 1,
                                      duration:
                                          MediaQuery.disableAnimationsOf(
                                            context,
                                          )
                                          ? Duration.zero
                                          : const Duration(milliseconds: 150),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: SizedBox(
                                          key: ValueKey(
                                            'viewer-strip-image-${photo.id}',
                                          ),
                                          width: size.width,
                                          height: size.height,
                                          child: _FilmstripThumb(
                                            photo: photo,
                                            gateway: gateway,
                                            size: size,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                  return ValueListenableBuilder<double>(
                    valueListenable: _swipe,
                    child: list,
                    builder: (context, dx, child) => Transform.translate(
                      offset: Offset(_stripFollow(dx, layout, index), 0),
                      child: child,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// One filmstrip tile per full page travelled: the strip follows the page
  /// turn in phase, and a cancelled swipe walks it back with the photo.
  double _stripFollow(double dx, ViewerFilmstripLayout layout, int? index) {
    if (dx == 0 || index == null) return 0;
    final target = index + (dx < 0 ? 1 : -1);
    if (target < 0 || target >= layout.count) return 0;
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return 0;
    return (dx / width).clamp(-1.0, 1.0) * layout.extentAt(index);
  }

  /// Overlay glass side panel sliding over the stage's right side; the media
  /// stays visible behind it and the stage is never re-laid-out.
  Widget _detailsPanel(AppStrings strings, LocalPhoto photo) {
    final modified = DateTime.fromMillisecondsSinceEpoch(photo.modifiedMs)
        .toLocal();
    final localizations = MaterialLocalizations.of(context);
    return Positioned(
      top: _mobileLayout ? _mobileHeaderBottom : _headerInset,
      bottom: 8,
      right: 8,
      left: 8,
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Transform.translate(
              offset: Offset((1 - t) * 380, 0),
              child: child,
            ),
            child: SizedBox(
              width: 340,
              child: GlassSurface(
                key: const ValueKey('viewer-details-panel'),
                role: GlassRole.overlay,
                radius: GlassTheme.panelRadius,
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
                                    if (data['motion_offset'] != null &&
                                        !_showMotion)
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: IconButton(
                                          key: const ValueKey(
                                            'viewer-details-motion-toggle',
                                          ),
                                          icon: const Icon(
                                            Icons.play_circle_outline,
                                          ),
                                          onPressed: () => setState(() {
                                            _videoControlsVisible = false;
                                            _showMotion = true;
                                          }),
                                          tooltip: strings.pick(
                                            '播放动态照片',
                                            'Play motion photo',
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

/// One collapsible chrome region. Mirrors the GTK revealers: the header slides
/// down into place, the filmstrip slides up, and the overlay controls
/// crossfade, all over the same 220 ms (instant with reduced motion). The
/// outgoing child is unmounted once the fold finishes, so hidden chrome cannot
/// hold pointer or keyboard focus.
class _RevealRegion extends StatelessWidget {
  const _RevealRegion({
    required this.revealed,
    required this.child,
    this.foldOffset = Offset.zero,
    this.glass = false,
  });

  final bool revealed;
  final Widget child;

  /// Fraction of the region's own size travelled while folding; zero
  /// crossfades in place.
  final Offset foldOffset;

  /// Fades the shader visibility instead of wrapping glass in [Opacity]. An
  /// ancestor opacity forces the backdrop pass into a layer that samples
  /// black, so the glass would flash a dark plate before blurring.
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return IgnorePointer(
      ignoring: !revealed,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.center,
          children: [...previous, ?current],
        ),
        transitionBuilder: (child, animation) => AnimatedBuilder(
          animation: animation,
          child: glass
              ? GlassMaterializeTransition(
                  animation: animation,
                  scaleFrom: 1,
                  contentSigma: 0,
                  child: child,
                )
              : child,
          builder: (context, child) {
            final value = animation.value;
            return FractionalTranslation(
              translation: Offset(
                foldOffset.dx * (1 - value),
                foldOffset.dy * (1 - value),
              ),
              child: glass
                  ? GlassRevealScope(progress: value, child: child!)
                  : Opacity(opacity: value, child: child),
            );
          },
        ),
        child: revealed ? child : const SizedBox.shrink(),
      ),
    );
  }
}

/// The touch page turn: the current stage follows the finger while the
/// neighbouring photo rides in from the opposite edge. Neighbours are built
/// only while the page is actually moving off centre.
class _SwipeStage extends StatelessWidget {
  const _SwipeStage({
    required this.offset,
    required this.stage,
    required this.previous,
    required this.next,
  });

  final ValueListenable<double> offset;
  final Widget stage;
  final Widget? previous, next;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: offset,
    child: stage,
    builder: (context, dx, child) {
      final width = MediaQuery.sizeOf(context).width;
      return Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          if (dx > 0 && previous != null)
            Transform.translate(
              offset: Offset(dx - width, 0),
              child: RepaintBoundary(child: previous),
            ),
          if (dx < 0 && next != null)
            Transform.translate(
              offset: Offset(dx + width, 0),
              child: RepaintBoundary(child: next),
            ),
          Transform.translate(offset: Offset(dx, 0), child: child),
        ],
      );
    },
  );
}

/// Still preview of the page entering from either side. It mirrors the framed
/// thumbnail and blurred fill of the settled stage so the swipe hand-off does
/// not visibly swap artwork mid-page.
class _NeighborPreview extends StatefulWidget {
  const _NeighborPreview({
    super.key,
    required this.photo,
    required this.gateway,
    required this.scheme,
  });

  final LocalPhoto photo;
  final LocalLibraryGateway gateway;

  /// See [_PhotoFillBackdrop.scheme]; captured above the viewer's dark theme.
  final ColorScheme scheme;

  @override
  State<_NeighborPreview> createState() => _NeighborPreviewState();
}

class _NeighborPreviewState extends State<_NeighborPreview> {
  ThumbnailHandle? _request;
  String? _identity;

  @override
  void dispose() {
    _request?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photo;
    final pool = ThumbnailPool.forGateway(widget.gateway);
    final identity = '${photo.id}:${photo.contentVersion}';
    if (_identity != identity) {
      _identity = identity;
      _request?.release();
      _request = pool.acquire(
        photo,
        pool.bestAvailableSize(photo) ?? 512,
        priority: 1,
      );
    }
    final request = _request!;
    return ExcludeSemantics(
      child: ClipRect(
        child: FutureBuilder<String>(
          future: request.future,
          initialData: request.path,
          builder: (context, snapshot) {
            final path = snapshot.data;
            final scheme = widget.scheme;
            final sigma = (MediaQuery.sizeOf(context).shortestSide * .055)
                .clamp(24.0, 72.0)
                .toDouble();
            final scrim = scheme.surface.withValues(
              alpha: scheme.brightness == Brightness.dark ? .58 : .62,
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: scheme.surface),
                if (path != null) ...[
                  ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: sigma,
                      sigmaY: sigma,
                    ),
                    child: Image(
                      image: ThumbnailImage.file(path, photo),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      excludeFromSemantics: true,
                    ),
                  ),
                  ColoredBox(color: scrim),
                  Center(
                    child: _PhotoStageFrame(
                      photo: photo,
                      scheme: scheme,
                      frameKey: null,
                      child: Image(
                        image: ThumbnailImage.file(path, photo),
                        fit: BoxFit.contain,
                        excludeFromSemantics: true,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Draws the photo's own colors into letterbox gaps on either axis. The heavy
/// blur and theme-tinted scrim read as decoration, and the framed original
/// above keeps the true image boundary crisp.
class _PhotoFillBackdrop extends StatelessWidget {
  const _PhotoFillBackdrop({
    required this.image,
    required this.scheme,
    this.placeholder,
  });

  final ImageProvider image;

  /// Already-decoded thumbnail drawn under the bounded original until it
  /// paints. It sits inside the blur layer so a swipe hand-off keeps the fill
  /// soft instead of flashing a sharp thumbnail first.
  final ImageProvider? placeholder;

  /// The app-level scheme, captured above the viewer's forced dark chrome, so
  /// the veil lightens or darkens with the user's theme.
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final sigma = (constraints.biggest.shortestSide * .055)
          .clamp(24.0, 72.0)
          .toDouble();
      final dark = scheme.brightness == Brightness.dark;
      final scrim = scheme.surface.withValues(alpha: dark ? .58 : .62);
      final fade = MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180);
      return IgnorePointer(
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // A solid base keeps the gaps from flashing the dark scaffold
              // while the blurred copy is still decoding.
              ColoredBox(color: scheme.surface),
              ImageFiltered(
                key: const ValueKey('viewer-photo-fill-blur'),
                imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (placeholder != null)
                      Image(
                        key: const ValueKey('viewer-photo-fill-placeholder'),
                        image: placeholder!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    Image(
                      key: const ValueKey('viewer-photo-fill-image'),
                      image: image,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      excludeFromSemantics: true,
                      frameBuilder: (context, child, frame, synchronous) =>
                          AnimatedOpacity(
                            opacity: synchronous || frame != null ? 1 : 0,
                            duration: fade,
                            curve: Curves.easeOut,
                            child: child,
                          ),
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
              ColoredBox(
                key: const ValueKey('viewer-photo-fill-scrim'),
                color: scrim,
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Mirrors [_PhotoFillBackdrop] for videos, which cannot be decoded as images:
/// the thumbnail doubles as the blurred cover fill behind the framed video.
class _VideoFillBackdrop extends StatelessWidget {
  const _VideoFillBackdrop({
    required this.photo,
    required this.gateway,
    required this.scheme,
  });

  final LocalPhoto photo;
  final LocalLibraryGateway gateway;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final sigma = (constraints.biggest.shortestSide * .055)
          .clamp(24.0, 72.0)
          .toDouble();
      final dark = scheme.brightness == Brightness.dark;
      final scrim = scheme.surface.withValues(alpha: dark ? .58 : .62);
      final aspect = _PhotoStageFrame._aspectRatio(photo) ?? 16 / 9;
      return IgnorePointer(
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: scheme.surface),
              ImageFiltered(
                key: const ValueKey('viewer-video-fill-blur'),
                imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: aspect >= 1 ? 1200 : 1200 * aspect,
                    height: aspect >= 1 ? 1200 / aspect : 1200,
                    child: ViewerThumbnail(photo: photo, gateway: gateway),
                  ),
                ),
              ),
              ColoredBox(
                key: const ValueKey('viewer-video-fill-scrim'),
                color: scrim,
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Centers the untouched original at its true aspect ratio and marks its edge
/// with a hairline plus shadow so it cannot be mistaken for the blurred fill.
class _PhotoStageFrame extends StatelessWidget {
  const _PhotoStageFrame({
    required this.photo,
    required this.scheme,
    required this.child,
    this.frameKey = const ValueKey('viewer-photo-frame'),
  });

  final LocalPhoto photo;

  /// See [_PhotoFillBackdrop.scheme]; the hairline and shadow follow it too.
  final ColorScheme scheme;
  final Widget child;
  final Key? frameKey;

  static double? _aspectRatio(LocalPhoto photo) {
    final width = photo.width, height = photo.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return photo.orientation >= 5 ? height / width : width / height;
  }

  @override
  Widget build(BuildContext context) {
    final aspect = _aspectRatio(photo);
    if (aspect == null) return child;
    final dark = scheme.brightness == Brightness.dark;
    final border = Border.all(
      color: scheme.onSurface.withValues(alpha: dark ? .34 : .30),
    );
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: DecoratedBox(
          key: frameKey,
          decoration: BoxDecoration(
            border: border,
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: dark ? .55 : .30),
                blurRadius: 28,
                spreadRadius: 3,
              ),
            ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              // Opaque photos paint over the background decor; redraw the
              // hairline above the child so the true edge stays explicit.
              IgnorePointer(
                child: DecoratedBox(decoration: BoxDecoration(border: border)),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
  var _closing = false;

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

  void _close() {
    // A click and a key can land in the same frame; never pop twice and take
    // the viewer down with the preview.
    if (_closing) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final photo = widget.photo;
    final scheme = Theme.of(context).colorScheme;
    final gateway = ref.read(coreGatewayProvider) as LocalLibraryGateway;
    Widget thumbnail() => ViewerThumbnail(photo: photo, gateway: gateway);
    Widget image(String path) {
      final provider = boundedViewerImage(
        path,
        photo,
        MediaQuery.sizeOf(context),
        MediaQuery.devicePixelRatioOf(context),
        animate: true,
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          _PhotoFillBackdrop(image: provider, scheme: scheme),
          InteractiveViewer(
            maxScale: 8,
            child: Center(
              child: _PhotoStageFrame(
                photo: photo,
                scheme: scheme,
                child: ProgressiveImage(
                  placeholder: thumbnail(),
                  image: provider,
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
            ),
          ),
        ],
      );
    }

    return CallbackShortcuts(
      bindings: {
        // No on-screen exit control: the preview leaves by a click anywhere
        // on the media, or by the same keys that navigation uses — Escape,
        // F/Shift+F, and Alt+Left.
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.keyF): _close,
        const SingleActivator(LogicalKeyboardKey.keyF, shift: true): _close,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _close,
        const SingleActivator(LogicalKeyboardKey.space): () =>
            _video.currentState?.togglePlayback(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const ValueKey('viewer-fullscreen'),
          backgroundColor: Colors.black,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (photo.mediaKind == 'video')
                  LocalVideoStage(
                    key: _video,
                    path: photo.path,
                    placeholder: thumbnail(),
                  )
                else if (photo.mimeType == 'image/heic')
                  FutureBuilder<String?>(
                    future: _preview,
                    builder: (context, snapshot) =>
                        snapshot.hasData ? image(snapshot.data!) : thumbnail(),
                  )
                else
                  image(photo.path),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilmstripThumb extends StatefulWidget {
  const _FilmstripThumb({
    required this.photo,
    required this.gateway,
    required this.size,
  });
  final LocalPhoto photo;
  final LocalLibraryGateway gateway;
  final Size size;
  @override
  State<_FilmstripThumb> createState() => _FilmstripThumbState();
}

class _FilmstripThumbState extends State<_FilmstripThumb> {
  ThumbnailHandle? _request;
  String? _identity;

  @override
  void dispose() {
    _request?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ThumbnailPool.forGateway(widget.gateway).epoch,
    builder: (context, _) => _build(context),
  );
  Widget _build(BuildContext context) {
    final photo = widget.photo;
    final identity =
        '${identityHashCode(widget.gateway)}:${photo.id}:${photo.contentVersion}:${ThumbnailPool.forGateway(widget.gateway).epoch.value}';
    final size = thumbnailSizeClassFor(
      widget.size.longestSide * MediaQuery.devicePixelRatioOf(context),
    );
    if (_identity != '$identity:$size') {
      _identity = '$identity:$size';
      _request?.release();
      _request = ThumbnailPool.forGateway(widget.gateway).acquire(photo, size);
    }
    return FutureBuilder<String>(
      future: _request!.future,
      initialData: _request!.path,
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
          return FutureBuilder<String?>(
            future: _request!.placeholder,
            builder: (context, preview) => preview.data == null
                ? const Center(
                    child: Icon(
                      Icons.photo_outlined,
                      color: Colors.white24,
                      size: 20,
                    ),
                  )
                : Image(
                    image: ThumbnailImage.file(
                      preview.data!,
                      photo,
                      use: ThumbnailUse.embedded,
                    ),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
          );
        }
        final target = thumbnailDecodeWidth(
          widget.size.width * MediaQuery.devicePixelRatioOf(context),
        );
        return Image(
          image: ThumbnailImage.file(path, photo, width: target),
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
    );
  }
}
