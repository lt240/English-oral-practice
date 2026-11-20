import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_surface.dart';
import '../../core/widgets/ambient_background.dart';
import '../../core/widgets/liquid_glass.dart';
import '../../data/speech_library.dart';
import '../../services/audio_player_service.dart';
import '../../services/db/app_database.dart';

/// 聆听模式（P0-2：由占位壳实装）
///
/// 参考 VoiceTube / 每日英语听力：
/// 句级字幕同步、逐词高亮、单句循环、A-B 复读、变速、点句跳转、点词跳播。
/// 无文稿的内容也可整篇聆听（显示主题讨论问题）。
class ListeningPage extends StatefulWidget {
  const ListeningPage({super.key, required this.speech, this.initialIndex = 0});

  final SpeechEntry speech;
  final int initialIndex;

  @override
  State<ListeningPage> createState() => _ListeningPageState();
}

class _ListeningPageState extends State<ListeningPage> {
  final AudioPlayerService _player = AudioPlayerService();
  final ScrollController _scroll = ScrollController();
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _posSub;

  bool _ready = false;
  String? _error;
  bool _playing = false;
  int _activeIndex = 0;
  int _activeWord = -1;
  bool _loopSentence = false;
  Duration? _abStart;
  Duration? _abEnd;
  bool _showTranslation = true;
  double _speed = 1.0;
  static const _speeds = [0.75, 1.0, 1.25, 1.5];

  late final SpeechEntry _speech =
      widget.speech.ensureTimestamps().ensureWordTimings();
  bool get _hasScript => _speech.sentences.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _activeIndex = widget.initialIndex.clamp(
      0,
      _speech.sentences.isEmpty ? 0 : _speech.sentences.length - 1,
    );
    _init();
  }

  Future<void> _init() async {
    final path = widget.speech.audioPath;
    if (path == null || path.isEmpty) {
      if (mounted) setState(() => _error = '该内容没有关联音频文件');
      return;
    }
    try {
      await _player.open(path);
      await _player.setSpeed(_speed);
      _playingSub = _player.playingStream.listen((v) {
        if (mounted) setState(() => _playing = v);
      });
      _posSub = _player.positionStream.listen(_onPosition);
      if (!mounted) return;
      setState(() => _ready = true);
      _saveProgress();
    } catch (e) {
      if (mounted) setState(() => _error = '无法打开音频：$e');
    }
  }

  void _onPosition(Duration pos) {
    // 单句循环 / A-B 复读处于 clip 模式，positionStream 是裁剪后相对值，
    // 高亮保持当前句不变，避免用相对位置误算索引。
    if (!_hasScript || _loopSentence || _abEnd != null) return;
    if (_refreshHighlight(pos)) _scrollToCurrent();
  }

  /// 根据播放位置重算当前句/词并刷新高亮，返回是否发生变化。
  ///
  /// 时间轴基准：句子的 startTime/endTime 是「音频绝对时间」（首句 startTime 即
  /// 片头时长，末句 endTime ≈ 音频时长），播放器 position 也是绝对时间，
  /// 二者直接匹配，无需任何偏移换算。片头/文末空白只影响进度条的「正文视角」显示，
  /// 不影响这里的句/词定位。
  bool _refreshHighlight(Duration pos) {
    final sentences = _speech.sentences;
    final t = pos.inMilliseconds / 1000.0;
    final idx =
        _speech.sentenceIndexAt(t).clamp(0, sentences.length - 1).toInt();
    var wordIdx = -1;
    final words = sentences[idx].words;
    for (var i = 0; i < words.length; i++) {
      if (t >= words[i].start && t <= words[i].end) {
        wordIdx = i;
        break;
      }
    }
    final sentenceChanged = idx != _activeIndex;
    final changed = sentenceChanged || wordIdx != _activeWord;
    if (changed) {
      setState(() {
        _activeIndex = idx;
        _activeWord = wordIdx;
      });
      if (sentenceChanged) _saveProgress();
    }
    return changed;
  }

  void _scrollToCurrent() {
    if (!_scroll.hasClients || !_hasScript) return;
    // 每句约 74px，滚动到让当前句保持在中上部
    final target = (_activeIndex * 74.0 - 80).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  void _saveProgress() {
    AppDatabase.instance.saveProgress(widget.speech.id, _activeIndex);
  }

  Future<void> _togglePlay() async {
    if (!_ready) return;
    if (_playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> _seekBy(Duration delta) async {
    if (!_ready) return;
    final d = _player.duration;
    var next = _player.position + delta;
    if (next < Duration.zero) next = Duration.zero;
    if (d != null && next > d) next = d;
    await _player.seek(next);
  }

  /// 片头偏移（毫秒）：进度条与时间显示统一扣除，片头音乐不占据进度条。
  int get _offsetMs => (_speech.audioOffsetSec * 1000).round();

  /// 进度条拖动：把正文进度 x∈[0,1] 换算回音频绝对位置 seek，
  /// 并主动重算高亮（just_audio seek 后位置流可能不立即触发）。
  Future<void> _onSliderSeek(double x) async {
    if (!_ready) return;
    // 拖动进度条时退出单句循环 / A-B 复读，回到整篇绝对时间轴。
    if (_loopSentence || _abEnd != null) {
      setState(() {
        _loopSentence = false;
        _abStart = null;
        _abEnd = null;
      });
      await _player.clearClip();
    }
    final bodyTotal = (_speech.bodyDurationSec * 1000).round().clamp(
      1,
      1 << 31,
    );
    final target = Duration(milliseconds: (bodyTotal * x).round() + _offsetMs);
    await _player.seek(target);
    if (_hasScript) {
      _refreshHighlight(target);
      _scrollToCurrent();
    }
  }

  Future<void> _jumpToSentence(int i) async {
    if (!_hasScript || !_ready) return;
    final s = _speech.sentences[i];
    setState(() {
      _activeIndex = i;
      _activeWord = -1;
      _loopSentence = false;
      _abStart = null;
      _abEnd = null;
    });
    // 普通跳转不用 setClip：clearClip 恢复到整篇绝对时间轴后 seek，
    // 否则 clip 模式下 positionStream/duration 变为裁剪后相对值，
    // 与整篇进度条 total 量纲不一致（进度条被 clamp 到末端）。
    await _player.clearClip();
    await _player.seek(Duration(milliseconds: (s.start * 1000).round()));
    await _player.play();
    _saveProgress();
  }

  Future<void> _toggleSentenceLoop() async {
    if (!_hasScript || !_ready) return;
    if (_loopSentence) {
      await _player.clearClip();
      setState(() {
        _loopSentence = false;
        _abStart = null;
        _abEnd = null;
      });
      return;
    }
    final s = _speech.sentences[_activeIndex];
    setState(() {
      _loopSentence = true;
      _abStart = null;
      _abEnd = null;
    });
    await _player.playRange(
      start: Duration(milliseconds: (s.start * 1000).round()),
      end: Duration(milliseconds: (s.end * 1000).round()),
      loop: true,
    );
  }

  Future<void> _markAB() async {
    if (!_ready) return;
    final pos = _player.position;
    if (_abStart == null || _abEnd != null) {
      setState(() {
        _abStart = pos;
        _abEnd = null;
      });
      _toast('已设置 A 点 ${_fmt(pos)}，再点一次设置 B 点');
      return;
    }
    if (pos <= _abStart!) {
      _toast('B 点需要晚于 A 点');
      return;
    }
    setState(() {
      _abEnd = pos;
      _loopSentence = false;
    });
    await _player.playRange(start: _abStart!, end: pos, loop: true);
    _toast('A-B 复读 ${_fmt(_abStart!)} → ${_fmt(pos)}');
  }

  Future<void> _cycleSpeed() async {
    final i = _speeds.indexOf(_speed);
    final next = _speeds[(i + 1) % _speeds.length];
    await _player.setSpeed(next);
    setState(() => _speed = next);
  }

  Future<void> _playWord(int sentenceIndex, int wordIndex) async {
    if (!_ready) return;
    final w = _speech.sentences[sentenceIndex].words[wordIndex];
    setState(() {
      _activeIndex = sentenceIndex;
      _activeWord = wordIndex;
    });
    // 点词跳播同样走整篇 seek，避免 setClip 残留导致后续播放被裁剪、
    // 进度条量纲错乱。
    await _player.clearClip();
    await _player.seek(Duration(milliseconds: (w.start * 1000).round()));
    await _player.play();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    _posSub?.cancel();
    _player.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: AppSurface.textPrimary(context),
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.speech.topicZh,
                style: TextStyle(
                  fontSize: 12,
                  color: AppSurface.textSecondary(context),
                ),
              ),
              Text(
                widget.speech.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(child: _buildSubtitles(context)),
              _buildControls(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubtitles(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: LiquidGlass(
            child: Text(
              _error!,
              style: const TextStyle(color: AppColors.wrong),
            ),
          ),
        ),
      );
    }

    if (!_hasScript) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        children: [
          LiquidGlass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('文稿整理中', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  '这段音频已可直接聆听。逐句文稿尚未整理完成，'
                  '完成后即可使用跟读与逐词高亮。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _buildQuestions(context),
        ],
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      itemCount: _speech.sentences.length + 1,
      itemBuilder: (context, i) {
        if (i == _speech.sentences.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 14),
            child: _buildQuestions(context),
          );
        }
        final active = i == _activeIndex;
        final s = _speech.sentences[i];
        return GestureDetector(
          onTap: () => _jumpToSentence(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color:
                  active
                      ? AppColors.primary.withValues(alpha: 0.16)
                      : AppSurface.inset(context),
              border:
                  active
                      ? Border.all(
                        color: AppColors.primary.withValues(alpha: 0.5),
                      )
                      : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _fmt(Duration(milliseconds: (s.start * 1000).round())),
                      style: TextStyle(
                        fontSize: 11,
                        color: AppSurface.textTertiary(context),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: _buildWords(context, i, active)),
                  ],
                ),
                if (_showTranslation && s.chinese.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Padding(
                    padding: const EdgeInsets.only(left: 42),
                    child: Text(
                      s.chinese,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: AppSurface.textSecondary(context),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildWords(BuildContext context, int sentenceIndex, bool active) {
    final words = _speech.sentences[sentenceIndex].words;
    final spans = <InlineSpan>[];
    for (var i = 0; i < words.length; i++) {
      final highlighted = active && i == _activeWord;
      spans.add(
        WidgetSpan(
          child: GestureDetector(
            onTap: () => _playWord(sentenceIndex, i),
            child: Container(
              margin: const EdgeInsets.only(right: 4, bottom: 2),
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color:
                    highlighted
                        ? AppColors.primary.withValues(alpha: 0.85)
                        : null,
              ),
              child: Text(
                words[i].word,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.45,
                  color:
                      highlighted
                          ? Colors.white
                          : active
                          ? AppSurface.textPrimary(context)
                          : AppSurface.textSecondary(context),
                  fontWeight: active ? FontWeight.w500 : FontWeight.w300,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return RichText(text: TextSpan(children: spans));
  }

  Widget _buildQuestions(BuildContext context) {
    final qs = widget.speech.topicQuestions;
    if (qs.isEmpty) return const SizedBox.shrink();
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
              Text('主题讨论', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 10),
          for (final raw in qs) ...[
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
                        style: const TextStyle(fontSize: 13.5, height: 1.4),
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

  Widget _buildControls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StreamBuilder<Duration>(
            stream: _player.positionStream,
            builder: (context, snap) {
              final pos = snap.data ?? Duration.zero;
              // 单句循环 / A-B 复读（clip）时 position/duration 是相对值，直接展示段内进度；
              // 整篇播放时用「正文时间轴」：总量 = bodyDurationSec（末句end − 片头），
              // 片头音乐与文末空白都不占据进度条。
              final offsetMs =
                  (_loopSentence || _abEnd != null) ? 0 : _offsetMs;
              final bodyTotal = (_speech.bodyDurationSec * 1000).round().clamp(
                1,
                1 << 31,
              );
              final bodyPos =
                  (pos.inMilliseconds - offsetMs).clamp(0, bodyTotal).toInt();
              final v = (bodyPos / bodyTotal).clamp(0.0, 1.0).toDouble();
              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                    ),
                    child: Slider(
                      value: v,
                      activeColor: AppColors.primary,
                      onChanged: _ready ? _onSliderSeek : null,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _fmt(Duration(milliseconds: bodyPos)),
                          style: TextStyle(
                            fontSize: 11,
                            color: AppSurface.textTertiary(context),
                          ),
                        ),
                        Text(
                          _fmt(Duration(milliseconds: bodyTotal)),
                          style: TextStyle(
                            fontSize: 11,
                            color: AppSurface.textTertiary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 4),
          LiquidGlass(
            borderRadius: const BorderRadius.all(Radius.circular(28)),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _circleBtn(
                  Icons.replay_10_rounded,
                  () => _seekBy(const Duration(seconds: -10)),
                ),
                _circleBtn(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  _togglePlay,
                  big: true,
                ),
                _circleBtn(
                  Icons.forward_10_rounded,
                  () => _seekBy(const Duration(seconds: 10)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chip(
                  Icons.repeat_one_rounded,
                  '单句循环',
                  _loopSentence,
                  _toggleSentenceLoop,
                ),
                const SizedBox(width: 8),
                _chip(Icons.loop_rounded, 'A-B 复读', _abEnd != null, _markAB),
                const SizedBox(width: 8),
                _chip(Icons.speed_rounded, '${_speed}x', false, _cycleSpeed),
                const SizedBox(width: 8),
                _chip(
                  Icons.translate_rounded,
                  '译文',
                  _showTranslation,
                  () => setState(() => _showTranslation = !_showTranslation),
                ),
                const SizedBox(width: 8),
                _chip(Icons.restart_alt_rounded, '整篇', false, () async {
                  await _player.clearClip();
                  await _player.seek(Duration.zero);
                  setState(() {
                    _loopSentence = false;
                    _abStart = null;
                    _abEnd = null;
                  });
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap, {bool big = false}) {
    final size = big ? 58.0 : 42.0;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color:
              big
                  ? AppColors.primary.withValues(alpha: 0.88)
                  : AppSurface.inset(context),
        ),
        child: Icon(
          icon,
          color: big ? Colors.white : AppSurface.textPrimary(context),
          size: big ? 30 : 22,
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color:
              selected
                  ? AppColors.primary.withValues(alpha: 0.22)
                  : AppSurface.inset(context),
          border:
              selected
                  ? Border.all(color: AppColors.primary.withValues(alpha: 0.5))
                  : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color:
                  selected
                      ? AppColors.primary
                      : AppSurface.textSecondary(context),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color:
                    selected
                        ? AppColors.primary
                        : AppSurface.textSecondary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
