/// 识别结果归一化与容错（P1-6 / B1 / 模型智能化）
///
/// tiny.en 这类端侧模型对同音词、缩写、数字、连读弱读容易误判。
/// 在「识别文本 → 逐词对齐」之间加一层语言层校正，比换更大模型
/// 成本低得多，且完全离线。校正分三级：
///   ① 缩写/数字/标点归一化（确定性）
///   ② 同音异形词表（确定性，标注为模糊命中）
///   ③ 发音近似键 + 单字符编辑距离（保守，仅长词）
class TextNormalizer {
  TextNormalizer._();

  static const Map<String, String> _contractions = {
    "can't": 'cannot',
    "won't": 'will not',
    "don't": 'do not',
    "doesn't": 'does not',
    "didn't": 'did not',
    "isn't": 'is not',
    "aren't": 'are not',
    "wasn't": 'was not',
    "weren't": 'were not',
    "haven't": 'have not',
    "hasn't": 'has not',
    "hadn't": 'had not',
    "shouldn't": 'should not',
    "wouldn't": 'would not',
    "couldn't": 'could not',
    "i'm": 'i am',
    "you're": 'you are',
    "we're": 'we are',
    "they're": 'they are',
    "it's": 'it is',
    "that's": 'that is',
    "there's": 'there is',
    "he's": 'he is',
    "she's": 'she is',
    "i've": 'i have',
    "you've": 'you have',
    "we've": 'we have',
    "i'll": 'i will',
    "you'll": 'you will',
    "we'll": 'we will',
    "i'd": 'i would',
    "let's": 'let us',
    "gonna": 'going to',
    "wanna": 'want to',
    "gotta": 'got to',
    "kinda": 'kind of',
    "sorta": 'sort of',
    "outta": 'out of',
    "lotsa": 'lots of',
    "cos": 'because',
    "cause": 'because',
  };

  static const Map<String, String> _digits = {
    '0': 'zero',
    '1': 'one',
    '2': 'two',
    '3': 'three',
    '4': 'four',
    '5': 'five',
    '6': 'six',
    '7': 'seven',
    '8': 'eight',
    '9': 'nine',
    '10': 'ten',
    '11': 'eleven',
    '12': 'twelve',
    '13': 'thirteen',
    '14': 'fourteen',
    '15': 'fifteen',
    '16': 'sixteen',
    '17': 'seventeen',
    '18': 'eighteen',
    '19': 'nineteen',
    '20': 'twenty',
    '30': 'thirty',
    '40': 'forty',
    '50': 'fifty',
    '60': 'sixty',
    '70': 'seventy',
    '80': 'eighty',
    '90': 'ninety',
    '100': 'hundred',
    '1000': 'thousand',
    '1667': 'sixteen sixty seven',
    '50000': 'fifty thousand',
  };

  /// 同音异形词组：同组内的词互相视为等价
  static const List<Set<String>> _homophoneGroups = [
    {'write', 'right', 'rite', 'wright'},
    {'there', 'their', "they're"},
    {'to', 'too', 'two'},
    {'see', 'sea'},
    {'hear', 'here'},
    {'know', 'no'},
    {'new', 'knew', 'gnu'},
    {'wear', 'where', 'ware'},
    {'buy', 'by', 'bye'},
    {'for', 'four', 'fore'},
    {'one', 'won'},
    {'our', 'hour', 'are'},
    {'peace', 'piece'},
    {'plain', 'plane'},
    {'break', 'brake'},
    {'whole', 'hole'},
    {'weather', 'whether'},
    {'would', 'wood'},
    {'made', 'maid'},
    {'red', 'read'},
    {'blue', 'blew'},
    {'flower', 'flour'},
    {'pair', 'pear', 'pare'},
    {'son', 'sun'},
    {'week', 'weak'},
    {'wait', 'weight'},
    {'way', 'weigh'},
    {'hi', 'high'},
    {'eye', 'i'},
    {'be', 'bee'},
    {'dear', 'deer'},
    {'meet', 'meat'},
    {'threw', 'through'},
    {'tail', 'tale'},
    {'sail', 'sale'},
    {'night', 'knight'},
    {'not', 'knot'},
    {'some', 'sum'},
    {'time', 'thyme'},
    {'ad', 'add'},
    {'cell', 'sell'},
    {'cent', 'sent', 'scent'},
    {'court', 'caught'},
    {'flea', 'flee'},
    {'hair', 'hare'},
    {'heel', 'heal'},
    {'mail', 'male'},
    {'principal', 'principle'},
    {'role', 'roll'},
    {'root', 'route'},
    {'scene', 'seen'},
    {'steal', 'steel'},
    {'their', 'there'},
    {'waste', 'waist'},
  ];

  static final Map<String, Set<String>> _homophoneIndex = () {
    final map = <String, Set<String>>{};
    for (final group in _homophoneGroups) {
      for (final w in group) {
        map.putIfAbsent(w, () => <String>{}).addAll(group);
      }
    }
    return map;
  }();

  /// 主入口：把识别文本（或参考文本）归一化成可比较的小写词串
  static String normalize(String text) {
    var s = text.toLowerCase().trim();
    // 括号内的笑声/掌声等转写噪声
    s = s.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    s = s.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    // 连字符视为空格，撇号保留（缩写表用）
    s = s.replaceAll('-', ' ');
    s = s.replaceAll(RegExp(r"[^a-z0-9\s']"), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

    final out = <String>[];
    for (var raw in s.split(' ')) {
      if (raw.isEmpty) continue;
      // 去首尾残留撇号
      raw = raw.replaceAll(RegExp(r"^'+|'+$"), '');
      if (raw.isEmpty) continue;
      if (_digits.containsKey(raw)) {
        out.addAll(_digits[raw]!.split(' '));
        continue;
      }
      if (_contractions.containsKey(raw)) {
        out.addAll(_contractions[raw]!.split(' '));
        continue;
      }
      // 口语填充词：对齐前丢弃，避免被判「多读」
      if (_fillers.contains(raw)) continue;
      out.add(raw);
    }
    return out.join(' ');
  }

  static const Set<String> _fillers = {
    'um', 'uh', 'erm', 'hmm', 'mm', 'ah', 'er',
  };

  /// 简化发音键：把拼写差异收敛到近似音形
  static String phoneticKey(String w) {
    var s = w.toLowerCase().replaceAll(RegExp(r"[^a-z]"), '');
    if (s.isEmpty) return '';
    s = s
        .replaceAll('ph', 'f')
        .replaceAll('gh', '')
        .replaceAll('ck', 'k')
        .replaceAll('qu', 'kw')
        .replaceAll('x', 'ks')
        .replaceAll('wh', 'w')
        .replaceAll('kn', 'n')
        .replaceAll('wr', 'r')
        .replaceAll('mb', 'm')
        .replaceAll('tion', 'shn')
        .replaceAll('sion', 'shn')
        .replaceAll('y', 'i');
    s = s.replaceAllMapped(RegExp(r'(.)\1+'), (m) => m.group(1)!);
    if (s.length > 2 && s.endsWith('e')) s = s.substring(0, s.length - 1);
    return s;
  }

  /// 是否应视为「同一个词」（供 aligner 判定 cost=0）
  static bool equivalent(String ref, String hyp, {bool fuzzy = true}) {
    if (ref == hyp) return true;
    if (!fuzzy) return false;
    final hom = _homophoneIndex[ref];
    if (hom != null && hom.contains(hyp)) return true;
    if (phoneticKey(ref) == phoneticKey(hyp)) return true;
    // 长词单字符差异（常见 ASR 尾音/复数误听）
    if (ref.length >= 5 && hyp.length >= 5 && ref[0] == hyp[0]) {
      if (_editDistanceOne(ref, hyp)) return true;
    }
    return false;
  }

  static bool _editDistanceOne(String a, String b) {
    if ((a.length - b.length).abs() > 1) return false;
    if (a.length == b.length) {
      var diff = 0;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i] && ++diff > 1) return false;
      }
      return diff == 1;
    }
    final long = a.length > b.length ? a : b;
    final short = a.length > b.length ? b : a;
    var i = 0;
    var j = 0;
    var skipped = false;
    while (i < long.length && j < short.length) {
      if (long[i] == short[j]) {
        i++;
        j++;
      } else {
        if (skipped) return false;
        skipped = true;
        i++;
      }
    }
    return true;
  }

  /// 错词发音提示（B5：不只标红，还告诉用户怎么改）
  static String? confusionHint(String ref, String spoken) {
    final r = ref.toLowerCase();
    final s = spoken.toLowerCase();
    if (r.isEmpty || s.isEmpty) return null;
    final hom = _homophoneIndex[r];
    if (hom != null && hom.contains(s)) {
      return '「$ref」与「$spoken」同音，拼写不同，识别难以区分，此处按读对处理';
    }
    if (r.startsWith('th') || s.startsWith('th')) {
      return '注意 /θ/ 与 /s/：舌尖轻抵上齿，不要读成 s';
    }
    if (r.contains('v') || s.contains('w')) {
      return '注意 /v/ 与 /w/：上齿轻触下唇，不要读成 w';
    }
    if (r.contains('r') || s.contains('l')) {
      return '注意 /r/ 与 /l/：卷舌但不触碰上颚';
    }
    if (r.endsWith('ed') || r.endsWith('s')) {
      return '注意词尾 -ed / -s 要读出来，别吞音';
    }
    if (_editDistanceOne(r, s)) {
      return '与「$ref」只差一个音，放慢速度再读一遍';
    }
    return '重听原声，注意重音与元音长度';
  }

  /// 识别质量（0~1）：给 UI 标注「本次识别可信度」
  static RecognitionQuality assess(String raw, int referenceWordCount) {
    if (raw.trim().isEmpty) {
      return const RecognitionQuality(
          score: 0, label: '未识别到语音', hint: '靠近麦克风，确认录音权限');
    }
    final tokens = normalize(raw).split(' ').where((w) => w.isNotEmpty).toList();
    final ratio = referenceWordCount == 0
        ? 1.0
        : (tokens.length / referenceWordCount).clamp(0.0, 1.5);
    final deviation = (ratio - 1).abs();
    final fillers = raw
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .map((w) => w.replaceAll(RegExp(r"[^a-z]"), ''))
        .where((w) => _fillers.contains(w))
        .length;
    var score = 1.0 - deviation * 0.7 - fillers * 0.03;
    score = score.clamp(0.0, 1.0);
    if (score >= 0.8) {
      return RecognitionQuality(score: score, label: '识别可信', hint: '');
    }
    if (score >= 0.55) {
      return RecognitionQuality(
          score: score, label: '识别一般', hint: '环境可能较吵，分数仅供参考');
    }
    return RecognitionQuality(
        score: score, label: '识别偏差较大', hint: '本句词数与原文差异明显，建议重录');
  }
}

class RecognitionQuality {
  final double score;
  final String label;
  final String hint;

  const RecognitionQuality({
    required this.score,
    required this.label,
    required this.hint,
  });
}
