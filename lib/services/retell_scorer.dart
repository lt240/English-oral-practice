// ─────────────────────────────────────────────────────────────
// 复述离线评分器
// 原理：把用户复述文本与每个关键点的「原文短语 + 同义表达」做
//       独立词覆盖率匹配，命中任一表达即算该要点覆盖。
// 全本地规则，无网络依赖。
// ─────────────────────────────────────────────────────────────

import '../data/speech_library.dart';

/// 单个关键点的命中结果
class KeyPointResult {
  final KeyPoint point;
  final bool covered;

  /// 实际命中的表达（phrase 或某条 synonym），未命中为 null
  final String? matched;

  const KeyPointResult({
    required this.point,
    required this.covered,
    this.matched,
  });
}

/// 整段复述评分结果
class RetellScoreResult {
  /// 覆盖率得分 0~100
  final int score;

  final int covered;
  final int total;
  final List<KeyPointResult> results;

  const RetellScoreResult({
    required this.score,
    required this.covered,
    required this.total,
    required this.results,
  });
}

class RetellScorer {
  /// 常见英文停用词（匹配时忽略，只看实词）
  static const _stopWords = {
    'a', 'an', 'the', 'to', 'of', 'in', 'on', 'for', 'and', 'or',
    'is', 'are', 'was', 'were', 'be', 'been', 'am', 'i', 'you', 'he',
    'she', 'it', 'we', 'they', 'my', 'your', 'his', 'her', 'its', 'our',
    'their', 'me', 'him', 'us', 'them', 'this', 'that', 'these', 'those',
    'with', 'at', 'by', 'from', 'as', 'do', 'does', 'did', 'have', 'has',
    'had', 'will', 'would', 'can', 'could', 'if', 'but', 'not', 'no', 'so',
    'up', 'out', 'about', 'into', 'over', 'such', 'than', 'then', 'there',
  };

  /// 文本归一化：小写、去标点（含数字千分位逗号）、空白规整
  static String normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// 提取表达中的实词
  static List<String> _contentWords(String expression) {
    return normalize(expression)
        .split(' ')
        .where((w) => w.isNotEmpty && !_stopWords.contains(w))
        .toList();
  }

  /// 判断某个表达是否被用户文本覆盖
  /// 规则：1~2 个实词必须全部命中（避免仅靠 give 这类常见词误判）；
  ///       3 个及以上命中比例 ≥ 0.5（向上取整，即 3 中 2、5 中 3）。
  static bool _expressionCovered(String expression, Set<String> spoken) {
    final words = _contentWords(expression);
    if (words.isEmpty) return false;
    final hit = words.where(spoken.contains).length;
    if (words.length <= 2) return hit == words.length;
    return hit >= (words.length * 0.5).ceil();
  }

  /// 提取表达中的实词（对外可见，供要点定位等复用）
  static List<String> contentWordsOf(String expression) =>
      _contentWords(expression);

  /// 按用户圈选的句子范围（全局句下标）过滤要点。
  /// 定位方式：以「包含该要点实词最多的句子」为锚点，锚点未覆盖的实词
  /// 取距锚点最近的出现位置，得到该要点横跨的句段 [lo, hi]；仅当句段
  /// 完全处于所选范围内时保留该要点。无法在字幕中定位的要点，只在选择
  /// 整段时参与评分。
  static List<KeyPoint> keyPointsInRange({
    required List<TranscriptSentence> sentences,
    required RetellClip clip,
    required int startIndex,
    required int endIndex,
  }) {
    // 选择范围覆盖整段 → 直接返回全部要点
    if (startIndex <= clip.startIndex && endIndex >= clip.endIndex) {
      return clip.keyPoints;
    }

    // 预构建：实词 → 在片段内出现的全局句下标
    final occ = <String, List<int>>{};
    for (var g = clip.startIndex; g <= clip.endIndex; g++) {
      final ws = normalize(sentences[g].english).split(' ').toSet();
      for (final w in ws) {
        if (w.isEmpty) continue;
        (occ[w] ??= <int>[]).add(g);
      }
    }

    final out = <KeyPoint>[];
    for (final kp in clip.keyPoints) {
      final words = _contentWords(kp.phrase).toSet();
      if (words.isEmpty) continue;

      // 锚点：包含该要点实词最多的句子
      int? anchor;
      var bestCount = 0;
      final anchorHits = <String>{};
      for (var g = clip.startIndex; g <= clip.endIndex; g++) {
        final ws = normalize(sentences[g].english).split(' ').toSet();
        var cnt = 0;
        final hits = <String>{};
        for (final w in words) {
          if (ws.contains(w)) {
            cnt += 1;
            hits.add(w);
          }
        }
        if (cnt > bestCount) {
          bestCount = cnt;
          anchor = g;
          anchorHits
            ..clear()
            ..addAll(hits);
        }
      }
      // 实词一个都找不到：无法定位，仅在整段范围评分
      if (anchor == null || bestCount == 0) continue;

      var lo = anchor;
      var hi = anchor;
      var located = true;
      // 锚点未覆盖的实词：取距锚点最近的出现句
      for (final w in words.where((w) => !anchorHits.contains(w))) {
        final hits = occ[w];
        if (hits == null) {
          located = false;
          break;
        }
        var best = hits.first;
        var bestDist = (best - anchor).abs();
        for (final h in hits.skip(1)) {
          final d = (h - anchor).abs();
          if (d < bestDist) {
            bestDist = d;
            best = h;
          }
        }
        if (best < lo) lo = best;
        if (best > hi) hi = best;
      }
      if (!located) continue;
      if (lo >= startIndex && hi <= endIndex) out.add(kp);
    }
    return out;
  }

  /// 对整段复述评分
  static RetellScoreResult score({
    required List<KeyPoint> keyPoints,
    required String recognized,
  }) {
    final spoken = normalize(recognized).split(' ').toSet();
    final results = <KeyPointResult>[];
    var coveredCount = 0;

    for (final kp in keyPoints) {
      String? matched;
      if (_expressionCovered(kp.phrase, spoken)) {
        matched = kp.phrase;
      } else {
        for (final syn in kp.synonyms) {
          if (_expressionCovered(syn, spoken)) {
            matched = syn;
            break;
          }
        }
      }
      if (matched != null) coveredCount += 1;
      results.add(KeyPointResult(
        point: kp,
        covered: matched != null,
        matched: matched,
      ));
    }

    final total = keyPoints.length;
    final score = total == 0 ? 0 : (coveredCount * 100 / total).round();
    return RetellScoreResult(
      score: score,
      covered: coveredCount,
      total: total,
      results: results,
    );
  }
}
