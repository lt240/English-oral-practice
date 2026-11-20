import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'app.dart';
import 'services/asr/model_installer.dart';
import 'services/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 全局兜底：任何未捕获的 Dart 异常 / Flutter 框架错误都不再让 App 静默闪退，
  // 而是记录到 debugPrint（可经 logcat 看到），帮助定位「打不开闪退」的根因。
  runZonedGuarded(() async {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      debugPrint('=== FlutterError ===\n${details.exception}\n${details.stack}');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('=== PlatformDispatcher error ===\n$error\n$stack');
      return true;
    };
    await _bootstrap();
  }, (error, stack) {
    debugPrint('=== runZonedGuarded 捕获 ===\n$error\n$stack');
  });
}

Future<void> _bootstrap() async {
  // 初始化 sherpa-onnx 原生绑定（端侧 ONNX Runtime，纯离线）。
  // 真机上若原生库加载失败（缺 .so / ABI 不匹配 / 权限），这里会抛异常导致白屏。
  // 用 try-catch 兜底：绑定失败时 App 仍能启动，仅跟读/识别功能不可用并给出提示。
  var asrReady = true;
  try {
    await sherpa.initBindingsAsync();
  } catch (e) {
    asrReady = false;
    debugPrint('sherpa-onnx 初始化失败，跟读识别将不可用：$e');
  }

  // 加载本地设置（TTS、主题等）
  final settings = SettingsController();
  try {
    await settings.load();
  } catch (e) {
    debugPrint('设置加载失败，使用默认值：$e');
  }
  settings.asrReady = asrReady;

  // P0-4：先出首帧，模型复制（约 99MB）放到首帧之后异步执行。
  runApp(TedCompanionApp(settings: settings));

  // 仅当识别可用时才后台预热模型，避免真机 sherpa 不可用时做无谓的大文件复制
  if (asrReady) {
    Future<void>(() async {
      try {
        await ModelInstaller().copyBundledAssets();
      } catch (e) {
        debugPrint('模型后台预热失败（跟读页会重试并给出提示）：$e');
      }
    });
  }
}
