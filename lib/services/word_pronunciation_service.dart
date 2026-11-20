import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// 单词真人发音服务（单例）
///
/// 本机系统 TTS 引擎不可用（无任何已绑定引擎），故采用在线真人词典
/// 发音 MP3（有道词典音源，约 20~50KB/词），通过 just_audio 播放。
/// 首次播放需联网，播放后写入应用私有目录永久缓存，之后纯离线。
class WordPronunciationService {
  WordPronunciationService._();
  static final WordPronunciationService instance = WordPronunciationService._();

  AudioPlayer? _player;
  String? _currentWord;
  bool _playing = false;

  bool get isPlaying => _playing;

  /// 播放单词发音。成功返回 true；无网络/音源失败返回 false。
  Future<bool> play(String word) async {
    final w = word.trim().toLowerCase();
    if (w.isEmpty) return false;
    if (_playing && _currentWord == w) return true;

    await stop();
    _playing = true;
    _currentWord = w;
    StreamSubscription<PlayerState>? sub;
    try {
      final file = await _cacheFile(w);
      // 缓存存在但可能损坏/为空 → 校验后再决定是否重新下载
      if (!file.existsSync() || file.lengthSync() < 1500) {
        final ok = await _download(w, file);
        if (!ok) return false;
      }

      final player = _player ??= AudioPlayer();

      // 等待播放真正结束（失败/停止由超时兜底，避免永久卡住）
      final done = Completer<void>();
      sub = player.playerStateStream.listen((state) {
        if (!done.isCompleted &&
            state.processingState == ProcessingState.completed) {
          done.complete();
        }
      });

      await player.setFilePath(file.path);
      await player.play();
      // 等待完成；给长词留足时间，但用「实际时长 + 余量」更稳
      await done.future.timeout(const Duration(seconds: 12), onTimeout: () {});
      return true;
    } catch (_) {
      return false;
    } finally {
      await sub?.cancel();
      _playing = false;
    }
  }

  /// 停止播放（弹窗关闭 / 切换新词时调用）
  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (_) {
      // 播放器未就绪时忽略
    }
    _playing = false;
  }

  /// 下载真人发音：先试美式（type=1），失败再试英式（type=2）
  Future<bool> _download(String word, File dest) async {
    for (final type in ['1', '2']) {
      try {
        final uri = Uri.https('dict.youdao.com', '/dictvoice', {
          'audio': word,
          'type': type,
        });
        final client =
            HttpClient()..connectionTimeout = const Duration(seconds: 6);
        final req = await client.getUrl(uri);
        final resp = await req.close().timeout(const Duration(seconds: 8));
        if (resp.statusCode != 200) {
          client.close(force: true);
          continue;
        }
        // 只接受音频内容类型；有道偶发返回 text/html 错误页
        final contentType = resp.headers.contentType?.mimeType ?? '';
        if (contentType.isNotEmpty &&
            !contentType.contains('audio') &&
            !contentType.contains('mpeg')) {
          client.close(force: true);
          continue;
        }
        final builder = await resp
            .fold<BytesBuilder>(BytesBuilder(), (b, data) => b..add(data))
            .timeout(const Duration(seconds: 10));
        client.close(force: true);
        final bytes = builder.takeBytes();
        // 有效 MP3 至少数千字节；过滤错误页/空响应
        if (bytes.length < 1500) continue;
        // 校验 MP3 魔数（ID3 或 MPEG 帧同步），避免缓存 HTML 错误页
        if (!_looksLikeMp3(bytes)) continue;
        await dest.writeAsBytes(bytes, flush: true);
        return true;
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  /// 判断字节是否为有效 MP3：ID3v2 标签（"ID3"）或 MPEG 帧同步（0xFF 0xE0/0xF0/0xF1）
  bool _looksLikeMp3(List<int> bytes) {
    if (bytes.length < 4) return false;
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
      return true; // "ID3"
    }
    // MPEG 帧头：0xFF 后跟 0xE0~0xFF 且低三位为同步字
    if (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
      return true;
    }
    return false;
  }

  Future<File> _cacheFile(String word) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}pron');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final safe = word.replaceAll(RegExp(r"[^a-z0-9]"), '_');
    return File('${dir.path}${Platform.pathSeparator}$safe.mp3');
  }
}
