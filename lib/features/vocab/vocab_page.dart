import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_surface.dart';
import '../../core/widgets/liquid_glass.dart';
import '../../services/db/app_database.dart';
import '../../services/dictionary_service.dart';
import '../../services/word_pronunciation_service.dart';

/// 生词本（P1-2）：收藏词 → 卡片复习（SM-2）→ 导出 CSV
class VocabPage extends StatefulWidget {
  const VocabPage({super.key});

  @override
  State<VocabPage> createState() => _VocabPageState();
}

class _VocabPageState extends State<VocabPage> {
  List<VocabItem> _items = [];
  int _dueCount = 0;
  bool _onlyDue = false;

  /// 正在发音的单词（用于小喇叭图标反馈）
  String? _speakingWord;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final all = await AppDatabase.instance.allVocab();
      final due = await AppDatabase.instance.dueVocab();
      if (!mounted) return;
      setState(() {
        _items = _onlyDue ? due : all;
        _dueCount = due.length;
      });
    } catch (_) {}
  }

  Future<void> _grade(VocabItem item, int score) async {
    final next = Srs.next(prev: item.schedule, score: score);
    await AppDatabase.instance.updateVocabSchedule(item.id, next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('「${item.word}」下次复习：${next.intervalDays} 天后'),
      duration: const Duration(seconds: 2),
    ));
    await _refresh();
  }

  /// 点击小喇叭：播放真人发音，播放期间图标切换，失败弹 SnackBar 提示
  Future<void> _play(VocabItem item) async {
    if (_speakingWord != null) return;
    setState(() => _speakingWord = item.word);
    var ok = false;
    try {
      ok = await WordPronunciationService.instance.play(item.word);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _speakingWord = null);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('发音获取失败：首次播放需联网（约 30KB），请检查网络后重试'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _addWord() async {
    final controller = TextEditingController();
    final word = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加生词'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.none,
          decoration: const InputDecoration(hintText: '输入英文单词'),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(controller.text.trim()),
              child: const Text('添加')),
        ],
      ),
    );
    if (word == null || word.isEmpty) return;
    final entry = await DictionaryService.instance.lookup(word);
    await AppDatabase.instance.addVocab(
      word: word,
      phonetic: entry?.phonetic,
      meaning: entry?.groups
          .map((g) => g.zh.isEmpty ? g.glosses.join('; ') : g.zh)
          .where((s) => s.isNotEmpty)
          .join('；'),
    );
    await _refresh();
  }

  Future<void> _export() async {
    final buf = StringBuffer('word,phonetic,meaning,source_sentence\n');
    for (final v in _items) {
      String esc(String s) => '"${s.replaceAll('"', '""')}"';
      buf.writeln([
        esc(v.word),
        esc(v.phonetic),
        esc(v.meaning),
        esc(v.sourceSentence),
      ].join(','));
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('CSV 已复制到剪贴板，可粘贴到 Anki / 表格')));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 130),
        children: [
          Row(
            children: [
              Expanded(
                  child: Text('生词本',
                      style: Theme.of(context).textTheme.titleLarge)),
              IconButton(
                onPressed: _export,
                icon: Icon(Icons.ios_share_rounded,
                    size: 20, color: AppSurface.textSecondary(context)),
                tooltip: '导出 CSV',
              ),
              IconButton(
                onPressed: _addWord,
                icon: const Icon(Icons.add_rounded,
                    size: 22, color: AppColors.primary),
                tooltip: '添加生词',
              ),
            ],
          ),
          const SizedBox(height: 12),
          LiquidGlass(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _Figure(value: '${_items.length}', label: '收藏词'),
                _Figure(value: '$_dueCount', label: '今日到期'),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _tab('全部', !_onlyDue, () => setState(() {
                    _onlyDue = false;
                    _refresh();
                  })),
              const SizedBox(width: 8),
              _tab('今日复习', _onlyDue, () => setState(() {
                    _onlyDue = true;
                    _refresh();
                  })),
            ],
          ),
          const SizedBox(height: 12),
          if (_items.isEmpty)
            LiquidGlass(
              child: Text(
                '还没有生词。跟读时点击红色错词可一键收藏，查词弹窗里也能加入生词本。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else
            for (final item in _items) _card(context, item),
        ],
      ),
    );
  }

  Widget _tab(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: selected
              ? AppColors.primary.withValues(alpha: 0.85)
              : AppSurface.inset(context),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                color: selected ? Colors.white : AppSurface.textSecondary(context))),
      ),
    );
  }

  Widget _card(BuildContext context, VocabItem item) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LiquidGlass(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(item.word,
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w600)),
                ),
                if (item.phonetic.isNotEmpty)
                  Text('/${item.phonetic}/',
                      style: Theme.of(context).textTheme.bodySmall),
                _speakerButton(item),
                IconButton(
                  onPressed: () async {
                    await AppDatabase.instance.removeVocab(item.word);
                    await _refresh();
                  },
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: AppSurface.textTertiary(context)),
                  tooltip: '移除',
                ),
              ],
            ),
            if (item.meaning.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(item.meaning,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            if (item.sourceSentence.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(item.sourceSentence,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: AppSurface.textTertiary(context))),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Text('下次间隔 ${item.schedule.intervalDays} 天',
                    style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                _gradeBtn('忘了', 30, AppColors.wrong, item),
                const SizedBox(width: 8),
                _gradeBtn('记得', 88, AppColors.correct, item),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 小喇叭发音按钮：播放中切换为声波图标作为反馈
  Widget _speakerButton(VocabItem item) {
    final speaking = _speakingWord == item.word;
    return IconButton(
      onPressed: () => _play(item),
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: Icon(
          speaking ? Icons.graphic_eq_rounded : Icons.volume_up_rounded,
          key: ValueKey(speaking),
          size: 19,
          color: AppColors.primary,
        ),
      ),
      tooltip: speaking ? '播放中' : '播放发音',
    );
  }

  Widget _gradeBtn(String label, int score, Color color, VocabItem item) {
    return GestureDetector(
      onTap: () => _grade(item, score),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: color.withValues(alpha: 0.16),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, color: color)),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w300,
                color: AppColors.primary)),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
