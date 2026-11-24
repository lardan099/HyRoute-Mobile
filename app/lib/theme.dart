import 'package:flutter/material.dart';

const accent = Color(0xff3c6864);

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: dark ? const Color(0xffa8ceca) : const Color(0xff2d605d),
        onPrimary: dark ? const Color(0xff162322) : Colors.white,
        onSurface: dark ? const Color(0xffeeefee) : const Color(0xff1b1e1d),
        onSurfaceVariant: dark
            ? const Color(0xffa5aba8)
            : const Color(0xff515a55),
        surface: dark ? const Color(0xff171918) : const Color(0xfffafafa),
        surfaceContainerHigh: dark
            ? const Color(0xff222624)
            : const Color(0xffe8ece9),
        outlineVariant: dark
            ? const Color(0xff343937)
            : const Color(0xffd9dedb),
      );
  final theme = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff111312)
        : const Color(0xfff3f5f3),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      elevation: 0,
      height: 60,
      indicatorColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 21,
          color: states.contains(WidgetState.selected)
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xff111312) : const Color(0xfff3f5f3),
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant),
  );
  final type = theme.textTheme;
  return theme.copyWith(
    textTheme: type.copyWith(
      headlineSmall: type.headlineSmall?.copyWith(
        height: 1.16,
        letterSpacing: -0.45,
        fontWeight: FontWeight.w600,
      ),
      titleLarge: type.titleLarge?.copyWith(
        height: 1.2,
        letterSpacing: -0.25,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: type.titleMedium?.copyWith(
        height: 1.25,
        letterSpacing: 0,
        fontWeight: FontWeight.w500,
      ),
      bodyMedium: type.bodyMedium?.copyWith(height: 1.36, letterSpacing: 0),
      bodySmall: type.bodySmall?.copyWith(
        fontSize: 13,
        height: 1.34,
        letterSpacing: 0.12,
      ),
      labelLarge: type.labelLarge?.copyWith(
        letterSpacing: 0,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
