// ─────────────────────────────────────────────────────────────
// 一次性脚本：用 whisper.cpp 的识别结果为演讲稿生成精确时间戳
//
// 输入：
//   tools/whisper/transcript.json  —— whisper-cli -ojf 产物（词级时间戳）
//   lib/data/speech_library.dart   —— 原文 + 中文翻译（本脚本直接 import）
//
// 处理：
//   1. 从 whisper token 重建「识别词 + 毫秒时间」全局序列
//   2. 原文所有句子的单词拼接成全局序列
//   3. 编辑距离 DP 做全局模糊对齐（词序单调，无需网络）
//   4. 每个词获得时间戳，聚合回句子 → startTime / endTime
//   5. 对不上的句子按「前一句结束 + 词数估算」兜底并打印警告
//
// 输出：
//   assets/content/<speechId>.json —— App 运行时加载（text/translation/startTime/endTime）
//
// 运行：
//   dart run tools/generate_timestamps.dart
// ─────────────────────────────────────────────────────────────

import 'dart:convert';
import 'dart:io';

import 'package:ted_companion/data/speech_library.dart';

/// 归一化：小写、仅保留字母和词内撇号
String norm(String w) {
  final s = w.toLowerCase();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final isLetter = (c >= 97 && c <= 122);
    final isApos = s[i] == "'" || s[i] == '’';
    if (isLetter || isApos) buf.write(s[i]);
  }
  return buf.toString();
}

List<String> tokenize(String text) {
  return text
      .split(RegExp(r"[^A-Za-z']+"))
      .map(norm)
      .where((w) => w.isNotEmpty)
      .toList();
}

class HWord {
  HWord(this.word, this.fromMs, this.toMs);
  final String word;
  final int fromMs;
  final int toMs;
}

class RWord {
  RWord(this.sentence, this.word);
  final int sentence;
  final String word;
  HWord? match; // 对齐到的识别词
}

void main() {
  const speechIndex = 0;
  final speech = kSpeechLibrary[speechIndex];

  // ── 1. 读取 whisper 结果，重建识别词序列 ─────────────────
  final raw =
      File('tools/whisper/transcript.json').readAsStringSync();
  final json = jsonDecode(raw) as Map<String, dynamic>;
  final segments = json['transcription'] as List;

  final heard = <HWord>[];
  for (final seg in segments) {
    for (final tok in seg['tokens'] as List) {
      final text = (tok['text'] as String).trim();
      // 跳过特殊控制符 [_BEG_] / [_TT_] 等
      if (text.startsWith('[') && text.endsWith(']')) continue;
      final w = norm(text);
      if (w.isEmpty) continue;
      final from = (tok['offsets']['from'] as num).round();
      final to = (tok['offsets']['to'] as num).round();
      heard.add(HWord(w, from, to <= from ? from + 200 : to));
    }
  }

  // ── 2. 原文单词全局序列（记录所属句子）──────────────────
  final refs = <RWord>[];
  for (var i = 0; i < speech.sentences.length; i++) {
    for (final w in tokenize(speech.sentences[i].english)) {
      refs.add(RWord(i, w));
    }
  }

  stdout.writeln('原文词数：${refs.length}，识别词数：${heard.length}');

  // ── 3. 编辑距离 DP 全局对齐 ─────────────────────────────
  final n = refs.length;
  final m = heard.length;
  // 滚动数组不行（要回溯），用 Int32 二维
  final dp = List<List<int>>.generate(
      n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = 0; i <= n; i++) {
    dp[i][0] = i;
  }
  for (var j = 0; j <= m; j++) {
    dp[0][j] = j;
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      final subCost = refs[i - 1].word == heard[j - 1].word ? 0 : 1;
      final a = dp[i - 1][j - 1] + subCost;
      final b = dp[i - 1][j] + 1;
      final c = dp[i][j - 1] + 1;
      dp[i][j] = a < b ? (a < c ? a : c) : (b < c ? b : c);
    }
  }

  // 回溯
  var i = n, j = m;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0) {
      final subCost = refs[i - 1].word == heard[j - 1].word ? 0 : 1;
      if (dp[i][j] == dp[i - 1][j - 1] + subCost) {
        if (subCost == 0) refs[i - 1].match = heard[j - 1];
        i--;
        j--;
        continue;
      }
    }
    if (i > 0 && dp[i][j] == dp[i - 1][j] + 1) {
      i--;
    } else {
      j--;
    }
  }

  // ── 4. 聚合到句子（含缺失词插值）────────────────────────
  final matchCount = refs.where((r) => r.match != null).length;
  stdout.writeln('精确对齐词数：$matchCount / $n'
      '（${(matchCount * 100 / n).toStringAsFixed(1)}%）');

  final starts = List<double>.filled(speech.sentences.length, -1);
  final ends = List<double>.filled(speech.sentences.length, -1);
  final warnings = <String>[];

  // 先填有直接对齐的句子
  for (var s = 0; s < speech.sentences.length; s++) {
    final words = refs.where((r) => r.sentence == s).toList();
    final hits = words.map((w) => w.match).whereType<HWord>().toList();
    if (hits.isEmpty) continue;
    starts[s] = hits.first.fromMs / 1000.0;
    ends[s] = hits.last.toMs / 1000.0;
  }

  // ── 5. 兜底：完全没对上的句子按词数估算 ─────────────────
  for (var s = 0; s < speech.sentences.length; s++) {
    if (starts[s] >= 0) continue;
    final wordCount = tokenize(speech.sentences[s].english).length;
    final prevEnd = s == 0 ? 0.0 : ends[s - 1];
    final est = prevEnd + 0.35 * wordCount + 0.25;
    starts[s] = prevEnd + 0.05;
    ends[s] = est;
    warnings.add(
        '⚠ 句 ${s + 1} 无识别对齐，已按 $wordCount 词估算 ${starts[s].toStringAsFixed(2)}–${ends[s].toStringAsFixed(2)}s');
  }

  // 单调性校验：start 必须随句序递增；违反则贴到前句 end 之后
  for (var s = 1; s < speech.sentences.length; s++) {
    if (starts[s] < ends[s - 1] - 0.01) {
      warnings.add('⚠ 句 ${s + 1} 起点早于前句终点，已修正顺序');
      starts[s] = ends[s - 1] + 0.02;
      if (ends[s] < starts[s] + 0.2) ends[s] = starts[s] + 0.3;
    }
  }

  for (final w in warnings) {
    stdout.writeln(w);
  }

  // ── 6. 输出 JSON（App 运行时加载）───────────────────────
  final out = <String, dynamic>{
    'id': speech.id,
    'title': speech.title,
    'speaker': speech.speaker,
    'level': speech.level,
    'durationMs': speech.duration.inMilliseconds,
    'coverUrl': speech.coverUrl,
    'audioPath': speech.audioPath,
    'sentences': [
      for (var s = 0; s < speech.sentences.length; s++)
        {
          'text': speech.sentences[s].english,
          'translation': speech.sentences[s].chinese,
          'startTime': double.parse(starts[s].toStringAsFixed(3)),
          'endTime': double.parse(ends[s].toStringAsFixed(3)),
        }
    ],
  };

  Directory('assets/content').createSync(recursive: true);
  final outPath = 'assets/content/${speech.id}.json';
  File(outPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
  stdout.writeln('\n✅ 已写出 $outPath（${speech.sentences.length} 句，'
      '${warnings.length} 条警告）');
}
