// ─────────────────────────────────────────────────────────────
// Whisper 词级时间戳 + 官方逐字稿 → 词级对齐句子（纯 Dart）
//
//   dart run tools/align_whisper.dart <speechId>
//
// 为什么需要融合：
//   · whisper(tiny) 有词级时间戳 + 标点 + 大小写，但有系统性识别错误
//     （如把 twentysomething 听成 "20s something's"）
//   · 官方逐字稿词准确，但完全无标点、全小写
//   故用「官方稿词 + whisper 时间戳 + whisper 段边界」三者融合：
//     词       → 官方稿（权威，修正 whisper 错误）
//     时间戳   → whisper 词级（合并 subword 后）
//     句子边界 → whisper 分段（有标点，自然切句）
//
// 输入：
//   tools/whisper/<speechId>.json    whisper.cpp -ojf 输出（含 token offsets）
//   tools/transcripts_source.json    官方逐字稿（13 篇，含 [mm:ss] 时间码）
//   assets/content/<speechId>.json   现有内容 JSON（元数据 + 中文翻译）
// 输出：
//   tools/whisper/<speechId>.sentences.json   融合后的句子（text + words + 时间戳）
// ─────────────────────────────────────────────────────────────
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

/// speechId → 官方逐字稿篇号（与 import_transcripts.py 的 SECTION_TO_ID 一致）
const Map<String, int> idToSection = {
  'levitin_stay_calm': 1,
  'ted_true_confidence': 2,
  'meg_jay_why_30': 3,
  'ted_humility_water': 4,
  'brewer_break_habit': 5,
  'ted_self_criticism': 6,
  'ted_believe_yourself': 7,
  'ted_not_personal': 8,
  'esfahani_more_than_happy': 9,
  'ted_why_meaning': 10,
  'ted_meaning_of_life': 11,
  'robbins_five_seconds': 12,
  'ted_mind_control': 13,
};

/// 归一化：小写 + 只留字母与撇号
String norm(String w) {
  final s = w.toLowerCase();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if ((c >= 97 && c <= 122) || s[i] == "'" || s[i] == '’') b.write(s[i]);
  }
  return b.toString();
}

bool isControl(String text) =>
    text.startsWith('[') && text.endsWith(']') && text.length < 24;

/// 首字母大写（仅当首字符是字母时）
String cap(String w) {
  if (w.isEmpty) return w;
  final c = w.codeUnitAt(0);
  if (c >= 97 && c <= 122) return String.fromCharCode(c - 32) + w.substring(1);
  return w;
}

class Word {
  final String text; // whisper 原始词（含大小写）
  final String n; // 归一化
  final int from; // ms
  final int to; // ms
  final int seg; // 所属 whisper 段
  Word(this.text, this.n, this.from, this.to, this.seg);
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tools/align_whisper.dart <speechId>');
    exit(2);
  }
  final id = args[0];
  final secNo = idToSection[id];
  if (secNo == null) {
    stderr.writeln('未在 idToSection 中找到 $id，请在脚本里补充映射。');
    exit(2);
  }

  // ── 1. whisper：合并 subword → 全局词列表 + 段边界 ──
  final wj = jsonDecode(File('tools/whisper/$id.json').readAsStringSync())
      as Map<String, dynamic>;
  final segs = (wj['transcription'] as List).cast<Map<String, dynamic>>();

  final wWords = <Word>[];
  final segStart = <int>[]; // 每段在 wWords 中的起始索引
  final segText = <String>[]; // 每段原始文本（含标点）
  final segEndPunct = <String>[]; // 每段末尾标点

  for (final seg in segs) {
    final rawText = (seg['text'] as String? ?? '').trim();
    final tokens = (seg['tokens'] as List? ?? const []).cast<Map<String, dynamic>>();
    if (rawText.isEmpty && tokens.isEmpty) continue;

    segStart.add(wWords.length);
    segText.add(rawText);
    // 末尾标点（. ? ! ，取最后一个非字母数字字符）
    final endPunct = RegExp(r'[.!?…]+$').firstMatch(rawText)?.group(0) ?? '';
    segEndPunct.add(endPunct);

    final segIdx = segStart.length - 1;
    for (final tok in tokens) {
      final raw = tok['text'] as String;
      final t = raw.trim();
      if (t.isEmpty || isControl(t)) continue;
      final from = (tok['offsets']['from'] as num).round();
      var to = (tok['offsets']['to'] as num).round();
      if (to <= from) to = from + 100;
      final isNew = raw.startsWith(' ') || raw.startsWith('\n');
      if (isNew || wWords.isEmpty || wWords.last.seg != segIdx) {
        wWords.add(Word(t, norm(t), from, to, segIdx));
      } else {
        // subword 后缀：拼到前一个词
        final last = wWords.last;
        final merged = Word('${last.text}$t', '${last.n}${norm(t)}',
            last.from, to > last.to ? to : last.to, segIdx);
        wWords[wWords.length - 1] = merged;
      }
    }
  }
  segStart.add(wWords.length); // 哨兵

  // ── 2. 官方稿对应篇目 → 全局词序列 ──
  final src = jsonDecode(File('tools/transcripts_source.json').readAsStringSync())
      as Map<String, dynamic>;
  final paras = (src['paragraphs'] as List).cast<String>();
  final offWords = <String>[];
  var cur = -1;
  for (final p in paras) {
    final m = RegExp(r'^第\s*(\d+)\s*篇[\s　]+(.+)$').firstMatch(p);
    if (m != null && p.length < 45 && !p.contains('的视频文件')) {
      cur = int.parse(m.group(1)!) == secNo ? secNo : -1;
      continue;
    }
    if (cur != secNo) continue;
    final t = RegExp(r'^\[(\d{1,2}):(\d{2})\]\s*(.*)$').firstMatch(p);
    if (t != null) {
      offWords.addAll(t.group(3)!.trim().split(RegExp(r'\s+'))
          .map(norm).where((w) => w.isNotEmpty));
    }
  }

  // ── 3. DP 对齐（编辑距离）─
  final n = wWords.length, m = offWords.length;
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = 0; i <= n; i++) {
    dp[i][0] = i;
  }
  for (var j = 0; j <= m; j++) {
    dp[0][j] = j;
  }
  for (var i = 1; i <= n; i++) {
    final wi = wWords[i - 1].n;
    for (var j = 1; j <= m; j++) {
      final sub = wi == offWords[j - 1] ? 0 : 1;
      final a = dp[i - 1][j - 1] + sub;
      final b = dp[i - 1][j] + 1;
      final c = dp[i][j - 1] + 1;
      dp[i][j] = a < b ? (a < c ? a : c) : (b < c ? b : c);
    }
  }
  // 回溯：alignOfWhisper[i] = 官方稿词下标（-1 表示该 whisper 词为插入/多余）
  final alignOfWhisper = List<int>.filled(n, -1);
  var i = n, j = m;
  while (i > 0 && j > 0) {
    final sub = wWords[i - 1].n == offWords[j - 1] ? 0 : 1;
    if (dp[i][j] == dp[i - 1][j - 1] + sub) {
      alignOfWhisper[i - 1] = j - 1;
      i--;
      j--;
    } else if (dp[i][j] == dp[i - 1][j] + 1) {
      i--; // whisper 词是插入（官方稿无对应），保持 -1
    } else {
      j--; // 官方稿词被 whisper 漏掉
    }
  }

  // ── 4. 融合：构建句子 ──
  final sentences = <Map<String, dynamic>>[];
  var totalWords = 0;
  var corrected = 0;

  for (var s = 0; s < segText.length; s++) {
    final a = segStart[s], b = segStart[s + 1];
    if (b <= a) continue;
    final fusedText = <String>[];
    final fusedWords = <Map<String, dynamic>>[];
    for (var k = a; k < b; k++) {
      final w = wWords[k];
      final oi = alignOfWhisper[k];
      String text;
      if (oi >= 0 && w.n != offWords[oi]) {
        // whisper 识别错误 → 用官方稿权威词
        text = offWords[oi];
        corrected++;
      } else {
        text = w.text;
      }
      fusedText.add(text);
      fusedWords.add({
        'w': text,
        's': double.parse((w.from / 1000.0).toStringAsFixed(3)),
        'e': double.parse((w.to / 1000.0).toStringAsFixed(3)),
      });
      totalWords++;
    }

    // 句首大写 + 末尾标点
    var line = fusedText.join(' ');
    if (line.isNotEmpty) {
      final first = fusedText.first;
      final capped = cap(first);
      if (capped != first) {
        line = capped + line.substring(first.length);
      }
    }
    final ep = segEndPunct[s];
    if (ep.isNotEmpty && !line.endsWith(ep)) line = '$line$ep';

    final startSec = (wWords[a].from) / 1000.0;
    final endSec = (wWords[b - 1].to) / 1000.0;
    if (endSec - startSec < 0.05) continue;

    sentences.add({
      'text': line,
      'startTime': double.parse(startSec.toStringAsFixed(3)),
      'endTime': double.parse(endSec.toStringAsFixed(3)),
      'words': fusedWords,
    });
  }

  // ── 5. 回填中文翻译（整句归一化匹配）─
  final existing = File('assets/content/$id.json').existsSync()
      ? jsonDecode(File('assets/content/$id.json').readAsStringSync()) as Map<String, dynamic>
      : <String, dynamic>{};
  final oldSents =
      (existing['sentences'] as List? ?? const []).cast<Map<String, dynamic>>();
  final oldByNorm = <String, String>{};
  for (final s in oldSents) {
    final key = norm(s['text'] as String? ?? '');
    if (key.isNotEmpty) oldByNorm[key] = (s['translation'] as String? ?? '');
  }
  var withTrans = 0;
  for (final s in sentences) {
    final key = norm(s['text'] as String? ?? '');
    final tr = oldByNorm[key];
    s['translation'] = (tr != null && tr.isNotEmpty) ? tr : '';
    if (tr != null && tr.isNotEmpty) withTrans++;
  }

  File('tools/whisper/$id.sentences.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(sentences));

  // ── 统计 ──
  final dist = dp[n][m];
  final consistency = 100 * (1 - dist / (n > m ? n : m));
  print('speech=$id (官方稿第$secNo篇)');
  print('whisper 词=$n  官方稿词=$m  编辑距离=$dist  一致性=${consistency.toStringAsFixed(1)}%');
  print('融合句子=${sentences.length}  总词=$totalWords  修正错误词=$corrected');
  print('已回填译文=$withTrans/${sentences.length}');
  print('首句: [${sentences.first['startTime']}s] ${sentences.first['text']}');
  print('末句: [${sentences.last['startTime']}s] ${sentences.last['text']}');
  print('末句 end=${sentences.last['endTime']}s');

  var back = 0, gap = 0;
  double prevEnd = 0;
  for (final s in sentences) {
    final st = (s['startTime'] as num).toDouble();
    final en = (s['endTime'] as num).toDouble();
    if (st < prevEnd - 0.05) back++;
    if (st - prevEnd > 2.0 && prevEnd > 0) gap++;
    prevEnd = en;
  }
  print('时间戳异常：start 回退 $back 处 / 句间 >2s 静音 $gap 处');
  print('输出 → tools/whisper/$id.sentences.json');
}
