import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 错误重读模式
enum RepeatMode { off, sentence, words }

/// 训练模式：跟读 / 复述
enum TrainMode { shadowing, retelling }

/// 全局设置（全部持久化到本地）
class SettingsController extends ChangeNotifier {
  static const _kVoiceMale = 'tts_voice_male';
  static const _kRate = 'tts_rate';
  static const _kDark = 'dark_mode';

  static const _kOriginalPlays = 'practice_original_plays';
  static const _kRepeatMode = 'practice_repeat_mode';
  static const _kAutoAdvance = 'practice_auto_advance';
  static const _kVadAutoStop = 'practice_vad_auto_stop';
  static const _kLastTrainMode = 'train_last_mode';
  static const _kRetellMaxSeconds = 'retell_max_seconds';

  // P1-5 / 模型智能化新增
  static const _kDailyGoal = 'daily_goal';
  static const _kAccurateAsr = 'accurate_asr';
  static const _kFuzzyHomophones = 'fuzzy_homophones';

  bool _voiceMale = false;
  double _rate = 1.0;
  bool _darkMode = false;

  int _originalPlays = 1;
  RepeatMode _repeatMode = RepeatMode.off;
  bool _autoAdvance = true;
  bool _vadAutoStop = true;
  TrainMode? _lastTrainMode;
  int _retellMaxSeconds = 90;

  int _dailyGoal = 10;
  bool _accurateAsr = false; // true = 优先使用 base.en（更准，需模型文件）
  bool _fuzzyHomophones = true; // 同音异形容错

  // sherpa-onnx 原生绑定是否初始化成功（main.dart 启动时写入）。
  // false 表示真机原生库加载失败，跟读/识别不可用，但 App 仍能启动。
  bool asrReady = true;

  bool get voiceMale => _voiceMale;
  double get rate => _rate;
  bool get darkMode => _darkMode;
  ThemeMode get themeMode => _darkMode ? ThemeMode.dark : ThemeMode.light;

  int get originalPlays => _originalPlays;
  RepeatMode get repeatMode => _repeatMode;
  bool get autoAdvance => _autoAdvance;
  bool get vadAutoStop => _vadAutoStop;
  TrainMode? get lastTrainMode => _lastTrainMode;
  int get retellMaxSeconds => _retellMaxSeconds;

  int get dailyGoal => _dailyGoal;
  bool get accurateAsr => _accurateAsr;
  bool get fuzzyHomophones => _fuzzyHomophones;

  static const retellMaxSteps = [60, 90, 120];
  static const speedSteps = [0.75, 1.0, 1.25];
  static const dailyGoalSteps = [5, 10, 20, 30];

  Future<double> cycleSpeed() async {
    final i = speedSteps.indexOf(rate);
    final next = speedSteps[(i + 1) % speedSteps.length];
    await setRate(next);
    return next;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _voiceMale = prefs.getBool(_kVoiceMale) ?? false;
    _rate = prefs.getDouble(_kRate) ?? 1.0;
    _darkMode = prefs.getBool(_kDark) ?? false;

    _originalPlays = prefs.getInt(_kOriginalPlays) ?? 1;
    final repeatIndex = prefs.getInt(_kRepeatMode) ?? 0;
    _repeatMode =
        (repeatIndex < 0 || repeatIndex >= RepeatMode.values.length)
            ? RepeatMode.off
            : RepeatMode.values[repeatIndex];
    _autoAdvance = prefs.getBool(_kAutoAdvance) ?? true;
    _vadAutoStop = prefs.getBool(_kVadAutoStop) ?? true;

    final m = prefs.getInt(_kLastTrainMode);
    _lastTrainMode =
        (m == null || m < 0 || m >= TrainMode.values.length)
            ? null
            : TrainMode.values[m];

    _retellMaxSeconds = prefs.getInt(_kRetellMaxSeconds) ?? 90;
    _dailyGoal = prefs.getInt(_kDailyGoal) ?? 10;
    _accurateAsr = prefs.getBool(_kAccurateAsr) ?? false;
    _fuzzyHomophones = prefs.getBool(_kFuzzyHomophones) ?? true;
    notifyListeners();
  }

  Future<void> setVoiceMale(bool value) async {
    _voiceMale = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_kVoiceMale, value);
  }

  Future<void> setRate(double value) async {
    _rate = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(_kRate, value);
  }

  Future<void> setDarkMode(bool value) async {
    _darkMode = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_kDark, value);
  }

  Future<void> setOriginalPlays(int value) async {
    _originalPlays = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(
      _kOriginalPlays,
      value,
    );
  }

  Future<void> setRepeatMode(RepeatMode value) async {
    _repeatMode = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(
      _kRepeatMode,
      value.index,
    );
  }

  Future<void> setAutoAdvance(bool value) async {
    _autoAdvance = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_kAutoAdvance, value);
  }

  Future<void> setVadAutoStop(bool value) async {
    _vadAutoStop = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_kVadAutoStop, value);
  }

  Future<void> setLastTrainMode(TrainMode? mode) async {
    _lastTrainMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (mode == null) {
      await prefs.remove(_kLastTrainMode);
    } else {
      await prefs.setInt(_kLastTrainMode, mode.index);
    }
  }

  Future<void> setRetellMaxSeconds(int value) async {
    _retellMaxSeconds = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(
      _kRetellMaxSeconds,
      value,
    );
  }

  Future<void> setDailyGoal(int value) async {
    _dailyGoal = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(_kDailyGoal, value);
  }

  Future<void> setAccurateAsr(bool value) async {
    _accurateAsr = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_kAccurateAsr, value);
  }

  Future<void> setFuzzyHomophones(bool value) async {
    _fuzzyHomophones = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(
      _kFuzzyHomophones,
      value,
    );
  }
}

/// 把 [SettingsController] 注入到组件树
class SettingsScope extends InheritedNotifier<SettingsController> {
  const SettingsScope({
    super.key,
    required SettingsController controller,
    required super.child,
  }) : super(notifier: controller);

  static SettingsController? of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SettingsScope>();
    return scope?.notifier;
  }
}
