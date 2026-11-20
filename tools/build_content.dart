// ─────────────────────────────────────────────────────────────
// 内容库编译脚本（纯 Dart，无需 Flutter 运行时）
//
//   dart run tools/build_content.dart
//
// 读取 assets/content/index.json 列出的 <id>.json，生成
// lib/data/speech_library.g.dart（编译期常量）。
// 新增内容：把音频放到「TED音频」素材目录 → 复制到 assets/audio/ →
// 新增一份内容 JSON → 在 index.json 里登记 → 重跑本脚本即可。
// ─────────────────────────────────────────────────────────────
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const contentDir = 'assets/content';
const audioDir = 'assets/audio';
const outputPath = 'lib/data/speech_library.g.dart';

/// 把任意字符串转成合法的 Dart 字符串字面量。
/// JSON 编码已经处理了引号/换行/反斜杠，只需额外转义 Dart 的 $ 插值符。
String d(String s) => jsonEncode(s).replaceAll(r'$', r'\$');

String dList(List<dynamic> items) =>
    '[${items.map((e) => d(e.toString())).join(', ')}]';

String fmtNum(Object? v, [double fallback = 0]) {
  if (v is num) return v.toString();
  return fallback.toString();
}

/// 推断一级分类：优先 JSON 显式 category 字段，否则默认 TED 演讲。
///
/// 现有内容全部是 TED/TEDx/TEDMED 演讲；「名人演讲」暂无真实内容，仅当 JSON
/// 显式标记 `category: "celebrity"` 时进入名人演讲，避免把 ASR 稿（speaker 记为
/// 「TED」）误判成名人演讲。
String categoryCode(Map<String, dynamic> j) {
  final c = j['category'] as String?;
  if (c == 'celebrity') return 'SpeechCategory.celebrity';
  return 'SpeechCategory.ted';
}

void main(List<String> args) {
  final root = Directory.current.path;
  final indexFile = File('$root/$contentDir/index.json');
  if (!indexFile.existsSync()) {
    stderr.writeln('缺少 $contentDir/index.json');
    exit(2);
  }

  final index =
      jsonDecode(indexFile.readAsStringSync()) as Map<String, dynamic>;
  final version = (index['version'] as num? ?? 1).toInt();
  final entries =
      (index['entries'] as List? ?? const []).cast<Map<String, dynamic>>();

  final buf = StringBuffer();
  buf.writeln('// GENERATED FILE — DO NOT EDIT.');
  buf.writeln('// 由 tools/build_content.dart 从 assets/content/ 生成。');
  buf.writeln('// 来源：index.json v$version');
  buf.writeln("import 'speech_library.dart';");
  buf.writeln();
  buf.writeln('const int kContentCatalogVersion = $version;');
  buf.writeln();
  buf.writeln('const List<SpeechEntry> kSpeechLibrary = [');

  var speechCount = 0;
  var sentenceCount = 0;
  var missingAudio = <String>[];
  var noTranscript = <String>[];

  for (final meta in entries) {
    if (meta['enabled'] == false) continue;
    final file = meta['file'] as String? ?? '${meta['id']}.json';
    final f = File('$root/$contentDir/$file');
    if (!f.existsSync()) {
      stderr.writeln('警告：内容文件不存在 $contentDir/$file，已跳过');
      continue;
    }
    final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final sentences =
        (j['sentences'] as List? ?? const []).cast<Map<String, dynamic>>();
    final clips =
        (j['clips'] as List? ?? const []).cast<Map<String, dynamic>>();
    final audio = j['audioPath'] as String?;

    if (audio != null &&
        audio.isNotEmpty &&
        !File('$root/${audio.replaceFirst('assets/', '')}').existsSync() &&
        !File('$root/$audio').existsSync()) {
      missingAudio.add('${j['id']}: $audio');
    }
    if (sentences.isEmpty) noTranscript.add(j['id'] as String? ?? file);

    var durationMs = (j['durationMs'] as num? ?? 0).toInt();
    if (durationMs <= 0 && sentences.isNotEmpty) {
      final lastEnd = sentences.last['endTime'] as num? ?? 0;
      durationMs = (lastEnd * 1000).round();
    }

    // 片头偏移（秒）：JSON 显式提供 audioOffsetSec 时优先；否则用首句 startTime
    // 兜底（与 SpeechEntry.fromJson 的规则一致）。用于让进度条/文字高亮
    // 扣除片头音乐/静音，落在「正文时间轴」上。
    final firstStart =
        sentences.isNotEmpty
            ? ((sentences.first['startTime'] as num?)?.toDouble() ?? 0.0)
            : 0.0;
    final audioOffsetSec =
        (j['audioOffsetSec'] as num?)?.toDouble() ?? firstStart;

    buf.writeln('  SpeechEntry(');
    buf.writeln('    id: ${d(j['id'] as String? ?? file)},');
    buf.writeln('    title: ${d(j['title'] as String? ?? '')},');
    buf.writeln('    titleZh: ${d(j['titleZh'] as String? ?? '')},');
    buf.writeln('    topicZh: ${d(j['topicZh'] as String? ?? '')},');
    buf.writeln('    speaker: ${d(j['speaker'] as String? ?? '')},');
    buf.writeln('    level: ${d(j['level'] as String? ?? '入门')},');
    buf.writeln('    difficulty: ${(j['difficulty'] as num? ?? 1).toInt()},');
    buf.writeln('    duration: Duration(milliseconds: $durationMs),');
    buf.writeln('    coverUrl: ${d(j['coverUrl'] as String? ?? '')},');
    buf.writeln(
      '    coverColors: ${dList(j['coverColors'] as List? ?? const ['#5E7CF7', '#8E6CF7'])},',
    );
    buf.writeln('    tags: ${dList(j['tags'] as List? ?? const [])},');
    buf.writeln(
      '    topicQuestions: ${dList(j['topicQuestions'] as List? ?? const [])},',
    );
    buf.writeln('    hasTranscript: ${sentences.isNotEmpty},');
    buf.writeln(
      '    transcriptScope: ${d(j['transcriptScope'] as String? ?? 'full')},',
    );
    buf.writeln('    source: ${d(j['source'] as String? ?? 'builtin')},');
    buf.writeln('    category: ${categoryCode(j)},');
    buf.writeln('    audioOffsetSec: $audioOffsetSec,');
    buf.writeln(
      audio == null ? '    audioPath: null,' : '    audioPath: ${d(audio)},',
    );

    buf.writeln('    sentences: [');
    for (final s in sentences) {
      final words =
          (s['words'] as List? ?? const []).cast<Map<String, dynamic>>();
      buf.writeln('      TranscriptSentence(');
      buf.writeln('        english: ${d(s['text'] as String? ?? '')},');
      buf.writeln('        chinese: ${d(s['translation'] as String? ?? '')},');
      buf.writeln('        start: ${fmtNum(s['startTime'])},');
      buf.writeln('        end: ${fmtNum(s['endTime'])},');
      if (words.isNotEmpty) {
        buf.writeln('        words: [');
        for (final w in words) {
          buf.writeln(
            '          WordTime(word: ${d(w['w'] as String? ?? w['word'] as String? ?? '')}, '
            'start: ${fmtNum(w['s'] ?? w['start'])}, end: ${fmtNum(w['e'] ?? w['end'])}),',
          );
        }
        buf.writeln('        ],');
      }
      buf.writeln('      ),');
      sentenceCount++;
    }
    buf.writeln('    ],');

    if (clips.isNotEmpty) {
      buf.writeln('    clips: [');
      for (final c in clips) {
        final kps =
            (c['keyPoints'] as List? ?? const []).cast<Map<String, dynamic>>();
        buf.writeln('      RetellClip(');
        buf.writeln('        start: ${fmtNum(c['startTime'])},');
        buf.writeln('        end: ${fmtNum(c['endTime'])},');
        buf.writeln(
          '        startIndex: ${(c['startIndex'] as num? ?? 0).toInt()},',
        );
        buf.writeln(
          '        endIndex: ${(c['endIndex'] as num? ?? 0).toInt()},',
        );
        if (c['summary'] != null) {
          buf.writeln('        summary: ${d(c['summary'] as String)},');
        }
        if (kps.isNotEmpty) {
          buf.writeln('        keyPoints: [');
          for (final kp in kps) {
            buf.writeln(
              '          KeyPoint(phrase: ${d(kp['phrase'] as String? ?? '')}, '
              'synonyms: ${dList(kp['synonyms'] as List? ?? const [])}),',
            );
          }
          buf.writeln('        ],');
        }
        buf.writeln('      ),');
      }
      buf.writeln('    ],');
    }

    buf.writeln('  ),');
    speechCount++;
  }

  buf.writeln('];');
  buf.writeln();
  buf.writeln('/// 按 id 查演讲（供统计页 / 深链 / 断点续读使用）');
  buf.writeln('SpeechEntry? speechById(String id) {');
  buf.writeln('  for (final s in kSpeechLibrary) {');
  buf.writeln('    if (s.id == id) return s;');
  buf.writeln('  }');
  buf.writeln('  return null;');
  buf.writeln('}');

  File('$root/$outputPath').writeAsStringSync(buf.toString());

  print('内容库已生成：$outputPath');
  print('  演讲 $speechCount 篇 / 句子 $sentenceCount 条 / index v$version');
  if (noTranscript.isNotEmpty) {
    print('  仅音频（文稿待补）：${noTranscript.join(', ')}');
  }
  if (missingAudio.isNotEmpty) {
    print('  警告：以下音频文件未找到，App 内将无法播放：');
    for (final m in missingAudio) {
      print('    - $m');
    }
  }
}
