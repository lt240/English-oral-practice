import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 简洁浅色基底 + 玻璃质感由组件层实现（AmbientBackground + LiquidGlass）
ThemeData buildGlassTheme() {
  final base = ThemeData.light(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFFF5F7FC),
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.primary,
      secondary: AppColors.primarySoft,
      surface: Colors.white,
    ),
    textTheme: base.textTheme
        .apply(
          bodyColor: AppColors.textPrimary,
          displayColor: AppColors.textPrimary,
        )
        .copyWith(
          titleLarge: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w300,
            letterSpacing: 0.5,
          ),
          titleMedium: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
          ),
          bodyLarge: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w300,
            height: 1.5,
          ),
          bodySmall: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w300,
            color: AppColors.textSecondary,
          ),
        ),
    iconTheme: const IconThemeData(color: AppColors.textPrimary, size: 22),
  );
}

/// 深色基底：深夜蓝，玻璃质感在深色上更通透
ThemeData buildDarkGlassTheme() {
  final base = ThemeData.dark(useMaterial3: true);

  // 与 AppSurface.background 深色渐变起点保持一致（微暖深紫棕）
  const bg = Color(0xFF1B1722);
  const textMain = Color(0xFFF3EDE8);
  const textSub = Color(0xFFCFC3C4);

  return base.copyWith(
    scaffoldBackgroundColor: bg,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.primary,
      secondary: AppColors.primarySoft,
      surface: const Color(0xFF1B2438),
    ),
    textTheme: base.textTheme
        .apply(
          bodyColor: textMain,
          displayColor: textMain,
        )
        .copyWith(
          titleLarge: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w300,
            letterSpacing: 0.5,
          ),
          titleMedium: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
          ),
          bodyLarge: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w300,
            height: 1.5,
          ),
          bodySmall: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w300,
            color: textSub,
          ),
        ),
    iconTheme: const IconThemeData(color: textMain, size: 22),
  );
}
