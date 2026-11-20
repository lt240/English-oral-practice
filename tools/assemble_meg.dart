// ─────────────────────────────────────────────────────────────
// 一次性组装脚本：meg_jay_why_30 的词级对齐句子 + 翻译 + 复述 clips
// 写入 assets/content/meg_jay_why_30.json
//
// 输入：
//   tools/whisper/meg_jay_why_30.sentences.json   融合句子（含 words 时间戳）
//   tools/whisper/meg_translations.json           150 句中文翻译
//   tools/whisper/meg_clips.json                  复述片段（summary + keyPoints）
//   assets/content/meg_jay_why_30.json            现有元数据
// 运行：
//   dart run tools/assemble_meg.dart
// ─────────────────────────────────────────────────────────────
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

void main() {
  final root = Directory.current.path;
  final sentences = (jsonDecode(
          File('$root/tools/whisper/meg_jay_why_30.sentences.json').readAsStringSync())
      as List)
      .cast<Map<String, dynamic>>();
  final translations = (jsonDecode(
          File('$root/tools/whisper/meg_translations.json').readAsStringSync())
      as List)
      .cast<String>();
  final clips = (jsonDecode(
          File('$root/tools/whisper/meg_clips.json').readAsStringSync())
      as List)
      .cast<Map<String, dynamic>>();
  final contentPath = '$root/assets/content/meg_jay_why_30.json';
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
    final startTime = sentences[si]['startTime'];
    final endTime = sentences[ei]['endTime'];
    outClips.add({
      'startTime': startTime,
      'endTime': endTime,
      'startIndex': si,
      'endIndex': ei,
      'summary': c['summary'],
      'keyPoints': c['keyPoints'],
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
