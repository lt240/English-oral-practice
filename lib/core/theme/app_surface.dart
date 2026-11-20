import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 语义化表面色（P0-1）
///
/// 所有「随明暗变化」的取色都必须经过这里，禁止在页面里直接写
/// `Colors.white` / `AppColors.textPrimary` 之类的固定值。
/// 背景渐变、玻璃底色、文字三者同源，深色模式下才不会出现「浅底浅字」。
class AppSurface {
  AppSurface._();

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// 页面背景渐变（与 glass_theme 的 scaffoldBackgroundColor 保持一致）
  static List<Color> background(BuildContext context) => isDark(context)
      // 用户反馈：深色偏一点点暖，用微暖的深紫棕替代原来的冷蓝
      ? const [Color(0xFF1B1722), Color(0xFF100D16)]
      : const [Color(0xFFF5F7FC), Color(0xFFE7EDF7)];

  /// 环境光斑颜色：深色用低饱和冷色，避免深底发光
  static List<Color> blobs(BuildContext context) => isDark(context)
      ? const [
          Color(0xFF7A4A6B), // 暖紫，替代原来的冷蓝
          Color(0xFF4A3B7C),
          Color(0xFF8A504F),
          Color(0xFF6A5A4A), // 暖褐，替代原来的薄荷绿
        ]
      : const [
          Color(0xFFB8CCF6),
          Color(0xFFDEC6F4),
          Color(0xFFF5C6D9),
          Color(0xFFBEE7DB),
        ];

  /// 光斑峰值不透明度
  static double blobAlpha(BuildContext context) =>
      isDark(context) ? 0.22 : 0.75;

  /// 玻璃底色
  static Color glassTint(BuildContext context) => isDark(context)
      ? const Color(0xFF8FA6D8)
      : Colors.white;

  /// 高光描边强度（深色下过曝，需显著压低）
  static double borderStrength(BuildContext context) =>
      isDark(context) ? 0.26 : 1.0;

  /// 卡片内嵌衬底（列表项、按钮底）
  static Color inset(BuildContext context) =>
      Colors.white.withValues(alpha: isDark(context) ? 0.08 : 0.12);

  /// 主文字（替代硬编码 AppColors.textPrimary）
  static Color textPrimary(BuildContext context) => isDark(context)
      // 微暖白，配合偏暖深色底
      ? const Color(0xFFF3EDE8)
      : AppColors.textPrimary;

  /// 次级文字
  static Color textSecondary(BuildContext context) => isDark(context)
      ? const Color(0xFFCFC3C4)
      : AppColors.textSecondary;

  /// 三级文字 / 图标
  static Color textTertiary(BuildContext context) => isDark(context)
      ? const Color(0xFF9C8E9B)
      : AppColors.textTertiary;

  /// 强强调色上的文字（如主色按钮内），两种主题都保持白色
  static Color onPrimary = Colors.white;

  /// 主题主色（浅/深统一，保证品牌识别）
  static Color primary(BuildContext context) => AppColors.primary;
}
