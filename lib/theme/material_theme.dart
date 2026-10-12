import 'package:flutter/material.dart';

import 'neu_colors.dart';

/// Material 3 palette. Existing page color roles are mapped to ColorScheme so
/// both appearances can share the same stateful widgets and business logic.
ThemeData buildMaterialTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF5B8DEF),
    brightness: brightness,
  );
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
