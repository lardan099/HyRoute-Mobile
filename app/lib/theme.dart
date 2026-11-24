import 'package:flutter/material.dart';

const accent = Color(0xff244fb1);
const connectionPanelLight = Color(0xff172b51);
const connectionPanelDark = Color(0xff213557);
const connectionDetail = Color(0xffceddfa);
const connectionActive = Color(0xffa8e3cf);

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: dark ? const Color(0xffafc8ff) : const Color(0xff244fb1),
        onPrimary: dark ? const Color(0xff182d58) : Colors.white,
        onSurface: dark ? const Color(0xffedf3ff) : const Color(0xff18243b),
        onSurfaceVariant: dark
            ? const Color(0xffafbed6)
            : const Color(0xff53637b),
        surface: dark ? const Color(0xff172131) : const Color(0xffffffff),
        surfaceContainerHigh: dark
            ? const Color(0xff243149)
            : const Color(0xffe7edf7),
        outlineVariant: dark
            ? const Color(0xff34455f)
            : const Color(0xffd6dfeb),
      );
  final theme = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff101723)
        : const Color(0xfff4f7fb),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      elevation: 0,
      height: 60,
      indicatorColor: scheme.primary.withValues(alpha: 0.12),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 21,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xff101723) : const Color(0xfff4f7fb),
      surfaceTintColor: Colors.transparent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
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
        letterSpacing: -0.4,
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
