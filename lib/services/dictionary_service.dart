import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// 按词性分组的释义集合（展示用）
class SenseGroup {
  const SenseGroup({
    required this.pos,
    required this.zh,
    required this.glosses,
    required this.isPrimary,
  });

  /// n 名词 / v 动词 / a 形容词 / r 副词 / x 其他
  final String pos;

  /// 核心中文翻译（可能为空）
  final String zh;

  /// 简短英文释义
  final List<String> glosses;

  /// 是否为语境推断出的主要词性
  final bool isPrimary;
}

/// 词典查询结果
class DictEntry {
  const DictEntry({
    required this.word,
    required this.phonetic,
    required this.root,
    required this.inflLabel,
    required this.groups,
    required this.rareGroups,
    this.usIpa = '',
  });

  /// 被点击的词（可能是合成词拆出的部分）
  final String word;

  final String phonetic;

  /// 变形词的原形（如 stuck → stick）；非变形词为空
  final String root;

  /// 变形类型中文标签（如「过去式 / 过去分词」）；无变形为空
  final String inflLabel;

  /// 标准美式 IPA 音标（CMU Pronouncing Dictionary → IPA）
  final String usIpa;

  /// 核心释义（原形优先，已按语境排序与精简）
  final List<SenseGroup> groups;

  /// 本词特有的生僻/附加义项（默认折叠展示）
  final List<SenseGroup> rareGroups;
}

/// 离线词典服务
///
/// 数据来源：ECDICT（https://github.com/skywind3000/ECDICT，MIT License），
/// 约 5.8 万高频词条，gzip 约 3.2MB。变形词（stuck/felt/went 等）强制
/// 关联原形词条的核心释义，本词特有的同形异义降级折叠。
class DictionaryService {
  DictionaryService._();
  static final DictionaryService instance = DictionaryService._();

  static const String _assetPath = 'assets/dict/dict.json.gz';
  static const String _usPath = 'assets/dict/us_ipa.json.gz';

  /// 结构：{ 小写词: [音标, 原形, 变形码, {词性: {en:[], zh:}}] }
  Map<String, List<dynamic>>? _data;
  Future<void>? _loading;

  /// 美式 IPA：{ 小写词: IPA 串 }（12.6 万条，来自 CMU Pronouncing Dict）
  Map<String, String>? _us;
  Future<void>? _usLoading;

  bool get isLoaded => _data != null;
  bool get isUsLoaded => _us != null;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> ensureUsLoaded() => _usLoading ??= _loadUs();

  Future<void> _loadUs() async {
    try {
      final byteData = await rootBundle.load(_usPath);
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      final decoded = jsonDecode(utf8.decode(GZipCodec().decode(bytes)))
          as Map<String, dynamic>;
      _us = decoded.cast<String, String>();
    } catch (_) {
      // 音标是增强数据，缺失时不影响释义查询
      _us = const <String, String>{};
    }
  }

  /// 查标准美式音标（先精确，再词形还原）
  String? usIpa(String word) {
    final w = _normalize(word);
    final direct = _us?[w];
    if (direct != null) return direct;
    if (_data != null) {
      final lemma = _lemmatize(w);
      final viaLemma = _us?[lemma];
      if (viaLemma != null) return viaLemma;
      if (w.contains('-')) {
        for (final part in w.split('-')) {
          if (part.length > 2 && _us?.containsKey(part) == true) {
            return _us![part];
          }
        }
      }
    }
    return null;
  }

  Future<void> _load() async {
    final byteData = await rootBundle.load(_assetPath);
    final bytes = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    final jsonBytes = GZipCodec().decode(bytes);
    final decoded =
        jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
    _data = decoded.cast<String, List<dynamic>>();
  }

  /// 查词。[contextSentence] 单词所在原句（语境词性判断用）。
  Future<DictEntry?> lookup(
    String rawWord, {
    String? contextSentence,
  }) async {
    await ensureLoaded();
    if (!isLoaded) return null;
    await ensureUsLoaded();
    final word = _normalize(rawWord);
    if (word.isEmpty) return null;

    // 1) 精确命中
    var raw = _data![word];
    var hitWord = word;
    if (raw == null) {
      // 2) 合成词拆词
      if (word.contains('-')) {
        for (final part in word.split('-')) {
          if (part.length > 2 && _data!.containsKey(part)) {
            raw = _data![part];
            hitWord = part;
            break;
          }
        }
      }
      // 3) 轻量词形还原
      if (raw == null) {
        final lemma = _lemmatize(word);
        raw = _data![lemma];
        hitWord = lemma;
      }
    }
    if (raw == null) return null;

    final phonetic = (raw.isNotEmpty ? raw[0] as String? : null) ?? '';
    final root = (raw.length > 1 ? raw[1] as String? : null) ?? '';
    final codes = (raw.length > 2 ? raw[2] as String? : null) ?? '';
    final ownGroups =
        (raw.length > 3 ? raw[3] as Map<dynamic, dynamic>? : null) ?? const {};

    var primaryPos = _inferPos(word, contextSentence);
    // 不规则形式（stuck/went）无 -ed 等后缀线索时，用变形码兜底
    primaryPos ??= _posFromCodes(codes);
    final inflLabel = _inflLabel(codes);

    // ── 变形词：核心释义取自原形词条 ────────────────────────
    if (root.isNotEmpty && _data!.containsKey(root)) {
      final rootRaw = _data![root]!;
      final rootGroups =
          (rootRaw.length > 3 ? rootRaw[3] as Map<dynamic, dynamic>? : null) ??
              const {};

      final groups = _buildGroups(
        source: rootGroups,
        primaryPos: rootGroups.containsKey(primaryPos) ? primaryPos : null,
      );

      // 原形没有该词性、但本词有（如 the following year 的形容词义）→
      // 把本词该词性义项提到核心区最前
      final extra = <SenseGroup>[];
      if (primaryPos != null &&
          !rootGroups.containsKey(primaryPos) &&
          ownGroups.containsKey(primaryPos)) {
        extra.add(_groupFrom(ownGroups[primaryPos] as Map<dynamic, dynamic>,
            primaryPos, true));
      }

      // 本词特有义项 → 折叠区（排除「X的过去式」说明组 x，以及已提走的组）
      final rare = <SenseGroup>[];
      for (final entry in ownGroups.entries) {
        final pos = entry.key as String;
        if (pos == 'x' || pos == primaryPos && extra.isNotEmpty) continue;
        rare.add(_groupFrom(entry.value as Map<dynamic, dynamic>, pos, false));
      }

      return DictEntry(
        word: hitWord,
        phonetic: phonetic,
        root: root,
        inflLabel: inflLabel,
        usIpa: usIpa(word) ?? usIpa(hitWord) ?? '',
        groups: [...extra, ...groups].take(3).toList(),
        rareGroups: rare,
      );
    }

    // ── 原形词：释义取自身 ────────────────────────────────
    return DictEntry(
      word: hitWord,
      phonetic: phonetic,
      root: '',
      inflLabel: '',
      usIpa: usIpa(word) ?? usIpa(hitWord) ?? '',
      groups: _buildGroups(source: ownGroups, primaryPos: primaryPos),
      rareGroups: const [],
    );
  }

  /// 按主要词性排序并精简，构造展示组
  List<SenseGroup> _buildGroups({
    required Map<dynamic, dynamic> source,
    required String? primaryPos,
  }) {
    final posOrder = <String>[
      if (primaryPos != null && source.containsKey(primaryPos)) primaryPos,
      for (final p in source.keys)
        if (p != primaryPos) p as String,
    ];
    final groups = <SenseGroup>[];
    for (var i = 0; i < posOrder.length; i++) {
      final g = _groupFrom(source[posOrder[i]] as Map<dynamic, dynamic>,
          posOrder[i], i == 0);
      if (g.zh.isEmpty && g.glosses.isEmpty) continue;
      groups.add(g);
      if (groups.length >= 3) break;
    }
    return groups;
  }

  SenseGroup _groupFrom(Map<dynamic, dynamic> raw, String pos, bool primary) {
    final enAll = (raw['en'] as List<dynamic>? ?? const []).cast<String>();
    return SenseGroup(
      pos: pos,
      zh: (raw['zh'] as String? ?? '').trim(),
      glosses: enAll.take(primary ? 2 : 1).toList(),
      isPrimary: primary,
    );
  }

  /// 变形码推断词性：动词形式码(p/d/i/3)→v；比较级/最高级(r/t)→a；
  /// 复数(s)→n。动词码与复数同时出现（如 books 的 s3）时无法消歧，返回 null。
  String? _posFromCodes(String codes) {
    final hasVerb = codes.contains('p') ||
        codes.contains('d') ||
        codes.contains('i') ||
        codes.contains('3');
    final hasPlural = codes.contains('s');
    if (hasVerb && hasPlural) return null;
    if (hasVerb) return 'v';
    if (codes.contains('r') || codes.contains('t')) return 'a';
    if (hasPlural) return 'n';
    return null;
  }

  /// 变形码 → 中文标签
  /// 码：p 过去式 / d 过去分词 / i 现在分词 / 3 三单 / r 比较级 / t 最高级 / s 复数
  String _inflLabel(String codes) {
    const labels = {
      'p': '过去式',
      'd': '过去分词',
      'i': '现在分词',
      '3': '第三人称单数',
      'r': '比较级',
      't': '最高级',
      's': '复数',
    };
    final parts = <String>[];
    for (final c in ['p', 'd', 'i', '3', 'r', 't', 's']) {
      if (codes.contains(c) && labels[c] != null) parts.add(labels[c]!);
    }
    return parts.join(' / ');
  }

  // ── 语境词性推断（轻量规则）────────────────────────────────

  static const Set<String> _be = {'be', 'been', 'being', 'is', 'am', 'are',
    'was', 'were'};
  static const Set<String> _linking = {'feel', 'feels', 'felt', 'look',
    'looks', 'looked', 'seem', 'seems', 'seemed', 'become', 'becomes',
    'became', 'get', 'gets', 'got', 'remain', 'remains', 'remained',
    'stay', 'stays', 'stayed', 'sound', 'sounds', 'sounded'};
  static const Set<String> _have = {'have', 'has', 'had'};
  static const Set<String> _modal = {'can', 'could', 'will', 'would', 'shall',
    'should', 'may', 'might', 'must'};
  static const Set<String> _det = {'a', 'an', 'the', 'this', 'that',
    'these', 'those', 'his', 'her', 'their', 'its', 'my', 'your', 'our',
    'some', 'any', 'no', 'one', 'each', 'every'};
  static const Set<String> _subjectPron = {'i', 'you', 'he', 'she', 'we',
    'they', 'it'};
  static const Set<String> _adverbBeforeAdj = {'very', 'too', 'so', 'pretty',
    'really', 'quite', 'rather'};

  String? _inferPos(String word, String? sentence) {
    if (word.endsWith('ly')) return 'r';

    final toks = sentence == null
        ? const <String>[]
        : RegExp(r"[A-Za-z']+")
            .allMatches(sentence)
            .map((m) => m.group(0)!.toLowerCase())
            .toList();
    final idx = toks.indexOf(word);
    final prev = idx > 0 ? toks[idx - 1] : '';
    final next = idx >= 0 && idx + 1 < toks.length ? toks[idx + 1] : '';

    if (word.endsWith('ing')) {
      if (_be.contains(prev)) return 'v';
      if (_linking.contains(prev)) return 'a';
      if (_det.contains(prev)) return 'a';
      return 'v';
    }

    if (word.endsWith('ed')) {
      if (_be.contains(prev) || _have.contains(prev)) return 'v';
      if (_linking.contains(prev)) return 'a';
      return 'v';
    }

    if (prev == 'to') return 'v';
    if (_modal.contains(prev)) return 'v';
    if (_adverbBeforeAdj.contains(prev)) return 'a';
    if (_det.contains(prev)) {
      if (next.isNotEmpty && _looksLikeNoun(next)) return 'a';
      return 'n';
    }
    if (_subjectPron.contains(prev)) return 'v';
    if (_have.contains(prev)) return 'v';
    return null;
  }

  bool _looksLikeNoun(String w) {
    if (_data?.containsKey(w) != true) return false;
    final raw = _data![w]!;
    if (raw.length <= 3) return false;
    final groups = raw[3] as Map<dynamic, dynamic>;
    return groups['n'] != null && groups['a'] == null;
  }

  // ── 归一化与词形还原 ──────────────────────────────────────

  String _normalize(String w) {
    var s = w.trim().toLowerCase();
    s = s.replaceAll(RegExp(r"^[^a-z']+"), '');
    s = s.replaceAll(RegExp(r"[^a-z']+$"), '');
    return s;
  }

  String _lemmatize(String w) {
    final candidates = <String>[];
    if (w.endsWith('ies') && w.length > 4) {
      candidates.add('${w.substring(0, w.length - 3)}y');
    }
    if (w.endsWith('es') && w.length > 3) {
      candidates.add(w.substring(0, w.length - 2));
    }
    if (w.endsWith('s') && !w.endsWith('ss') && w.length > 3) {
      candidates.add(w.substring(0, w.length - 1));
    }
    if (w.endsWith('ing') && w.length > 5) {
      final stem = w.substring(0, w.length - 3);
      candidates
        ..add(stem)
        ..add('${stem}e');
      if (stem.length > 1 && stem[stem.length - 1] == stem[stem.length - 2]) {
        candidates.add(stem.substring(0, stem.length - 1));
      }
    }
    if (w.endsWith('ed') && w.length > 4) {
      final stem = w.substring(0, w.length - 2);
      candidates
        ..add(stem)
        ..add('${stem}e');
    }
    for (final c in candidates) {
      if (_data!.containsKey(c)) return c;
    }
    return w;
  }
}
