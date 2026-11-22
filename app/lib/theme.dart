import 'package:flutter/material.dart';

const accent = Color(0xff2f6fed);

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: dark ? const Color(0xffa8c5ff) : const Color(0xff2259c9),
        surface: dark ? const Color(0xff181b21) : Colors.white,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff111318)
        : const Color(0xfff3f4f7),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      elevation: 0,
      height: 67,
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: dark ? const Color(0xff2a2f39) : const Color(0xffe1e4ea),
        ),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xff111318) : const Color(0xfff3f4f7),
      surfaceTintColor: Colors.transparent,
    ),
  );
}
