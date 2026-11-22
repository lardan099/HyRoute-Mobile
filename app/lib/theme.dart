import 'package:flutter/material.dart';

const accent = Color(0xff19886a);

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: dark ? const Color(0xff84e4c4) : const Color(0xff14644f),
        surface: dark ? const Color(0xff1b2422) : Colors.white,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff101715)
        : const Color(0xfff1f5f3),
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
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: dark ? const Color(0xff2b3732) : const Color(0xffdfe7e2),
        ),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xff101715) : const Color(0xfff1f5f3),
      surfaceTintColor: Colors.transparent,
    ),
  );
}
