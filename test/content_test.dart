import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ted_companion/data/speech_library.dart';

/// 内容管线产物完整性：index.json 与 14 篇内容 JSON 必须能被模型正确解析，
/// 时间戳单调递增、音频路径有效、封面/主题/讨论问题齐备。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内容索引与编译产物篇数一致', () async {
    final raw = await rootBundle.loadString('assets/content/index.json');
    final index = jsonDecode(raw) as Map<String, dynamic>;
    final entries = index['entries'] as List;
    expect(entries.length, 14, reason: '内容库应收录 1 篇内置 + 13 篇导入素材');
    expect(
      kSpeechLibrary.length,
      entries.length,
      reason: 'speech_library.g.dart 必须与 index.json 同步',
    );
    expect(kContentCatalogVersion, index['version']);
  });

  test('每篇 JSON 可解析且必需字段齐全', () async {
    final raw = await rootBundle.loadString('assets/content/index.json');
    final index = jsonDecode(raw) as Map<String, dynamic>;
    for (final e in (index['entries'] as List).cast<Map<String, dynamic>>()) {
      final file = e['file'] as String;
      final json =
          jsonDecode(await rootBundle.loadString('assets/content/$file'))
              as Map<String, dynamic>;
      final speech = SpeechEntry.fromJson(json);

      expect(speech.id, isNotEmpty, reason: '$file 缺 id');
      expect(speech.title, isNotEmpty, reason: '$file 缺英文标题');
      expect(speech.topicZh, isNotEmpty, reason: '$file 缺中文主题');
      expect(speech.titleZh, isNotEmpty, reason: '$file 缺中文标题');
      expect(
        speech.coverColors.length,
        greaterThanOrEqualTo(2),
        reason: '$file 封面配色不足',
      );
      expect(speech.tags, isNotEmpty, reason: '$file 缺标签');
      expect(speech.topicQuestions, isNotEmpty, reason: '$file 缺主题问题');
      if (json['audioMissing'] == true) {
        expect(
          speech.audioPath == null || speech.audioPath!.isEmpty,
          isTrue,
          reason: '$file 标记为音频待补时 audioPath 应为空',
        );
      } else {
        expect(
          speech.audioPath,
          startsWith('assets/audio/'),
          reason: '$file 音频路径无效',
        );
      }
      expect(speech.duration.inSeconds, greaterThan(0), reason: '$file 时长无效');
    }
  });

  test('有文稿的篇目时间戳有效且单调递增', () async {
    final withScript = kSpeechLibrary.where((s) => s.hasTranscript).toList();
    expect(withScript.length, 14, reason: '14 篇都应带逐句文稿');
    for (final s in withScript) {
      // asr_full 是完整识别稿，只保证原节选句译文被保留；
      // 其余篇目仍要求逐句有中文译文。
      final partialTranslation = s.transcriptScope == 'asr_full';
      var translated = 0;
      expect(s.sentences.length, greaterThan(20), reason: '${s.id} 文稿句数异常');
      var prev = -1.0;
      for (final sentence in s.sentences) {
        expect(sentence.english, isNotEmpty);
        if (sentence.chinese.isNotEmpty) {
          translated++;
        } else if (!partialTranslation) {
          fail('${s.id} 缺少中文翻译');
        }
        expect(
          sentence.end,
          greaterThan(sentence.start),
          reason: '${s.id} 存在非法时间区间',
        );
        expect(
          sentence.start,
          greaterThanOrEqualTo(prev),
          reason: '${s.id} 时间戳非单调递增',
        );
        prev = sentence.end;
      }
      if (partialTranslation) {
        expect(translated, greaterThan(0), reason: '${s.id} 完整识别稿未保留任何译文');
      }
    }
  });

  test('句级二分定位正确', () async {
    final s = kSpeechLibrary.firstWhere((e) => e.hasTranscript);
    expect(s.sentenceIndexAt(-1), 0);
    expect(s.sentenceIndexAt(0), 0);
    final mid = s.sentences[s.sentences.length ~/ 2].start;
    expect(
      s.sentenceIndexAt(mid),
      greaterThanOrEqualTo(s.sentences.length ~/ 2 - 1),
    );
  });

  test('词级时间戳兜底覆盖每句', () async {
    for (final s in kSpeechLibrary.where((e) => e.hasTranscript)) {
      final filled = s.ensureWordTimings();
      for (final sentence in filled.sentences) {
        expect(sentence.words, isNotEmpty, reason: '${s.id} 存在无词级时间戳的句子');
      }
    }
  });

  test('speechById 能查到全部篇目', () async {
    for (final s in kSpeechLibrary) {
      expect(speechById(s.id), isNotNull);
      expect(speechById(s.id)!.title, s.title);
    }
    expect(speechById('not_exist'), isNull);
  });

  test('按中文主题分组可覆盖全部篇目', () async {
    final groups = groupByTopic(kSpeechLibrary);
    final total = groups.fold<int>(0, (sum, g) => sum + g.entries.length);
    expect(total, kSpeechLibrary.length);
    expect(groups.every((g) => g.topic.isNotEmpty), isTrue);
  });

  test('时间轴语速、结尾与文本字段合理', () async {
    final cjk = RegExp(r'[\u4e00-\u9fff]');
    String normalized(String text) =>
        text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '').trim();

    for (final s in kSpeechLibrary.where((e) => e.hasTranscript)) {
      var totalWords = 0;
      for (var i = 0; i < s.sentences.length; i++) {
        final sentence = s.sentences[i];
        final words =
            sentence.english
                .split(RegExp(r'\s+'))
                .where((w) => w.isNotEmpty)
                .length;
        totalWords += words;
        expect(
          cjk.hasMatch(sentence.english),
          isFalse,
          reason: '${s.id} 英文句混入中文：${sentence.english}',
        );
        final duration = sentence.end - sentence.start;
        expect(duration, greaterThan(0.2), reason: '${s.id} 第 $i 句时长过短');
        expect(
          words / duration,
          lessThan(7.0),
          reason: '${s.id} 第 $i 句语速异常：${sentence.english}',
        );
        if (i > 0) {
          expect(
            normalized(sentence.english),
            isNot(normalized(s.sentences[i - 1].english)),
            reason: '${s.id} 第 $i 句与上一句重复',
          );
        }
      }
      final wpm = totalWords / (s.duration.inMilliseconds / 60000.0);
      expect(
        wpm,
        greaterThanOrEqualTo(80),
        reason: '${s.id} 整体语速过低：${wpm.toStringAsFixed(1)} WPM',
      );
      expect(
        wpm,
        lessThanOrEqualTo(220),
        reason: '${s.id} 整体语速过高：${wpm.toStringAsFixed(1)} WPM',
      );
      final tail = (s.duration.inMilliseconds / 1000.0) - s.sentences.last.end;
      expect(
        tail.abs(),
        lessThan(35),
        reason: '${s.id} 末句与音频结尾相差 ${tail.toStringAsFixed(1)} 秒',
      );
    }
  });
}
