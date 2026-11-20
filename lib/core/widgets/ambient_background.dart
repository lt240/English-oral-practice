import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_surface.dart';

/// 柔和环境漫射光背景：浅色基底 + 多层低饱和度彩色光斑（强模糊）
/// 玻璃卡片浮在其上，才会呈现折射光斑的「液态玻璃」观感。
///
/// P0-1：渐变与光斑全部走 [AppSurface]，深色模式下同步切换，
/// 不再出现「深色文字浮在浅色背景上」的低对比问题。
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AppSurface.background(context);
    final blobs = AppSurface.blobs(context);
    final alpha = AppSurface.blobAlpha(context);

    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: colors,
              ),
            ),
          ),
        ),

        // 柔和弥散光斑（蓝 / 紫 / 粉 / 薄荷）
        Positioned(top: -90, left: -70, child: _blob(blobs[0], 320, alpha)),
        Positioned(top: 110, right: -110, child: _blob(blobs[1], 300, alpha)),
        Positioned(bottom: -130, left: 30, child: _blob(blobs[2], 350, alpha)),
        Positioned(bottom: 40, right: 60, child: _blob(blobs[3], 210, alpha)),

        Positioned.fill(child: child),
      ],
    );
  }

  Widget _blob(Color color, double size, double alpha) {
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}
