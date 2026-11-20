/// 间隔重复与统计的纯逻辑（不依赖 Flutter / sqflite，可脱离运行环境单测）
library;

/// SM-2 排程状态
class Schedule {
  final double ease;
  final int intervalDays;
  final int repetitions;
  final int dueAt;
  final int lapses;

  const Schedule({
    required this.ease,
    required this.intervalDays,
    required this.repetitions,
    required this.dueAt,
    this.lapses = 0,
  });

  factory Schedule.fromRow(Map<String, Object?> row) => Schedule(
        ease: (row['ease'] as num?)?.toDouble() ?? 2.5,
        intervalDays: (row['interval_days'] as num?)?.toInt() ?? 0,
        repetitions: (row['repetitions'] as num?)?.toInt() ?? 0,
        dueAt: (row['due_at'] as num?)?.toInt() ?? 0,
        lapses: (row['lapses'] as num?)?.toInt() ?? 0,
      );
}

/// SM-2 简版：分数 → grade → 下次复习间隔
class Srs {
  Srs._();

  static Schedule next({
    required Schedule prev,
    required int score,
    int nowMs = -1,
  }) {
    final grade = gradeOf(score);
    final now = nowMs >= 0 ? nowMs : DateTime.now().millisecondsSinceEpoch;
    if (grade < 3) {
      return Schedule(
        ease: prev.ease,
        intervalDays: 1,
        repetitions: 0,
        dueAt: now + const Duration(days: 1).inMilliseconds,
        lapses: prev.lapses + 1,
      );
    }
    var ease = prev.ease + (0.1 - (5 - grade) * (0.08 + (5 - grade) * 0.02));
    if (ease < 1.3) ease = 1.3;
    final reps = prev.repetitions + 1;
    final interval = reps == 1
        ? 1
        : reps == 2
            ? 3
            : (prev.intervalDays * ease).round().clamp(1, 365);
    return Schedule(
      ease: ease,
      intervalDays: interval,
      repetitions: reps,
      dueAt: now + Duration(days: interval).inMilliseconds,
      lapses: prev.lapses,
    );
  }

  static int gradeOf(int score) => score >= 90
      ? 5
      : score >= 75
          ? 4
          : score >= 60
              ? 3
              : score >= 40
                  ? 2
                  : 0;
}

/// 每日聚合点
class DailyPoint {
  final String date;
  final int count;
  final double avg;

  const DailyPoint({required this.date, required this.count, required this.avg});
}

/// 连续打卡天数：今天还没练不打断昨天的连续记录
int streakFromSeries(List<DailyPoint> series) {
  var streak = 0;
  for (var i = series.length - 1; i >= 0; i--) {
    if (series[i].count > 0) {
      streak++;
    } else if (i == series.length - 1) {
      continue;
    } else {
      break;
    }
  }
  return streak;
}

/// 分数稳定性：展示用「本次 / 最好 / 近 N 次均值」（P1-6）
class ScoreSummary {
  final int current;
  final int best;
  final double recentAverage;
  final int attempts;

  const ScoreSummary({
    required this.current,
    required this.best,
    required this.recentAverage,
    required this.attempts,
  });

  factory ScoreSummary.of(List<int> historyNewestFirst) {
    if (historyNewestFirst.isEmpty) {
      return const ScoreSummary(
          current: 0, best: 0, recentAverage: 0, attempts: 0);
    }
    final current = historyNewestFirst.first;
    final best = historyNewestFirst.reduce((a, b) => a > b ? a : b);
    final sum = historyNewestFirst.fold<int>(0, (a, b) => a + b);
    return ScoreSummary(
      current: current,
      best: best,
      recentAverage: sum / historyNewestFirst.length,
      attempts: historyNewestFirst.length,
    );
  }

  /// 是否建议以「近 N 次均值」替代单次分（波动过大时更可信）
  bool get prefersAverage => attempts >= 3 && (best - current).abs() > 12;
}
