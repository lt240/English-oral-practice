import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'model_installer.dart';

/// 离线 Whisper 识别封装（非流式，整句解码）
class OfflineAsrService {
  sherpa.OfflineRecognizer? _recognizer;
  AsrTier? _tier;

  bool get isLoaded => _recognizer != null;

  /// 加载 int8 Whisper 英文模型（encoder/decoder/tokens）
  /// 同档位重复调用时直接复用，不重新加载
  Future<void> load(
    ModelPaths paths, {
    AsrTier? tier,
    int numThreads = 2,
  }) async {
    if (tier != null && tier == _tier && isLoaded) return;

    _recognizer?.free();

    final config = sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: paths.encoder,
          decoder: paths.decoder,
        ),
        tokens: paths.tokens,
        modelType: 'whisper',
        numThreads: numThreads,
        debug: false,
      ),
    );

    _recognizer = sherpa.OfflineRecognizer(config);
    _tier = tier;
  }

  /// 对一整段语音（VAD 断出的句子）解码，返回识别文本
  String decodeSegment(
    Float32List samples, {
    int sampleRate = 16000,
  }) {
    final recognizer = _recognizer;
    if (recognizer == null) {
      throw StateError('识别模型尚未加载');
    }

    final stream = recognizer.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
    recognizer.decode(stream);
    final text = recognizer.getResult(stream).text;
    stream.free();
    return text;
  }

  void dispose() {
    _recognizer?.free();
    _recognizer = null;
  }
}
