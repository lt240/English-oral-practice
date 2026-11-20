import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/ambient_background.dart';
import '../../core/widgets/dictionary_popup.dart';
import '../../core/widgets/liquid_glass.dart';
import '../../core/widgets/tappable_text.dart';
import '../../data/speech_library.dart';
import '../../services/aligner.dart';
import '../../services/asr/model_installer.dart';
import '../../services/asr/text_normalizer.dart';
import '../../services/db/app_database.dart';
import '../../services/settings_controller.dart';
import '../../services/shadowing_recorder.dart';
import '../../core/theme/app_surface.dart';

/// 训练状态机
enum Phase {
  idle, // 空闲（连续聆听模式）
  playingOriginal, // 播放原声
  waitingUser, // 等待用户开口
  recording, // 录音中
  scoring, // 识别评分中
  showResult, // 展示结果
  wordDrill, // 错词专项
}

/// 跟读详情页：字幕自动跟随 + 跟读训练状态机
class ShadowingDetailPage extends StatefulWidget {
  const ShadowingDetailPage({
    super.key,
    required this.speech,
    this.initialIndex = 0,
    this.onSwitchMode,
  });

  final SpeechEntry speech;
  final int initialIndex;

  /// 由模式宿主页注入：返回模式选择页；null（如从复习页直达）时不显示入口
  final VoidCallback? onSwitchMode;

  @override
  State<ShadowingDetailPage> createState() => _ShadowingDetailPageState();
}

class _ShadowingDetailPageState extends State<ShadowingDetailPage> {
  SpeechEntry? _speech;
  bool _ready = false;

  final AudioPlayer _player = AudioPlayer();
  final ShadowingRecorder _recorder = ShadowingRecorder();
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _itemKeys = {};

  int _index = 0;
  Phase _phase = Phase.idle;

  // 结果数据
  List<AlignedWord> _aligned = [];
  String _recognized = '';
  int _score = 0;
  int _nCorrect = 0, _nWrong = 0, _nMissed = 0, _nExtra = 0;
  List<String> _wrongWords = [];
  List<String> _missedWords = [];
  RecognitionQuality? _quality;
  String _hint = '';

  // 流程计数
  int _playsLeft = 0;
  int _attempts = 0;
  int _drillAttempts = 0;
  List<String> _drillWords = [];
  bool _lastDrill = false;
  String _recordingTarget = '';

  /// 录音实时反馈：累积识别文本 + 逐词对齐（读到哪亮到哪）
  String _liveSpoken = '';
  List<AlignedWord> _liveAligned = [];
  bool _finalized = false;

  // 波形
  final List<double> _levels = [];

  StreamSubscription<Duration>? _posSub;
  Timer? _autoTimer;
  int _autoToken = 0;

  TranscriptSentence get _sentence => _speech!.sentences[_index];
  SettingsController get _settings => SettingsScope.of(context)!;

  GlobalKey _keyFor(int i) => _itemKeys.putIfAbsent(i, () => GlobalKey());

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final effective = widget.speech.ensureTimestamps();
    _speech = effective;
    _index =
        effective.sentences.isEmpty
            ? 0
            : widget.initialIndex.clamp(0, effective.sentences.length - 1);

    final path = effective.audioPath;
    if (path != null && path.isNotEmpty) {
      await _player.setAsset(path);
      if (mounted) await _player.setSpeed(_settings.rate);
    }
    _posSub = _player.positionStream.listen(_onPosition);

    if (mounted) setState(() => _ready = true);
  }

  // ─────────────────────────────────────────────────────────
  // 模块二：位置流 → 自动推进 / 自动高亮
  // ─────────────────────────────────────────────────────────
  void _onPosition(Duration pos) {
    if (!mounted || _speech == null) return;
    final sec = pos.inMilliseconds / 1000.0;

    if (_phase == Phase.playingOriginal) {
      if (sec >= _sentence.end - 0.03) {
        _player.pause();
        _onOriginalFinished();
      }
      return;
    }

    if (_phase == Phase.idle && _player.playing) {
      var idx = 0;
      for (var i = 0; i < _speech!.sentences.length; i++) {
        if (_speech!.sentences[i].start <= sec + 0.02) {
          idx = i;
        } else {
          break;
        }
      }
      if (idx != _index) {
        setState(() => _index = idx);
        _scrollTo(idx);
      }
    }
  }

  Future<void> _scrollTo(int i) async {
    await Future<void>.delayed(const Duration(milliseconds: 70));
    final ctx = _itemKeys[i]?.currentContext;
    if (ctx != null && ctx.mounted && mounted) {
      await Scrollable.ensureVisible(
        ctx,
        alignment: 0.25,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 顶部播放器：连续聆听模式 开/关
  Future<void> _toggleContinuous() async {
    if (_phase == Phase.idle && _player.playing) {
      await _player.pause();
      if (mounted) setState(() {});
      return;
    }
    await _exitToIdle();
    if (_player.position >= (_player.duration ?? Duration.zero)) {
      await _player.seek(Duration.zero);
    }
    await _player.setSpeed(_settings.rate);
    await _player.play();
    if (mounted) setState(() {});
  }

  Future<void> _exitToIdle() async {
    _cancelAuto();
    if (_recorder.isBusy) await _recorder.stop();
    if (mounted) setState(() => _phase = Phase.idle);
  }

  /// 点句卡：跳转并连续播放
  Future<void> _jumpToSentence(int i) async {
    await _exitToIdle();
    setState(() => _index = i);
    await _player.seek(
      Duration(milliseconds: (_speech!.sentences[i].start * 1000).round()),
    );
    await _player.setSpeed(_settings.rate);
    await _player.play();
  }

  // ─────────────────────────────────────────────────────────
  // 模块三：训练状态机
  // ─────────────────────────────────────────────────────────
  Future<void> _startTraining() async {
    _cancelAuto();
    _attempts = 0;
    _drillWords = [];
    _drillAttempts = 0;
    _lastDrill = false;
    final plays = _settings.originalPlays;
    if (plays == 0) {
      _enterWaiting();
      return;
    }
    _playsLeft = plays;
    await _playOriginal();
  }

  Future<void> _playOriginal() async {
    if (mounted) setState(() => _phase = Phase.playingOriginal);
    await _player.setSpeed(_settings.rate);
    await _player.seek(
      Duration(milliseconds: (_sentence.start * 1000).round()),
    );
    await _player.play();
  }

  Future<void> _onOriginalFinished() async {
    _playsLeft -= 1;
    if (_playsLeft > 0) {
      await _playOriginal();
      return;
    }
    await _enterWaiting();
  }

  Future<void> _skipOriginal() async {
    await _player.pause();
    await _enterWaiting();
  }

  Future<void> _enterWaiting() async {
    await HapticFeedback.mediumImpact();
    if (mounted) setState(() => _phase = Phase.waitingUser);
    if (_settings.autoAdvance) await _startRecording();
  }

  Future<void> _startRecording({List<String>? drill}) async {
    _finalized = false;
    _levels.clear();
    _liveSpoken = '';
    _recordingTarget = drill != null ? drill.join(' ') : _sentence.english;
    // 未开口时目标句全部显示为灰色（未读到）
    _liveAligned = [
      for (final w in WordAligner.tokenize(_recordingTarget))
        AlignedWord(reference: w, verdict: WordVerdict.missed),
    ];
    if (mounted) setState(() => _phase = Phase.recording);

    // 模型智能化：用户开启精准档且 base.en 文件齐全时才切换，否则安全回退
    var tier = _settings.accurateAsr ? AsrTier.base : AsrTier.tiny;
    if (tier == AsrTier.base && !await ModelInstaller().isReady(AsrTier.base)) {
      tier = AsrTier.tiny;
    }

    try {
      await _recorder.start(
        tier: tier,
        silenceDuration: _settings.vadAutoStop ? 0.8 : 20,
        stopAfterSegment: _settings.vadAutoStop,
        maxDuration: const Duration(seconds: 30),
        onMaxDuration: () {
          unawaited(_manualStopRecording());
        },
        onAmplitude: (level) {
          if (!mounted) return;
          setState(() {
            _levels.add(level);
            if (_levels.length > 46) _levels.removeAt(0);
          });
        },
        onAutoStop: () async {
          await _recorder.stop();
          await _finalizeScoring();
        },
        onSegment: _onLiveSegment,
      );
    } on MissingModelException catch (e) {
      if (mounted) {
        setState(
          () =>
              _phase =
                  _drillWords.isNotEmpty ? Phase.wordDrill : Phase.waitingUser,
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _phase =
                  _drillWords.isNotEmpty ? Phase.wordDrill : Phase.waitingUser,
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('录音启动失败：$e')));
      }
    }
  }

  Future<void> _manualStopRecording() async {
    await _recorder.stop(); // stop 会 flush 尾句 → _onLiveSegment
    if (!mounted) return;
    if (_phase == Phase.recording) {
      if (_liveSpoken.trim().isNotEmpty) {
        await _finalizeScoring();
      } else {
        // 完全没识别到内容：不写 0 分垃圾记录，退回等待/错词专项
        setState(
          () =>
              _phase =
                  _drillWords.isNotEmpty && _drillAttempts > 0
                      ? Phase.wordDrill
                      : Phase.waitingUser,
        );
      }
    }
  }

  /// 录音中：每个 VAD 段识别结果追加到累积文本，实时刷新逐词颜色
  void _onLiveSegment(RecognizedSegment seg) {
    if (!mounted || _phase != Phase.recording || _finalized) return;
    final t = seg.text.trim();
    if (t.isEmpty) return;
    _liveSpoken = _liveSpoken.isEmpty ? t : '$_liveSpoken $t';
    setState(() {
      _liveAligned = WordAligner.alignSentence(
        reference: _recordingTarget,
        recognized: _liveSpoken,
        fuzzy: _settings.fuzzyHomophones,
      );
    });
  }

  /// 录音结束：用累积识别文本做最终评分
  Future<void> _finalizeScoring() async {
    if (_finalized) return;
    _finalized = true;
    if (mounted) setState(() => _phase = Phase.scoring);
    // 让 scoring 界面先绘制
    await Future<void>.delayed(const Duration(milliseconds: 90));
    if (!mounted) return;

    final fuzzy = _settings.fuzzyHomophones;
    final aligned = WordAligner.alignSentence(
      reference: _recordingTarget,
      recognized: _liveSpoken,
      fuzzy: fuzzy,
    );
    final total = WordAligner.tokenize(_recordingTarget).length;
    var c = 0, w = 0, ms = 0, ex = 0;
    final wrongList = <String>[], missedList = <String>[];
    for (final a in aligned) {
      switch (a.verdict) {
        case WordVerdict.correct:
          c++;
        case WordVerdict.wrong:
          w++;
          if (a.reference != null) wrongList.add(a.reference!);
        case WordVerdict.missed:
          ms++;
          if (a.reference != null) missedList.add(a.reference!);
        case WordVerdict.extra:
          ex++;
      }
    }

    final score = total == 0 ? 0 : (c * 100 / total).round();
    final isDrill = _drillWords.isNotEmpty && _drillAttempts > 0;
    _lastDrill = isDrill;
    final quality = TextNormalizer.assess(_liveSpoken, total);
    var hint = '';
    for (final a in aligned) {
      if (a.verdict != WordVerdict.wrong) continue;
      final h = WordAligner.hintFor(a);
      if (h != null) {
        hint = h;
        break;
      }
    }

    setState(() {
      _quality = quality;
      _hint = hint;
      _aligned = aligned;
      _recognized = _liveSpoken;
      _score = score;
      _nCorrect = c;
      _nWrong = w;
      _nMissed = ms;
      _nExtra = ex;
      _wrongWords = wrongList;
      _missedWords = missedList;
      _phase = Phase.showResult;
    });

    final errors = w + ms;
    if (isDrill) {
      await _persistAttempt(
        score,
        total,
        c,
        w,
        ms,
        ex,
        wrongList,
        review: errors > 0 && _drillAttempts >= 3,
      );
      await _afterDrill(errors);
      return;
    }

    await _persistAttempt(
      score,
      total,
      c,
      w,
      ms,
      ex,
      wrongList,
      review:
          errors > 0 &&
          _settings.repeatMode == RepeatMode.sentence &&
          _attempts + 1 >= 3,
    );
    await _afterSentence(score, errors);
  }

  Future<void> _persistAttempt(
    int score,
    int total,
    int c,
    int w,
    int ms,
    int ex,
    List<String> wrongList, {
    required bool review,
  }) async {
    await AppDatabase.instance.insertAttempt({
      'speech_id': _speech!.id,
      'sentence_index': _index,
      'practiced_at': DateTime.now().millisecondsSinceEpoch,
      'score': score,
      'total': total,
      'correct': c,
      'wrong': w,
      'missed': ms,
      'extra': ex,
      'wrong_words': jsonEncode(wrongList),
      'repeat_count': _attempts,
      'needs_review': review ? 1 : 0,
    });

    // P1-3：按本次分数用 SM-2 排下一次复习
    await AppDatabase.instance.upsertReviewCard(_speech!.id, _index, score);

    // P1-2：错词自动沉淀进生词本（带来源原句，便于语境复习）
    final context =
        _index < _speech!.sentences.length
            ? _speech!.sentences[_index].english
            : '';
    for (final w in wrongList.take(5)) {
      await AppDatabase.instance.addVocab(
        word: w,
        sourceSentence: context,
        speechId: _speech!.id,
      );
    }

    // P1-4：记录断点，下次进入直接回到这一句
    await AppDatabase.instance.saveProgress(_speech!.id, _index);
  }

  /// 整句结果后的分支决策（含自动推进）
  Future<void> _afterSentence(int score, int errors) async {
    final mode = _settings.repeatMode;

    if (errors == 0 || mode == RepeatMode.off) {
      if (errors == 0) {
        await AppDatabase.instance.resolveReview(_speech!.id, _index);
      }
      _waitForManualNext();
      return;
    }

    if (mode == RepeatMode.sentence) {
      _attempts += 1;
      if (_attempts >= 3) {
        // 已落库为 needs_review
        _waitForManualNext();
        return;
      }
      _scheduleAuto(_repeatCurrentSentence);
      return;
    }

    if (mode == RepeatMode.words) {
      final drill = [..._wrongWords, ..._missedWords];
      if (drill.isEmpty) {
        _waitForManualNext();
        return;
      }
      _drillAttempts = 0;
      _scheduleAuto(() => _startDrill(drill));
    }
  }

  Future<void> _repeatCurrentSentence() async {
    if (!mounted) return;
    _finalized = false;
    await _startRecording();
  }

  /// 进入错词专项（展示待练词；自动推进时直接开录）
  Future<void> _startDrill(List<String> words) async {
    if (!mounted) return;
    setState(() {
      _drillWords = words;
      _drillAttempts += 1;
      _phase = Phase.wordDrill;
    });
    if (_settings.autoAdvance) await _beginDrillTake();
  }

  /// 错词专项：正式开口录一遍
  Future<void> _beginDrillTake() => _startRecording(drill: _drillWords);

  Future<void> _afterDrill(int errors) async {
    if (errors == 0) {
      await AppDatabase.instance.resolveReview(_speech!.id, _index);
      _drillAttempts = 0;
      _drillWords = [];
      _waitForManualNext();
      return;
    }
    if (_drillAttempts >= 3) {
      _drillAttempts = 0;
      _drillWords = [];
      _waitForManualNext();
      return;
    }
    _scheduleAuto(() => _startDrill([..._wrongWords, ..._missedWords]));
  }

  Future<void> _nextSentence() async {
    _cancelAuto();
    if (_index >= _speech!.sentences.length - 1) {
      if (mounted) {
        setState(() => _phase = Phase.idle);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('本篇已完成 🎉')));
      }
      return;
    }
    setState(() {
      _index += 1;
      _attempts = 0;
      _aligned = [];
    });
    _scrollTo(_index);
    await AppDatabase.instance.saveProgress(_speech!.id, _index);
    await _startTraining();
  }

  /// 留在结果页，由用户手动点「下一句/完成本篇」，不自动进入下一个句子
  void _waitForManualNext() {
    _cancelAuto();
  }

  void _scheduleAuto(VoidCallback action) {
    _cancelAuto();
    if (!_settings.autoAdvance) return;
    final token = ++_autoToken;
    _autoTimer = Timer(const Duration(milliseconds: 1500), () {
      if (token == _autoToken) action();
    });
  }

  void _cancelAuto() {
    _autoTimer?.cancel();
    _autoTimer = null;
  }

  @override
  void dispose() {
    _cancelAuto();
    _posSub?.cancel();
    _scroll.dispose();
    _player.dispose();
    _recorder.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────
  // 界面
  // ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            widget.speech.title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (widget.onSwitchMode != null)
              IconButton(
                tooltip: '切换模式',
                icon: const Icon(Icons.swap_horiz_rounded, size: 22),
                onPressed: _ready ? widget.onSwitchMode : null,
              ),
            IconButton(
              tooltip: '练习设置',
              icon: const Icon(Icons.tune_rounded, size: 21),
              onPressed: _ready ? _openPracticeSettings : null,
            ),
          ],
        ),
        body:
            !_ready
                ? const Center(child: CircularProgressIndicator())
                : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
                    child: Column(
                      children: [
                        _playerBar(),
                        const SizedBox(height: 12),
                        Expanded(child: _sentenceList()),
                        const SizedBox(height: 12),
                        _trainingPanel(),
                      ],
                    ),
                  ),
                ),
      ),
    );
  }

  // ── 顶部播放器 ───────────────────────────────────────────
  Widget _playerBar() {
    final dur = _player.duration ?? Duration.zero;
    final continuousPlaying = _phase == Phase.idle && _player.playing;

    return LiquidGlass(
      borderRadius: const BorderRadius.all(Radius.circular(18)),
      padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
      child: Row(
        children: [
          GestureDetector(
            onTap: _toggleContinuous,
            child: Icon(
              continuousPlaying
                  ? Icons.pause_circle_filled_rounded
                  : Icons.play_circle_filled_rounded,
              size: 34,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () async {
              final next = await _settings.cycleSpeed();
              await _player.setSpeed(next);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: Colors.white.withValues(alpha: 0.14),
              ),
              child: Text(
                '${_settings.rate}x',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<Duration>(
              stream: _player.positionStream,
              initialData: _player.position,
              builder: (context, snapshot) {
                final pos = snapshot.data ?? Duration.zero;
                final maxMs = dur.inMilliseconds.toDouble();
                final value =
                    maxMs <= 0
                        ? 0.0
                        : pos.inMilliseconds.toDouble().clamp(0.0, maxMs);
                return Row(
                  children: [
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                        ),
                        child: Slider(
                          value: value,
                          max: maxMs <= 0 ? 1 : maxMs,
                          onChanged: (v) async {
                            await _exitToIdle();
                            await _player.seek(
                              Duration(milliseconds: v.round()),
                            );
                          },
                        ),
                      ),
                    ),
                    Text(
                      _fmt(pos),
                      style: TextStyle(
                        fontSize: 11,
                        color: AppSurface.textTertiary(context),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── 句子列表 ─────────────────────────────────────────────
  Widget _sentenceList() {
    final count = _speech!.sentences.length;
    return ListView.builder(
      controller: _scroll,
      itemCount: count,
      padding: const EdgeInsets.only(bottom: 8),
      itemBuilder: (context, i) {
        final s = _speech!.sentences[i];
        final current = i == _index;
        return Padding(
          key: _keyFor(i),
          padding: const EdgeInsets.only(bottom: 10),
          child: GestureDetector(
            onTap: () => _jumpToSentence(i),
            child: LiquidGlass(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          current
                              ? AppColors.primary.withValues(alpha: 0.85)
                              : Colors.white.withValues(alpha: 0.12),
                    ),
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontSize: 11,
                        color:
                            current
                                ? Colors.white
                                : AppSurface.textTertiary(context),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TappableText(
                          s.english,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.4,
                            fontWeight:
                                current ? FontWeight.w400 : FontWeight.w300,
                            color:
                                current
                                    ? AppSurface.textPrimary(context)
                                    : AppSurface.textSecondary(context),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          s.chinese,
                          style: TextStyle(
                            fontSize: 12,
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
      },
    );
  }

  // ── 训练面板（按状态切换）────────────────────────────────
  Widget _trainingPanel() {
    return LiquidGlass(
      borderRadius: const BorderRadius.all(Radius.circular(22)),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: SingleChildScrollView(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          child: Container(key: ValueKey(_phase), child: _panelContent()),
        ),
      ),
    );
  }

  Widget _panelContent() {
    switch (_phase) {
      case Phase.idle:
        return Column(
          children: [
            Text(
              '从第 ${_index + 1} 句开始跟读训练',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              '原声播放后，请对着手机朗读原句',
              style: TextStyle(
                fontSize: 12.5,
                color: AppSurface.textTertiary(context),
              ),
            ),
            const SizedBox(height: 12),
            _panelButton(Icons.play_arrow_rounded, '开始跟读', _startTraining),
          ],
        );

      case Phase.playingOriginal:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(width: 14),
            Text('原声播放中（第 ${_settings.originalPlays - _playsLeft + 1} 遍）'),
            const SizedBox(width: 14),
            TextButton(onPressed: _skipOriginal, child: const Text('跳过')),
          ],
        );

      case Phase.waitingUser:
        return Column(
          children: [
            const Text(
              '🎤 该你读了',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w400),
            ),
            const SizedBox(height: 4),
            Text(
              '清晰朗读屏幕上的句子',
              style: TextStyle(
                fontSize: 12.5,
                color: AppSurface.textTertiary(context),
              ),
            ),
            const SizedBox(height: 12),
            _panelButton(Icons.mic_rounded, '开始录音', () => _startRecording()),
          ],
        );

      case Phase.recording:
        return Column(
          children: [
            // 目标句逐词实时变色：绿=读对 红=读错 灰=还没读到 橙=多读
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 100),
              child: SingleChildScrollView(child: _liveWordsView()),
            ),
            const SizedBox(height: 10),
            _waveform(),
            const SizedBox(height: 10),
            if (_settings.vadAutoStop)
              Text(
                '读完停顿约 0.7 秒自动结束，也可手动结束',
                style: TextStyle(
                  fontSize: 12,
                  color: AppSurface.textTertiary(context),
                ),
              )
            else
              const SizedBox.shrink(),
            const SizedBox(height: 8),
            _panelButton(
              Icons.stop_rounded,
              '结束录音并评分',
              _manualStopRecording,
              danger: true,
            ),
          ],
        );

      case Phase.scoring:
        return const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            SizedBox(width: 14),
            Text('正在识别与评分…'),
          ],
        );

      case Phase.showResult:
        return _resultPanel();

      case Phase.wordDrill:
        return _drillPanel();
    }
  }

  // ── 结果面板 ─────────────────────────────────────────────
  Widget _resultPanel() {
    final color =
        _score >= 80
            ? AppColors.correct
            : _score >= 50
            ? AppColors.primary
            : AppColors.wrong;

    final forcedSentence =
        _settings.repeatMode == RepeatMode.sentence &&
        _nWrong + _nMissed > 0 &&
        _attempts > 0 &&
        _attempts < 3;
    final label =
        forcedSentence
            ? '再读一遍（第 $_attempts/3 次）'
            : (_index >= _speech!.sentences.length - 1 ? '完成本篇' : '下一句');
    final action = forcedSentence ? _repeatCurrentSentence : _nextSentence;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _ScoreRing(score: _score, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                '读对 $_nCorrect · 读错 $_nWrong · 漏读 $_nMissed · 多读 $_nExtra',
                style: const TextStyle(fontSize: 13.5, height: 1.4),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _alignedWordsView(),
        if (_wrongWords.isNotEmpty || _missedWords.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final w in _wrongWords) _wordChip(w, AppColors.wrong),
              for (final w in _missedWords) _wordChip(w, AppColors.unread),
            ],
          ),
        ],
        const SizedBox(height: 6),
        Text(
          '识别：${_recognized.isEmpty ? '（未识别到内容）' : _recognized}',
          style: TextStyle(
            fontSize: 11.5,
            color: AppSurface.textTertiary(context),
          ),
        ),
        if (_quality != null) ...[
          const SizedBox(height: 5),
          Row(
            children: [
              Icon(
                _quality!.score >= 0.8
                    ? Icons.verified_outlined
                    : Icons.info_outline_rounded,
                size: 13,
                color:
                    _quality!.score >= 0.8
                        ? AppColors.correct
                        : AppColors.missed,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '${_quality!.label}${_quality!.hint.isEmpty ? '' : ' · ${_quality!.hint}'}',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppSurface.textTertiary(context),
                  ),
                ),
              ),
            ],
          ),
        ],
        if (_hint.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            '发音提示：$_hint',
            style: const TextStyle(fontSize: 11.5, color: AppColors.missed),
          ),
        ],
        const SizedBox(height: 12),
        if (_lastDrill)
          Row(
            children: [
              if (_nWrong + _nMissed > 0 && _drillAttempts < 3) ...[
                Expanded(
                  child: _panelButton(
                    Icons.refresh_rounded,
                    '再练错词',
                    () => _startDrill([..._wrongWords, ..._missedWords]),
                    outlined: true,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: _panelButton(
                  Icons.arrow_forward_rounded,
                  _index >= _speech!.sentences.length - 1 ? '完成本篇' : '下一句',
                  _nextSentence,
                ),
              ),
            ],
          )
        else
          Row(
            children: [
              Expanded(
                child: _panelButton(
                  Icons.refresh_rounded,
                  '重读',
                  _repeatCurrentSentence,
                  outlined: true,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _panelButton(Icons.arrow_forward_rounded, label, action),
              ),
            ],
          ),
      ],
    );
  }

  /// 原文逐词按状态上色：绿=读对 红=读错 灰删除线=漏读 橙=多读
  Widget _alignedWordsView() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final a in _aligned)
          GestureDetector(
            onTap:
                () => DictionaryPopup.show(
                  context,
                  (a.reference ?? a.spoken ?? '').trim(),
                  contextSentence: _sentence.english,
                ),
            child: Text(
              (a.reference ?? a.spoken ?? '').trim(),
              style: TextStyle(
                fontSize: 15,
                height: 1.3,
                fontWeight:
                    a.verdict == WordVerdict.correct
                        ? FontWeight.w300
                        : FontWeight.w400,
                color: _verdictColor(a.verdict),
                decoration:
                    a.verdict == WordVerdict.missed
                        ? TextDecoration.lineThrough
                        : null,
                decorationColor: AppColors.unread,
              ),
            ),
          ),
      ],
    );
  }

  Color _verdictColor(WordVerdict verdict) {
    switch (verdict) {
      case WordVerdict.correct:
        return AppColors.correct;
      case WordVerdict.wrong:
        return AppColors.wrong;
      case WordVerdict.missed:
        return AppColors.unread;
      case WordVerdict.extra:
        return AppColors.missed;
    }
  }

  /// 录音中目标句逐词实时上色（missed=还没读到，用暗灰普通字，不加删除线）
  Widget _liveWordsView() {
    return Wrap(
      spacing: 5,
      runSpacing: 6,
      children: [
        for (final a in _liveAligned)
          GestureDetector(
            onTap:
                () => DictionaryPopup.show(
                  context,
                  (a.reference ?? a.spoken ?? '').trim(),
                  contextSentence: _sentence.english,
                ),
            child: Text(
              (a.reference ?? a.spoken ?? '').trim(),
              style: TextStyle(
                fontSize: 14.5,
                height: 1.3,
                fontWeight:
                    a.verdict == WordVerdict.missed
                        ? FontWeight.w400
                        : FontWeight.w700,
                color: _verdictColor(
                  a.verdict,
                ).withValues(alpha: a.verdict == WordVerdict.missed ? 0.55 : 1),
              ),
            ),
          ),
      ],
    );
  }

  // ── 错词专项面板 ─────────────────────────────────────────
  Widget _drillPanel() {
    final busy = _recorder.isBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '只练错词',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final w in _drillWords) _wordChip(w, AppColors.primary),
          ],
        ),
        const SizedBox(height: 12),
        if (busy) ...[
          _waveform(),
          const SizedBox(height: 12),
          if (_settings.vadAutoStop)
            Text(
              '读完停顿约 0.7 秒自动结束，也可手动结束',
              style: TextStyle(
                fontSize: 12,
                color: AppSurface.textTertiary(context),
              ),
            ),
          const SizedBox(height: 8),
          _panelButton(
            Icons.stop_rounded,
            '结束录音并评分',
            _manualStopRecording,
            danger: true,
          ),
        ] else
          _panelButton(
            Icons.mic_rounded,
            '朗读这些词（$_drillAttempts/3）',
            _beginDrillTake,
          ),
      ],
    );
  }

  // ── 小组件 ───────────────────────────────────────────────
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

  Widget _wordChip(String text, Color color) {
    return GestureDetector(
      onTap:
          () => DictionaryPopup.show(
            context,
            text,
            contextSentence: _sentence.english,
          ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: color.withValues(alpha: 0.16),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Text(text, style: TextStyle(fontSize: 12.5, color: color)),
      ),
    );
  }

  Widget _panelButton(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool outlined = false,
    bool danger = false,
  }) {
    final color = danger ? AppColors.wrong : AppColors.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color:
              outlined
                  ? Colors.white.withValues(alpha: 0.12)
                  : color.withValues(alpha: 0.88),
          border:
              outlined
                  ? Border.all(
                    color: AppSurface.textTertiary(
                      context,
                    ).withValues(alpha: 0.4),
                  )
                  : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 19,
              color: outlined ? AppSurface.textPrimary(context) : Colors.white,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color:
                    outlined ? AppSurface.textPrimary(context) : Colors.white,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── 练习设置弹层 ─────────────────────────────────────────
  Future<void> _openPracticeSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            final s = _settings;
            Widget section(String title, Widget child) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppSurface.textTertiary(context),
                    ),
                  ),
                  const SizedBox(height: 8),
                  child,
                ],
              );
            }

            Widget option(String label, bool selected, VoidCallback onTap) {
              return GestureDetector(
                onTap: () {
                  onTap();
                  setSheet(() {});
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color:
                        selected
                            ? AppColors.primary.withValues(alpha: 0.8)
                            : Colors.white.withValues(alpha: 0.1),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color:
                          selected
                              ? Colors.white
                              : AppSurface.textSecondary(context),
                    ),
                  ),
                ),
              );
            }

            Widget rowWrap(List<Widget> children) {
              return Wrap(spacing: 8, runSpacing: 8, children: children);
            }

            Widget toggle(String label, bool value, ValueChanged<bool> onSet) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(label, style: const TextStyle(fontSize: 14)),
                  Switch(
                    value: value,
                    onChanged: (v) {
                      onSet(v);
                      setSheet(() {});
                    },
                  ),
                ],
              );
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: LiquidGlass(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '练习设置',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 18),
                    section(
                      '原声播放次数',
                      rowWrap([
                        option(
                          '不播',
                          s.originalPlays == 0,
                          () => s.setOriginalPlays(0),
                        ),
                        option(
                          '1 遍',
                          s.originalPlays == 1,
                          () => s.setOriginalPlays(1),
                        ),
                        option(
                          '2 遍',
                          s.originalPlays == 2,
                          () => s.setOriginalPlays(2),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 16),
                    section(
                      '播放 / 录音语速',
                      rowWrap([
                        for (final v in SettingsController.speedSteps)
                          option('$v', s.rate == v, () async {
                            await s.setRate(v);
                            await _player.setSpeed(v);
                          }),
                      ]),
                    ),
                    const SizedBox(height: 16),
                    section(
                      '读错后是否重读',
                      rowWrap([
                        option(
                          '关闭',
                          s.repeatMode == RepeatMode.off,
                          () => s.setRepeatMode(RepeatMode.off),
                        ),
                        option(
                          '重读整句',
                          s.repeatMode == RepeatMode.sentence,
                          () => s.setRepeatMode(RepeatMode.sentence),
                        ),
                        option(
                          '只练错词',
                          s.repeatMode == RepeatMode.words,
                          () => s.setRepeatMode(RepeatMode.words),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    toggle('自动推进流程', s.autoAdvance, s.setAutoAdvance),
                    toggle('静音自动停止录音', s.vadAutoStop, s.setVadAutoStop),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 得分环
class _ScoreRing extends StatelessWidget {
  const _ScoreRing({required this.score, required this.color});

  final int score;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,
      height: 58,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: score / 100,
            strokeWidth: 4.5,
            valueColor: AlwaysStoppedAnimation<Color>(color),
            backgroundColor: color.withValues(alpha: 0.12),
          ),
          Text(
            '$score',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
