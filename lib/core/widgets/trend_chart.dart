import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_surface.dart';
import '../../services/srs.dart';

/// 近 N 天练习趋势：柱=每日句数，折线=每日均分（自绘，无第三方依赖）
class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.points,
    required this.goal,
    this.height = 150,
  });

  final List<DailyPoint> points;
  final int goal;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();
    final maxCount = points
        .map((e) => e.count)
        .fold<int>(goal, (a, b) => b > a ? b : a);
    final ceiling = (maxCount * 1.2).ceil().clamp(1, 10000);

    return SizedBox(
      height: height,
      child: Column(
        children: [
          Expanded(
            child: CustomPaint(
              painter: _TrendPainter(
                points: points,
                ceiling: ceiling.toDouble(),
                goal: goal.toDouble(),
                barColor: AppColors.primary,
                lineColor: AppColors.missed,
                guideColor: AppSurface.textTertiary(context),
              ),
              child: Container(),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_shortDate(points.first.date),
                  style: TextStyle(
                      fontSize: 10, color: AppSurface.textTertiary(context))),
              Text('柱：句数   线：均分',
                  style: TextStyle(
                      fontSize: 10, color: AppSurface.textTertiary(context))),
              Text(_shortDate(points.last.date),
                  style: TextStyle(
                      fontSize: 10, color: AppSurface.textTertiary(context))),
            ],
          ),
        ],
      ),
    );
  }

  String _shortDate(String d) {
    final p = d.split('-');
    return p.length == 3 ? '${p[1]}/${p[2]}' : d;
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.points,
    required this.ceiling,
    required this.goal,
    required this.barColor,
    required this.lineColor,
    required this.guideColor,
  });

  final List<DailyPoint> points;
  final double ceiling;
  final double goal;
  final Color barColor;
  final Color lineColor;
  final Color guideColor;

  @override
  void paint(Canvas canvas, Size size) {
    final n = points.length;
    final slot = size.width / n;
    final barW = (slot * 0.55).clamp(1.5, 18.0);

    // 目标线
    final goalY = size.height - (goal / ceiling) * size.height;
    final dash = Paint()
      ..color = guideColor.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, goalY), Offset(x + 4, goalY), dash);
      x += 8;
    }

    // 柱：每日句数
    final barPaint = Paint()..color = barColor.withValues(alpha: 0.72);
    for (var i = 0; i < n; i++) {
      final h = (points[i].count / ceiling) * size.height;
      if (h <= 0) continue;
      final cx = slot * i + slot / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(cx - barW / 2, size.height - h, cx + barW / 2,
            size.height),
        Radius.circular(barW / 2),
      );
      canvas.drawRRect(rect, barPaint);
    }

    // 折线：每日均分（0~100 映射到全高）
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    var started = false;
    for (var i = 0; i < n; i++) {
      if (points[i].count == 0) continue;
      final cx = slot * i + slot / 2;
      final cy = size.height - (points[i].avg / 100) * size.height;
      if (!started) {
        path.moveTo(cx, cy);
        started = true;
      } else {
        path.lineTo(cx, cy);
      }
    }
    if (started) canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.points != points || old.ceiling != ceiling || old.goal != goal;
}
