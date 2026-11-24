import 'package:flutter/material.dart';

const accent = Color(0xff526929);

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: dark ? const Color(0xffd1fb8d) : const Color(0xff405b1c),
        onPrimary: dark ? const Color(0xff1a2710) : Colors.white,
        onSurface: dark ? const Color(0xfff2f4f3) : const Color(0xff181d25),
        onSurfaceVariant: dark
            ? const Color(0xffacb7c5)
            : const Color(0xff505d6a),
        surface: dark ? const Color(0xff181f2b) : Colors.white,
        surfaceContainerHigh: dark
            ? const Color(0xff232e3d)
            : const Color(0xffe8edf0),
        outlineVariant: dark
            ? const Color(0xff303c4c)
            : const Color(0xffd8dfe5),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff101620)
        : const Color(0xfff0f3f5),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      elevation: 0,
      height: 60,
      indicatorColor: scheme.primary.withValues(alpha: dark ? 0.16 : 0.13),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xff101620) : const Color(0xfff0f3f5),
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant),
  );
}
