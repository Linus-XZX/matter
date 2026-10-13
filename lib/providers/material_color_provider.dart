import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/material_theme.dart';
import '../theme/system_material_colors.dart';

class MaterialColorSettings {
  const MaterialColorSettings({
    this.followSystem = true,
    this.seedColor = defaultMaterialSeedColor,
    this.lightBackground = MaterialBackground.tonal,
    this.darkBackground = MaterialBackground.tonal,
  });

  final bool followSystem;
  final Color seedColor;
  final MaterialBackground lightBackground;
  final MaterialBackground darkBackground;

  MaterialColorSettings copyWith({
    bool? followSystem,
    Color? seedColor,
    MaterialBackground? lightBackground,
    MaterialBackground? darkBackground,
  }) => MaterialColorSettings(
    followSystem: followSystem ?? this.followSystem,
    seedColor: seedColor ?? this.seedColor,
    lightBackground: lightBackground ?? this.lightBackground,
    darkBackground: darkBackground ?? this.darkBackground,
  );
}

class MaterialColorSettingsNotifier extends Notifier<MaterialColorSettings> {
  static const _prefsKey = 'material_color_settings';
  late Future<SharedPreferences> _prefs;
  late Future<void> _restored;

  @override
  MaterialColorSettings build() {
    _prefs = SharedPreferences.getInstance();
    _restored = _restore();
    return const MaterialColorSettings();
  }

  Future<void> _restore() async {
    final saved = (await _prefs).getString(_prefsKey);
    if (!ref.mounted || saved == null) return;
    final data = jsonDecode(saved) as Map<String, dynamic>;
    MaterialBackground background(String key) =>
        MaterialBackground.values.firstWhere(
          (value) => value.name == data[key],
          orElse: () => MaterialBackground.tonal,
        );
    state = MaterialColorSettings(
      followSystem: data['followSystem'] as bool? ?? true,
      seedColor: Color(
        data['seedColor'] as int? ?? defaultMaterialSeedColor.toARGB32(),
      ),
      lightBackground: background('lightBackground'),
      darkBackground: background('darkBackground'),
    );
  }

  Future<void> setFollowSystem(bool value) async {
    await _restored;
    if (!ref.mounted) return;
    if (value) ref.invalidate(systemMaterialColorsProvider);
    state = state.copyWith(followSystem: value);
    await _persist();
  }

  Future<void> setSeedColor(Color color) async {
    await _restored;
    if (!ref.mounted) return;
    state = state.copyWith(followSystem: false, seedColor: color);
    await _persist();
  }

  Future<void> setBackground(
    Brightness brightness,
    MaterialBackground background,
  ) async {
    await _restored;
    if (!ref.mounted) return;
    state = brightness == Brightness.light
        ? state.copyWith(lightBackground: background)
        : state.copyWith(darkBackground: background);
    await _persist();
  }

  Future<void> _persist() async {
    final data = jsonEncode({
      'followSystem': state.followSystem,
      'seedColor': state.seedColor.toARGB32(),
      'lightBackground': state.lightBackground.name,
      'darkBackground': state.darkBackground.name,
    });
    await (await _prefs).setString(_prefsKey, data);
  }
}

final materialColorSettingsProvider =
    NotifierProvider<MaterialColorSettingsNotifier, MaterialColorSettings>(
      MaterialColorSettingsNotifier.new,
    );

final systemMaterialColorsProvider = FutureProvider<MaterialColorSchemes?>(
  (ref) => loadSystemMaterialColors(),
);

final materialColorSchemesProvider = Provider<MaterialColorSchemes>((ref) {
  final settings = ref.watch(materialColorSettingsProvider);
  final system = settings.followSystem
      ? ref.watch(systemMaterialColorsProvider).asData?.value
      : null;
  return (
    light: applyMaterialBackground(
      system?.light ?? ColorScheme.fromSeed(seedColor: settings.seedColor),
      settings.lightBackground,
    ),
    dark: applyMaterialBackground(
      system?.dark ??
          ColorScheme.fromSeed(
            seedColor: settings.seedColor,
            brightness: Brightness.dark,
          ),
      settings.darkBackground,
    ),
  );
});
