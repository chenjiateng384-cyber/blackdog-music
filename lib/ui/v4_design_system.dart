import 'package:flutter/material.dart';

/// V4 uses a small, fixed token set so pages feel like one product instead of
/// a collection of individually styled Flutter widgets.
abstract final class V4Space {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double page = 20;
  static const double lg = 24;
  static const double section = 32;
  static const double xl = 40;
}

abstract final class V4Radius {
  static const double small = 10;
  static const double control = 14;
  static const double artwork = 16;
  static const double card = 22;
  static const double hero = 28;
  static const double sheet = 30;
}

abstract final class V4Size {
  static const double tapTarget = 48;
  static const double listArtwork = 52;
  static const double compactArtwork = 112;
  static const double navigationBar = 72;
  static const double divider = 0.7;
}

abstract final class V4Layout {
  static const double compactBreakpoint = 600;
  static const double maxContentWidth = 720;

  static double horizontalPaddingFor(double width) =>
      width >= compactBreakpoint ? V4Space.lg : V4Space.page;
}

abstract final class V4Motion {
  static const Duration quick = Duration(milliseconds: 160);
  static const Duration standard = Duration(milliseconds: 240);
}

abstract final class V4Colors {
  static const Color accent = Color(0xFFC84056);
  static const Color accentDark = Color(0xFFFF8A9D);

  static ColorScheme lightScheme() => _scheme(Brightness.light);

  static ColorScheme darkScheme() => _scheme(Brightness.dark);

  static ColorScheme _scheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      surface: dark ? const Color(0xFF0D0D0F) : const Color(0xFFFAF9F7),
    ).copyWith(
      primary: dark ? accentDark : accent,
      onPrimary: dark ? const Color(0xFF4B111D) : Colors.white,
      primaryContainer: dark
          ? const Color(0xFF51202A)
          : const Color(0xFFFBE8EB),
      onPrimaryContainer: dark
          ? const Color(0xFFFFD9DF)
          : const Color(0xFF57121E),
      surface: dark ? const Color(0xFF0D0D0F) : const Color(0xFFFAF9F7),
      onSurface: dark ? const Color(0xFFF2EFF1) : const Color(0xFF1E1B1D),
      surfaceContainerLowest: dark
          ? const Color(0xFF09090A)
          : const Color(0xFFFFFFFF),
      surfaceContainerLow: dark
          ? const Color(0xFF151518)
          : const Color(0xFFF5F2F1),
      surfaceContainer: dark
          ? const Color(0xFF1A1A1E)
          : const Color(0xFFF0EDEC),
      surfaceContainerHigh: dark
          ? const Color(0xFF202024)
          : const Color(0xFFEAE6E5),
      surfaceContainerHighest: dark
          ? const Color(0xFF28272C)
          : const Color(0xFFE4DFE0),
      onSurfaceVariant: dark
          ? const Color(0xFFC9C3C6)
          : const Color(0xFF686164),
      outline: dark ? const Color(0xFF928A8E) : const Color(0xFF81777B),
      outlineVariant: dark ? const Color(0xFF494347) : const Color(0xFFD6CED1),
    );
  }
}

TextTheme v4TextTheme(ColorScheme colors) => TextTheme(
  displaySmall: TextStyle(
    fontSize: 34,
    height: 1.08,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.8,
    color: colors.onSurface,
  ),
  headlineMedium: TextStyle(
    fontSize: 28,
    height: 1.14,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.45,
    color: colors.onSurface,
  ),
  headlineSmall: TextStyle(
    fontSize: 24,
    height: 1.18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    color: colors.onSurface,
  ),
  titleLarge: TextStyle(
    fontSize: 21,
    height: 1.25,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: colors.onSurface,
  ),
  titleMedium: TextStyle(
    fontSize: 17,
    height: 1.3,
    fontWeight: FontWeight.w700,
    color: colors.onSurface,
  ),
  titleSmall: TextStyle(
    fontSize: 15,
    height: 1.3,
    fontWeight: FontWeight.w700,
    color: colors.onSurface,
  ),
  bodyLarge: TextStyle(
    fontSize: 16,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: colors.onSurface,
  ),
  bodyMedium: TextStyle(
    fontSize: 14,
    height: 1.42,
    fontWeight: FontWeight.w400,
    color: colors.onSurface,
  ),
  bodySmall: TextStyle(
    fontSize: 12.5,
    height: 1.38,
    fontWeight: FontWeight.w400,
    color: colors.onSurfaceVariant,
  ),
  labelLarge: TextStyle(
    fontSize: 14,
    height: 1.25,
    fontWeight: FontWeight.w700,
    color: colors.onSurface,
  ),
  labelMedium: TextStyle(
    fontSize: 12,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: colors.onSurfaceVariant,
  ),
);
