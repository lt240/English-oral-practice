// 核心逻辑验证：不依赖 Flutter / sqflite，纯 Dart 可直接运行
// 用法：dart run test/verify_core.dart
// ignore_for_file: avoid_print
import 'package:ted_companion/models/practice_result.dart';
import 'package:ted_companion/services/aligner.dart';
import 'package:ted_companion/services/asr/text_normalizer.dart';
import 'package:ted_companion/services/srs.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool condition) {
  if (condition) {
    _passed++;
    print('  PASS  $name');
  } else {
    _failed++;
    print('  FAIL  $name');
  }
}

void main() {
  print('== 文本归一化 TextNormalizer ==');
  check(
    '去标点、转小写、展开缩写 it\'s → it is',
    WordAligner.tokenize("Hello, World! It's me.").join('|') ==
        'hello|world|it|is|me',
  );
  check('空字符串返回空列表', WordAligner.tokenize('   ').isEmpty);
  check(
    '数字转英文',
    TextNormalizer.normalize('try it for 30 days') == 'try it for thirty days',
  );
  check(
    '缩写展开 gonna → going to',
    TextNormalizer.normalize("I'm gonna try") == 'i am going to try',
  );
  check(
    '剔除括号转写噪声与填充词',
    TextNormalizer.normalize('(Laughter) Um, so I, uh, tried it') ==
        'so i tried it',
  );
  check(
    '口语音 near 同音表命中',
    TextNormalizer.equivalent('write', 'right'),
  );
  check(
    '同音表不误判无关词',
    !TextNormalizer.equivalent('write', 'wrong'),
  );
  check(
    '关闭容错时同音词不相等',
    !TextNormalizer.equivalent('write', 'right', fuzzy: false),
  );
  check(
    '发音近似键：phone / fone',
    TextNormalizer.phoneticKey('phone') == TextNormalizer.phoneticKey('fone'),
  );

  print('== WordAligner.align（基础） ==');
  var r = WordAligner.alignSentence(
      reference: 'i have a dream', recognized: 'I have a dream');
  check('全对 → 全 correct',
      r.every((w) => w.verdict == WordVerdict.correct) && r.length == 4);

  r = WordAligner.alignSentence(
      reference: 'the quick brown fox', recognized: 'the quick brown box');
  check('fox→box 替换 → 1 wrong + 3 correct',
      r.where((w) => w.verdict == WordVerdict.wrong).length == 1 &&
          r.where((w) => w.verdict == WordVerdict.correct).length == 3);
  check('错词记录的是原文词 fox',
      r.firstWhere((w) => w.verdict == WordVerdict.wrong).reference == 'fox');

  r = WordAligner.alignSentence(
      reference: 'try something new for thirty days',
      recognized: 'try something for thirty days');
  check('漏读 new → 1 missed',
      r.singleWhere((w) => w.verdict == WordVerdict.missed).reference == 'new');

  r = WordAligner.alignSentence(
      reference: 'paper towel', recognized: 'paper the towel');
  check('多读 the → 1 extra',
      r.singleWhere((w) => w.verdict == WordVerdict.extra).spoken == 'the');

  r = WordAligner.alignSentence(reference: 'a b c', recognized: '');
  check('全漏读 → 3 missed',
      r.length == 3 && r.every((w) => w.verdict == WordVerdict.missed));

  print('== WordAligner（智能化容错） ==');
  r = WordAligner.alignSentence(
      reference: 'i want to write it right',
      recognized: 'I want to right it write');
  check('同音异形 write/right 按读对处理',
      r.every((w) => w.verdict == WordVerdict.correct));
  check('模糊命中带 fuzzy 标记', r.any((w) => w.fuzzy));

  r = WordAligner.alignSentence(
      reference: 'i want to write it right',
      recognized: 'I want to right it write',
      fuzzy: false);
  check('关闭容错后同音词判错',
      r.where((w) => w.verdict == WordVerdict.wrong).length == 2);

  r = WordAligner.alignSentence(
      reference: "I can't do it", recognized: 'I cannot do it');
  check("缩写 can't / cannot 对齐为全对",
      r.every((w) => w.verdict == WordVerdict.correct));

  check('错词给出发音提示',
      (WordAligner.hintFor(const AlignedWord(
                  reference: 'think', spoken: 'sink',
                  verdict: WordVerdict.wrong)) ??
              '')
          .contains('θ'));

  print('== 识别质量评估 ==');
  final good = TextNormalizer.assess('I have a dream today', 5);
  check('词数吻合 → 可信', good.score >= 0.8);
  final bad = TextNormalizer.assess('I', 10);
  check('词数严重不足 → 低可信', bad.score < 0.55);
  check('空识别给出指引', TextNormalizer.assess('', 5).label == '未识别到语音');

  print('== SentenceScore ==');
  final score = SentenceScore(
    words: WordAligner.alignSentence(
      reference: 'schools kill creativity in children',
      recognized: 'schools kill creativity children',
    ),
    referenceCount: 5,
  );
  check('4/5 正确率 = 0.8', (score.accuracy - 0.8).abs() < 1e-9);
  check('错词清单含 in', score.errorWords.contains('in'));
  check('漏读数 = 1', score.missedCount == 1);

  print('== SM-2 排程 ==');
  const zero = Schedule(
      ease: 2.5, intervalDays: 0, repetitions: 0, dueAt: 0);
  final s1 = Srs.next(prev: zero, score: 95, nowMs: 0);
  check('首次高分 → 1 天后', s1.intervalDays == 1 && s1.repetitions == 1);
  final s2 = Srs.next(prev: s1, score: 95, nowMs: 0);
  check('第二次 → 3 天后', s2.intervalDays == 3);
  final s3 = Srs.next(prev: s2, score: 95, nowMs: 0);
  check('第三次 → 按 ease 增长', s3.intervalDays > 3);
  final fail = Srs.next(prev: s3, score: 30, nowMs: 0);
  check('低分 → 重置为 1 天 + lapses+1',
      fail.intervalDays == 1 && fail.repetitions == 0 && fail.lapses == 1);
  check('dueAt 严格大于 now（高分）',
      s1.dueAt == const Duration(days: 1).inMilliseconds);
  check('分数分档边界', Srs.gradeOf(90) == 5 && Srs.gradeOf(39) == 0);

  print('== 连续打卡 ==');
  check('空序列 → 0', streakFromSeries([]) == 0);
  check('今天没练但前两天练了 → 2',
      streakFromSeries(const [
        DailyPoint(date: 'a', count: 1, avg: 80),
        DailyPoint(date: 'b', count: 2, avg: 80),
        DailyPoint(date: 'c', count: 0, avg: 0),
      ]) ==
          2);
  check('中间断档会截断',
      streakFromSeries(const [
        DailyPoint(date: 'a', count: 1, avg: 80),
        DailyPoint(date: 'b', count: 0, avg: 0),
        DailyPoint(date: 'c', count: 1, avg: 80),
      ]) ==
          1);

  print('== 分数稳定性 ==');
  final summary = ScoreSummary.of([70, 95, 90, 92]);
  check('最好分 95', summary.best == 95);
  check('近 4 次均值正确', (summary.recentAverage - 86.75).abs() < 1e-9);
  check('波动大时建议展示均值', summary.prefersAverage);
  check('空历史不崩', ScoreSummary.of([]).attempts == 0);

  print('');
  print('结果：$_passed 通过 / $_failed 失败');
  if (_failed > 0) throw StateError('存在失败用例');
}
