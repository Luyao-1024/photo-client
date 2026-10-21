import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services/core_gateway.dart';
import 'services/local_library_gateway.dart';
import 'ui/glass_surface.dart';
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

import 'dart:ui';

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
  void _timings(List<FrameTiming> frames) =>
      ref.read(autoGlassProvider.notifier).record(frames);
  GlobalKey<NavigatorState> get _navigatorKey =>
      ref.read(appNavigatorKeyProvider);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addTimingsCallback(_timings);
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
                  '已加入图库的照片会保留，未完成的来源可以下次重新扫描。',
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
    WidgetsBinding.instance.removeTimingsCallback(_timings);
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
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations:
              preferences.reduceMotion ||
              MediaQuery.disableAnimationsOf(context),
        ),
        child: WindowFrame(child: child ?? const SizedBox.shrink()),
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
