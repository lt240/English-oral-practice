import 'package:flutter/material.dart';

import '../../services/dictionary_service.dart';
import '../../services/word_pronunciation_service.dart';
import 'liquid_glass.dart';

/// 单词词典弹窗：核心中文翻译置顶，按句子语境排序词性，释义精简展示
class DictionaryPopup {
  DictionaryPopup._();

  /// 词性码 → 中文标签
  static const Map<String, String> _posLabels = {
    'n': '名词',
    'v': '动词',
    'a': '形容词',
    'r': '副词',
    'x': '',
  };

  /// [word] 被点击的单词；[contextSentence] 其所在原句（语境排词性用）
  static Future<void> show(
    BuildContext context,
    String word, {
    String? contextSentence,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _DictionarySheet(
        rawWord: word,
        contextSentence: contextSentence,
      ),
    );
  }
}

class _DictionarySheet extends StatefulWidget {
  const _DictionarySheet({
    required this.rawWord,
    required this.contextSentence,
  });

  final String rawWord;
  final String? contextSentence;

  @override
  State<_DictionarySheet> createState() => _DictionarySheetState();
}

class _DictionarySheetState extends State<_DictionarySheet> {
  DictEntry? _entry;
  bool _loading = true;
  bool _notFound = false;

  /// 小喇叭是否正在播放
  bool _speaking = false;

  /// 生僻义项折叠区是否展开
  bool _rareExpanded = false;

  @override
  void initState() {
    super.initState();
    _query();
  }

  @override
  void dispose() {
    // 弹窗关闭时停止发音，避免声音在后台继续
    WordPronunciationService.instance.stop();
    super.dispose();
  }

  Future<void> _query() async {
    final entry = await DictionaryService.instance.lookup(
      widget.rawWord,
      contextSentence: widget.contextSentence,
    );
    if (!mounted) return;
    setState(() {
      _entry = entry;
      _loading = false;
      _notFound = entry == null;
    });
  }

  /// 点击小喇叭：播放真人发音，播放期间图标切换为声波
  Future<void> _play(DictEntry entry) async {
    if (_speaking) return;
    setState(() => _speaking = true);
    var ok = false;
    try {
      ok = await WordPronunciationService.instance.play(entry.word);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _speaking = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('发音获取失败：首次播放需联网（约 30KB），请检查网络后重试'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, 14 + bottomInset),
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(24),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              )
            else if (_notFound)
              _notFoundView()
            else
              _content(_entry!),
          ],
        ),
      ),
    );
  }

  Widget _content(DictEntry entry) {
    final showRare = entry.rareGroups.isNotEmpty;
    return Flexible(
      child: SingleChildScrollView(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 单词 + 发音按钮 + 关闭
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      entry.word,
                      style: const TextStyle(
                          fontSize: 21, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _speakerButton(entry),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ),
            if (entry.usIpa.isNotEmpty || entry.phonetic.isNotEmpty) ...[
              const SizedBox(height: 3),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 9,
                children: [
                  if (entry.usIpa.isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('美',
                            style: TextStyle(
                                fontSize: 10, color: Color(0xFF93A9FF))),
                        const SizedBox(width: 3),
                        Text(
                          '/${entry.usIpa}/',
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: Color(0xFF7E96FF),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  if (entry.phonetic.isNotEmpty)
                    Text(
                      '/${entry.phonetic}/',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF93A9FF),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                ],
              ),
            ],
            // 变形词横幅：stick 的过去式 / 过去分词（原形可点）
            if (entry.root.isNotEmpty) ...[
              const SizedBox(height: 9),
              _rootBanner(entry),
            ],
            const SizedBox(height: 12),
            // 核心释义（原形核心义，主要词性置顶）
            for (final g in entry.groups) ...[
              if (g.zh.isNotEmpty) _zhRow(g),
              for (final gloss in g.glosses) _enRow(g, gloss),
              if (g != entry.groups.last) const SizedBox(height: 10),
            ],
            // 生僻/附加义项：默认折叠
            if (showRare) _rareSection(entry),
          ],
        ),
      ),
    );
  }

  /// 变形词横幅：图标 + 可点原形 + 变形类型
  Widget _rootBanner(DictEntry entry) {
    return GestureDetector(
      onTap: () => DictionaryPopup.show(context, entry.root),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF5E7CF7).withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: const Color(0xFF5E7CF7).withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.alt_route_rounded,
              size: 14,
              color: Color(0xFF7E96FF),
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: entry.root,
                    style: const TextStyle(
                      color: Color(0xFF93A9FF),
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.underline,
                      decorationColor: Color(0xFF93A9FF),
                    ),
                  ),
                  TextSpan(text: ' 的${entry.inflLabel}'),
                ]),
                style: const TextStyle(fontSize: 12.5, height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 生僻义项折叠区
  Widget _rareSection(DictEntry entry) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(
          height: 22,
          color: Colors.white.withValues(alpha: 0.12),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _rareExpanded = !_rareExpanded),
          child: Row(
            children: [
              Icon(
                Icons.label_outline_rounded,
                size: 14,
                color: Colors.white.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 7),
              Text(
                '本词其他义项（${entry.rareGroups.length}）',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
              const Spacer(),
              AnimatedRotation(
                turns: _rareExpanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
        if (_rareExpanded) ...[
          const SizedBox(height: 10),
          for (final g in entry.rareGroups) ...[
            if (g.zh.isNotEmpty) _zhRow(g),
            for (final gloss in g.glosses) _enRow(g, gloss),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }

  /// 中文翻译行：词性标签 + 中文
  Widget _zhRow(SenseGroup g) {
    final label = DictionaryPopup._posLabels[g.pos] ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty) ...[
            _posChip(label, g.isPrimary),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              g.zh,
              style: TextStyle(
                fontSize: g.isPrimary ? 16.5 : 14.5,
                height: 1.4,
                fontWeight: g.isPrimary ? FontWeight.w700 : FontWeight.w400,
                color: Colors.white.withValues(
                  alpha: g.isPrimary ? 0.98 : 0.78,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 英文释义行：小号灰字，前面带小竖点
  Widget _enRow(SenseGroup g, String gloss) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Container(
              width: 3,
              height: 3,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              gloss,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 小喇叭发音按钮：醒目蓝色圆形；播放时切换为声波图标并加蓝色光晕
  Widget _speakerButton(DictEntry entry) {
    return GestureDetector(
      onTap: () => _play(entry),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 37,
        height: 37,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF7E96FF), Color(0xFF4C6AE8)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF5E7CF7).withValues(
                alpha: _speaking ? 0.65 : 0.35,
              ),
              blurRadius: _speaking ? 16 : 9,
              spreadRadius: _speaking ? 1.5 : 0,
            ),
          ],
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.35),
            width: 1,
          ),
        ),
        alignment: Alignment.center,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Icon(
            _speaking ? Icons.graphic_eq_rounded : Icons.volume_up_rounded,
            key: ValueKey(_speaking),
            size: 19,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  /// 词性小标签（主要词性高亮）
  Widget _posChip(String label, bool primary) {
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: primary
            ? const Color(0xFF5E7CF7).withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: primary
              ? const Color(0xFF5E7CF7).withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.16),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.15,
          color: primary
              ? Colors.white
              : Colors.white.withValues(alpha: 0.7),
          fontWeight: primary ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
    );
  }

  Widget _notFoundView() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 20,
            color: Colors.white.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '词典未收录「${widget.rawWord}」',
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
          ),
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Text(
              '关闭',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
