import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'services/core_gateway.dart';
import 'services/local_library_gateway.dart';
import 'ui/photo_theme.dart';
import 'ui/window_frame.dart';
import 'services/window_controller.dart';
import 'services/app_navigation.dart';
import 'platform/in_app_source_picker.dart';
import 'ui/library_shell.dart';
import 'ui/local_library_controller.dart';
import 'ui/presentation_preferences.dart';
import 'ui/runtime_controller.dart';
import 'ui/strings.dart';
import 'ui/auto_glass_policy.dart';

class PhotoClientApp extends StatelessWidget {
  const PhotoClientApp({super.key, required this.gateway, this.sourcePicker});

  final CoreGateway gateway;
  final LocalSourcePicker? sourcePicker;

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      coreGatewayProvider.overrideWithValue(gateway),
      sourcePickerProvider.overrideWith(
        (ref) =>
            sourcePicker ??
            InAppSourcePicker(ref.read(appNavigatorKeyProvider)),
      ),
    ],
    child: const _Application(),
  );
}

class _Application extends ConsumerStatefulWidget {
  const _Application();

  @override
  ConsumerState<_Application> createState() => _ApplicationState();
}

class _ApplicationState extends ConsumerState<_Application>
    with WidgetsBindingObserver {
  static String? _lastQualityReport;

  /// The effective tier is what the frame budget allowed, which is not always
  /// the tier the user asked for. Both belong in the log.
  static void _reportEffectiveQuality(
    GlassQuality quality,
    String phase,
    bool frost,
  ) {
    final report = '${quality.name}/$phase/frost=$frost';
    if (report == _lastQualityReport) return;
    _lastQualityReport = report;
    debugPrint('GLASS_EFFECTIVE $report');
  }

  GlobalKey<NavigatorState> get _navigatorKey =>
      ref.read(appNavigatorKeyProvider);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WindowController.instance.initialize();
    PaintingBinding.instance.imageCache.maximumSizeBytes = 128 * 1024 * 1024;
    WindowController.instance.confirmLibraryClose = () async {
      if (!ref.read(localLibraryProvider).scanning) return true;
      final context = _navigatorKey.currentContext;
      if (context == null) return false;
      final strings = AppStrings.of(context);
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(strings.pick('停止扫描并退出？', 'Stop scanning and close?')),
              content: Text(
                strings.pick(
                  '已加入的照片会保留，未完成的来源可以下次重新扫描。',
                  'Photos already added are kept. You can rescan unfinished sources next time.',
                ),
              ),
              actions: [
                TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(strings.pick('继续扫描', 'Keep scanning')),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(strings.pick('停止并退出', 'Stop and close')),
                ),
              ],
            ),
          ) ??
          false;
    };
    WindowController.instance.prepareClose = () async {
      await ref.read(presentationProvider.notifier).flush();
      await ref.read(runtimeProvider.notifier).shutdown();
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(ref.read(runtimeProvider.notifier).shutdown());
    }
  }

  @override
  void dispose() {
    WindowController.instance.confirmLibraryClose = null;
    WindowController.instance.prepareClose = null;
    WidgetsBinding.instance.removeObserver(this);
    // ProviderScope owns subscription cancellation and native session cleanup.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(presentationProvider);
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'PhotoViewer',
      builder: (context, child) => GlassAdaptiveScope(
        // The scope is the ceiling for every glass surface below it.
        //
        // "Liquid glass" is an explicit request, so it must not be silently
        // capped by the platform heuristic: the package caps desktop at the
        // standard tier because ANGLE compiles the multi-pass SDF at runtime,
        // and the floor is what lifts that cap back. Frost stays the first
        // thing to go when the frame budget overruns.
        //
        // "Reduced" never rises above the standard tier. "Automatic" leaves
        // the tier to the measured frame budget, and the platform heuristic
        // decides where the search starts.
        minQuality: preferences.glassMode == 'full'
            ? GlassQuality.premium
            : (preferences.glassMode == 'auto'
                  ? GlassQuality.minimal
                  : GlassQuality.standard),
        maxQuality: preferences.glassMode == 'reduced'
            ? GlassQuality.standard
            : GlassQuality.premium,
        frostStep: preferences.glassMode == 'full',
        allowStepUp: preferences.glassMode != 'reduced',
        onQualityChanged: (from, to) =>
            ref.read(autoGlassProvider.notifier).report(to),
        onDiagnostic: (diagnostic) {
          // The effective tier and the reason behind it belong in the log:
          // "the user asked for premium" and "premium is what the frame
          // budget allowed" are different statements.
          debugPrint(
            'GLASS_QUALITY ${diagnostic.from.name}->${diagnostic.to.name} '
            'phase=${diagnostic.phase.name} '
            'reason=${diagnostic.reason.name} '
            'p75=${diagnostic.p75Ms} p95=${diagnostic.p95Ms} '
            'frames=${diagnostic.framesMeasured} '
            'requested=${preferences.glassMode} '
            'bounds=${preferences.glassMode == 'full' ? 'premium' : preferences.glassMode == 'auto' ? 'minimal' : 'standard'}'
            '..${preferences.glassMode == 'reduced' ? 'standard' : 'premium'}',
          );
        },
        child: Builder(
          builder: (context) {
            final scope = GlassAdaptiveScopeData.maybeOf(context);
            if (scope != null) {
              _reportEffectiveQuality(
                scope.effectiveQuality,
                scope.phase.name,
                scope.frostEnabled,
              );
            }
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations:
                    preferences.reduceMotion ||
                    MediaQuery.disableAnimationsOf(context),
              ),
              child: WindowFrame(child: child ?? const SizedBox.shrink()),
            );
          },
        ),
      ),
      theme: photoTheme(Brightness.light),
      darkTheme: photoTheme(Brightness.dark),
      themeMode: preferences.themeMode,
      locale: preferences.locale,
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      localeResolutionCallback: (locale, supported) =>
          locale?.languageCode == 'zh'
          ? const Locale('zh', 'CN')
          : const Locale('en'),
      home: const LibraryShell(),
    );
  }
}
