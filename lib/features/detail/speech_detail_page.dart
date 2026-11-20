import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_surface.dart';
import '../../core/widgets/ambient_background.dart';
import '../../core/widgets/liquid_glass.dart';
import '../../core/widgets/speech_cover.dart';
import '../../data/speech_library.dart';
import '../../services/db/app_database.dart';
import '../../services/settings_controller.dart';
import '../listening/listening_page.dart';
import '../retell/retell_page.dart';
import 'shadowing_detail_page.dart';

/// 演讲详情页：内容概览 + 三种训练模式 + 断点续读 + 主题问题
class SpeechDetailPage extends StatefulWidget {
  const SpeechDetailPage({super.key, required this.speech});

  final SpeechEntry speech;

  @override
  State<SpeechDetailPage> createState() => _SpeechDetailPageState();
}

class _SpeechDetailPageState extends State<SpeechDetailPage> {
  TrainMode? _mode;
  int _resumeIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadProgress();
  }

  Future<void> _loadProgress() async {
    try {
      final i = await AppDatabase.instance.getProgress(widget.speech.id);
      if (mounted) setState(() => _resumeIndex = i);
    } catch (_) {}
  }

  void _choose(TrainMode mode) {
    setState(() => _mode = mode);
  }

  void _backToSelect() {
    setState(() => _mode = null);
    _loadProgress();
  }

  Future<void> _openListening() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => ListeningPage(
              speech: widget.speech,
              initialIndex: _resumeIndex,
            ),
      ),
    );
    await _loadProgress();
  }

  @override
  Widget build(BuildContext context) {
    switch (_mode) {
      case TrainMode.shadowing:
        return ShadowingDetailPage(
          speech: widget.speech,
          initialIndex: _resumeIndex,
          onSwitchMode: _backToSelect,
        );
      case TrainMode.retelling:
        return RetellPage(speech: widget.speech, onSwitchMode: _backToSelect);
      case null:
        return _buildSelectView(context);
    }
  }

  Widget _buildSelectView(BuildContext context) {
    final s = widget.speech;
    final total = s.sentences.length;
    final resumable = _resumeIndex > 0 && total > 0;
    final audioMissing = s.audioPath == null || s.audioPath!.isEmpty;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppSurface.textPrimary(context)),
        title: Text(
          '内容详情',
          style: TextStyle(
            fontSize: 16,
            color: AppSurface.textPrimary(context),
          ),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: AmbientBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SpeechCover(
                    speech: s,
                    width: 104,
                    height: 104,
                    titleFontSize: 16,
                    borderRadius: 20,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (s.titleZh.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                            s.titleZh,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        const SizedBox(height: 8),
                        Text(
                          '${s.speaker} · ${_duration(s.duration)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${s.topicZh} · 难度 ${s.difficulty} · $total 句',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              if (resumable) ...[
                LiquidGlass(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.history_rounded,
                        size: 20,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '上次练到第 ${_resumeIndex + 1} 句，共 $total 句',
                          style: const TextStyle(fontSize: 13.5),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _choose(TrainMode.shadowing),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: AppColors.primary.withValues(alpha: 0.85),
                          ),
                          child: const Text(
                            '继续',
                            style: TextStyle(fontSize: 12, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              if (audioMissing) ...[
                LiquidGlass(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.volume_off_rounded,
                        size: 19,
                        color: AppColors.wrong,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '这个素材是 B 站分离出的视频流，文件里没有音轨，暂时无法播放。'
                          '请重新下载「带声音」的版本放进「TED音频」目录，'
                          '运行 tools/import_media.py 后即可恢复。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              if (!s.hasTranscript) ...[
                LiquidGlass(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.info_outline_rounded,
                        size: 19,
                        color: AppColors.missed,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '本篇音频可完整聆听，逐句文稿尚在整理中。'
                          '文稿补齐后即可开放跟读与复述。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              if (s.source.contains('语音识别')) ...[
                LiquidGlass(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.graphic_eq_rounded,
                        size: 19,
                        color: AppColors.primarySoft,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '本篇文稿来自音频的语音识别逐字稿，带真实时间码，'
                          '保留口语原貌（英文小写、无标点已做轻度整理）。'
                          '${s.hasFullChinese ? '中文译文已补齐，可对照学习。' : '中文译文仅覆盖原节选句，未覆盖处暂无中译。'}'
                          '可直接用于聆听与跟读评分。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              _ModeCard(
                icon: Icons.headphones_rounded,
                title: '聆听模式',
                desc: '句级字幕同步、逐词高亮、单句循环、A-B 复读与变速。',
                color: const Color(0xFF3E7BF0),
                enabled: !audioMissing,
                disabledNote: '音频待补',
                onTap: _openListening,
              ),
              const SizedBox(height: 12),
              _ModeCard(
                icon: Icons.record_voice_over_rounded,
                title: '跟读模式',
                desc:
                    resumable
                        ? '从第 ${_resumeIndex + 1} 句继续，逐句听原声并跟读，实时逐词纠错打分。'
                        : '逐句听原声并跟读，实时逐词纠错打分。',
                color: const Color(0xFF5E7CF7),
                enabled: !audioMissing && s.hasTranscript,
                disabledNote: audioMissing ? '音频待补' : '文稿整理中',
                onTap: () => _choose(TrainMode.shadowing),
              ),
              const SizedBox(height: 12),
              _ModeCard(
                icon: Icons.repeat_rounded,
                title: '复述模式',
                desc: '听完整段原声后用自己的话复述，训练连贯表达。',
                color: const Color(0xFF8E6CF7),
                enabled:
                    !audioMissing && s.hasTranscript && s.hasRetellKeyPoints,
                disabledNote:
                    audioMissing
                        ? '音频待补'
                        : (!s.hasTranscript ? '文稿整理中' : '复述要点待配置'),
                onTap: () => _choose(TrainMode.retelling),
              ),
              if (s.topicQuestions.isNotEmpty) ...[
                const SizedBox(height: 18),
                _buildQuestions(context),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuestions(BuildContext context) {
    return LiquidGlass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.question_answer_outlined,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Text('主题问题', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 12),
          for (final raw in widget.speech.topicQuestions) ...[
            Builder(
              builder: (context) {
                final parts = raw.split('｜');
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '• ${parts.first}',
                        style: const TextStyle(fontSize: 13.5, height: 1.45),
                      ),
                      if (parts.length > 1)
                        Padding(
                          padding: const EdgeInsets.only(left: 12, top: 3),
                          child: Text(
                            parts.last,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  String _duration(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// 模式卡片（玻璃拟态）
class _ModeCard extends StatefulWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.desc,
    required this.color,
    required this.onTap,
    this.enabled = true,
    this.disabledNote,
  });

  final IconData icon;
  final String title;
  final String desc;
  final Color color;
  final VoidCallback onTap;
  final bool enabled;
  final String? disabledNote;

  @override
  State<_ModeCard> createState() => _ModeCardState();
}

class _ModeCardState extends State<_ModeCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: enabled ? widget.onTap : null,
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1,
          duration: const Duration(milliseconds: 120),
          child: LiquidGlass(
            borderRadius: BorderRadius.circular(24),
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        widget.color,
                        widget.color.withValues(alpha: 0.6),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(widget.icon, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        widget.desc,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (!enabled && widget.disabledNote != null) ...[
                        const SizedBox(height: 5),
                        Text(
                          widget.disabledNote!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.missed,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppSurface.textTertiary(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
