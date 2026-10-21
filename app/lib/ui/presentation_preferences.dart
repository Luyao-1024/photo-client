import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_library_tools.dart';
import 'runtime_controller.dart';

final presentationProvider =
    NotifierProvider<PresentationController, PresentationPreferences>(
      PresentationController.new,
    );

/// Only transparent materials are supported. A solid material is not a mode:
/// anything outside this set resolves to automatic.
const Set<String> glassModes = {'auto', 'full', 'reduced'};

String normalizeGlassMode(String? value) =>
    value != null && glassModes.contains(value) ? value : 'auto';

class PresentationPreferences {
  const PresentationPreferences({
    this.themeMode = ThemeMode.system,
    this.locale,
    this.glassMode = 'auto',
    this.transparency = .5,
    this.reduceMotion = false,
    this.dayColumns = 5,
    this.thumbnailWorkers = 2,
    this.logLevel = 'info',
    this.order = 'date_desc',
    this.saveFailed = false,
  });
  final ThemeMode themeMode;
  final Locale? locale;
  final bool reduceMotion, saveFailed;
  final String glassMode, logLevel, order;
  final double transparency;
  final int dayColumns, thumbnailWorkers;

  PresentationPreferences copyWith({
    ThemeMode? themeMode,
    Locale? locale,
    String? glassMode,
    double? transparency,
    bool? reduceMotion,
    int? dayColumns,
    int? thumbnailWorkers,
    String? logLevel,
    String? order,
    bool? saveFailed,
  }) => PresentationPreferences(
    themeMode: themeMode ?? this.themeMode,
    locale: locale ?? this.locale,
    glassMode: glassMode ?? this.glassMode,
    transparency: transparency ?? this.transparency,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    dayColumns: dayColumns ?? this.dayColumns,
    thumbnailWorkers: thumbnailWorkers ?? this.thumbnailWorkers,
    logLevel: logLevel ?? this.logLevel,
    order: order ?? this.order,
    saveFailed: saveFailed ?? this.saveFailed,
  );
}

class PresentationController extends Notifier<PresentationPreferences> {
  bool _loaded = false, _disposed = false;
  int _edits = 0;
  Future<void> _writes = Future.value();
  @override
  PresentationPreferences build() {
    ref.onDispose(() => _disposed = true);
    ref.listen(runtimeProvider, (_, next) {
      if (next.phase == ConnectionPhase.ready && !_loaded) {
        _loaded = true;
        scheduleMicrotask(_restore);
      }
    }, fireImmediately: true);
    return const PresentationPreferences();
  }

  Future<void> _restore() async {
    final gateway = ref.read(coreGatewayProvider);
    if (gateway is! LocalLibraryTools) return;
    final edits = _edits;
    try {
      final data = await (gateway as LocalLibraryTools).localCommand({
        'op': 'preferences',
      }) as Map;
      if (_disposed || edits != _edits) return;
      final mode = normalizeGlassMode(data['glassMode'] as String?);
      state = PresentationPreferences(
        themeMode: ThemeMode.values.firstWhere(
          (m) => m.name == data['theme'],
          orElse: () => ThemeMode.system,
        ),
        locale: data['locale'] == null
            ? null
            : Locale(data['locale'] as String),
        glassMode: mode,
        transparency: ((data['transparency'] as num?)?.toDouble() ?? .5).clamp(
          0,
          1,
        ),
        reduceMotion: data['reduceMotion'] as bool? ?? false,
        dayColumns: ((data['dayColumns'] as int?) ?? 5).clamp(3, 8),
        thumbnailWorkers: ((data['thumbnailWorkers'] as int?) ?? 2).clamp(1, 4),
        logLevel: data['logLevel'] as String? ?? 'info',
        order: data['order'] as String? ?? 'date_desc',
      );
    } catch (_) {
      if (!_disposed) state = state.copyWith(saveFailed: true);
    }
  }

  void _persist(String key, Object value) {
    _edits++;
    final gateway = ref.read(coreGatewayProvider);
    if (gateway is! LocalLibraryTools) return;
    _writes = _writes.then((_) async {
      try {
        await (gateway as LocalLibraryTools).localCommand({
          'op': 'setPreference',
          'key': key,
          'value': value,
        });
        if (!_disposed) state = state.copyWith(saveFailed: false);
      } catch (_) {
        if (!_disposed) state = state.copyWith(saveFailed: true);
      }
    });
  }

  Future<void> flush() => _writes;
  void setTheme(ThemeMode value) {
    state = state.copyWith(themeMode: value);
    _persist('theme', value.name);
  }

  void setLocale(Locale value) {
    state = state.copyWith(locale: value);
    _persist('locale', value.languageCode);
  }

  void setGlassMode(String value) {
    final mode = normalizeGlassMode(value);
    state = state.copyWith(glassMode: mode);
    _persist('glassMode', mode);
  }

  void setTransparency(double value) {
    state = state.copyWith(transparency: value);
    _persist('transparency', value);
  }

  void setReduceMotion(bool value) {
    state = state.copyWith(reduceMotion: value);
    _persist('reduceMotion', value);
  }

  void setDayColumns(int value) {
    state = state.copyWith(dayColumns: value);
    _persist('dayColumns', value);
  }

  void setThumbnailWorkers(int value) {
    state = state.copyWith(thumbnailWorkers: value);
    _persist('thumbnailWorkers', value);
  }

  void setLogLevel(String value) {
    state = state.copyWith(logLevel: value);
    _persist('logLevel', value);
  }

  void setOrder(String value) {
    state = state.copyWith(order: value);
    _persist('order', value);
  }
}
