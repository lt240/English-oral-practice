import 'package:flutter/material.dart';

/// 全局配色：低饱和度、柔和、轻奢
class AppColors {
  AppColors._();

  // 文字
  static const Color textPrimary = Color(0xFF1C2434);
  static const Color textSecondary = Color(0xFF6B7488);
  static const Color textTertiary = Color(0xFF9AA3B4);

  // 玻璃
  static const Color glassTint = Colors.white;

  // 跟读反馈
  static const Color correct = Color(0xFF2ECC8B); // 读对 - 绿
  static const Color wrong = Color(0xFFFF5B6A); // 读错 - 红
  static const Color missed = Color(0xFFFFA940); // 漏读/多读 - 橙
  static const Color unread = Color(0xFFA4ADC0); // 未读 - 灰

  // 主题色
  static const Color primary = Color(0xFF5E7CF7);
  static const Color primarySoft = Color(0xFF8FA6FB);
}
