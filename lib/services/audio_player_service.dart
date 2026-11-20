import 'package:just_audio/just_audio.dart';

/// 原声播放控制器（P0-2 实装聆听模式后不再是死代码）
///
/// 提供：整篇播放 / 片段截取（句级、词级）/ 单句循环 / A-B 复读 / 变速。
/// 音频统一以 Flutter asset key 传入（如 assets/audio/ted_01.mp4）。
class AudioPlayerService {
  final AudioPlayer _player = AudioPlayer();
  String? _openedAsset;
  Duration? _clipStart;
  Duration? _clipEnd;

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<bool> get playingStream => _player.playingStream;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  bool get isPlaying => _player.playing;
  bool get hasClip => _clipStart != null;
  Duration? get clipStart => _clipStart;
  Duration? get clipEnd => _clipEnd;

  Future<void> open(String assetPath) async {
    if (_openedAsset == assetPath) return;
    await _player.setAsset(assetPath);
    _openedAsset = assetPath;
    _clipStart = null;
    _clipEnd = null;
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> seek(Duration position) => _player.seek(position);
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  /// 播放 [start, end] 区间；loop=true 时单句 / A-B 循环
  Future<void> playRange({
    required Duration start,
    required Duration end,
    bool loop = false,
  }) async {
    _clipStart = start;
    _clipEnd = end;
    await _player.setClip(start: start, end: end);
    await _player.setLoopMode(loop ? LoopMode.one : LoopMode.off);
    await _player.seek(start);
    await _player.play();
  }

  /// 播放单个词的原声片段（点词跳播，±0.15s 余量）
  Future<void> playWordClip({
    required Duration start,
    required Duration end,
  }) async {
    const pad = Duration(milliseconds: 150);
    final s = start - pad < Duration.zero ? Duration.zero : start - pad;
    await playRange(start: s, end: end + pad);
  }

  /// 清除片段裁剪，恢复整篇
  Future<void> clearClip() async {
    _clipStart = null;
    _clipEnd = null;
    await _player.setLoopMode(LoopMode.off);
    await _player.setClip();
  }

  Future<void> setLoopMode(LoopMode mode) => _player.setLoopMode(mode);

  void dispose() => _player.dispose();
}
