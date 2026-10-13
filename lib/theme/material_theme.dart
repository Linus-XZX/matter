import 'package:flutter/material.dart';

import 'neu_colors.dart';

const defaultMaterialSeedColor = Color(0xFF5B8DEF);

enum MaterialBackground {
  tonal,
  pure,
  soft;

  Color? colorFor(Brightness brightness) => switch (this) {
    tonal => null,
    pure => brightness == Brightness.dark ? Colors.black : Colors.white,
    soft =>
      brightness == Brightness.dark
          ? const Color(0xFF202124)
          : const Color(0xFFFFF8EE),
  };
}

/// Background presets change neutral surfaces while preserving accent roles.
ColorScheme applyMaterialBackground(
  ColorScheme scheme,
  MaterialBackground background,
) {
  if (background == MaterialBackground.tonal) return scheme;
  final dark = scheme.brightness == Brightness.dark;
  final neutral = ColorScheme.fromSeed(
    seedColor: background == MaterialBackground.pure
        ? Colors.grey
        : dark
        ? const Color(0xFF738095)
        : const Color(0xFFB99A68),
    brightness: scheme.brightness,
    dynamicSchemeVariant: background == MaterialBackground.pure
        ? DynamicSchemeVariant.monochrome
        : DynamicSchemeVariant.tonalSpot,
  );
  Color surface(Color color) => dark && background == MaterialBackground.soft
      ? Color.alphaBlend(Colors.white.withValues(alpha: .06), color)
      : color;
  return scheme.copyWith(
    surface: background.colorFor(scheme.brightness),
    onSurface: neutral.onSurface,
    onSurfaceVariant: neutral.onSurfaceVariant,
    surfaceDim: surface(neutral.surfaceDim),
    surfaceBright: surface(neutral.surfaceBright),
    surfaceContainerLowest: surface(neutral.surfaceContainerLowest),
    surfaceContainerLow: surface(neutral.surfaceContainerLow),
    surfaceContainer: surface(neutral.surfaceContainer),
    surfaceContainerHigh: surface(neutral.surfaceContainerHigh),
    surfaceContainerHighest: surface(neutral.surfaceContainerHighest),
    outline: neutral.outline,
    outlineVariant: neutral.outlineVariant,
    inverseSurface: neutral.inverseSurface,
    onInverseSurface: neutral.onInverseSurface,
  );
}

/// Material 3 palette. Existing page color roles are mapped to ColorScheme so
/// both appearances can share the same stateful widgets and business logic.
ThemeData buildMaterialTheme(
  Brightness brightness, {
  Color seedColor = defaultMaterialSeedColor,
  ColorScheme? colorScheme,
}) {
  final scheme =
      colorScheme ??
      ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
  final dark = brightness == Brightness.dark;
  final overlaySurface = scheme.surfaceContainer.withValues(alpha: .88);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamilyFallback: kEmojiFontFallback,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: overlaySurface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: overlaySurface),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
    ),
    extensions: [
      NeuColors(
        isMaterial: true,
        base: scheme.surface,
        surface: scheme.surfaceContainerLow,
        surfaceStrong: scheme.surfaceContainerHigh,
        card: scheme.surfaceContainerLow,
        shadowLight: Colors.transparent,
        shadowDark: Colors.transparent,
        text: scheme.onSurface,
        textSecondary: scheme.onSurfaceVariant,
        textTertiary: scheme.onSurfaceVariant,
        accent: scheme.primary,
        accentPressed: scheme.primary,
        onAccent: scheme.onPrimary,
        accentSoft: scheme.primaryContainer,
        success: dark ? const Color(0xFF8AD6A1) : const Color(0xFF206A39),
        warning: dark ? const Color(0xFFEEC16C) : const Color(0xFF805600),
        error: scheme.error,
        glassFill: overlaySurface,
        glassBorder: Colors.transparent,
        hairline: scheme.outlineVariant,
        highlightAlpha: 0,
      ),
    ],
  );
}
