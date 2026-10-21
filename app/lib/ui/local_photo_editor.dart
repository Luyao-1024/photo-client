import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
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
  const LocalPhotoEditor({super.key, required this.photo});

  final LocalPhoto photo;

  @override
  ConsumerState<LocalPhotoEditor> createState() => _LocalPhotoEditorState();
}

class _LocalPhotoEditorState extends ConsumerState<LocalPhotoEditor> {
  late LocalPhoto _photo = widget.photo;
  int _rotation = 0;
  int _brightness = 0;
  int _contrast = 0;
  int _saturation = 0;
  Rect? _crop;
  bool _cropMode = false;
  bool _saving = false;
  Offset? _dragStart;
  Size _previewSize = Size.zero;

  bool get _dirty =>
      _rotation % 360 != 0 ||
      _brightness != 0 ||
      _contrast != 0 ||
      _saturation != 0 ||
      _crop != null;

  bool get _canCrop => _photo.width != null && _photo.height != null;

  int get _rotatedWidth =>
      _rotation % 180 == 0 ? (_photo.width ?? 0) : (_photo.height ?? 0);

  int get _rotatedHeight =>
      _rotation % 180 == 0 ? (_photo.height ?? 0) : (_photo.width ?? 0);

  EditOptions get _options => EditOptions(
    rotationDegrees: _rotation % 360,
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
    _brightness = 0;
    _contrast = 0;
    _saturation = 0;
    _crop = null;
    _cropMode = false;
  });

  Future<void> _close() async {
    if (!_dirty || _saving) {
      Navigator.of(context).pop();
      return;
    }
    final strings = AppStrings.of(context);
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.discardEditsTitle),
        content: Text(strings.discardEditsBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.continueEditing),
          ),
          FilledButton(
            key: const ValueKey('editor-discard'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(strings.discard),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
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
          _brightness = 0;
          _contrast = 0;
          _saturation = 0;
          _crop = null;
        }
      });
      if (copy) {
        Navigator.of(context).pop(saved);
        return;
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(strings.appliedEdits)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(strings.editorFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final preferences = ref.watch(presentationProvider);
    return Theme(
      data: photoTheme(Brightness.dark),
      child: Scaffold(
        key: const ValueKey('editor'),
        backgroundColor: const Color(0xff10131a),
        appBar: AppBar(
          backgroundColor: const Color(0xff171b24),
          foregroundColor: Colors.white,
          leading: IconButton(
            key: const ValueKey('editor-close'),
            icon: const Icon(Icons.arrow_back),
            tooltip: strings.back,
            onPressed: _saving ? null : _close,
          ),
          title: Text(_photo.name, overflow: TextOverflow.ellipsis),
          actions: [
            TextButton(
              key: const ValueKey('editor-reset'),
              onPressed: _dirty && !_saving ? _reset : null,
              child: Text(strings.reset),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: OutlinedButton(
                key: const ValueKey('editor-save-copy'),
                onPressed: _dirty && !_saving ? () => _save(copy: true) : null,
                child: Text(strings.saveCopy),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: FilledButton(
                key: const ValueKey('editor-save'),
                onPressed: _dirty && !_saving ? () => _save(copy: false) : null,
                child: Text(_saving ? strings.saving : strings.save),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final preview = _preview(strings, preferences);
              final controls = _controls(strings, preferences);
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: preview),
                    SizedBox(width: 340, child: controls),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(child: preview),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: controls,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _preview(AppStrings strings, PresentationPreferences preferences) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final box = constraints.biggest;
          final imageAspect = _rotatedWidth > 0 && _rotatedHeight > 0
              ? _rotatedWidth / _rotatedHeight
              : 1.0;
          final fitted = _fitRect(box, imageAspect);
          _previewSize = fitted.size;
          return Center(
            child: SizedBox(
              width: fitted.width,
              height: fitted.height,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: _cropMode ? _cropStart : null,
                onPanUpdate: _cropMode ? _cropUpdate : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RotatedBox(
                      quarterTurns: _rotation ~/ 90,
                      child: ColorFiltered(
                        colorFilter: ColorFilter.matrix(
                          _colorMatrix(_brightness, _contrast, _saturation),
                        ),
                        child: Image(
                          image: LocalPhotoImage(_photo.path, _photo),
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stack) => Center(
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: Colors.white54,
                              semanticLabel: strings.imageUnavailable,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_crop != null || _cropMode)
                      IgnorePointer(
                        child: CustomPaint(
                          painter: _CropPainter(selection: _crop),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _cropStart(DragStartDetails details) {
    final box = _previewSize;
    if (box.isEmpty) return;
    setState(() {
      _dragStart = _clampNormalized(details.localPosition, box);
      _crop = Rect.fromPoints(_dragStart!, _dragStart!);
    });
  }

  void _cropUpdate(DragUpdateDetails details) {
    final box = _previewSize;
    final start = _dragStart;
    if (box.isEmpty || start == null) return;
    final current = _clampNormalized(details.localPosition, box);
    setState(() => _crop = Rect.fromPoints(start, current));
  }

  Offset _clampNormalized(Offset local, Size size) => Offset(
    (local.dx / size.width).clamp(0.0, 1.0),
    (local.dy / size.height).clamp(0.0, 1.0),
  );

  Widget _controls(AppStrings strings, PresentationPreferences preferences) {
    final theme = Theme.of(context);
    return GlassSurface(
      enabled: preferences.glass,
      radius: 0,
      child: SingleChildScrollView(
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
            const SizedBox(height: 20),
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
                  onSelected: !_canCrop
                      ? null
                      : (value) => setState(() {
                          _cropMode = value;
                          if (!value) _crop = null;
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
                    onPressed: () => setState(() => _crop = null),
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
  final t = 128 * (1 - cFactor) + brightness / 100 * 255;
  final s = 1 + saturation / 100;
  final inv = 1 - s;
  const r = 0.213, g = 0.715, b = 0.072;
  final sat = <List<double>>[
    [s * r + inv, s * g, s * b],
    [s * r, s * g + inv, s * b],
    [s * r, s * g, s * b + inv],
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
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      oldDelegate.selection != selection;
}
