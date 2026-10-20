import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services/core_gateway.dart';
import 'services/local_library_gateway.dart';
import 'ui/glass_surface.dart';
import 'ui/library_shell.dart';
import 'ui/local_library_controller.dart';
import 'ui/presentation_preferences.dart';
import 'ui/runtime_controller.dart';

class PhotoClientApp extends StatelessWidget {
  const PhotoClientApp({super.key, required this.gateway, this.sourcePicker});

  final CoreGateway gateway;
  final LocalSourcePicker? sourcePicker;

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      coreGatewayProvider.overrideWithValue(gateway),
      sourcePickerProvider.overrideWithValue(sourcePicker),
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(ref.read(runtimeProvider.notifier).shutdown());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // ProviderScope owns subscription cancellation and native session cleanup.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(presentationProvider);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PhotoViewer',
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
