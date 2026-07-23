import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppColors {
  static const primary = Color(0xFF6366F1);
  static const primaryLight = Color(0xFF818CF8);
  static const accent = Color(0xFF06B6D4);
  static const accentSecondary = Color(0xFF8B5CF6);
  static const background = Color(0xFF0B0B14);
  static const surface = Color(0xFF161623);
  static const surfaceLight = Color(0xFF1E1E2E);
  static const textPrimary = Color(0xFFF1F5F9);
  static const textSecondary = Color(0xFF94A3B8);
  static const textMuted = Color(0xFF64748B);
  static const success = Color(0xFF34D399);
  static const warning = Color(0xFFFBBF24);
  static const error = Color(0xFFF87171);
  static const glassBorder = Color(0x33FFFFFF);

  static const gradientPrimary = LinearGradient(
    colors: [accent, primary],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientHero = LinearGradient(
    colors: [Color(0xFF06B6D4), Color(0xFF6366F1), Color(0xFF8B5CF6)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientBackground = LinearGradient(
    colors: [Color(0xFF0B0B14), Color(0xFF12121F), Color(0xFF0F172A)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}

ThemeData buildAppTheme() {
  const colorScheme = ColorScheme.dark(
    primary: AppColors.primary,
    secondary: AppColors.accent,
    surface: AppColors.surface,
    error: AppColors.error,
    onPrimary: Colors.white,
    onSecondary: Colors.white,
    onSurface: AppColors.textPrimary,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      titleTextStyle: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceLight,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.glassBorder, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
      labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
      hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.textSecondary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.accent;
        return AppColors.textMuted;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return AppColors.accent.withValues(alpha: 0.35);
        }
        return AppColors.surfaceLight;
      }),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.glassBorder,
      thickness: 1,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
  );
}

BoxDecoration glassCardDecoration({Color? borderColor}) {
  return BoxDecoration(
    color: AppColors.surface.withValues(alpha: 0.85),
    borderRadius: BorderRadius.circular(20),
    border: Border.all(
      color: borderColor ?? AppColors.glassBorder,
      width: 1,
    ),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.25),
        blurRadius: 20,
        offset: const Offset(0, 8),
      ),
    ],
  );
}

BoxDecoration hudPanelDecoration({Color? accentColor}) {
  return BoxDecoration(
    color: Colors.black.withValues(alpha: 0.55),
    borderRadius: BorderRadius.circular(14),
    border: Border.all(
      color: (accentColor ?? AppColors.glassBorder).withValues(alpha: 0.6),
      width: 1,
    ),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.3),
        blurRadius: 12,
        offset: const Offset(0, 4),
      ),
    ],
  );
}
