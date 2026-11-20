import 'dart:math' as math;

import 'asr/text_normalizer.dart';

/// 词级判定：对 / 错 / 漏读 / 多读
enum WordVerdict { correct, wrong, missed, extra }

class AlignedWord {
  final String? reference; // 原文词（多读时为 null）
  final String? spoken; // 识别词（漏读时为 null）
  final WordVerdict verdict;

  /// 模糊命中：同音异形 / 发音近似，按「读对」计分但可单独标注
  final bool fuzzy;

  const AlignedWord({
    this.reference,
    this.spoken,
    required this.verdict,
    this.fuzzy = false,
  });
}

/// 原文 ↔ 识别文本 逐词对齐（编辑距离 DP + 回溯）
///
/// P1-6 / B1：比对前先经 [TextNormalizer] 归一化（缩写、数字、标点、
/// 填充词），并支持同音异形与发音近似容错，显著降低端侧小模型的误判。
class WordAligner {
  /// 归一化分词
  static List<String> tokenize(String text) {
    final normalized = TextNormalizer.normalize(text);
    if (normalized.isEmpty) return const [];
    return normalized.split(' ').where((w) => w.isNotEmpty).toList();
  }

  static List<AlignedWord> align(
    List<String> ref,
    List<String> hyp, {
    bool fuzzy = true,
  }) {
    final n = ref.length;
    final m = hyp.length;

    final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = 1; i <= n; i++) {
      dp[i][0] = i;
    }
    for (var j = 1; j <= m; j++) {
      dp[0][j] = j;
    }
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        final same = TextNormalizer.equivalent(ref[i - 1], hyp[j - 1],
            fuzzy: fuzzy);
        final cost = same ? 0 : 1;
        dp[i][j] = [
          dp[i - 1][j] + 1, // 删除 → 漏读
          dp[i][j - 1] + 1, // 插入 → 多读
          dp[i - 1][j - 1] + cost, // 匹配/替换
        ].reduce(math.min);
      }
    }

    final result = <AlignedWord>[];
    var i = n;
    var j = m;

    while (i > 0 || j > 0) {
      if (i > 0 && j > 0) {
        final same = TextNormalizer.equivalent(ref[i - 1], hyp[j - 1],
            fuzzy: fuzzy);
        final cost = same ? 0 : 1;
        if (dp[i][j] == dp[i - 1][j - 1] + cost) {
          result.add(
            AlignedWord(
              reference: ref[i - 1],
              spoken: hyp[j - 1],
              verdict: cost == 0 ? WordVerdict.correct : WordVerdict.wrong,
              fuzzy: cost == 0 && ref[i - 1] != hyp[j - 1],
            ),
          );
          i--;
          j--;
          continue;
        }
      }

      if (j > 0 && (i == 0 || dp[i][j] == dp[i][j - 1] + 1)) {
        result.add(AlignedWord(spoken: hyp[j - 1], verdict: WordVerdict.extra));
        j--;
      } else {
        result.add(
            AlignedWord(reference: ref[i - 1], verdict: WordVerdict.missed));
        i--;
      }
    }

    return result.reversed.toList();
  }

  static List<AlignedWord> alignSentence({
    required String reference,
    required String recognized,
    bool fuzzy = true,
  }) {
    return align(tokenize(reference), tokenize(recognized), fuzzy: fuzzy);
  }

  /// 错词的发音改进提示（B5）
  static String? hintFor(AlignedWord w) {
    if (w.verdict != WordVerdict.wrong) return null;
    return TextNormalizer.confusionHint(
        w.reference ?? '', w.spoken ?? '');
  }
}
