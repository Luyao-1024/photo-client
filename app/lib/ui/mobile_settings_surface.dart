import 'package:flutter/material.dart';

Color mobileAccentColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff72a7ff)
    : const Color(0xff0866ff);

Color mobileSettingsBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff17181c)
    : const Color(0xfff1f3f5);

Color mobileSettingsCardColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff25262c)
    : Colors.white;

ThemeData mobileSettingsTheme(BuildContext context) {
  final theme = Theme.of(context);
  return theme.copyWith(
    scaffoldBackgroundColor: mobileSettingsBackground(context),
    colorScheme: theme.colorScheme.copyWith(
      primary: mobileAccentColor(context),
      onPrimary: Colors.white,
    ),
  );
}

class MobileSettingsScaffold extends StatelessWidget {
  const MobileSettingsScaffold({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(
    data: mobileSettingsTheme(context),
    child: Scaffold(
      backgroundColor: mobileSettingsBackground(context),
      appBar: AppBar(
        title: Text(title),
        backgroundColor: mobileSettingsBackground(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(top: false, child: child),
    ),
  );
}

class MobileSettingsGroup extends StatelessWidget {
  const MobileSettingsGroup({
    super.key,
    required this.title,
    required this.children,
    this.contentPadding = EdgeInsets.zero,
  });

  final String title;
  final List<Widget> children;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Material(
            color: mobileSettingsCardColor(context),
            borderRadius: BorderRadius.circular(22),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: contentPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0)
                      const Divider(height: 1, indent: 16, endIndent: 16),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
