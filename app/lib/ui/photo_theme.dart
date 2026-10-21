import 'package:flutter/material.dart';

/// The application theme.
///
/// The glass material reads its tints from the brightness, so the page
/// background stays a plain surface: the glass sits over it and the backdrop
/// it samples is the content behind, not a painted gradient.
ThemeData photoTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff4f8eff),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff121721)
        : const Color(0xffeef1f6),
    visualDensity: VisualDensity.standard,
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
  );
}
