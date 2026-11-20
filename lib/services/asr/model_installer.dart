import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 识别模型档位
enum AsrTier {
  tiny, // 快速：whisper tiny.en int8（省 CPU，首选）
  base, // 标准：whisper base.en int8（更准）
}

class ModelPaths {
  final String vad;
  final String encoder;
  final String decoder;
  final String tokens;

  const ModelPaths({
    required this.vad,
    required this.encoder,
    required this.decoder,
    required this.tokens,
  });
}

/// 模型缺失异常：携带缺失文件清单与离线获取指引
class MissingModelException implements Exception {
  final AsrTier tier;
  final List<String> missing;

  const MissingModelException(this.tier, this.missing);

  @override
  String toString() => '缺少离线模型文件：${missing.join(', ')}';
}

/// 模型文件管理：
/// 模型放在 `assets/models/`（随安装包分发，完全离线），
/// 首次运行复制到应用支持目录后供 sherpa-onnx 读取。
class ModelInstaller {
  static const String vadFile = 'silero_vad.onnx';

  /// 模型下载地址（仅在你打包素材的电脑上需要，手机端永不联网下载）
  static const String vadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx';
  static const String tinyEnUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.en.tar.bz2';
  static const String baseEnUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-base.en.tar.bz2';

  static const Map<AsrTier, (String, String, String)> _asrFiles = {
    AsrTier.tiny: (
      'tiny.en-encoder.int8.onnx',
      'tiny.en-decoder.int8.onnx',
      'tiny.en-tokens.txt',
    ),
    AsrTier.base: (
      'base.en-encoder.int8.onnx',
      'base.en-decoder.int8.onnx',
      'base.en-tokens.txt',
    ),
  };

  Future<Directory> _modelDir() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/models');
  }

  /// 共享的「正在复制」Future。
  /// P0-4 把预热移到 runApp 之后，而跟读页 ensureReady() 也会触发复制；
  /// 若用户装完立刻点录音，两个协程会并发写同一个 85MB decoder 文件，
  /// 可能让模型加载到写一半的文件。这里保证同一时刻只有一次复制。
  static Future<void>? _copying;

  /// 复制 assets/models/ 内全部文件到应用支持目录（增量、按长度跳过）
  Future<void> copyBundledAssets() {
    final running = _copying;
    if (running != null) return running;
    final future = _doCopyBundledAssets();
    _copying = future;
    return future.whenComplete(() => _copying = null);
  }

  Future<void> _doCopyBundledAssets() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final dir = await _modelDir();

    for (final asset in manifest.listAssets()) {
      if (!asset.startsWith('assets/models/')) continue;
      if (asset.endsWith('.gitkeep')) continue;

      final name = p.basename(asset);
      final target = File('${dir.path}/$name');
      final data = await rootBundle.load(asset);

      if (!await target.exists() ||
          target.lengthSync() != data.lengthInBytes) {
        await target.create(recursive: true);
        await target.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      }
    }
  }

  Future<List<String>> missingFiles(AsrTier tier) async {
    final dir = (await _modelDir()).path;
    final files = _asrFiles[tier]!;
    final required = [
      vadFile,
      files.$1,
      files.$2,
      files.$3,
    ];

    final missing = <String>[];
    for (final f in required) {
      if (!await File('$dir/$f').exists()) missing.add(f);
    }
    return missing;
  }

  Future<bool> isReady(AsrTier tier) async =>
      (await missingFiles(tier)).isEmpty;

  /// 确保模型就绪并返回绝对路径；未就绪时抛 [MissingModelException]
  Future<ModelPaths> ensureReady(AsrTier tier) async {
    await copyBundledAssets();

    final missing = await missingFiles(tier);
    if (missing.isNotEmpty) throw MissingModelException(tier, missing);

    return pathsFor(tier);
  }

  Future<ModelPaths> pathsFor(AsrTier tier) async {
    final dir = (await _modelDir()).path;
    final files = _asrFiles[tier]!;
    return ModelPaths(
      vad: '$dir/$vadFile',
      encoder: '$dir/${files.$1}',
      decoder: '$dir/${files.$2}',
      tokens: '$dir/${files.$3}',
    );
  }
}
