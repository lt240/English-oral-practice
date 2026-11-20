import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_surface.dart';

/// ─────────────────────────────────────────────────────────────
/// 液态玻璃容器（Liquid Glass）
///
/// ① 底层强模糊 BackdropFilter + ImageFilter.blur
/// ② 层次化高光描边（左上强、右下弱）
/// ③ 多层半透明叠加，制造玻璃厚度
/// ④ 柔和弥散阴影
///
/// P0-1：tintColor 缺省时走 [AppSurface.glassTint]；描边强度走
/// [AppSurface.borderStrength]，深色下自动压低，避免白色描边过曝。
/// ─────────────────────────────────────────────────────────────
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(26)),
    this.blurSigma = 40,
    this.tintColor,
    this.tintOpacity = 0.15,
    this.padding = const EdgeInsets.all(20),
    this.margin,
    this.shadows,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;

  /// ② 玻璃底色；null = 跟随主题语义色
  final Color? tintColor;
  final double tintOpacity;

  final EdgeInsets padding;
  final EdgeInsets? margin;
  final List<BoxShadow>? shadows;

  @override
  Widget build(BuildContext context) {
    final dark = AppSurface.isDark(context);
    final tint = tintColor ?? AppSurface.glassTint(context);
    final effectiveShadows = shadows ??
        [
          BoxShadow(
            color: const Color(0xFF0E1E3C)
                .withValues(alpha: dark ? 0.38 : 0.10),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ];

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: effectiveShadows,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: CustomPaint(
            foregroundPainter: _GlassBorderPainter(
              borderRadius: borderRadius,
              strength: AppSurface.borderStrength(context),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    tint.withValues(alpha: (tintOpacity + 0.05).clamp(0, 1)),
                    tint.withValues(alpha: (tintOpacity - 0.05).clamp(0, 1)),
                  ],
                ),
              ),
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// ② 高光描边画笔：1px 亮色渐变，左上强、右下弱；光源来自左上方
class _GlassBorderPainter extends CustomPainter {
  _GlassBorderPainter({required this.borderRadius, required this.strength});

  final BorderRadius borderRadius;
  final double strength;

  Color _w(double alpha) =>
      Colors.white.withValues(alpha: (alpha * strength).clamp(0.0, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = borderRadius.toRRect(Offset.zero & size);

    final edgeShader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      stops: const [0, 0.35, 1],
      colors: [_w(0.60), _w(0.20), _w(0.05)],
    ).createShader(Offset.zero & size);

    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = edgeShader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final topShader = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [_w(0.50), _w(0.10), _w(0.0)],
    ).createShader(Rect.fromLTWH(0, 0, size.width, 1));

    canvas.drawLine(
      Offset.zero,
      Offset(size.width, 0),
      Paint()
        ..shader = topShader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final leftShader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [_w(0.40), _w(0.08), _w(0.0)],
    ).createShader(Rect.fromLTWH(0, 0, 1, size.height));

    canvas.drawLine(
      Offset.zero,
      Offset(0, size.height),
      Paint()
        ..shader = leftShader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _GlassBorderPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.strength != strength;
}
