import 'package:flutter/material.dart';

import 'glass_theme.dart';

/// The application theme.
///
/// Controls and surfaces share geometry, ink, focus and selection tokens.
ThemeData photoTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff4f8eff),
    brightness: brightness,
  );
  final glass = GlassTheme.fromScheme(scheme);
  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(GlassTheme.controlRadius),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    extensions: [glass],
    scaffoldBackgroundColor: dark
        ? const Color(0xff121721)
        : const Color(0xffeef1f6),
    visualDensity: VisualDensity.standard,
    iconButtonTheme: IconButtonThemeData(
      style:
          IconButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: controlShape,
          ).copyWith(
            side: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.focused)
                  ? BorderSide(color: scheme.primary, width: 2)
                  : BorderSide.none,
            ),
          ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: controlShape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: controlShape,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: controlShape),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: glass.inset,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GlassTheme.controlRadius),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GlassTheme.controlRadius),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(GlassTheme.controlRadius),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: controlShape,
      side: BorderSide(color: scheme.outlineVariant),
      backgroundColor: glass.inset,
      selectedColor: glass.selection,
      checkmarkColor: scheme.primary,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    ),
    listTileTheme: ListTileThemeData(
      shape: controlShape,
      selectedTileColor: glass.selection,
      selectedColor: scheme.primary,
      iconColor: scheme.onSurfaceVariant,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: glass.tint.withValues(alpha: .96),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GlassTheme.panelRadius),
        side: BorderSide(color: glass.edge),
      ),
      elevation: 4,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: .5),
      thickness: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? const Color(0xf0273346) : const Color(0xf0172033),
      contentTextStyle: const TextStyle(color: Colors.white),
      actionTextColor: const Color(0xffa9c8ff),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GlassTheme.panelRadius),
      ),
      behavior: SnackBarBehavior.floating,
      elevation: 4,
    ),
  );
}
