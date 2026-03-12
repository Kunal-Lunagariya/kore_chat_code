import 'package:flutter/material.dart';

class AppTheme {
  static const Color redAccent = Color(0xFFE31E24);
  static const Color redDark = Color(0xFFB71C1C);

  // ── Dark palette ──────────────────────────────────────────────
  static const Color darkBg = Color(0xFF0D0D0D);
  static const Color darkCard = Color(0xFF1A1A1A);
  static const Color darkInput = Color(0xFF242424);
  static const Color darkTextPrimary = Color(0xFFFFFFFF);
  static const Color darkTextSecondary = Color(0xFF9E9E9E);
  static const Color darkBorder = Color(0xFF2C2C2C);

  // ── Light palette ─────────────────────────────────────────────
  static const Color lightBg = Color(0xFFF5F5F5);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightInput = Color(0xFFF0F0F0);
  static const Color lightTextPrimary = Color(0xFF0D0D0D);
  static const Color lightTextSecondary = Color(0xFF757575);
  static const Color lightBorder = Color(0xFFE0E0E0);

  // ── Dark ThemeData ─────────────────────────────────────────────
  static ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: darkBg,
    colorScheme: const ColorScheme.dark(
      primary: redAccent,
      secondary: redDark,
      surface: darkCard,
      onSurface: darkTextPrimary,
    ),
    inputDecorationTheme: _inputTheme(
      fillColor: darkInput,
      borderColor: darkBorder,
      textColor: darkTextPrimary,
      hintColor: darkTextSecondary,
    ),
    textTheme: _textTheme(darkTextPrimary, darkTextSecondary),
    useMaterial3: true,
  );

  // ── Light ThemeData ────────────────────────────────────────────
  static ThemeData lightTheme = ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: lightBg,
    colorScheme: const ColorScheme.light(
      primary: redAccent,
      secondary: redDark,
      surface: lightCard,
      onSurface: lightTextPrimary,
    ),
    inputDecorationTheme: _inputTheme(
      fillColor: lightInput,
      borderColor: lightBorder,
      textColor: lightTextPrimary,
      hintColor: lightTextSecondary,
    ),
    textTheme: _textTheme(lightTextPrimary, lightTextSecondary),
    useMaterial3: true,
  );

  static InputDecorationTheme _inputTheme({
    required Color fillColor,
    required Color borderColor,
    required Color textColor,
    required Color hintColor,
  }) {
    return InputDecorationTheme(
      filled: true,
      fillColor: fillColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: borderColor, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: redAccent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
      ),
      hintStyle: TextStyle(color: hintColor, fontSize: 14),
      errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 12),
    );
  }

  static TextTheme _textTheme(Color primary, Color secondary) {
    return TextTheme(
      displayLarge: TextStyle(color: primary, fontWeight: FontWeight.w900),
      titleLarge: TextStyle(color: primary, fontWeight: FontWeight.w700),
      bodyMedium: TextStyle(color: secondary),
      labelSmall: TextStyle(color: secondary, letterSpacing: 0.8),
    );
  }
}