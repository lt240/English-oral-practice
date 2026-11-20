import 'package:flutter/material.dart';

import '../../data/speech_library.dart';

/// 内容封面：中文主题定色 + 英文标题文字为主视觉（不联网、不加载图片）
///
/// 用户要求「内容库内根据中文主题和英文文字封面」：
/// 渐变色取自该篇的中文主题配色，大号英文标题铺在封面上，
/// 中文主题作为角标，保证完全离线也有可辨识的封面。
class SpeechCover extends StatelessWidget {
  const SpeechCover({
    super.key,
    required this.speech,
    this.width = 72,
    this.height = 72,
    this.borderRadius = 16,
    this.titleFontSize = 13,
    this.showTopic = true,
  });

  final SpeechEntry speech;
  final double width;
  final double height;
  final double borderRadius;
  final double titleFontSize;
  final bool showTopic;

  static Color hex(String s, {Color fallback = const Color(0xFF5E7CF7)}) {
    if (s.length < 7) return fallback;
    final v = int.tryParse('FF${s.replaceFirst('#', '').substring(0, 6)}',
        radix: 16);
    return v == null ? fallback : Color(v);
  }

  @override
  Widget build(BuildContext context) {
    final colors = speech.coverColors.length >= 2
        ? [hex(speech.coverColors[0]), hex(speech.coverColors[1])]
        : [hex(speech.coverColors.first), const Color(0xFF8E6CF7)];

    final words = speech.title.split(' ');
    final line1 = words.take(3).join(' ');
    final line2 = words.length > 3 ? words.skip(3).join(' ') : '';

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.first.withValues(alpha: 0.32),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Stack(
          children: [
            // 右上角装饰光斑
            Positioned(
              right: -18,
              top: -18,
              child: Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.12),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(width >= 100 ? 14 : 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    line1,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: titleFontSize,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                  if (line2.isNotEmpty)
                    Text(
                      line2,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.88),
                        fontSize: titleFontSize * 0.88,
                        height: 1.15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  if (showTopic) ...[
                    SizedBox(height: width >= 100 ? 8 : 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: Colors.white.withValues(alpha: 0.22),
                      ),
                      child: Text(
                        speech.topicZh,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: width >= 100 ? 11 : 8.5,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
