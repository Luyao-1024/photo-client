import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/android_runtime.dart';
import 'glass_surface.dart';
import 'library_access.dart';
import 'strings.dart';

/// The path-based library needs the all-files contract on Android 11+, exactly
/// as the desktop build needs ordinary filesystem access. Nothing is faked when
/// the grant is missing: the product UI does not start until the system says so.
class AndroidPermissionGate extends ConsumerStatefulWidget {
  const AndroidPermissionGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AndroidPermissionGate> createState() =>
      _AndroidPermissionGateState();
}

class _AndroidPermissionGateState extends ConsumerState<AndroidPermissionGate>
    with WidgetsBindingObserver {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _check() async {
    if (!AndroidRuntime.isAndroid) {
      if (mounted) setState(() => _granted = true);
      return;
    }
    try {
      final granted = await AndroidRuntime.hasAllFiles();
      if (mounted) {
        ref.read(libraryAccessProvider.notifier).setGranted(granted);
        setState(() => _granted = granted);
      }
    } catch (_) {
      if (mounted) {
        ref.read(libraryAccessProvider.notifier).setGranted(false);
        setState(() => _granted = false);
      }
    }
  }

  Future<void> _request() async {
    try {
      await AndroidRuntime.requestAllFiles();
    } on PlatformException {
      await AndroidRuntime.openAppSettings();
    } on MissingPluginException {
      // A host widget test has no Android activity behind the channel.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AndroidRuntime.isAndroid) return widget.child;
    final granted = _granted;
    if (granted == true) return widget.child;
    if (granted == null) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final strings = AppStrings.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: GlassSurface(
                role: GlassRole.reading,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 26, 28, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.photo_library_outlined,
                            size: 28,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              strings.pick('允许访问照片和视频', 'Allow photo access'),
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        strings.pick(
                          'PhotoViewer 使用与桌面版相同的路径式图库，需要读取、整理和编辑设备上的照片与视频。\n\n请在系统设置中打开“允许管理所有文件”，然后返回这里继续。权限由系统授予，应用不会伪造访问路径。',
                          'PhotoViewer uses the same path-based library as the desktop client and needs to read, organize, and edit photos and videos on this device.\n\nTurn on “Allow management of all files” in system settings, then return here. The grant comes from Android; the app never fakes filesystem access.',
                        ),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 22),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => unawaited(_check()),
                            child: Text(strings.pick('重新检查', 'Check again')),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () => unawaited(_request()),
                            child: Text(
                              strings.pick('打开系统设置', 'Open settings'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
