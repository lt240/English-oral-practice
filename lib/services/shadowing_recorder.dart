import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asr/asr_service.dart';
import 'asr/model_installer.dart';
import 'asr/pcm_utils.dart';

/// 一句被识别出的跟读
class RecognizedSegment {
  final double start; // 秒（本次录音内）
  final double end;
  final String text;

  const RecognizedSegment({
    required this.start,
    required this.end,
    required this.text,
  });
}

/// 录音器状态：空闲 / 模型加载中 / 聆听中
enum RecorderState { idle, initializing, listening }

/// ─────────────────────────────────────────────────────────────
/// 跟读录音器：麦克风 → Silero VAD 断句 → 离线 Whisper 整句识别
///
/// 流程：
///   开始 → 16kHz 单声道 PCM 流
///        → 每 512 采样喂给 VAD
///        → 检测到停顿（默认 0.7s 静音）后形成语音段
///        → Whisper 解码 → onSegment 回调
/// ─────────────────────────────────────────────────────────────
class ShadowingRecorder extends ChangeNotifier {
  ShadowingRecorder({
    ModelInstaller? installer,
    OfflineAsrService? asr,
    AudioRecorder? mic,
  }) : _installer = installer ?? ModelInstaller(),
       _asr = asr ?? OfflineAsrService(),
       _mic = mic ?? AudioRecorder();

  final ModelInstaller _installer;
  final OfflineAsrService _asr;
  final AudioRecorder _mic;

  sherpa.VoiceActivityDetector? _vad;
  StreamSubscription<Uint8List>? _micSub;

  RecorderState _state = RecorderState.idle;
  bool _speaking = false;
  bool _disposed = false;
  Future<void>? _stopFuture;
  AsrTier? _loadedTier;
  void Function(RecognizedSegment segment)? _onSegment;
  void Function(double level)? _onAmplitude;
  void Function()? _onAutoStop;
  bool _stopAfterSegment = false;

  /// 说话停止后的「真说完了吗」宽限定时器
  Timer? _autoStopTimer;

  /// 宽限期：说话停止后再等 600ms；期间重新开口视为换气并取消结束
  static const _autoStopGrace = Duration(milliseconds: 600);

  /// 复述长录音的最大时长保护（到点自动结束）
  Timer? _maxDurationTimer;
  void Function()? _onMaxDuration;

  RecorderState get recorderState => _state;
  bool get isListening => _state == RecorderState.listening;
  bool get isInitializing => _state == RecorderState.initializing;
  bool get isBusy => _state != RecorderState.idle;
  bool get isSpeaking => _speaking;

  Future<void> start({
    AsrTier tier = AsrTier.tiny,
    double silenceDuration = 0.7,
    double vadThreshold = 0.5,
    int numThreads = 2,
    void Function(RecognizedSegment segment)? onSegment,
    void Function(double level)? onAmplitude, // 实时音量 0~1（画波形）
    void Function()? onAutoStop, // VAD 判定说完后的自动结束回调
    bool stopAfterSegment = false, // 出句即自动结束本轮
    Duration? maxDuration, // 最大录音时长（复述长录音保护），到点触发 onMaxDuration
    void Function()? onMaxDuration, // 到达最大时长回调（由调用方负责停止录音）
  }) async {
    // 防重入：加载中/聆听中直接忽略，杜绝「点第二下把录音关掉」
    if (_state != RecorderState.idle) return;

    _state = RecorderState.initializing;
    _speaking = false;
    _onSegment = onSegment;
    _onAmplitude = onAmplitude;
    _onAutoStop = onAutoStop;
    _onMaxDuration = onMaxDuration;
    _stopAfterSegment = stopAfterSegment;
    _notify();

    try {
      if (!await _mic.hasPermission()) {
        throw StateError('没有麦克风权限，请在系统设置中允许后重试');
      }

      // 1. 模型文件检查（资源复制已在 App 启动时预热完成）
      final missing = await _installer.missingFiles(tier);
      if (missing.isNotEmpty) throw MissingModelException(tier, missing);
      final paths = await _installer.pathsFor(tier);

      // 2. 识别器按档位缓存：同档位不重复加载（加载 86MB decoder 很耗时）
      if (_loadedTier != tier || !_asr.isLoaded) {
        debugPrint('[recorder] 加载识别模型：$tier');
        await _asr.load(paths, tier: tier, numThreads: numThreads);
        _loadedTier = tier;
      }

      // 3. 启动 VAD（Silero，窗口 512 采样）
      _vad = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: paths.vad,
            threshold: vadThreshold,
            minSilenceDuration: silenceDuration, // 停顿时长
            minSpeechDuration: 0.25,
            windowSize: 512,
            maxSpeechDuration: 20,
          ),
          numThreads: 1,
          debug: false,
        ),
        bufferSizeInSeconds: 60,
      );

      // 4. 打开麦克风流（16kHz / 单声道 / PCM16）
      final stream = await _mic.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      const windowSize = 512;
      final pending = <double>[];

      _micSub = stream.listen((data) {
        final samples = pcm16BytesToSamples(data);
        pending.addAll(samples);

        // 实时音量（RMS）→ 波形
        var sumSq = 0.0;
        for (final s in samples) {
          sumSq += s * s;
        }
        final rms = samples.isEmpty ? 0.0 : math.sqrt(sumSq / samples.length);
        _onAmplitude?.call((rms * 5).clamp(0.0, 1.0));

        // 按 512 采样窗口逐块喂入 VAD
        while (pending.length >= windowSize) {
          final chunk = Float32List.fromList(pending.sublist(0, windowSize));
          pending.removeRange(0, windowSize);
          _vad?.acceptWaveform(chunk);
        }

        final speaking = _vad?.isDetected() ?? false;
        if (speaking != _speaking) {
          _speaking = speaking;
          if (_stopAfterSegment) {
            if (speaking) {
              // 宽限期内又开口 → 只是换气，取消结束
              _autoStopTimer?.cancel();
              _autoStopTimer = null;
            } else {
              // 说话刚停 → 启动宽限，持续静音 0.7s 才判定真说完
              _autoStopTimer ??= Timer(_autoStopGrace, () {
                _autoStopTimer = null;
                _onAutoStop?.call();
              });
            }
          }
          _notify();
        }

        _drainVad();
      });

      _state = RecorderState.listening;
      // 最大录音时长保护（从真正开始聆听计时，不含模型加载耗时）
      if (maxDuration != null) {
        _maxDurationTimer = Timer(maxDuration, () {
          _maxDurationTimer = null;
          _onMaxDuration?.call();
        });
      }
      _notify();
      debugPrint('[recorder] 进入聆听');
    } catch (e) {
      _state = RecorderState.idle;
      _notify();
      rethrow;
    }
  }

  /// 取出 VAD 已产出的全部完整语音段并识别
  void _drainVad() {
    if (_disposed) return;
    final vad = _vad;
    if (vad == null) return;

    while (!vad.isEmpty()) {
      final frame = vad.front();
      final segSamples = frame.samples;
      final startSec = frame.start / 16000;
      final endSec = startSec + segSamples.length / 16000;
      vad.pop();

      debugPrint('[recorder] VAD 出句 ${segSamples.length} 采样，开始解码');
      final text = _asr.decodeSegment(segSamples);
      debugPrint('[recorder] 识别结果：$text');
      _onSegment?.call(
        RecognizedSegment(start: startSec, end: endSec, text: text),
      );
    }
  }

  Future<void> stop() {
    final pending = _stopFuture;
    if (pending != null) return pending;
    final future = _stopInternal();
    final tracked = future.whenComplete(() {
      _stopFuture = null;
    });
    _stopFuture = tracked;
    return tracked;
  }

  Future<void> _stopInternal() async {
    if (_state == RecorderState.idle) return;

    _autoStopTimer?.cancel();
    _autoStopTimer = null;
    _maxDurationTimer?.cancel();
    _maxDurationTimer = null;
    _stopAfterSegment = false;

    await _micSub?.cancel();
    _micSub = null;

    // 先把 VAD 中尚未成熟的尾句强制取出，避免「刚读完就停=白读」
    try {
      _drainVad();
      _vad?.flush();
      _drainVad();
    } catch (e) {
      debugPrint('[recorder] 尾句 flush 失败：$e');
    }

    await _mic.stop();
    _vad?.free();
    _vad = null;

    _state = RecorderState.idle;
    _speaking = false;
    _notify();
    debugPrint('[recorder] 停止聆听');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _autoStopTimer?.cancel();
    _maxDurationTimer?.cancel();
    unawaited(_disposeAsync());
    super.dispose();
  }

  Future<void> _disposeAsync() async {
    try {
      await stop();
    } catch (e) {
      debugPrint('[recorder] dispose 停止失败：$e');
    }
    _asr.dispose();
    _mic.dispose();
  }
}
