import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_surface.dart';
import '../../core/widgets/ambient_background.dart';
import '../../core/widgets/liquid_glass.dart';
import '../../core/widgets/trend_chart.dart';
import '../../data/speech_library.dart';
import '../../services/db/app_database.dart';
import '../../services/settings_controller.dart';
import '../detail/shadowing_detail_page.dart';
import '../vocab/vocab_page.dart';

/// 练习统计（P1-5）：趋势曲线、连续打卡、每日目标、错词榜、SRS 复习队列
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  int _todayCount = 0;
  double _average = 0;
  int _days = 0;
  int _streak = 0;
  int _range = 7;
  List<DailyPoint> _series = [];
  List<MapEntry<String, int>> _topWrong = [];
  List<Map<String, Object?>> _review = [];
  int _dueCards = 0;
  int _vocabCount = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final overview = await AppDatabase.instance.overview();
      final series = await AppDatabase.instance.dailySeries(30);
      final top = await AppDatabase.instance.topWrongWords(limit: 10);
      final review = await AppDatabase.instance.reviewItems();
      final due = await AppDatabase.instance.dueReviewCount();
      final vocab = await AppDatabase.instance.allVocab();

      final seen = <String>{};
      final unique = <Map<String, Object?>>[];
      for (final r in review) {
        final key = '${r['speech_id']}#${r['sentence_index']}';
        if (seen.add(key)) unique.add(r);
      }
      if (!mounted) return;
      setState(() {
        _todayCount = overview.count;
        _average = overview.avg;
        _days = overview.days;
        _streak = overview.streak;
        _series = series;
        _topWrong = top;
        _review = unique;
        _dueCards = due;
        _vocabCount = vocab.length;
      });
    } catch (_) {
      // 数据库不可用时保持空态
    }
  }

  Future<void> _practiceReview(Map<String, Object?> row) async {
    final speechId = row['speech_id'] as String;
    final index = row['sentence_index'] as int;
    final speech = speechById(speechId);
    if (speech == null) return;
    await Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (_, __, ___) =>
            ShadowingDetailPage(speech: speech, initialIndex: index),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _addToVocab(String word) async {
    await AppDatabase.instance.addVocab(word: word);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「$word」已加入生词本'),
          duration: const Duration(seconds: 2)),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsScope.of(context);
    final goal = settings?.dailyGoal ?? 10;
    final shown = _series.length >= _range
        ? _series.sublist(_series.length - _range)
        : _series;
    final goalRatio = goal == 0 ? 0.0 : (_todayCount / goal).clamp(0.0, 1.0);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 130),
        children: [
          Text('练习统计', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 18),
          LiquidGlass(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _StatFigure(value: '$_todayCount', label: '今日句数'),
                _StatFigure(
                    value: _average == 0 ? '—' : _average.round().toString(),
                    label: '今日均分'),
                _StatFigure(value: '$_streak', label: '连续打卡'),
                _StatFigure(value: '$_days', label: '学习天数'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          LiquidGlass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.flag_rounded, size: 17, color: AppColors.primary),
                    const SizedBox(width: 7),
                    Text('每日目标', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    Text('$_todayCount / $goal 句',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: goalRatio,
                    minHeight: 6,
                    backgroundColor: AppSurface.inset(context),
                    color: goalRatio >= 1 ? AppColors.correct : AppColors.primary,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (final g in SettingsController.dailyGoalSteps)
                      Padding(
                        padding: const EdgeInsets.only(right: 7),
                        child: GestureDetector(
                          onTap: () async {
                            await settings?.setDailyGoal(g);
                            if (mounted) setState(() {});
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 11, vertical: 5),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: goal == g
                                  ? AppColors.primary.withValues(alpha: 0.85)
                                  : AppSurface.inset(context),
                            ),
                            child: Text('$g 句',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    color: goal == g
                                        ? Colors.white
                                        : AppSurface.textSecondary(context))),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          LiquidGlass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('练习趋势', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    for (final d in const [7, 30])
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: GestureDetector(
                          onTap: () => setState(() => _range = d),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(9),
                              color: _range == d
                                  ? AppColors.primary.withValues(alpha: 0.85)
                                  : AppSurface.inset(context),
                            ),
                            child: Text('$d 天',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: _range == d
                                        ? Colors.white
                                        : AppSurface.textSecondary(context))),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                TrendChart(points: shown, goal: goal),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AmbientBackground(
                    child: Scaffold(
                      backgroundColor: Colors.transparent,
                      body: VocabPage(),
                    ),
                  ),
                ),
              );
              await _refresh();
            },
            child: LiquidGlass(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.menu_book_rounded,
                      size: 20, color: AppColors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('生词本 · $_vocabCount 词',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      color: AppSurface.textTertiary(context)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          LiquidGlass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('错词 TOP 榜（点击收藏）',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                if (_topWrong.isEmpty)
                  Text('还没有错词记录，完成一次跟读试试吧',
                      style: Theme.of(context).textTheme.bodySmall)
                else
                  for (var i = 0; i < _topWrong.length; i++)
                    GestureDetector(
                      onTap: () => _addToVocab(_topWrong[i].key),
                      child: _WrongRank(
                        rank: i + 1,
                        word: _topWrong[i].key,
                        count: _topWrong[i].value,
                        maxCount: _topWrong.first.value,
                      ),
                    ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          LiquidGlass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('今日复习', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    if (_dueCards > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(9),
                          color: AppColors.missed.withValues(alpha: 0.16),
                        ),
                        child: Text('$_dueCards 句到期',
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.missed)),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text('按遗忘曲线自动排程：1 / 3 / 7 / 16 天后重现',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                if (_review.isEmpty)
                  Text('暂无到期复习，很棒 🎉',
                      style: Theme.of(context).textTheme.bodySmall)
                else
                  for (final row in _review) _reviewTile(row),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _reviewTile(Map<String, Object?> row) {
    final speechId = row['speech_id'] as String;
    final index = row['sentence_index'] as int;
    final speech = speechById(speechId);
    final sentence = (speech != null && index < speech.sentences.length)
        ? speech.sentences[index].english
        : '第 ${index + 1} 句';
    final wrongRaw = row['wrong_words'] as String?;
    final wrongs = <String>[];
    if (wrongRaw != null && wrongRaw.isNotEmpty) {
      for (final w in json.decode(wrongRaw) as List) {
        wrongs.add(w as String);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => _practiceReview(row),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppSurface.inset(context),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(sentence,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, height: 1.4)),
              if (wrongs.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 5,
                  runSpacing: 5,
                  children: [
                    for (final w in wrongs)
                      Text(w,
                          style: const TextStyle(
                              fontSize: 11.5, color: AppColors.wrong)),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: AppColors.primary.withValues(alpha: 0.85),
                  ),
                  child: const Text('一键重练',
                      style: TextStyle(fontSize: 12, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatFigure extends StatelessWidget {
  const _StatFigure({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w200,
                color: AppColors.primary)),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _WrongRank extends StatelessWidget {
  const _WrongRank({
    required this.rank,
    required this.word,
    required this.count,
    required this.maxCount,
  });

  final int rank;
  final String word;
  final int count;
  final int maxCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text('$rank',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                    color: AppSurface.textTertiary(context))),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 92,
            child: Text(word,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: maxCount == 0 ? 0 : count / maxCount,
              child: Container(
                height: 5,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  gradient: const LinearGradient(
                      colors: [AppColors.primarySoft, AppColors.primary]),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('$count',
              style: TextStyle(
                  fontSize: 12, color: AppSurface.textTertiary(context))),
        ],
      ),
    );
  }
}
