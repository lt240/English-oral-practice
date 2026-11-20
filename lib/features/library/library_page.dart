import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_surface.dart';
import '../../core/widgets/liquid_glass.dart';
import '../../core/widgets/speech_cover.dart';
import '../../data/speech_library.dart';
import '../../services/db/app_database.dart';
import '../detail/speech_detail_page.dart';

/// 内容库（P2-2 / P1-4 / C5）
///
/// 中文主题分组 + 英文文字封面、搜索、主题筛选、难度筛选、
/// 断点续读进度环、最近练习、文稿状态标识。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final TextEditingController _search = TextEditingController();
  String _category = '全部'; // 一级分类
  String _topic = '全部'; // 二级主题（一级分类非「全部」时显示）
  int _maxDifficulty = 5;
  Map<String, int> _progress = {};
  List<String> _recentIds = [];

  static const _categories = ['全部', 'TED演讲', '名人演讲'];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final progress = await AppDatabase.instance.allProgress();
      final recent = await AppDatabase.instance.recentProgress(limit: 3);
      if (!mounted) return;
      setState(() {
        _progress = progress;
        _recentIds =
            [
              for (final r in recent) r['speech_id'] as String? ?? '',
            ].where((e) => e.isNotEmpty).toList();
      });
    } catch (_) {
      // 数据库不可用时（如纯单元测试环境）退化为无进度显示
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return s == 0 ? '$m 分钟' : '$m分${s.toString().padLeft(2, '0')}秒';
  }

  bool _inCategory(SpeechEntry s) {
    if (_category == 'TED演讲') return s.category == SpeechCategory.ted;
    if (_category == '名人演讲') return s.category == SpeechCategory.celebrity;
    return true;
  }

  List<String> get _topics {
    final set = <String>{'全部'};
    for (final s in kSpeechLibrary) {
      if (!_inCategory(s)) continue;
      set.add(s.topicZh);
    }
    return set.toList();
  }

  bool _matches(SpeechEntry s, String q) {
    if (!_inCategory(s)) return false;
    if (_topic != '全部' && s.topicZh != _topic) return false;
    if (s.difficulty > _maxDifficulty) return false;
    if (q.isEmpty) return true;
    return s.title.toLowerCase().contains(q) ||
        s.titleZh.contains(q) ||
        s.topicZh.contains(q) ||
        s.speaker.toLowerCase().contains(q) ||
        s.tags.any((t) => t.contains(q));
  }

  List<SpeechEntry> get _filtered {
    final q = _search.text.trim().toLowerCase();
    final out = <SpeechEntry>[];
    for (final s in kSpeechLibrary) {
      if (_matches(s, q)) out.add(s);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 130),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '英语口语学习助手',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${kSpeechLibrary.length} 篇内容 · 离线可用',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.wifi_off_rounded,
                size: 18,
                color: AppSurface.textTertiary(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildSearch(context),
          const SizedBox(height: 10),
          _buildFilters(context),
          if (_recentIds.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildRecent(context),
          ],
          const SizedBox(height: 18),
          if (list.isEmpty)
            LiquidGlass(
              child: Text(
                '没有匹配的内容，换个关键词或主题试试',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else
            for (final speech in list) _buildCard(context, speech),
        ],
      ),
    );
  }

  Widget _buildSearch(BuildContext context) {
    return LiquidGlass(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      borderRadius: const BorderRadius.all(Radius.circular(18)),
      child: TextField(
        controller: _search,
        onChanged: (_) => setState(() {}),
        style: TextStyle(fontSize: 14, color: AppSurface.textPrimary(context)),
        decoration: InputDecoration(
          hintText: '搜索标题、主题、演讲者…',
          hintStyle: TextStyle(
            fontSize: 13,
            color: AppSurface.textTertiary(context),
          ),
          border: InputBorder.none,
          icon: Icon(
            Icons.search_rounded,
            size: 20,
            color: AppSurface.textTertiary(context),
          ),
          suffixIcon:
              _search.text.isEmpty
                  ? null
                  : IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: AppSurface.textTertiary(context),
                    ),
                    onPressed: () {
                      _search.clear();
                      setState(() {});
                    },
                  ),
        ),
      ),
    );
  }

  Widget _buildFilters(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCategoryTabs(context),
        if (_category != '全部') ...[
          const SizedBox(height: 8),
          _buildTopicChips(context),
        ],
        const SizedBox(height: 8),
        _buildDifficulty(context),
      ],
    );
  }

  Widget _buildCategoryTabs(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 7),
        itemBuilder: (context, i) {
          final c = _categories[i];
          final selected = c == _category;
          return GestureDetector(
            onTap:
                () => setState(() {
                  _category = c;
                  _topic = '全部'; // 切换一级分类时重置二级主题
                }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(17),
                color:
                    selected
                        ? AppColors.primary.withValues(alpha: 0.85)
                        : AppSurface.inset(context),
              ),
              child: Text(
                c,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color:
                      selected
                          ? Colors.white
                          : AppSurface.textSecondary(context),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTopicChips(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _topics.length,
        separatorBuilder: (_, __) => const SizedBox(width: 7),
        itemBuilder: (context, i) {
          final t = _topics[i];
          final selected = t == _topic;
          return GestureDetector(
            onTap: () => setState(() => _topic = t),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(17),
                color:
                    selected
                        ? AppColors.primary.withValues(alpha: 0.85)
                        : AppSurface.inset(context),
              ),
              child: Text(
                t,
                style: TextStyle(
                  fontSize: 12,
                  color:
                      selected
                          ? Colors.white
                          : AppSurface.textSecondary(context),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDifficulty(BuildContext context) {
    return Row(
      children: [
        Text('难度 ≤', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: 8),
        for (var d = 1; d <= 5; d++)
          GestureDetector(
            onTap: () => setState(() => _maxDifficulty = d),
            child: Container(
              margin: const EdgeInsets.only(right: 5),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color:
                    d <= _maxDifficulty
                        ? AppColors.primary.withValues(alpha: 0.65)
                        : AppSurface.inset(context),
              ),
              child: Text(
                '$d',
                style: TextStyle(
                  fontSize: 11,
                  color:
                      d <= _maxDifficulty
                          ? Colors.white
                          : AppSurface.textTertiary(context),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRecent(BuildContext context) {
    final items =
        [
          for (final id in _recentIds) speechById(id),
        ].whereType<SpeechEntry>().toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return LiquidGlass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.history_rounded,
                size: 17,
                color: AppColors.primary,
              ),
              const SizedBox(width: 7),
              Text('继续练习', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 10),
          for (final s in items)
            GestureDetector(
              onTap: () => _open(context, s),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.titleZh.isEmpty ? s.title : s.titleZh,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    Text(
                      '第 ${(_progress[s.id] ?? 0) + 1} 句',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.play_arrow_rounded,
                      size: 18,
                      color: AppColors.primary,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCard(BuildContext context, SpeechEntry speech) {
    final done = _progress[speech.id] ?? 0;
    final total = speech.sentences.length;
    final ratio = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => _open(context, speech),
        child: LiquidGlass(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SpeechCover(speech: speech, width: 76, height: 76),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      speech.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (speech.titleZh.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        speech.titleZh,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      '${speech.speaker} · ${_formatDuration(speech.duration)} · '
                      '${speech.sentences.length} 句 · 难度 ${speech.difficulty}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (speech.audioPath == null ||
                            speech.audioPath!.isEmpty)
                          _badge(context, '音频待补', AppColors.wrong)
                        else if (!speech.hasTranscript)
                          _badge(context, '文稿整理中', AppColors.missed)
                        else if (speech.source.contains('语音识别'))
                          _badge(
                            context,
                            speech.hasFullChinese ? '识别稿' : '识别稿·部分中译',
                            AppColors.missed,
                          )
                        else if (done > 0)
                          _badge(
                            context,
                            '继续第 ${done + 1} 句',
                            AppColors.primary,
                          ),
                        if (speech.tags.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              speech.tags.take(2).join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: AppSurface.textTertiary(context),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 30,
                height: 30,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: ratio,
                      strokeWidth: 3,
                      backgroundColor: AppSurface.inset(context),
                      color: AppColors.primary,
                    ),
                    if (ratio >= 1)
                      const Icon(
                        Icons.check_rounded,
                        size: 15,
                        color: AppColors.correct,
                      )
                    else if (ratio > 0)
                      Text(
                        '${(ratio * 100).round()}',
                        style: TextStyle(
                          fontSize: 8,
                          color: AppSurface.textTertiary(context),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: color.withValues(alpha: 0.14),
      ),
      child: Text(text, style: TextStyle(fontSize: 10.5, color: color)),
    );
  }

  Future<void> _open(BuildContext context, SpeechEntry speech) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SpeechDetailPage(speech: speech)));
    await _refresh();
  }
}
