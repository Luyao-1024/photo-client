import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/window_controller.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_gateway.dart';
import 'glass_surface.dart';
import 'local_library_controller.dart';
import 'local_photo_image.dart';
import 'presentation_preferences.dart';
import 'strings.dart';

/// Photo editor page. Rotation, crop, and colour adjustments are previewed
/// live and applied by the native core on save, either as a new sibling file
/// or over the original (which keeps a private backup).
class LocalPhotoEditor extends ConsumerStatefulWidget {
  const LocalPhotoEditor({super.key, required this.photo, this.onClosed});

  final LocalPhoto photo;
  final ValueChanged<LocalPhoto?>? onClosed;

  @override
  ConsumerState<LocalPhotoEditor> createState() => LocalPhotoEditorState();
}

class LocalPhotoEditorState extends ConsumerState<LocalPhotoEditor> {
  late LocalPhoto _photo = widget.photo;
  int _rotation = 0;
  int _brightness = 0;
  int _contrast = 0;
  int _saturation = 0;
  Rect? _crop;
  bool _cropMode = false;
  bool _saving = false;
  bool _flipHorizontal = false,
      _flipVertical = false,
      _compare = false,
      _confirming = false;
  String _ratio = 'free';
  Rect? _dragOriginal;
  String _cropDrag = 'new';
  late final Future<bool> Function() _windowGuard = _confirmExit;
  @override
  void initState() {
    super.initState();
    WindowController.instance.confirmClose = _windowGuard;
  }

  @override
  void dispose() {
    if (WindowController.instance.confirmClose == _windowGuard) {
      WindowController.instance.confirmClose = null;
    }
    super.dispose();
  }

  void _finish([LocalPhoto? saved]) {
    if (widget.onClosed != null) {
      widget.onClosed!(saved);
    } else {
      Navigator.of(context).pop(saved);
    }
  }

  Future<void> requestClose() => _close();
  Offset? _dragStart;
  Size _previewSize = Size.zero;

  bool get _dirty =>
      _flipHorizontal ||
      _flipVertical ||
      _rotation % 360 != 0 ||
      _brightness != 0 ||
      _contrast != 0 ||
      _saturation != 0 ||
      _crop != null;

  bool get _canCrop => _photo.width != null && _photo.height != null;

  int get _rotatedWidth => (_rotation % 180 == 0) != (_photo.orientation >= 5)
      ? (_photo.width ?? 0)
      : (_photo.height ?? 0);

  int get _rotatedHeight => (_rotation % 180 == 0) != (_photo.orientation >= 5)
      ? (_photo.height ?? 0)
      : (_photo.width ?? 0);

  EditOptions get _options => EditOptions(
    expectedContentVersion: _photo.contentVersion,
    rotationDegrees: _rotation % 360,
    flipHorizontal: _flipHorizontal,
    flipVertical: _flipVertical,
    brightness: _brightness,
    contrast: _contrast,
    saturation: _saturation,
    crop: _crop == null
        ? null
        : CropBox(
            x: (_crop!.left * _rotatedWidth).round(),
            y: (_crop!.top * _rotatedHeight).round(),
            width: (_crop!.width * _rotatedWidth).round(),
            height: (_crop!.height * _rotatedHeight).round(),
          ),
  );

  void _rotate(int delta) => setState(() {
    _rotation = (_rotation + delta) % 360;
    if (_rotation < 0) _rotation += 360;
    _crop = null;
  });

  void _reset() => setState(() {
    _rotation = 0;
    _flipHorizontal = false;
    _flipVertical = false;
    _compare = false;
    _brightness = 0;
    _contrast = 0;
    _saturation = 0;
    _crop = null;
    _cropMode = false;
  });

  Future<bool> _confirmExit() async {
    if (_saving || _confirming) return false;
    if (!_dirty) return true;
    _confirming = true;
    final strings = AppStrings.of(context);
    try {
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(strings.discardEditsTitle),
              content: Text(strings.discardEditsBody),
              actions: [
                TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(strings.continueEditing),
                ),
                TextButton(
                  key: const ValueKey('editor-discard'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(strings.discard),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      _confirming = false;
    }
  }

  Future<void> _close() async {
    if (await _confirmExit() && mounted) _finish();
  }

  Future<void> _save({required bool copy}) async {
    if (_saving) return;
    final strings = AppStrings.of(context);
    if (!copy) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(strings.saveOverwrite),
          content: Text(
            strings.pick(
              '将覆盖原文件（保留一份备份）。',
              'The original file is replaced (a backup is kept).',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              key: const ValueKey('editor-confirm-overwrite'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(strings.saveOverwrite),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(localLibraryProvider.notifier)
          .saveEdited(_photo.id, _options.copyWith(saveCopy: copy));
      if (!mounted) return;
      setState(() {
        _saving = false;
        _photo = copy ? _photo : saved;
        if (!copy) {
          _rotation = 0;
          _flipHorizontal = false;
          _flipVertical = false;
          _compare = false;
          _brightness = 0;
          _contrast = 0;
          _saturation = 0;
          _crop = null;
        }
      });
      if (copy) {
        _finish(saved);
        return;
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(strings.appliedEdits),
            // A full-width toast would swallow clicks on the sidebar beneath
            // the viewer until it expires.
            behavior: SnackBarBehavior.floating,
            width: math.min(360, MediaQuery.sizeOf(context).width - 32),
          ),
        );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            width: math.min(360, MediaQuery.sizeOf(context).width - 32),
            content: Text(
              error.toString().contains('SourceChanged')
                  ? strings.pick(
                      '原文件已发生变化，请重新打开照片后编辑。',
                      'The original file changed. Reopen the photo before editing.',
                    )
                  : strings.editorFailed,
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final preferences = ref.watch(presentationProvider);
    return Theme(
      data: photoTheme(Brightness.dark),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              unawaited(_close()),
          const SingleActivator(LogicalKeyboardKey.keyE): () =>
              unawaited(_close()),
        },
        child: Focus(
          autofocus: true,
          child: PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) unawaited(_close());
            },
            child: Scaffold(
              key: const ValueKey('editor'),
              backgroundColor: const Color(0xff10131a),
              body: SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final preview = _preview(strings, preferences);
                    final controls = _sidePanel(strings, preferences);
                    return constraints.maxWidth >= 700
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: preview),
                              SizedBox(width: 320, child: controls),
                            ],
                          )
                        : Column(
                            children: [
                              Expanded(child: preview),
                              SizedBox(
                                height: math.min(
                                  350,
                                  constraints.maxHeight * .52,
                                ),
                                child: controls,
                              ),
                            ],
                          );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sidePanel(AppStrings strings, PresentationPreferences preferences) =>
      GlassSurface(
        key: const ValueKey('editor-controls'),
        role: GlassRole.reading,
        enabled: preferences.glass,
        radius: 0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          strings.edit,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (_dirty)
                          Text(
                            strings.pick('有未保存的修改', 'Unsaved changes'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('editor-reset'),
                    tooltip: strings.reset,
                    onPressed: _dirty && !_saving ? _reset : null,
                    icon: const Icon(Icons.restart_alt),
                  ),
                  IconButton(
                    key: const ValueKey('editor-close'),
                    tooltip: strings.close,
                    onPressed: _saving ? null : _close,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(child: _controls(strings, preferences)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_dirty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: OutlinedButton.icon(
                        key: const ValueKey('editor-compare'),
                        onPressed: _saving
                            ? null
                            : () => setState(() => _compare = !_compare),
                        icon: Icon(
                          _compare
                              ? Icons.visibility_off_outlined
                              : Icons.compare_outlined,
                        ),
                        label: Text(
                          strings.pick(
                            _compare ? '查看修改' : '与原图对比',
                            _compare ? 'Show changes' : 'Compare original',
                          ),
                        ),
                      ),
                    ),
                  FilledButton(
                    key: const ValueKey('editor-save-copy'),
                    onPressed: _dirty && !_saving
                        ? () => _save(copy: true)
                        : null,
                    child: Text(_saving ? strings.saving : strings.saveCopy),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: _saving ? null : _close,
                          child: Text(strings.cancel),
                        ),
                      ),
                      Expanded(
                        child: TextButton(
                          key: const ValueKey('editor-save'),
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .error,
                          ),
                          onPressed: _dirty && !_saving
                              ? () => _save(copy: false)
                              : null,
                          child: Text(strings.saveOverwrite),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _preview(AppStrings strings, PresentationPreferences preferences) =>
      Padding(
        padding: const EdgeInsets.all(20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final box = constraints.biggest;
            final w = _compare
                ? (_photo.orientation >= 5 ? _photo.height : _photo.width)
                : _rotatedWidth;
            final h = _compare
                ? (_photo.orientation >= 5 ? _photo.width : _photo.height)
                : _rotatedHeight;
            final fitted = _fitRect(box, (w ?? 1) / (h ?? 1));
            _previewSize = fitted.size;
            return Stack(
              fit: StackFit.expand,
              children: [
                Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.diagonal3Values(
                    !_compare && _flipHorizontal ? -1 : 1,
                    !_compare && _flipVertical ? -1 : 1,
                    1,
                  ),
                  child: RotatedBox(
                    quarterTurns: _compare ? 0 : _rotation ~/ 90,
                    child: ColorFiltered(
                      colorFilter: ColorFilter.matrix(
                        _colorMatrix(
                          _compare ? 0 : _brightness,
                          _compare ? 0 : _contrast,
                          _compare ? 0 : _saturation,
                        ),
                      ),
                      child: Image(
                        image: LocalPhotoImage(_photo.path, _photo),
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stack) => Center(
                          child: Text(
                            strings.imageUnavailable,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!_compare && _cropMode)
                  Positioned.fromRect(
                    rect: fitted,
                    child: GestureDetector(
                      key: const ValueKey('editor-crop-stage'),
                      behavior: HitTestBehavior.opaque,
                      onPanStart: _saving ? null : _cropStart,
                      onPanUpdate: _saving ? null : _cropUpdate,
                      child: CustomPaint(
                        painter: _CropPainter(selection: _crop),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );

  Offset _normalized(Offset point) => Offset(
    (point.dx / _previewSize.width).clamp(0, 1),
    (point.dy / _previewSize.height).clamp(0, 1),
  );
  void _cropStart(DragStartDetails details) {
    if (_previewSize.isEmpty) return;
    final point = _normalized(details.localPosition);
    _dragStart = point;
    _dragOriginal = _crop;
    _cropDrag = 'new';
    final rect = _crop;
    if (rect != null) {
      final corners = {
        'tl': rect.topLeft,
        'tr': rect.topRight,
        'bl': rect.bottomLeft,
        'br': rect.bottomRight,
      };
      for (final entry in corners.entries) {
        if ((entry.value - point).distance < .08) {
          _cropDrag = entry.key;
          return;
        }
      }
      if (rect.contains(point)) {
        _cropDrag = 'move';
        return;
      }
    }
    setState(() => _crop = Rect.fromPoints(point, point));
  }

  double? get _targetAspect => switch (_ratio) {
    'original' => _rotatedWidth / _rotatedHeight,
    '1:1' => 1,
    '4:3' => 4 / 3,
    '3:2' => 3 / 2,
    '16:9' => 16 / 9,
    _ => null,
  };
  void _cropUpdate(DragUpdateDetails details) {
    final start = _dragStart;
    if (start == null || _previewSize.isEmpty) return;
    final point = _normalized(details.localPosition);
    final original = _dragOriginal;
    Rect rect;
    if (_cropDrag == 'move' && original != null) {
      final delta = point - start;
      rect = original.shift(
        Offset(
          delta.dx.clamp(-original.left, 1 - original.right),
          delta.dy.clamp(-original.top, 1 - original.bottom),
        ),
      );
    } else {
      final fixed = original == null
          ? start
          : switch (_cropDrag) {
              'tl' => original.bottomRight,
              'tr' => original.bottomLeft,
              'bl' => original.topRight,
              'br' => original.topLeft,
              _ => start,
            };
      rect = Rect.fromPoints(fixed, point);
      final aspect = _targetAspect;
      if (aspect != null) {
        final normalizedAspect = aspect * _rotatedHeight / _rotatedWidth;
        var width = rect.width;
        var height = width / normalizedAspect;
        if (height > rect.height) {
          height = rect.height;
          width = height * normalizedAspect;
        }
        rect = Rect.fromLTWH(
          point.dx < fixed.dx ? fixed.dx - width : fixed.dx,
          point.dy < fixed.dy ? fixed.dy - height : fixed.dy,
          width,
          height,
        );
      }
    }
    setState(() => _crop = rect);
  }

  Widget _controls(AppStrings strings, PresentationPreferences preferences) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(strings.rotation, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('editor-rotate-left'),
                onPressed: _saving ? null : () => _rotate(-90),
                icon: const Icon(Icons.rotate_90_degrees_ccw_outlined),
                label: Text(strings.rotateLeft),
              ),
              OutlinedButton.icon(
                key: const ValueKey('editor-rotate-right'),
                onPressed: _saving ? null : () => _rotate(90),
                icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
                label: Text(strings.rotateRight),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              IconButton(
                key: const ValueKey('editor-flip-horizontal'),
                tooltip: strings.pick('水平翻转', 'Flip horizontally'),
                onPressed: _saving
                    ? null
                    : () => setState(() => _flipHorizontal = !_flipHorizontal),
                isSelected: _flipHorizontal,
                icon: const Icon(Icons.flip),
              ),
              IconButton(
                key: const ValueKey('editor-flip-vertical'),
                tooltip: strings.pick('垂直翻转', 'Flip vertically'),
                onPressed: _saving
                    ? null
                    : () => setState(() => _flipVertical = !_flipVertical),
                isSelected: _flipVertical,
                icon: const RotatedBox(
                  quarterTurns: 1,
                  child: Icon(Icons.flip),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            key: const ValueKey('editor-crop-ratio'),
            isExpanded: true,
            initialValue: _ratio,
            decoration: InputDecoration(
              labelText: strings.pick('裁剪比例', 'Crop ratio'),
            ),
            items: [
              for (final value in [
                'free',
                'original',
                '1:1',
                '4:3',
                '3:2',
                '16:9',
              ])
                DropdownMenuItem(
                  value: value,
                  child: Text(
                    value == 'free'
                        ? strings.pick('自由', 'Free')
                        : value == 'original'
                        ? strings.pick('原始比例', 'Original')
                        : value,
                  ),
                ),
            ],
            onChanged: _saving
                ? null
                : (value) {
                    if (value != null) {
                      setState(() {
                        _ratio = value;
                        _crop = null;
                        _cropMode = true;
                      });
                    }
                  },
          ),
          const SizedBox(height: 12),
          Text(strings.crop, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                key: const ValueKey('editor-crop-toggle'),
                selected: _cropMode,
                onSelected: !_canCrop || _saving
                    ? null
                    : (value) => setState(() {
                        _cropMode = value;
                      }),
                avatar: const Icon(Icons.crop, size: 18),
                label: Text(
                  _cropMode
                      ? strings.pick('拖动选择区域', 'Drag to select')
                      : strings.crop,
                ),
              ),
              const SizedBox(width: 8),
              if (_crop != null)
                IconButton(
                  key: const ValueKey('editor-crop-clear'),
                  tooltip: strings.cancel,
                  onPressed: _saving
                      ? null
                      : () => setState(() => _crop = null),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _slider(
            key: const ValueKey('editor-brightness'),
            label: strings.brightness,
            value: _brightness,
            onChanged: (value) => setState(() => _brightness = value),
          ),
          _slider(
            key: const ValueKey('editor-contrast'),
            label: strings.contrast,
            value: _contrast,
            onChanged: (value) => setState(() => _contrast = value),
          ),
          _slider(
            key: const ValueKey('editor-saturation'),
            label: strings.saturation,
            value: _saturation,
            onChanged: (value) => setState(() => _saturation = value),
          ),
          if (!_dirty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                strings.noPendingEdits,
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _slider({
    required Key key,
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text('${value > 0 ? '+' : ''}$value'),
        ],
      ),
      Slider(
        key: key,
        value: value.toDouble(),
        min: -100,
        max: 100,
        divisions: 40,
        label: '$value',
        onChanged: _saving ? null : (v) => onChanged(v.round()),
      ),
      const SizedBox(height: 8),
    ],
  );
}

Rect _fitRect(Size box, double aspect) {
  if (box.isEmpty || !aspect.isFinite || aspect <= 0) return Offset.zero & box;
  var width = box.width;
  var height = width / aspect;
  if (height > box.height) {
    height = box.height;
    width = height * aspect;
  }
  return Rect.fromLTWH(
    (box.width - width) / 2,
    (box.height - height) / 2,
    width,
    height,
  );
}

/// Mirrors the native pipeline (brighten → contrast → saturation) closely
/// enough for a live preview; the native core produces the saved pixels.
List<double> _colorMatrix(int brightness, int contrast, int saturation) {
  final cFactor = math.pow((100 + contrast) / 100, 2).toDouble();
  final t = 128 * (1 - cFactor) + cFactor * (brightness / 100 * 255);
  final s = 1 + saturation / 100;
  final inv = 1 - s;
  const r = .299, g = .587, b = .114;
  final sat = <List<double>>[
    [s + inv * r, inv * g, inv * b],
    [inv * r, s + inv * g, inv * b],
    [inv * r, inv * g, s + inv * b],
  ];
  final rows = <double>[];
  for (final row in sat) {
    final scale = cFactor;
    var translate = 0.0;
    for (var i = 0; i < 3; i += 1) {
      rows.add(row[i] * scale);
      translate += row[i] * t;
    }
    rows.add(0);
    rows.add(translate);
  }
  rows.addAll([0, 0, 0, 1, 0]);
  return rows;
}

class _CropPainter extends CustomPainter {
  const _CropPainter({required this.selection});

  final Rect? selection;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = selection;
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white;
    if (rect == null || rect.width < 0.005 || rect.height < 0.005) {
      canvas.drawRect(Offset.zero & size, border);
      return;
    }
    final pixels = Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );
    final dim = Paint()..color = Colors.black.withValues(alpha: .55);
    canvas
      ..drawRect(Rect.fromLTWH(0, 0, size.width, pixels.top), dim)
      ..drawRect(
        Rect.fromLTWH(
          0,
          pixels.bottom,
          size.width,
          size.height - pixels.bottom,
        ),
        dim,
      )
      ..drawRect(Rect.fromLTWH(0, pixels.top, pixels.left, pixels.height), dim)
      ..drawRect(
        Rect.fromLTWH(
          pixels.right,
          pixels.top,
          size.width - pixels.right,
          pixels.height,
        ),
        dim,
      )
      ..drawRect(pixels, border);
    for (final point in [
      pixels.topLeft,
      pixels.topRight,
      pixels.bottomLeft,
      pixels.bottomRight,
    ]) {
      canvas.drawCircle(point, 5, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      oldDelegate.selection != selection;
}
