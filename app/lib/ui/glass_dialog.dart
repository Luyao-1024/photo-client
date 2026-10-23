import 'package:flutter/material.dart';

import 'glass_surface.dart';
import 'glass_theme.dart';

/// One material per modal, including its title and actions. The route owns
/// dismissal, focus trapping, safe area and keyboard insets as usual.
class GlassDialog extends StatelessWidget {
  const GlassDialog({
    super.key,
    required this.child,
    this.constraints = const BoxConstraints(maxWidth: 900, maxHeight: 720),
  });
  final Widget child;
  final BoxConstraints constraints;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    clipBehavior: Clip.none,
    insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    constraints: constraints,
    child: GlassSurface(
      role: GlassRole.overlay,
      radius: GlassTheme.dialogRadius,
      child: child,
    ),
  );
}

class GlassAlertDialog extends StatelessWidget {
  const GlassAlertDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
  });
  final Widget title, content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassDialog(
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: Semantics(
              namesRoute: true,
              child: DefaultTextStyle(
                style: theme.textTheme.titleLarge!,
                child: title,
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: DefaultTextStyle(
                style: theme.textTheme.bodyMedium!,
                child: content,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: actions,
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps Flutter's menu route (positioning, focus traversal, Escape and outside
/// dismissal), while a single glass panel owns the material around its rows.
Future<T?> showGlassMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  BoxConstraints? constraints,
}) => showMenu<T>(
  context: context,
  position: position,
  color: Colors.transparent,
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  menuPadding: EdgeInsets.zero,
  clipBehavior: Clip.none,
  constraints: constraints,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(GlassTheme.panelRadius),
  ),
  items: [GlassMenuEntry<T>(items: items)],
);

class GlassMenuEntry<T> extends PopupMenuEntry<T> {
  const GlassMenuEntry({
    super.key,
    required this.items,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
  });
  final List<PopupMenuEntry<T>> items;
  final EdgeInsetsGeometry padding;

  @override
  double get height =>
      items.fold(padding.vertical, (sum, item) => sum + item.height);

  @override
  bool represents(T? value) => false;

  @override
  State<GlassMenuEntry<T>> createState() => _GlassMenuEntryState<T>();
}

class _GlassMenuEntryState<T> extends State<GlassMenuEntry<T>> {
  @override
  Widget build(BuildContext context) => GlassSurface(
    role: GlassRole.overlay,
    child: Padding(
      padding: widget.padding,
      child: Column(mainAxisSize: MainAxisSize.min, children: widget.items),
    ),
  );
}
