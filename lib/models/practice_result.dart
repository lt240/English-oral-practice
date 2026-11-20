import '../services/aligner.dart';

/// 单句跟读评分
class SentenceScore {
  final List<AlignedWord> words;
  final int referenceCount;

  const SentenceScore({
    required this.words,
    required this.referenceCount,
  });

  int get correctCount =>
      words.where((w) => w.verdict == WordVerdict.correct).length;
  int get wrongCount =>
      words.where((w) => w.verdict == WordVerdict.wrong).length;
  int get missedCount =>
      words.where((w) => w.verdict == WordVerdict.missed).length;
  int get extraCount =>
      words.where((w) => w.verdict == WordVerdict.extra).length;

  /// 本句正确率
  double get accuracy =>
      referenceCount == 0 ? 0 : correctCount / referenceCount;

  /// 读错/漏读的原文词（用于错词清单）
  List<String> get errorWords => words
      .where(
        (w) =>
            w.verdict == WordVerdict.wrong || w.verdict == WordVerdict.missed,
      )
      .map((w) => w.reference ?? '')
      .where((w) => w.isNotEmpty)
      .toList();
}

/// 整篇练习统计
class PracticeSummary {
  final String speechId;
  final DateTime startedAt;
  final DateTime finishedAt;
  final int totalWords;
  final int correct;
  final int wrong;
  final int missed;
  final int extra;

  const PracticeSummary({
    required this.speechId,
    required this.startedAt,
    required this.finishedAt,
    required this.totalWords,
    required this.correct,
    required this.wrong,
    required this.missed,
    required this.extra,
  });

  double get accuracy => totalWords == 0 ? 0 : correct / totalWords;
}
