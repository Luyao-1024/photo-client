// An isolated liquid-glass bench. Nothing from the photo app is involved:
// a colourful image is the backdrop, capsules are stacked on top of it, and
// the app writes the rendered frame to a PNG so the material can be judged
// on the pixels it actually produces.
//
//   flutter run -d linux --dart-define=SHOT=/tmp/glass.png
//
// The bench is the GPU-side evidence for the Photo client's glass material.
// The headless widget test only proves the tier wiring; the refraction itself
// is proven by the archived screenshots in ../report.json.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

const _shot = String.fromEnvironment('SHOT', defaultValue: '');

/// The three tiers the Photo client maps its roles onto, with the exact
/// recipe the app ships. `premium` is the raised capsule, `standard` is the
/// chrome, `minimal` is the reading panel.
const benchTiers = <GlassBenchTier>[
  GlassBenchTier(
    label: 'A · app recipe · premium',
    capsule: 'premium',
    quality: GlassQuality.premium,
    settings: LiquidGlassSettings(
      glassColor: Color(0x40ffffff),
      thickness: 16,
      blur: 2,
      chromaticAberration: 0.004,
      saturation: 1.4,
      lightAngle: -1.2,
      lightIntensity: 0.3,
      fresnelStrength: 0.4,
      rimLight: 0.35,
      rimShade: 0.9,
      rimShadeEnds: 0,
      edgeAbsorption: 0.035,
    ),
  ),
  GlassBenchTier(
    label: 'B · app recipe · standard',
    capsule: 'standard',
    quality: GlassQuality.standard,
    settings: LiquidGlassSettings(
      glassColor: Color(0x40ffffff),
      thickness: 12,
      blur: 2,
      saturation: 1.4,
      fresnelStrength: 0.4,
      rimLight: 0.35,
      rimShade: 0.9,
      rimShadeEnds: 0,
    ),
  ),
  GlassBenchTier(
    label: 'C · app recipe · minimal (reading)',
    capsule: 'minimal',
    quality: GlassQuality.minimal,
    settings: LiquidGlassSettings(
      glassColor: Color(0xf2ffffff),
      thickness: 0,
      blur: 0,
      saturation: 1,
      fresnelStrength: 0,
      rimLight: 0.2,
      rimShade: 0,
    ),
  ),
];

/// One material tier of the bench.
@immutable
class GlassBenchTier {
  const GlassBenchTier({
    required this.label,
    required this.capsule,
    required this.quality,
    required this.settings,
  });

  final String label;
  final String capsule;
  final GlassQuality quality;
  final LiquidGlassSettings settings;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BenchApp());
}

class BenchApp extends StatefulWidget {
  const BenchApp({super.key, this.backdrop});

  /// The backdrop the glass samples. Defaults to the colourful asset; tests
  /// inject a plain box so they do not depend on image decoding.
  final Widget? backdrop;

  @override
  State<BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<BenchApp> {
  final _key = GlobalKey();
  int _segment = 0;
  double _slider = .4;

  @override
  void initState() {
    super.initState();
    if (_shot.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
    }
  }

  Future<void> _capture() async {
    // Let the shaders compile and the first frames settle before the shot.
    await Future<void>.delayed(const Duration(seconds: 4));
    final boundary =
        _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(_shot).writeAsBytes(data!.buffer.asUint8List());
    stdout.writeln('GLASS_SHOT $_shot ${image.width}x${image.height}');
    await stdout.flush();
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff4f8eff),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xff0b0f16),
      ),
      home: RepaintBoundary(
        key: _key,
        child: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              widget.backdrop ??
                  Image.asset('assets/backdrop.png', fit: BoxFit.cover),
              SafeArea(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final tier in benchTiers) ...[
                        _Label(tier.label),
                        GlassBenchCapsule(
                          label: tier.capsule,
                          quality: tier.quality,
                          settings: tier.settings,
                        ),
                      ],
                      const _Label('D · GlassSegmentedControl (package widget)'),
                      GlassSegmentedControl(
                        segments: const [
                          GlassSegment(label: '年'),
                          GlassSegment(label: '月'),
                          GlassSegment(label: '日'),
                        ],
                        selectedIndex: _segment,
                        onSegmentSelected: (i) => setState(() => _segment = i),
                        useOwnLayer: true,
                        quality: GlassQuality.premium,
                      ),
                      const _Label('E · GlassButton (package widget)'),
                      GlassButton(
                        icon: const Icon(Icons.favorite),
                        onTap: () {},
                        useOwnLayer: true,
                        quality: GlassQuality.premium,
                      ),
                      const _Label('F · GlassSlider (package widget)'),
                      GlassSlider(
                        value: _slider,
                        onChanged: (v) => setState(() => _slider = v),
                        useOwnLayer: true,
                        quality: GlassQuality.premium,
                      ),
                    ],
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

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6, left: 24),
    child: Text(
      text,
      style: const TextStyle(
        color: Color(0xffffffff),
        fontSize: 12,
        fontWeight: FontWeight.w600,
        shadows: [Shadow(blurRadius: 6, color: Color(0x99000000))],
      ),
    ),
  );
}

/// A glass capsule over the backdrop.
class GlassBenchCapsule extends StatelessWidget {
  const GlassBenchCapsule({
    super.key,
    required this.label,
    required this.quality,
    required this.settings,
  });

  final String label;
  final GlassQuality quality;
  final LiquidGlassSettings settings;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: GlassContainer(
      shape: const LiquidRoundedSuperellipse(borderRadius: 28),
      settings: settings,
      quality: quality,
      useOwnLayer: true,
      child: SizedBox(
        height: 56,
        child: Center(
          child: Text(
            label,
            style: const TextStyle(color: Color(0xffffffff), fontSize: 14),
          ),
        ),
      ),
    ),
  );
}
