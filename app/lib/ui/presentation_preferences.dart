import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final presentationProvider =
    NotifierProvider<PresentationController, PresentationPreferences>(
      PresentationController.new,
    );

class PresentationPreferences {
  const PresentationPreferences({
    this.themeMode = ThemeMode.system,
    this.locale,
    this.glass = true,
  });
  final ThemeMode themeMode;
  final Locale? locale;
  final bool glass;
}

class PresentationController extends Notifier<PresentationPreferences> {
  @override
  PresentationPreferences build() => const PresentationPreferences();

  void setTheme(ThemeMode theme) => state = PresentationPreferences(
    themeMode: theme,
    locale: state.locale,
    glass: state.glass,
  );
  void setLocale(Locale locale) => state = PresentationPreferences(
    themeMode: state.themeMode,
    locale: locale,
    glass: state.glass,
  );
  void setGlass(bool glass) => state = PresentationPreferences(
    themeMode: state.themeMode,
    locale: state.locale,
    glass: glass,
  );
}
