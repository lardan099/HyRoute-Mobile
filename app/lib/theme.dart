import 'package:flutter/material.dart';

const accent = Color(0xff19886a);

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: dark ? const Color(0xffa2edc9) : const Color(0xff14644f),
        onPrimary: dark ? const Color(0xff102a20) : Colors.white,
        surface: dark ? const Color(0xff1d2024) : Colors.white,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff121417)
        : const Color(0xfff4f5f6),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      elevation: 0,
      height: 64,
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: dark ? const Color(0xff373e46) : const Color(0xffd8dde3),
        ),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xff121417) : const Color(0xfff4f5f6),
      surfaceTintColor: Colors.transparent,
    ),
  );
}
