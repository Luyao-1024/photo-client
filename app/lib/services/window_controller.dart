import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The platform only moves the window. Chrome and close policy belong to Dart.
class WindowController {
  WindowController._();
  static final instance = WindowController._();
  static const _channel = MethodChannel('photo_client/window');
  final maximized = ValueNotifier(false);
  final fullscreen = ValueNotifier(false);
  Future<bool> Function()? confirmClose;
  Future<bool> Function()? confirmLibraryClose;
  Future<void> Function()? prepareClose;
  bool _closing = false;

  void initialize() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'closeRequested') await close();
      if (call.method == 'stateChanged') {
        maximized.value = call.arguments == true;
      }
    });
  }

  Future<void> command(String method, [Object? args]) async {
    try {
      final result = await _channel.invokeMethod<bool>(method, args);
      if (result != null) maximized.value = result;
    } on MissingPluginException {
      // Widget tests and platforms without desktop chrome have no channel.
    }
  }

  Future<void> setFullscreen(bool value) async {
    if (!kIsWeb && Platform.isAndroid) {
      // Android has no desktop window; the viewer toggles immersive system UI
      // instead, keeping the same fullscreen state the desktop shell reads.
      await SystemChrome.setEnabledSystemUIMode(
        value ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
      fullscreen.value = value;
      return;
    }
    await command('fullscreen', value);
    fullscreen.value = value;
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    try {
      if (confirmClose != null && !await confirmClose!()) return;
      if (confirmLibraryClose != null && !await confirmLibraryClose!()) return;
      await prepareClose?.call();
      if (!kIsWeb && Platform.isAndroid) {
        await SystemNavigator.pop();
      } else {
        await command('close');
      }
    } finally {
      _closing = false;
    }
  }
}
