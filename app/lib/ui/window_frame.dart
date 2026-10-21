import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/window_controller.dart';
import 'glass_theme.dart';
import 'strings.dart';

class WindowFrame extends StatelessWidget {
  const WindowFrame({super.key, required this.child, this.background});
  final Widget child;
  final Widget? background;
  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.linux &&
        defaultTargetPlatform != TargetPlatform.windows) {
      return Stack(fit: StackFit.expand, children: [?background, child]);
    }
    final window = WindowController.instance;
    final strings = AppStrings.of(context);
    return Overlay.wrap(
      child: ValueListenableBuilder<bool>(
        valueListenable: window.fullscreen,
        builder: (context, fullscreen, _) => Stack(
          children: [
            Positioned.fill(
              child: ValueListenableBuilder<bool>(
                valueListenable: window.maximized,
                builder: (context, maximized, _) => ClipRRect(
                  key: const ValueKey('window-clip'),
                  borderRadius: BorderRadius.circular(
                    fullscreen ||
                            maximized ||
                            defaultTargetPlatform != TargetPlatform.linux
                        ? 0
                        : GlassTheme.windowRadius,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ?background,
                      Material(
                        color: Colors.transparent,
                        child: Column(
                          children: [
                            if (!fullscreen)
                              SizedBox(
                                key: const ValueKey('window-titlebar'),
                                height: 40,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onPanStart: (_) =>
                                            window.command('drag'),
                                        onDoubleTap: () =>
                                            window.command('maximize'),
                                        child: const Align(
                                          alignment: Alignment.centerLeft,
                                          child: Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 16,
                                            ),
                                            child: Text(
                                              'PhotoViewer',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    _WindowButton(
                                      key: const ValueKey('window-minimize'),
                                      icon: Icons.remove,
                                      label: strings.pick('最小化', 'Minimize'),
                                      onTap: () => window.command('minimize'),
                                    ),
                                    ValueListenableBuilder<bool>(
                                      valueListenable: window.maximized,
                                      builder: (context, maximized, _) =>
                                          _WindowButton(
                                            key: const ValueKey(
                                              'window-maximize',
                                            ),
                                            icon: maximized
                                                ? Icons.filter_none
                                                : Icons.crop_square,
                                            label: strings.pick(
                                              maximized ? '还原窗口' : '最大化',
                                              maximized
                                                  ? 'Restore window'
                                                  : 'Maximize',
                                            ),
                                            onTap: () =>
                                                window.command('maximize'),
                                          ),
                                    ),
                                    _WindowButton(
                                      key: const ValueKey('window-close'),
                                      icon: Icons.close,
                                      label: strings.close,
                                      danger: true,
                                      onTap: window.close,
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                ),
                              ),
                            Expanded(child: child),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!fullscreen)
              ValueListenableBuilder<bool>(
                valueListenable: window.maximized,
                builder: (context, maximized, _) => maximized
                    ? const SizedBox.shrink()
                    : Stack(
                        children: [
                          for (final edge in [0, 1, 2, 3, 4, 5, 6, 7])
                            Positioned(
                              left: [0, 3, 5].contains(edge)
                                  ? 0
                                  : [1, 6].contains(edge)
                                  ? 5
                                  : null,
                              right: [2, 4, 7].contains(edge)
                                  ? 0
                                  : [1, 6].contains(edge)
                                  ? 5
                                  : null,
                              top: [0, 1, 2].contains(edge)
                                  ? 0
                                  : [3, 4].contains(edge)
                                  ? 5
                                  : null,
                              bottom: [5, 6, 7].contains(edge)
                                  ? 0
                                  : [3, 4].contains(edge)
                                  ? 5
                                  : null,
                              width: [0, 2, 3, 4, 5, 7].contains(edge)
                                  ? 5
                                  : null,
                              height: [0, 1, 2, 5, 6, 7].contains(edge)
                                  ? 5
                                  : null,
                              child: MouseRegion(
                                cursor: [
                                  SystemMouseCursors.resizeUpLeftDownRight,
                                  SystemMouseCursors.resizeUpDown,
                                  SystemMouseCursors.resizeUpRightDownLeft,
                                  SystemMouseCursors.resizeLeftRight,
                                  SystemMouseCursors.resizeLeftRight,
                                  SystemMouseCursors.resizeUpRightDownLeft,
                                  SystemMouseCursors.resizeUpDown,
                                  SystemMouseCursors.resizeUpLeftDownRight,
                                ][edge],
                                child: Listener(
                                  behavior: HitTestBehavior.opaque,
                                  onPointerDown: (event) {
                                    if (event.buttons == kPrimaryMouseButton) {
                                      window.command('resize', edge);
                                    }
                                  },
                                  child: const SizedBox.expand(),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: IconButton(
      tooltip: label,
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      style: IconButton.styleFrom(
        minimumSize: const Size(30, 30),
        maximumSize: const Size(30, 30),
        padding: EdgeInsets.zero,
        backgroundColor: Colors.transparent,
        hoverColor: danger
            ? Theme.of(context).colorScheme.error.withValues(alpha: .2)
            : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassTheme.controlRadius),
        ),
      ),
    ),
  );
}
