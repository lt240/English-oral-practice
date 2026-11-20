// ─────────────────────────────────────────────────────────────
// 翻译复用：把旧 content JSON 的逐句翻译，按「连续中文流重切分」
// 迁移到新融合句子上。
//
//   dart run tools/reuse_translations.dart <speechId>
//
// 关键洞察：旧翻译是「完整中文按 ~14 词边界切成的碎片」，按序拼接后
// 是连贯中文。新句（whisper 段）是同一演讲的另一套切分。做法：
//   1. 全文词序列 DP 对齐 →「新词 → 旧词」单调映射；
//   2. 每个新句覆盖一段连续旧词 [lo,hi]，按词位置比例换算成
//      连续中文流里的字符位置（估算边界）；
//   3. 把这些估算边界「吸附」到最近的中文标点（，。；：！？——等），
//      得到干净、语义连贯的切分点（单调性约束）；
//   4. 按吸附后的边界切中文流。
//
// 旧句未翻译的碎片留空串，由后续人工补译。
//
// 输出：tools/whisper/<speechId>.translations.json（String[]，与句子数一致）
// ─────────────────────────────────────────────────────────────
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

String norm(String w) {
  final s = w.toLowerCase();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if ((c >= 97 && c <= 122) || s[i] == "'" || s[i] == '’') b.write(s[i]);
  }
  return b.toString();
}

/// 标点吸附：在 fullZh 中，从估算位置 est 出发，在 [lowBound, highBound)
/// 范围内找最近的标点（含句号/逗号/冒号/分号/破折号/引号等），返回该标点后一位。
int snapBoundary(String s, int est, int lowBound, int highBound) {
  const puncts = '，。！？；：、—…“”‘’（）《》';
  if (est <= lowBound) return lowBound;
  if (est >= highBound) return highBound;
  // 先向后找最近的标点
  for (var d = 0; d < 200; d++) {
    final fwd = est + d;
    if (fwd >= lowBound && fwd < highBound && puncts.contains(s[fwd])) {
      return fwd + 1;
    }
    final bwd = est - d;
    if (d > 0 && bwd >= lowBound && bwd < highBound && puncts.contains(s[bwd])) {
      return bwd + 1;
    }
  }
  return est;
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tools/reuse_translations.dart <speechId>');
    exit(2);
  }
  final id = args[0];
  final root = Directory.current.path;

  final contentPath = '$root/assets/content/$id.json';
  final sPath = '$root/tools/whisper/$id.sentences.json';
  final outPath = '$root/tools/whisper/$id.translations.json';

  final content = jsonDecode(File(contentPath).readAsStringSync())
      as Map<String, dynamic>;
  final oldSents =
      (content['sentences'] as List? ?? const []).cast<Map<String, dynamic>>();
  final newSents =
      (jsonDecode(File(sPath).readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();

  // ── 旧：词序列 + 每词所属旧句 + 每旧句词数 ──
  final oldWords = <String>[];
  final oldWordSent = <int>[];
  for (var i = 0; i < oldSents.length; i++) {
    final ws = (oldSents[i]['words'] as List? ?? const []).cast<Map<String, dynamic>>();
    for (final w in ws) {
      final t = (w['w'] as String? ?? w['word'] as String? ?? '').trim();
      if (t.isEmpty) continue;
      oldWords.add(norm(t));
      oldWordSent.add(i);
    }
  }
  final oldSentWordStart = List<int>.filled(oldSents.length, 0);
  final oldSentWordCount = List<int>.filled(oldSents.length, 0);
  for (var k = 0; k < oldWords.length; k++) {
    oldSentWordCount[oldWordSent[k]]++;
  }
  for (var i = 1; i < oldSents.length; i++) {
    oldSentWordStart[i] = oldSentWordStart[i - 1] + oldSentWordCount[i - 1];
  }

  // ── 新：词序列 + 每词所属新句 ──
  final newWords = <String>[];
  final newWordSent = <int>[];
  for (var i = 0; i < newSents.length; i++) {
    final ws = (newSents[i]['words'] as List? ?? const []).cast<Map<String, dynamic>>();
    for (final w in ws) {
      final t = (w['w'] as String? ?? w['word'] as String? ?? '').trim();
      if (t.isEmpty) continue;
      newWords.add(norm(t));
      newWordSent.add(i);
    }
  }

  // ── DP 对齐 ──
  final n = newWords.length, m = oldWords.length;
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = 0; i <= n; i++) {
    dp[i][0] = i;
  }
  for (var j = 0; j <= m; j++) {
    dp[0][j] = j;
  }
  for (var i = 1; i <= n; i++) {
    final wi = newWords[i - 1];
    for (var j = 1; j <= m; j++) {
      final sub = wi == oldWords[j - 1] ? 0 : 1;
      final a = dp[i - 1][j - 1] + sub;
      final b = dp[i - 1][j] + 1;
      final c = dp[i][j - 1] + 1;
      dp[i][j] = a < b ? (a < c ? a : c) : (b < c ? b : c);
    }
  }
  final newToOld = List<int>.filled(n, -1);
  var i = n, j = m;
  while (i > 0 && j > 0) {
    final sub = newWords[i - 1] == oldWords[j - 1] ? 0 : 1;
    if (dp[i][j] == dp[i - 1][j - 1] + sub) {
      newToOld[i - 1] = j - 1;
      i--;
      j--;
    } else if (dp[i][j] == dp[i - 1][j] + 1) {
      i--;
    } else {
      j--;
    }
  }

  // ── 每个新句覆盖的旧词范围 [lo, hi] ──
  final newSentLo = List<int>.filled(newSents.length, -1);
  final newSentHi = List<int>.filled(newSents.length, -1);
  for (var k = 0; k < n; k++) {
    final o = newToOld[k];
    if (o < 0) continue;
    final s = newWordSent[k];
    if (newSentLo[s] < 0) newSentLo[s] = o;
    newSentHi[s] = o;
  }

  // ── 连续中文流 + 每个旧句的字符区间 ──
  final zh = <String>[];
  final charStart = List<int>.filled(oldSents.length, 0);
  var acc = 0;
  for (var i = 0; i < oldSents.length; i++) {
    charStart[i] = acc;
    final t = oldSents[i]['translation'] as String? ?? '';
    zh.add(t);
    acc += t.length;
  }
  final fullZh = zh.join('');

  double charPosForOldWord(int oldWordIdx, int boundaryDir) {
    final o = oldWordSent[oldWordIdx];
    final start = oldSentWordStart[o];
    final cnt = oldSentWordCount[o];
    final zhFrag = zh[o];
    if (zhFrag.isEmpty || cnt <= 0) return charStart[o].toDouble();
    final offsetInOld = (oldWordIdx - start) + boundaryDir;
    final frac = (offsetInOld / cnt).clamp(0.0, 1.0);
    return charStart[o] + frac * zhFrag.length;
  }

  // ── 估算边界 + 标点吸附（单调）──
  final est = <int>[]; // 每句的估算结束位置
  for (var s = 0; s < newSents.length; s++) {
    final lo = newSentLo[s], hi = newSentHi[s];
    if (lo < 0 || hi < 0) {
      est.add(-1);
    } else {
      est.add(charPosForOldWord(hi, 1).round());
    }
  }

  // 吸附后的切分边界（第 s 句的结束字符位置）
  final snapped = List<int>.filled(newSents.length, 0);
  var prev = 0;
  for (var s = 0; s < newSents.length; s++) {
    var target = est[s];
    if (target < 0) target = prev; // 无覆盖，保持
    if (s == newSents.length - 1) {
      snapped[s] = fullZh.length;
      break;
    }
    final snappedPos = snapBoundary(fullZh, target, prev, fullZh.length);
    snapped[s] = snappedPos;
    prev = snappedPos;
  }

  // ── 切出每句中文 ──
  final result = List<String>.filled(newSents.length, '');
  var reused = 0;
  var start = 0;
  for (var s = 0; s < newSents.length; s++) {
    final end = snapped[s];
    if (end <= start) {
      result[s] = '';
    } else {
      final frag = fullZh.substring(start, end).trim();
      if (frag.isNotEmpty) {
        result[s] = frag;
        reused++;
      }
      start = end;
    }
  }

  File(outPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));

  final dist = dp[n][m];
  final consistency = 100 * (1 - dist / (n > m ? n : m));
  print('speech=$id');
  print('旧句=${oldSents.length}  新句=${newSents.length}');
  print('旧词=$m  新词=$n  编辑距离=$dist  词一致性=${consistency.toStringAsFixed(1)}%');
  print('复用翻译 $reused/${newSents.length} 句');
  print('输出 → $outPath');
}
