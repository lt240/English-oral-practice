import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/ambient_background.dart';
import '../../core/widgets/liquid_glass.dart';
import '../../core/widgets/tappable_text.dart';
import '../../data/speech_library.dart';
import '../../services/db/app_database.dart';
import '../../services/retell_scorer.dart';
import '../../services/settings_controller.dart';
import '../../services/shadowing_recorder.dart';

/// 复述流程阶段：片段列表 → 录音 → 评分中 → 结果
enum _Stage { list, recording, scoring, result }

/// 复述模式页：
/// 第一步：片段可展开查看全部句子；点句子自选「从哪句读到哪句」；播放所选范围原声。
/// 第二步：听完点「开始复述」→ 整段长录音（VAD 不强制断句，最长时长保护）
///         → 离线要点覆盖率评分 → 结果页（分数/命中要点/参考大意/识别原文）。
class RetellPage extends StatefulWidget {
  final SpeechEntry speech;

  /// 由宿主页注入：返回模式选择页
  final VoidCallback? onSwitchMode;

  const RetellPage({super.key, required this.speech, this.onSwitchMode});

  @override
  State<RetellPage> createState() => _RetellPageState();
}

class _RetellPageState extends State<RetellPage> {
  SpeechEntry? _speech;
  bool _ready = false;

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;

  /// 正在播放的片段下标（null = 未播放）
  int? _playingClip;

  /// 当前播放范围的末句（全局下标）与末句时间
  int _playEndIndex = 0;

  /// 展开的片段
  final Set<int> _expanded = {};

  /// 每段自选范围：片段下标 → [局部起点, 局部终点]；无此 key = 整段
  final Map<int, List<int>> _ranges = {};

  // ── 复述训练状态 ─────────────────────────────────────────────
  _Stage _stage = _Stage.list;
  int _activeClip = 0;

  final ShadowingRecorder _recorder = ShadowingRecorder();

  /// 模型加载中（start 返回前）
  bool _preparing = false;

  /// 正在收尾（防止「到点自动结束」与「手动完成」重入）
  bool _finishing = false;

  /// 累计识别文本（多段 VAD 句子拼接）
  String _liveSpoken = '';

  /// 实时音量序列（画波形）
  final List<double> _levels = [];

  /// 真正进入聆听的时刻（计时用）
  DateTime _recordStart = DateTime.now();
  Timer? _elapsedTimer;

  final ScrollController _liveScroll = ScrollController();
  final ScrollController _resultScroll = ScrollController();

  /// 本次评分结果
  RetellScoreResult? _scoreResult;

  /// 本次训练实际生效的句范围（全局下标）与对应要点
  int _rangeStart = 0;
  int _rangeEnd = 0;
  bool _isFullClip = true;
  List<KeyPoint> _scopedKeyPoints = const [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    SpeechEntry effective;
    try {
      final raw = await rootBundle.loadString(
        'assets/content/${widget.speech.id}.json',
      );
      effective = SpeechEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      effective = widget.speech.ensureTimestamps();
    }
    _speech = effective;

    final path = effective.audioPath;
    if (path != null && path.isNotEmpty) {
      await _player.setAsset(path);
      if (mounted) {
        await _player.setSpeed(SettingsScope.of(context)?.rate ?? 1.0);
      }
    }
    _posSub = _player.positionStream.listen(_onPosition);

    if (mounted) setState(() => _ready = true);
  }

  void _onPosition(Duration pos) {
    final clipIdx = _playingClip;
    if (clipIdx == null) return;
    final endSec = _speech!.sentences[_playEndIndex].end;
    if (pos.inMilliseconds / 1000 >= endSec - 0.03) {
      _player.pause();
      setState(() => _playingClip = null);
    }
  }

  /// 某片段当前生效的范围（全局句下标）：[start, end]
  List<int> _effectiveRange(int clipIdx) {
    final c = _speech!.clips[clipIdx];
    final r = _ranges[clipIdx];
    if (r == null) return [c.startIndex, c.endIndex];
    return [c.startIndex + r[0], c.startIndex + r[1]];
  }

  /// 播放片段（有自选范围播范围，否则整段）；正在播放同段则停止
  Future<void> _playClip(int clipIdx) async {
    if (_playingClip == clipIdx) {
      await _player.pause();
      if (mounted) setState(() => _playingClip = null);
      return;
    }
    final r = _effectiveRange(clipIdx);
    _playEndIndex = r[1];
    await _player.seek(
      Duration(milliseconds: (_speech!.sentences[r[0]].start * 1000).round()),
    );
    await _player.play();
    if (mounted) setState(() => _playingClip = clipIdx);
  }

  /// 点句选择范围：
  /// 第 1 下=只选该句；第 2 下=定为终点（自动排序）；第 3 下=重新开始
  void _pickSentence(int clipIdx, int local) {
    final cur = _ranges[clipIdx];
    setState(() {
      if (cur == null) {
        _ranges[clipIdx] = [local, local];
      } else if (cur[0] == cur[1]) {
        final a = cur[0] < local ? cur[0] : local;
        final b = cur[0] > local ? cur[0] : local;
        _ranges[clipIdx] = [a, b];
      } else {
        _ranges[clipIdx] = [local, local];
      }
    });
  }

  void _resetRange(int clipIdx) {
    setState(() => _ranges.remove(clipIdx));
  }

  // ── 复述训练流程 ─────────────────────────────────────────────

  /// 进入某片段的录音复述（再复述一次也走这里，会重置全部状态）
  void _enterRetell(int clipIdx) {
    final c = _speech!.clips[clipIdx];
    final r = _effectiveRange(clipIdx);
    final scoped = RetellScorer.keyPointsInRange(
      sentences: _speech!.sentences,
      clip: c,
      startIndex: r[0],
      endIndex: r[1],
    );
    _finishing = false;
    setState(() {
      _activeClip = clipIdx;
      _rangeStart = r[0];
      _rangeEnd = r[1];
      _isFullClip = _ranges[clipIdx] == null;
      _scopedKeyPoints = scoped;
      _stage = _Stage.recording;
      _preparing = true;
      _liveSpoken = '';
      _levels.clear();
      _scoreResult = null;
    });
    _startRetellRecording();
  }

  Future<void> _startRetellRecording() async {
    final maxSeconds = SettingsScope.of(context)?.retellMaxSeconds ?? 90;
    await _player.pause();
    if (!mounted) return;
    try {
      await _recorder.start(
        // 复述允许较长思考停顿，且不因出句自动结束
        silenceDuration: 1.2,
        stopAfterSegment: false,
        maxDuration: Duration(seconds: maxSeconds),
        onMaxDuration: _finishRetell,
        onAmplitude: (v) {
          if (!mounted || _stage != _Stage.recording) return;
          setState(() {
            _levels.add(v);
            if (_levels.length > 24) _levels.removeAt(0);
          });
        },
        onSegment: (seg) {
          if (!mounted || _stage != _Stage.recording) return;
          final t = seg.text.trim();
          if (t.isEmpty) return;
          setState(() {
            _liveSpoken = _liveSpoken.isEmpty ? t : '$_liveSpoken $t';
          });
          // 识别文本自动滚到底部
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_liveScroll.hasClients) {
              _liveScroll.jumpTo(_liveScroll.position.maxScrollExtent);
            }
          });
        },
      );
    } catch (e) {
      _abortToList('录音启动失败：$e');
      return;
    }

    if (!mounted) return;
    _recordStart = DateTime.now();
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && _stage == _Stage.recording) setState(() {});
    });
    setState(() => _preparing = false);
  }

  /// 取消复述，返回片段列表
  Future<void> _cancelRetell() async {
    if (_stage != _Stage.recording || _finishing) return;
    _finishing = true;
    _elapsedTimer?.cancel();
    await _recorder.stop();
    if (mounted) {
      setState(() {
        _stage = _Stage.list;
        _preparing = false;
        _finishing = false;
      });
    }
  }

  /// 完成复述：停止 → 评分 → 落库 → 结果页
  Future<void> _finishRetell() async {
    if (_finishing) return;
    _finishing = true;
    _elapsedTimer?.cancel();

    // stop 会 flush 尾句并同步触发 onSegment，故停止后 _liveSpoken 已完整
    await _recorder.stop();
    if (!mounted) return;
    setState(() => _stage = _Stage.scoring);
    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;

    final result = RetellScorer.score(
      keyPoints: _scopedKeyPoints,
      recognized: _liveSpoken,
    );

    // 落库：未命中的要点短语以 JSON 数组保存
    final missing = [
      for (final r in result.results)
        if (!r.covered) r.point.phrase,
    ];
    try {
      await AppDatabase.instance.insertRetellRecord({
        'speech_id': _speech!.id,
        'clip_index': _activeClip,
        'practiced_at': DateTime.now().millisecondsSinceEpoch,
        'score': result.score,
        'total_points': result.total,
        'covered_points': result.covered,
        'recognized': _liveSpoken,
        'missing_points': jsonEncode(missing),
      });
    } catch (e) {
      debugPrint('复述记录落库失败：$e');
    }

    if (mounted) {
      setState(() {
        _scoreResult = result;
        _stage = _Stage.result;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_resultScroll.hasClients) _resultScroll.jumpTo(0);
      });
    }
  }

  /// 异常中止，回到列表并提示
  void _abortToList(String msg) {
    if (!mounted) return;
    _elapsedTimer?.cancel();
    setState(() {
      _stage = _Stage.list;
      _preparing = false;
      _finishing = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _liveScroll.dispose();
    _resultScroll.dispose();
    _posSub?.cancel();
    _player.dispose();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_stage == _Stage.list ? '复述模式' : '复述训练'),
        actions: [
          if (_stage == _Stage.list)
            IconButton(
              tooltip: '切换模式',
              icon: const Icon(Icons.swap_horiz_rounded),
              onPressed: widget.onSwitchMode,
            ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: PopScope(
        canPop: _stage == _Stage.list,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (_stage == _Stage.recording) {
            _cancelRetell();
          } else if (_stage == _Stage.scoring) {
            // 评分中不允许返回
          } else {
            setState(() => _stage = _Stage.list);
          }
        },
        child: AmbientBackground(child: SafeArea(child: _body())),
      ),
    );
  }

  Widget _body() {
    if (!_ready) return const Center(child: CircularProgressIndicator());
    switch (_stage) {
      case _Stage.list:
        return _clipListView();
      case _Stage.recording:
        return _recordingView();
      case _Stage.scoring:
        return const _ScoringPanel();
      case _Stage.result:
        return _resultView();
    }
  }

  // ── 片段列表 ─────────────────────────────────────────────────

  Widget _clipListView() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      itemCount: _speech!.clips.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) return _hintBar();
        return _clipCard(i - 1);
      },
    );
  }

  Widget _hintBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(20),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.touch_app_outlined, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '先听整段原声，展开可点选句子范围；听完点「开始复述」用自己的话说一遍。',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.75),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _clipCard(int clipIdx) {
    final clip = _speech!.clips[clipIdx];
    final expanded = _expanded.contains(clipIdx);
    final range = _ranges[clipIdx];
    final playing = _playingClip == clipIdx;
    final title = clip.titleOf(_speech!.sentences);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(22),
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () => _playClip(clipIdx),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      gradient:
                          playing
                              ? const LinearGradient(
                                colors: [Color(0xFF2ECC8B), Color(0xFF26B69F)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              )
                              : null,
                      color:
                          playing ? null : Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        range == null
                            ? '片段 ${clipIdx + 1} · ${clip.durationLabel}'
                            : '片段 ${clipIdx + 1} · 已选第 ${clip.startIndex + range[0] + 1}~${clip.startIndex + range[1] + 1} 句',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color:
                              range == null
                                  ? Colors.white.withValues(alpha: 0.55)
                                  : AppColors.correct,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap:
                      () => setState(() {
                        if (!expanded) {
                          _expanded.add(clipIdx);
                        } else {
                          _expanded.remove(clipIdx);
                        }
                      }),
                  child: Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),

            // ── 展开：全部句子 + 范围选择 + 复述入口 ──
            if (expanded) ...[
              const SizedBox(height: 10),
              const Divider(height: 1, color: Color(0x22FFFFFF)),
              const SizedBox(height: 8),
              for (
                var local = 0;
                local <= clip.endIndex - clip.startIndex;
                local++
              )
                _sentenceRow(clipIdx, clip.startIndex + local, local),
              if (range != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 36),
                    ),
                    icon: const Icon(Icons.undo_rounded, size: 17),
                    label: const Text('恢复整段', style: TextStyle(fontSize: 13)),
                    onPressed: () => _resetRange(clipIdx),
                  ),
                ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.mic_rounded, size: 20),
                  label: const Text('开始复述本段'),
                  onPressed: () => _enterRetell(clipIdx),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 展开态的句子行（带范围高亮与 起/止 角标）
  Widget _sentenceRow(int clipIdx, int global, int local) {
    final s = _speech!.sentences[global];
    final range = _ranges[clipIdx];
    final selected = range != null && local >= range[0] && local <= range[1];
    final isStart = selected && range[0] == local;
    final isEnd = selected && range[1] == local;

    return GestureDetector(
      onTap: () => _pickSentence(clipIdx, local),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color:
              selected
                  ? AppColors.primary.withValues(alpha: 0.22)
                  : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color:
                selected
                    ? AppColors.primary.withValues(alpha: 0.7)
                    : const Color(0x18FFFFFF),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${global + 1}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.45),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TappableText(
                    s.english,
                    style: const TextStyle(fontSize: 14.5, height: 1.4),
                  ),
                ),
                if (isStart) _tag('起'),
                if (isStart && isEnd) const SizedBox(width: 4),
                if (isEnd) _tag('止'),
              ],
            ),
            if (s.chinese.isNotEmpty) ...[
              const SizedBox(height: 3),
              Padding(
                padding: const EdgeInsets.only(left: 22),
                child: Text(
                  s.chinese,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tag(String t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.correct,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        t,
        style: const TextStyle(
          fontSize: 10.5,
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  // ── 录音视图 ─────────────────────────────────────────────────

  Widget _recordingView() {
    final clip = _speech!.clips[_activeClip];
    final maxSeconds = SettingsScope.of(context)?.retellMaxSeconds ?? 90;
    final elapsed = DateTime.now().difference(_recordStart);
    final remain = maxSeconds - elapsed.inSeconds;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _isFullClip
                ? '片段 ${_activeClip + 1}'
                : '片段 ${_activeClip + 1} · 已选第 ${_rangeStart + 1}~${_rangeEnd + 1} 句',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            clip.titleOf(_speech!.sentences),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(
                Icons.fiber_manual_record_rounded,
                color: AppColors.wrong,
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(
                _mmss(elapsed),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '最长 ${(maxSeconds / 60).toStringAsFixed(maxSeconds % 60 == 0 ? 0 : 1)} 分钟',
                style: TextStyle(
                  fontSize: 12,
                  color:
                      remain <= 10
                          ? AppColors.wrong
                          : Colors.white.withValues(alpha: 0.5),
                  fontWeight: remain <= 10 ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _waveform(),
          const SizedBox(height: 14),
          Expanded(
            child: LiquidGlass(
              borderRadius: BorderRadius.circular(20),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.subtitles_outlined,
                        size: 16,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '实时识别',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child:
                        _preparing
                            ? const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(),
                                  SizedBox(height: 12),
                                  Text(
                                    '正在准备离线识别模型…',
                                    style: TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            )
                            : SingleChildScrollView(
                              controller: _liveScroll,
                              child: Text(
                                _liveSpoken.isEmpty
                                    ? '请对着麦克风，用英语把这段的大意说出来…'
                                    : _liveSpoken,
                                style: TextStyle(
                                  fontSize: 15,
                                  height: 1.5,
                                  color:
                                      _liveSpoken.isEmpty
                                          ? Colors.white.withValues(alpha: 0.4)
                                          : Colors.white,
                                ),
                              ),
                            ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: _preparing ? null : () => _cancelRetell(),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.correct,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.check_rounded, size: 20),
                  label: const Text('完成复述'),
                  onPressed: _preparing ? null : () => _finishRetell(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 实时波形（最新在左，与跟读页一致）
  Widget _waveform() {
    final bars =
        _levels.isEmpty
            ? List<double>.filled(24, 0.04)
            : _levels.reversed.toList();
    return SizedBox(
      height: 42,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final v in bars)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: (0.08 + v * 0.92).clamp(0.08, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── 结果视图 ─────────────────────────────────────────────────

  Widget _resultView() {
    final r = _scoreResult!;
    final clip = _speech!.clips[_activeClip];
    final Color tone;
    final String comment;
    if (r.total == 0) {
      tone = AppColors.primary;
      comment = '所选范围没有配置要点，可对照下方识别原文自查。';
    } else if (r.score >= 80) {
      tone = AppColors.correct;
      comment = '要点覆盖完整，很棒！';
    } else if (r.score >= 50) {
      tone = AppColors.primary;
      comment = '抓住了主要意思，再补全细节。';
    } else {
      tone = AppColors.wrong;
      comment = '先对照参考大意，再试一次。';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        children: [
          LiquidGlass(
            borderRadius: BorderRadius.circular(22),
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                SizedBox(
                  width: 72,
                  height: 72,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 72,
                        height: 72,
                        child: CircularProgressIndicator(
                          value: r.score / 100,
                          strokeWidth: 7,
                          backgroundColor: Colors.white.withValues(alpha: 0.1),
                          valueColor: AlwaysStoppedAnimation(tone),
                        ),
                      ),
                      Text(
                        '${r.score}',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '要点覆盖率',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        r.total == 0
                            ? '所选范围没有要点'
                            : '覆盖 ${r.covered}/${r.total} 个要点',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        comment,
                        style: TextStyle(fontSize: 13, color: tone),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              controller: _resultScroll,
              children: [
                // 参考大意
                LiquidGlass(
                  borderRadius: BorderRadius.circular(20),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.translate_rounded, size: 17),
                          const SizedBox(width: 6),
                          Text(
                            '参考大意',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _referenceText(clip),
                        style: const TextStyle(fontSize: 14.5, height: 1.55),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 要点命中清单（所选范围没有要点时不显示该卡）
                if (r.results.isNotEmpty)
                  LiquidGlass(
                    borderRadius: BorderRadius.circular(20),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '要点覆盖明细',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.6),
                          ),
                        ),
                        const SizedBox(height: 6),
                        for (final kp in r.results) _kpRow(kp),
                      ],
                    ),
                  ),
                if (r.results.isNotEmpty) const SizedBox(height: 12),
                // 识别原文
                LiquidGlass(
                  borderRadius: BorderRadius.circular(20),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.record_voice_over_rounded,
                            size: 17,
                            color: Colors.white.withValues(alpha: 0.6),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '你的复述（识别原文）',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _liveSpoken.isEmpty ? '（未识别到语音内容）' : _liveSpoken,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.55,
                          color:
                              _liveSpoken.isEmpty
                                  ? Colors.white.withValues(alpha: 0.4)
                                  : Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 19),
                  label: const Text('再复述一次'),
                  onPressed: () => _enterRetell(_activeClip),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => setState(() => _stage = _Stage.list),
                  child: const Text('返回片段列表'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 结果页单个要点行（命中绿/未命中灰）
  Widget _kpRow(KeyPointResult kp) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            kp.covered
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 19,
            color: kp.covered ? AppColors.correct : AppColors.unread,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  kp.point.phrase,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.35,
                    color: kp.covered ? Colors.white : AppColors.unread,
                    fontWeight: kp.covered ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
                if (kp.covered && kp.matched != kp.point.phrase)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '说到：${kp.matched!}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.correct.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 工具 ─────────────────────────────────────────────────────

  /// 本次训练范围对应的参考大意：
  /// 整段 → 数据中的整段 summary；子范围 → 所选句子的中文对照拼接。
  String _referenceText(RetellClip clip) {
    if (_isFullClip) return clip.summary ?? '（暂无参考大意）';
    final parts = <String>[];
    for (var g = _rangeStart; g <= _rangeEnd; g++) {
      final t = _speech!.sentences[g].chinese.trim();
      if (t.isNotEmpty) parts.add(t);
    }
    return parts.isEmpty ? '（所选句子暂无中文对照）' : parts.join(' ');
  }

  String _mmss(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// 评分中面板
class _ScoringPanel extends StatelessWidget {
  const _ScoringPanel();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 14),
          Text('正在识别与评分…', style: TextStyle(fontSize: 14)),
        ],
      ),
    );
  }
}
