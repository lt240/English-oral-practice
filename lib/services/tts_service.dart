import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 本地 TTS 朗读（系统内置语音，免费、离线）
/// 等价 Web 的 window.speechSynthesis；无需任何 API key。
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _speaking = false;
  bool _paused = false;

  bool get isSpeaking => _speaking;
  bool get isPaused => _paused;

  /// 初始化并按设置配置音色 / 语速
  Future<void> configure({
    required bool male,
    required double rate,
  }) async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(rate);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);

    // 发音人性别：各平台内置英文音声列表不同，按 best-effort 匹配。
    // Android/iOS 通常自带 "Male"/"Female" 命名或带 gender 字段的英文语音。
    try {
      final voices = await _tts.getVoices;
      Map<dynamic, dynamic>? target;
      for (final v in voices as List) {
        final map = v as Map;
        final locale = (map['locale'] ?? map['Locale'] ?? '').toString();
        final name = (map['name'] ?? map['Name'] ?? '').toString();
        final gender = (map['gender'] ?? '').toString().toLowerCase();
        if (!locale.toLowerCase().startsWith('en')) continue;

        final preferMale = gender.contains('male') ||
            name.toLowerCase().contains('male');
        final preferFemale = gender.contains('female') ||
            name.toLowerCase().contains('female');
        if (male && preferMale && !preferFemale) {
          target = map;
          break;
        }
        if (!male && preferFemale) {
          target = map;
          break;
        }
      }
      if (target != null) {
        await _tts.setVoice(Map<String, String>.from(
          target.map((k, v) => MapEntry(k.toString(), v.toString())),
        ));
      }
    } catch (_) {
      // 个别平台不支持枚举音声，忽略即可
    }
  }

  /// 朗读一段文本；[onComplete] 朗读结束时回调
  Future<void> speak(String text, {VoidCallback? onComplete}) async {
    await _tts.stop();
    _speaking = true;
    _paused = false;
    final result = await _tts.speak(text);
    // speak 在 awaitSpeakCompletion 模式下，完成朗读后才返回
    _speaking = false;
    _paused = false;
    if (result == 1) onComplete?.call();
  }

  Future<void> pause() async {
    final r = await _tts.pause();
    if (r == 1) {
      _paused = true;
      _speaking = false;
    }
  }

  Future<void> stop() async {
    await _tts.stop();
    _speaking = false;
    _paused = false;
  }

  Future<void> dispose() => _tts.stop();
}
