// ─────────────────────────────────────────────────────────────
// TED 演讲内容库 · 数据模型
//
// 内容源：assets/content/index.json + assets/content/<id>.json
// 由 tools/build_content.dart 生成 lib/data/speech_library.g.dart
// （编译期常量，首屏零等待；新增内容只需往内容源放文件并重跑脚本）
// ─────────────────────────────────────────────────────────────

import 'package:flutter/foundation.dart';

export 'speech_library.g.dart'
    show kSpeechLibrary, kContentCatalogVersion, speechById;

/// 词级时间戳（P2-1 / P2-3：逐词高亮、点词跳播）
class WordTime {
  final String word;
  final double start;
  final double end;

  const WordTime({required this.word, required this.start, required this.end});

  factory WordTime.fromJson(Map<String, dynamic> json) => WordTime(
    word: json['w'] as String? ?? json['word'] as String? ?? '',
    start:
        (json['s'] as num?)?.toDouble() ??
        (json['start'] as num?)?.toDouble() ??
        0,
    end:
        (json['e'] as num?)?.toDouble() ??
        (json['end'] as num?)?.toDouble() ??
        0,
  );
}

/// 一个字幕句
class TranscriptSentence {
  final String english;
  final String chinese;
  final double start; // 秒
  final double end;
  final List<WordTime> words;

  const TranscriptSentence({
    required this.english,
    required this.chinese,
    required this.start,
    required this.end,
    this.words = const [],
  });

  factory TranscriptSentence.fromJson(Map<String, dynamic> json) {
    return TranscriptSentence(
      english: json['text'] as String,
      chinese: json['translation'] as String? ?? '',
      start: (json['startTime'] as num? ?? 0).toDouble(),
      end: (json['endTime'] as num? ?? 0).toDouble(),
      words:
          (json['words'] as List?)
              ?.map((e) => WordTime.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  TranscriptSentence copyWith({
    String? english,
    String? chinese,
    double? start,
    double? end,
    List<WordTime>? words,
  }) => TranscriptSentence(
    english: english ?? this.english,
    chinese: chinese ?? this.chinese,
    start: start ?? this.start,
    end: end ?? this.end,
    words: words ?? this.words,
  );
}

/// 复述关键点：原文短语 + 可接受的同义表达（命中其一即算覆盖）
class KeyPoint {
  final String phrase;
  final List<String> synonyms;

  const KeyPoint({required this.phrase, this.synonyms = const []});

  factory KeyPoint.fromJson(Map<String, dynamic> json) {
    return KeyPoint(
      phrase: json['phrase'] as String,
      synonyms:
          (json['synonyms'] as List?)?.map((e) => e as String).toList() ??
          const [],
    );
  }
}

/// 复述片段（30~60 秒，覆盖若干句子）
class RetellClip {
  final double start;
  final double end;
  final int startIndex;
  final int endIndex;
  final String? summary;
  final List<KeyPoint> keyPoints;

  const RetellClip({
    required this.start,
    required this.end,
    required this.startIndex,
    required this.endIndex,
    this.summary,
    this.keyPoints = const [],
  });

  factory RetellClip.fromJson(Map<String, dynamic> json) {
    return RetellClip(
      start: (json['startTime'] as num).toDouble(),
      end: (json['endTime'] as num).toDouble(),
      startIndex: json['startIndex'] as int? ?? 0,
      endIndex: json['endIndex'] as int? ?? 0,
      summary: json['summary'] as String?,
      keyPoints:
          (json['keyPoints'] as List?)
              ?.map((e) => KeyPoint.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  double get duration => end - start;

  String get durationLabel {
    final s = duration.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  String titleOf(List<TranscriptSentence> sentences) {
    if (sentences.isEmpty || startIndex >= sentences.length) return '';
    final words = sentences[startIndex].english
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(6)
        .join(' ');
    return words;
  }

  String referenceOf(List<TranscriptSentence> sentences) {
    return [
      for (var i = startIndex; i <= endIndex && i < sentences.length; i++)
        sentences[i].english,
    ].join(' ');
  }

  RetellClip mappedTo(List<TranscriptSentence> sentences) {
    if (sentences.isEmpty) return this;
    var si = sentences.indexWhere((e) => e.end > start);
    if (si < 0) si = 0;
    var ei = sentences.lastIndexWhere((e) => e.start < end);
    if (ei < 0) ei = sentences.length - 1;
    return RetellClip(
      start: start,
      end: end,
      startIndex: si,
      endIndex: ei,
      summary: summary,
      keyPoints: keyPoints,
    );
  }

  /// 按时间戳把句子切成 30~60 秒片段（JSON 未提供 clips 时的兜底）
  static List<RetellClip> deriveClips(List<TranscriptSentence> sentences) {
    if (sentences.isEmpty) return const [];
    final clips = <RetellClip>[];
    var startIdx = 0;
    for (var i = 0; i < sentences.length; i++) {
      final dur = sentences[i].end - sentences[startIdx].start;
      final nextEnd = i + 1 < sentences.length ? sentences[i + 1].end : null;
      final nextDur =
          nextEnd == null ? null : nextEnd - sentences[startIdx].start;
      if (dur >= 30 && (nextDur == null || nextDur > 60)) {
        clips.add(
          RetellClip(
            start: sentences[startIdx].start,
            end: sentences[i].end,
            startIndex: startIdx,
            endIndex: i,
          ),
        );
        startIdx = i + 1;
      }
    }
    if (startIdx < sentences.length) {
      clips.add(
        RetellClip(
          start: sentences[startIdx].start,
          end: sentences[sentences.length - 1].end,
          startIndex: startIdx,
          endIndex: sentences.length - 1,
        ),
      );
    }
    return clips;
  }
}

/// 内容一级分类：TED 官方演讲 vs 名人演讲（转载/语音识别稿）
enum SpeechCategory {
  ted('TED演讲'),
  celebrity('名人演讲');

  const SpeechCategory(this.label);

  final String label;

  /// 解析分类：优先用 JSON 显式 category 字段，否则按 speaker 启发式判断。
  ///
  /// 规则：现有 14 篇全部是 TED/TEDx/TEDMED 演讲（speaker 为实名，或 ASR 稿
  /// 未标注真实演讲者而记为「TED」）。「名人演讲」分类暂无真实内容，默认归入
  /// TED 演讲，仅当 JSON 显式标记 `category: "celebrity"` 时才进入名人演讲。
  static SpeechCategory fromCode(String? code, {String speaker = ''}) {
    switch (code) {
      case 'celebrity':
        return SpeechCategory.celebrity;
      case 'ted':
      default:
        return SpeechCategory.ted;
    }
  }
}

/// 一篇演讲
class SpeechEntry {
  final String id;
  final String title; // 英文标题（封面主视觉）
  final String speaker;
  final String level;
  final Duration duration;

  /// 片头偏移（秒）：音频文件开头到「演讲正文起点」的时长。
  ///
  /// mp4 音频开头可能有片头音乐/静音，句子的 startTime/endTime 是相对
  /// 音频文件起点的绝对时间（含片头）。此偏移用于把「音频绝对时间」换算到
  /// 「正文时间轴」，让进度条扣除片头、进度与字幕对齐。
  /// 由内容数据组在 JSON 里提供 `audioOffsetSec`；缺省时用首句 startTime 兜底。
  final double audioOffsetSec;
  final String coverUrl;
  final String? audioPath;
  final List<TranscriptSentence> sentences;
  final List<RetellClip> clips;

  // ── 内容库升级字段（中文主题 / 英文文字封面 / 主题问题）──
  final String topicZh;
  final String titleZh;
  final List<String> tags;
  final int difficulty; // 1~5
  final List<String> coverColors; // 封面渐变（#RRGGBB）
  final List<String> topicQuestions;
  final bool hasTranscript; // false = 音频已就绪、文稿待补
  final String transcriptScope; // full / excerpt / asr / asr_full
  final String source; // builtin / imported
  final SpeechCategory category; // TED演讲 / 名人演讲

  /// 是否至少有一个片段配置了复述要点（否则复述评分恒为 0）。
  bool get hasRetellKeyPoints => clips.any((clip) => clip.keyPoints.isNotEmpty);

  /// 是否每一句都有中文译文。
  bool get hasFullChinese =>
      sentences.isNotEmpty && sentences.every((s) => s.chinese.isNotEmpty);

  const SpeechEntry({
    required this.id,
    required this.title,
    required this.speaker,
    required this.level,
    required this.duration,
    this.audioOffsetSec = 0,
    required this.coverUrl,
    this.audioPath,
    required this.sentences,
    this.clips = const [],
    this.topicZh = '',
    this.titleZh = '',
    this.tags = const [],
    this.difficulty = 1,
    this.coverColors = const ['#5E7CF7', '#8E6CF7'],
    this.topicQuestions = const [],
    this.hasTranscript = true,
    this.transcriptScope = 'full',
    this.source = 'builtin',
    this.category = SpeechCategory.ted,
  });

  factory SpeechEntry.fromJson(Map<String, dynamic> json) {
    final sentences =
        (json['sentences'] as List? ?? const [])
            .map((e) => TranscriptSentence.fromJson(e as Map<String, dynamic>))
            .toList();
    final rawClips =
        (json['clips'] as List?)
            ?.map((e) => RetellClip.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <RetellClip>[];
    final clips =
        rawClips.isEmpty
            ? (sentences.isEmpty
                ? const <RetellClip>[]
                : RetellClip.deriveClips(sentences))
            : [for (final c in rawClips) c.mappedTo(sentences)];

    return SpeechEntry(
      id: json['id'] as String,
      title: json['title'] as String,
      speaker: json['speaker'] as String? ?? '',
      level: json['level'] as String? ?? '入门',
      duration: Duration(
        milliseconds: (json['durationMs'] as num? ?? 0).toInt(),
      ),
      audioOffsetSec:
          (json['audioOffsetSec'] as num?)?.toDouble() ??
          (sentences.isNotEmpty ? sentences.first.start : 0),
      coverUrl: json['coverUrl'] as String? ?? '',
      audioPath: json['audioPath'] as String?,
      sentences: sentences,
      clips: clips,
      topicZh: json['topicZh'] as String? ?? '',
      titleZh: json['titleZh'] as String? ?? '',
      tags:
          (json['tags'] as List?)?.map((e) => e as String).toList() ?? const [],
      difficulty: (json['difficulty'] as num? ?? 1).toInt(),
      coverColors:
          (json['coverColors'] as List?)?.map((e) => e as String).toList() ??
          const ['#5E7CF7', '#8E6CF7'],
      topicQuestions:
          (json['topicQuestions'] as List?)?.map((e) => e as String).toList() ??
          const [],
      hasTranscript: json['hasTranscript'] as bool? ?? sentences.isNotEmpty,
      transcriptScope: json['transcriptScope'] as String? ?? 'full',
      source: json['source'] as String? ?? 'builtin',
      category: SpeechCategory.fromCode(
        json['category'] as String?,
        speaker: json['speaker'] as String? ?? '',
      ),
    );
  }

  /// 兜底：缺时间戳的句子按「前句结束 + 词数估算」填充，保证播放不崩。
  SpeechEntry ensureTimestamps() {
    final out = <TranscriptSentence>[];
    var prevEnd = 0.0;
    var warned = false;
    for (final s in sentences) {
      if (s.end > s.start && s.end > 0) {
        out.add(s);
        prevEnd = s.end;
        continue;
      }
      if (!warned) {
        debugPrint('[content] $id：存在无时间戳句子，使用估算值兜底');
        warned = true;
      }
      final words =
          s.english
              .split(RegExp(r"[^A-Za-z']+"))
              .where((w) => w.isNotEmpty)
              .length;
      final start = prevEnd + 0.05;
      final end = start + 0.35 * words + 0.25;
      out.add(
        s.copyWith(
          start: start,
          end: end,
          words: _estimateWords(s, start, end),
        ),
      );
      prevEnd = end;
    }
    return _copyWithSentences(out);
  }

  /// 为所有句子补齐词级时间戳（缺失时线性插值）
  SpeechEntry ensureWordTimings() {
    final out = <TranscriptSentence>[];
    for (final s in sentences) {
      if (s.words.isNotEmpty) {
        out.add(s);
      } else {
        final end = s.end > s.start ? s.end : s.start + 1;
        out.add(s.copyWith(words: _estimateWords(s, s.start, end)));
      }
    }
    return _copyWithSentences(out);
  }

  SpeechEntry _copyWithSentences(List<TranscriptSentence> out) => SpeechEntry(
    id: id,
    title: title,
    speaker: speaker,
    level: level,
    duration: duration,
    audioOffsetSec: audioOffsetSec,
    coverUrl: coverUrl,
    audioPath: audioPath,
    sentences: out,
    clips: clips.isEmpty ? RetellClip.deriveClips(out) : clips,
    topicZh: topicZh,
    titleZh: titleZh,
    tags: tags,
    difficulty: difficulty,
    coverColors: coverColors,
    topicQuestions: topicQuestions,
    hasTranscript: hasTranscript,
    transcriptScope: transcriptScope,
    source: source,
    category: category,
  );

  /// 句内按词数线性插值生成词级时间戳（P2-1 无对齐结果时的兜底）
  static List<WordTime> _estimateWords(
    TranscriptSentence s,
    double start,
    double end,
  ) {
    if (s.words.isNotEmpty) return s.words;
    final parts = s.english.split(RegExp(r'\s+'));
    final total = parts.where((w) => w.isNotEmpty).length;
    if (total == 0) return const [];
    final span = (end - start) / total;
    var cursor = start;
    final out = <WordTime>[];
    for (final w in parts) {
      if (w.isEmpty) continue;
      out.add(WordTime(word: w, start: cursor, end: cursor + span));
      cursor += span;
    }
    return out;
  }

  /// 正文时长（秒）＝末句结束时间 − 片头偏移。
  ///
  /// 进度条以「正文时间轴」展示：起点为首句 startTime（片头音乐不占据进度条），
  /// 终点为末句 endTime（文末音乐/静音同样不占据进度条）。
  /// 因此这里不用「音频真实时长」，而是用末句 endTime 作为正文终点，
  /// 天然排除片头与文末空白（如 matt_cutts 文末有 24.7s 音乐）。
  double get bodyDurationSec {
    if (sentences.isEmpty) return 0;
    final lastEnd = sentences.last.end;
    final total = lastEnd - audioOffsetSec;
    return total > 0 ? total : 0;
  }

  /// 把「音频绝对秒」换算为「正文秒」（扣除片头偏移，下限 0）。
  ///
  /// 句子的 startTime/endTime 与播放器 position 都在音频绝对时间轴上，
  /// 该换算仅用于进度条/时间显示等「正文视角」的 UI。
  double bodySecondsAt(double audioSeconds) {
    final v = audioSeconds - audioOffsetSec;
    return v < 0 ? 0 : v;
  }

  /// 二分查找当前播放位置所在句（O(log n)，句级同步用）
  int sentenceIndexAt(double seconds) {
    var lo = 0;
    var hi = sentences.length - 1;
    var ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (sentences[mid].start <= seconds) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}

/// 内容主题分组（内容库按中文主题聚合）
class TopicGroup {
  final String topic;
  final List<SpeechEntry> entries;

  const TopicGroup({required this.topic, required this.entries});
}

List<TopicGroup> groupByTopic(List<SpeechEntry> entries) {
  final map = <String, List<SpeechEntry>>{};
  for (final e in entries) {
    map.putIfAbsent(e.topicZh.isEmpty ? '其他' : e.topicZh, () => []).add(e);
  }
  final keys = map.keys.toList()..sort();
  return [for (final k in keys) TopicGroup(topic: k, entries: map[k]!)];
}
