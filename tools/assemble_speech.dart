// ─────────────────────────────────────────────────────────────
// 通用组装脚本：把某篇的词级对齐句子 + 翻译 + 复述 clips 写回 content JSON
//
//   dart run tools/assemble_speech.dart <speechId>
//
// 输入：
//   tools/whisper/<speechId>.sentences.json   融合句子（含 words 时间戳 + translation 占位）
//   tools/whisper/<speechId>.translations.json  逐句中文翻译（长度 == 句子数）
//   tools/whisper/<speechId>.clips.json         复述片段（summary + keyPoints）
//   assets/content/<speechId>.json              现有元数据
// 输出：写回 assets/content/<speechId>.json
// ─────────────────────────────────────────────────────────────
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tools/assemble_speech.dart <speechId>');
    exit(2);
  }
  final id = args[0];
  final root = Directory.current.path;

  final sPath = '$root/tools/whisper/$id.sentences.json';
  final tPath = '$root/tools/whisper/$id.translations.json';
  final cPath = '$root/tools/whisper/$id.clips.json';
  final contentPath = '$root/assets/content/$id.json';

  if (!File(sPath).existsSync()) {
    stderr.writeln('缺少 $sPath，请先运行 align_whisper.dart');
    exit(2);
  }
  if (!File(contentPath).existsSync()) {
    stderr.writeln('缺少 $contentPath');
    exit(2);
  }

  final sentences = (jsonDecode(File(sPath).readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  // ── 翻译：优先用 translations.json，否则用 sentences 里已回填的 translation ──
  List<String> translations;
  if (File(tPath).existsSync()) {
    translations = (jsonDecode(File(tPath).readAsStringSync()) as List)
        .cast<String>();
  } else {
    translations = sentences
        .map((s) => (s['translation'] as String? ?? ''))
        .toList();
  }

  List<Map<String, dynamic>> clips = [];
  if (File(cPath).existsSync()) {
    clips = (jsonDecode(File(cPath).readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
  }

  final content = jsonDecode(File(contentPath).readAsStringSync())
      as Map<String, dynamic>;

  if (translations.length != sentences.length) {
    stderr.writeln('翻译数 ${translations.length} != 句子数 ${sentences.length}，中止。');
    exit(2);
  }

  // ── 句子：附加翻译 ──
  final outSentences = <Map<String, dynamic>>[];
  for (var i = 0; i < sentences.length; i++) {
    final s = sentences[i];
    outSentences.add({
      'text': s['text'],
      'translation': translations[i],
      'startTime': s['startTime'],
      'endTime': s['endTime'],
      'words': s['words'],
    });
  }

  // ── clips：由句子索引推导起止时间 ──
  final outClips = <Map<String, dynamic>>[];
  for (final c in clips) {
    final si = (c['startIndex'] as num).toInt();
    final ei = (c['endIndex'] as num).toInt();
    if (si < 0 || ei >= sentences.length || si > ei) {
      stderr.writeln('clip 索引越界：$si..$ei（句子数 ${sentences.length}），跳过');
      continue;
    }
    outClips.add({
      'startTime': sentences[si]['startTime'],
      'endTime': sentences[ei]['endTime'],
      'startIndex': si,
      'endIndex': ei,
      'summary': c['summary'],
      'keyPoints': c['keyPoints'] ?? const [],
    });
  }

  // ── 元数据更新 ──
  content['sentences'] = outSentences;
  content['clips'] = outClips;
  content['hasTranscript'] = true;
  content['transcriptScope'] = 'full';
  content['timingSource'] = 'whisper_word';
  content['source'] = '官方逐字稿 + Whisper 词级对齐';

  File(contentPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(content));

  print('句子 ${outSentences.length} 条（含翻译）');
  print('clips ${outClips.length} 段');
  var zhCount = 0;
  for (final s in outSentences) {
    if ((s['translation'] as String).isNotEmpty) zhCount++;
  }
  print('有翻译的句子 $zhCount/${outSentences.length}');
  print('已写入 $contentPath');
}
