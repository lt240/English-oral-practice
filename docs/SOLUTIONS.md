# TED 跟读助手 · 逐项解决方案

> 对应文档：`docs/IMPROVEMENT_PLAN.md`（P0-1 ~ P2-8，共 23 项，顺序一致、无遗漏）
> 每项结构：要解决的问题 → 解决措施 → 实施步骤 → 所需资源 → 预期效果 → 风险与坑
> 代码片段为可直接落地的骨架，路径均相对项目根 `C:\Users\L't\Desktop\TED`。

---

## 阶段 P0 · 修正确性（12 人日）

### P0-1 深色模式修复：背景 / 玻璃 / 文字统一走主题 token

**要解决的问题**
`AmbientBackground` 写死浅色渐变（`#F5F7FC → #E7EDF7`），`LiquidGlass` 固定 `tintColor = Colors.white`，而 `buildDarkGlassTheme()` 只替换了 `textTheme`（浅色文字）。结果：深色模式下是"浅底 + 浅字"，正文对比度不足；另一个方向的问题是 7 个文件里硬编码 `AppColors.textPrimary`（深色值 `#1C2434`），一旦背景真变深，这些文字同样会消失。

**解决措施**
1. 新增一层"表面色"语义层 `AppSurface`，所有需要区分明暗的地方只调它，不再直接引用 `AppColors` / `Colors.white`。
2. `AmbientBackground` 按 `Theme.of(context).brightness` 切换渐变与光斑透明度（深色用低饱和冷色光斑，alpha 降到 0.25 左右，避免"深底发光"）。
3. `LiquidGlass` 的 `tintColor` 走 `AppSurface.glassTint(context)`；描边 `_GlassBorderPainter` 在深色下把白色描边换成白色 8%~18%（原来的 60% 在深底上会过曝）。
4. 全量替换硬编码文字色为 `Theme.of(context).textTheme.*!.color`。

**实施步骤**
1. 新建 `lib/core/theme/app_surface.dart`：

```dart
import 'package:flutter/material.dart';

/// 语义化表面色：唯一允许"随明暗变化"的取色入口
class AppSurface {
  AppSurface._();
  static bool isDark(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark;

  static Color ambientTop(BuildContext c) =>
      isDark(c) ? const Color(0xFF161D30) : const Color(0xFFF5F7FC);
  static Color ambientBottom(BuildContext c) =>
      isDark(c) ? const Color(0xFF0E1424) : const Color(0xFFE7EDF7);

  /// 玻璃底色：深色用深夜蓝，浅色用白
  static Color glassTint(BuildContext c) =>
      isDark(c) ? const Color(0xFF1B2438) : Colors.white;
  static double glassOpacity(BuildContext c) => isDark(c) ? 0.28 : 0.15;

  /// 卡片内的次级文字（替代硬编码 AppColors.textSecondary）
  static Color textSecondary(BuildContext c) =>
      Theme.of(c).textTheme.bodySmall?.color ?? const Color(0xFF6B7488);
  /// 分隔线 / 空态块底色
  static Color subtleFill(BuildContext c) => isDark(c)
      ? Colors.white.withValues(alpha: 0.06)
      : Colors.black.withValues(alpha: 0.04);
}
```

2. `ambient_background.dart`：删除 `const` 装饰，改为 `build()` 内取 `AppSurface.ambientTop/Bottom(context)`；`_blob` 增加 `opacity` 参数，深色传 `0.25`。
3. `liquid_glass.dart`：`tintColor` 默认值改为 `null`，`build` 内 `final tint = tintColor ?? AppSurface.glassTint(context);`；`_GlassBorderPainter` 增加 `isDark` 字段，深色下三处渐变的白色 alpha 依次降为 `0x2E / 0x14 / 0x00`。
4. 逐文件替换（已知热点）：
   - `features/listening/listening_page.dart:95,99`（`Colors.white.withValues`）
   - `features/detail/speech_detail_page.dart:97,192,200`（白字）
   - `features/stats/stats_page.dart:180`（`Colors.white.withValues(alpha: 0.1)`）
   - `features/detail/shadowing_detail_page.dart`（`_panelButton`、`_wordChip`）
   - `core/widgets/glass_nav_bar.dart`、`core/widgets/dictionary_popup.dart`
5. 校验：Android 模拟器 + Windows 桌面各切一次主题，`flutter analyze` 无 `deprecated_member_use`。

**所需资源**
- 人日：2（改造 1.5 + 双端走查 0.5）
- 依赖：无新依赖
- 影响文件：`core/theme/app_surface.dart`(新)、`ambient_background.dart`、`liquid_glass.dart`、`glass_theme.dart` + 6 个页面

**预期效果**
- 深色模式下正文对比度 ≥ 4.5:1（用 DevTools 取色校验 5 个页面），无"看不见的字"。
- 后续新增页面不再需要判断明暗，只调 `AppSurface`。

**风险与坑**
- 玻璃卡片在深色底上模糊后偏灰，`tintOpacity` 需从 0.15 提到 0.28，否则卡片边界糊在一起。
- `BackdropFilter` 叠 4 个背景光斑时，深色模式下模糊会放大噪点，光斑半径建议从 70 提到 90。

---

### P0-2 聆听模式二选一：实装（推荐）或下线

**要解决的问题**
`listening_page.dart` 是占位壳：字幕是硬编码英文、`replay_10`/`forward_10` 是空回调、`_playing` 只改图标不驱动 `AudioPlayer`，且该页未挂进 `ShellPage` 的 4 个 tab。README 却把"聆听"写成既有功能 —— 属于"文档承诺 / 代码不成立"。

**解决措施**
选择**实装**（成本 3 人日，且它是跟读的入口场景，砍掉会让产品少一个使用动机）。要做四件事：
1. 句级字幕同步：复用 `ShadowingDetailPage` 已有的 `positionStream → 当前句` 逻辑，抽成 `SentenceSyncController`。
2. 单句循环 + A-B 复读：维护 `({int start, int end})? loopRange`，`_onPosition` 越过 `end` 时 `seek(start)`。
3. 变速：`player.setSpeed(settings.rate)`，复用已有 `SettingsController.speedSteps`。
4. 点句跳转 + 点击查词：复用 `TappableText` + `DictionaryPopup`。

**实施步骤**
1. 新建 `lib/features/listening/listening_controller.dart`：持有 `AudioPlayer`、`List<TranscriptSentence>`、`currentIndex`、`loopRange`，暴露 `ChangeNotifier`；单句时长 = `sentence.start/end`。
2. 重写 `listening_page.dart`：`ListView.builder` 渲染句子，当前句加底色 + 自动 `Scrollable.ensureVisible`；底部播放条改为"上一句 / 播放暂停 / 下一句 / 循环当前句 / 变速"。
3. 在 `ShellPage` 增加第 5 个 tab（图标 `Icons.headphones_rounded`，label「聆听」），或改为从内容库卡片进入 —— **推荐后者**（4 tab 更清爽，聆听是"某一篇演讲"的属性而非全局页）。
4. `speech_detail_page.dart` 的模式选择从 2 张卡扩到 3 张：聆听 / 跟读 / 复述，`TrainMode` 枚举加 `listening`。
5. README 功能表同步。

**所需资源**
- 人日：3
- 依赖：`just_audio`（已有）
- 影响文件：`listening_page.dart`(重写)、`listening_controller.dart`(新)、`speech_detail_page.dart`、`settings_controller.dart`（`TrainMode` 加值）、`shell_page.dart`、`README.md`

**预期效果**
- 长篇内容可以先"听"再"读"，跟读前的输入环节成立。
- 单句循环与 A-B 复读可用，替代用户外挂播放器。

**风险与坑**
- `TrainMode` 枚举加值会改变 `SharedPreferences` 里 `train_last_mode` 的整型语义，老用户可能被错误路由。**加值时只能追加到末尾**，或改用字符串存 key。
- 循环边界要留 30~50 ms 提前量（`end - 0.03`），否则句尾吞字。

---

### P0-3 删除死代码

**要解决的问题**
`models/speech.dart`（`Speech`/`SubtitleCue`/`WordToken` 全库零引用，仅被占位页 import）、`services/audio_player_service.dart`、`services/stats_service.dart`（`recordAttempt` 从未被调用，且与 `AppDatabase` 统计双轨）、`listening_page.dart` 的占位实现 —— 会误导后续维护者以为"逐词高亮和统计已经有实现"。

**解决措施**
1. 直接删除 `lib/models/speech.dart`、`lib/services/audio_player_service.dart`。
2. `StatsService` 删除，但 `settings_page.dart:20,43` 调用了它的 `clear()` —— 改为 `AppDatabase.instance.clearAttempts()` 已覆盖，删掉 `_stats.clear()`。
3. 若 P0-2 选择"下线聆听"，同时删 `listening_page.dart` 并从 README 移除。
4. 跑 `dart fix --apply` + `flutter analyze` 确认无 dangling import。

**实施步骤**
1. `git rm` 三个文件；`settings_page.dart` 去掉 import 与字段。
2. 全库搜 `SubtitleCue|WordToken|StatsService|AudioPlayerService` 确认 0 命中。
3. 提交信息写清"删除未接线的占位实现，功能由 X 承担"，方便日后追溯。

**所需资源**
- 人日：1（含回归验证）
- 依赖：无
- 影响文件：删除 3 个、修改 `settings_page.dart`

**预期效果**
- `flutter analyze` 无 unused 类/文件；lib 行数下降约 120 行；新人读代码不再被"假实现"误导。

**风险与坑**
- `stats_service.dart` 虽死，但 `shared_preferences` 里可能残留 `practice_records` 键，清数据时顺手 `prefs.remove('practice_records')` 做一次迁移清理。

---

### P0-4 首启体验：模型异步预热 + 安装引导

**要解决的问题**
`main.dart:21` 在 `runApp` 之前 `await ModelInstaller().copyBundledAssets()`，逐文件 `rootBundle.load` 99 MB 并比对长度；中端安卓上首帧延迟 2~6 秒，期间纯黑屏，用户不知道在等什么。

**解决措施**
1. `main()` 只保留 `sherpa.initBindingsAsync()` 与 `SettingsController.load()`，模型复制挪到 `runApp` 之后异步执行（`unawaited`）。
2. 首次进入跟读时若模型未就绪，弹"离线模型安装"页：显示文件清单、总体进度条、剩余 MB、取消按钮 —— 复用已有的 `ModelInstaller.missingFiles/pathsFor`，新增 `installWithProgress()` 返回 `Stream<InstallProgress>`。
3. 增加全局状态 `ModelStatus`（`idle / installing / ready / failed`），供跟读页/设置页共用，避免重复复制。

**实施步骤**
1. `model_installer.dart` 新增：

```dart
class InstallProgress {
  final int done, total; // 字节
  final String currentFile;
  const InstallProgress(this.done, this.total, this.currentFile);
  double get ratio => total == 0 ? 0 : done / total;
}

/// 带进度的素材安装（替换 copyBundledAssets 的无反馈版本）
Stream<InstallProgress> installWithProgress({bool force = false}) async* {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final assets = manifest.listAssets()
      .where((a) => a.startsWith('assets/models/') && !a.endsWith('.gitkeep'))
      .toList();
  final dir = await _modelDir();
  // 先算总量，才能给出百分比
  final sizes = <String, int>{};
  var total = 0;
  for (final a in assets) {
    final d = await rootBundle.load(a);
    sizes[a] = d.lengthInBytes;
    total += d.lengthInBytes;
  }
  var done = 0;
  for (final a in assets) {
    final name = p.basename(a);
    final target = File('${dir.path}/$name');
    final size = sizes[a]!;
    if (force || !await target.exists() || target.lengthSync() != size) {
      final data = await rootBundle.load(a);
      await target.create(recursive: true);
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: false,
      );
    }
    done += size;
    yield InstallProgress(done, total, name);
  }
}
```

> 注意：内存占用优化 —— 上面为了算总大小把 99 MB 读了两遍。更稳的做法是**把总大小写进常量表**（`_asrBytes = {'silero_vad.onnx': 643854, ...}`），一次遍历一遍，峰值内存从 ~99 MB 降到单个文件大小。

2. `main.dart` 改为：

```dart
await sherpa.initBindingsAsync();
final settings = SettingsController();
await settings.load();
runApp(TedCompanionApp(settings: settings));
// 启动后预热，不阻塞首帧
unawaited(ModelInstaller().installWithProgress().drain<void>());
```

3. 新增 `lib/features/onboarding/model_install_sheet.dart`：`StreamBuilder<InstallProgress>` 画进度 + 取消（取消即 `subscription.cancel()`，已写入的文件保留，下次续装）。
4. `shadowing_page.dart` / `shadowing_detail_page.dart` 的 `MissingModelException` 分支从"弹文本"改成"打开安装页"。

**所需资源**
- 人日：3
- 依赖：无
- 影响文件：`main.dart`、`model_installer.dart`、`model_install_sheet.dart`(新)、两个跟读页

**预期效果**
- 冷启动首帧 < 1.5 s（中端安卓，`flutter run --profile` + DevTools 首帧时间）。
- 首次跟读有明确进度，用户不会以为卡死。

**风险与坑**
- 后台复制与前台录音可能同时读写同一目录：加 `_installing` 互斥标志，录音前 `await installer.ensureReady()` 会等待进行中的安装完成。
- Android 低存储设备写 99 MB 可能失败（`ENOSPC`），必须捕获并提示"至少需要 120 MB 可用空间"。

---

### P0-5 素材出包与仓库瘦身

**要解决的问题**
`assets/audio/meg_jay_30_not_20.mp3`（11.1 MB）无文稿、未接入内容库，但被 `pubspec.yaml` 的 `assets/audio/` 目录规则整体打进安装包；`build/` 6.0 GB 未清理；根目录遗留 `matt_cutts_30_days.json.bak`。

**解决措施**
1. 孤立音频移到项目内 `_unused/`（不入 assets）或直接移出仓库；确要保留则改用单文件声明而不是目录声明。
2. `pubspec.yaml` 把 `assets/audio/` 目录声明改成逐文件声明，从机制上杜绝"放个文件就进包"。
3. `flutter clean` + 清理 `.dart_tool`/`build`。
4. `.gitignore` 增加 `build/`、`*.bak`、`_unused/`。

**实施步骤**
1. 移动孤立 mp3 → `_unused/meg_jay_30_not_20.mp3`，提交时不跟踪。
2. `pubspec.yaml`：

```yaml
  assets:
    - assets/models/
    - assets/content/
    - assets/dict/
    # 音频逐条登记，避免未接入素材被打进包
    - assets/audio/matt_cutts_30_days.mp3
```

3. `flutter clean && flutter pub get`，对比 `flutter build apk --release` 前后体积。
4. 删除根目录 `.bak`。

**所需资源**
- 人日：0.5
- 依赖：无
- 影响文件：`pubspec.yaml`、`.gitignore`、`assets/audio/`

**预期效果**
- release APK 体积下降 ≥ 11 MB；仓库工作区从 6 GB 降到 ~200 MB。
- 后续新增音频必须显式登记，不会再"悄悄进包"。

**风险与坑**
- 逐文件声明后，`AssetManifest` 的 `listAssets()` 结果会变化 —— P0-4 的安装器只筛 `assets/models/`，不受影响，但 P2-4 做按需下载时要重新对齐清单来源。

---

### P0-6 数据库收敛：删空表、补索引、聚合下推

**要解决的问题**
`app_database.dart` 建了 4 张表，但 `speeches`（内容其实来自硬编码 `kSpeechLibrary`）和 `practice_sessions`（`insertSession` 从未调用）永远是空表；`attempts` 无任何索引，`reviewItems()` 全表扫 + 在 Dart 里去重；`topWrongWords()` 把全表 `wrong_words` 拉进内存聚合；`resolveReview()` 无 `LIMIT`，会更新该句所有历史行。

**解决措施**
1. 版本升到 v4：drop 两张空表，建索引。
2. `topWrongWords` 改为"取近 90 天 + `LIMIT 2000` 行"再聚合，或改用 SQLite `json_each`（需确认目标机型 SQLite ≥ 3.38；不稳妥则用前者）。
3. `resolveReview` 只更新最新一行：`WHERE id = (SELECT id FROM attempts WHERE ... ORDER BY practiced_at DESC LIMIT 1)`。
4. `overview()` 的 `days` 用 `COUNT(DISTINCT date(...))` 一条 SQL 完成。

**实施步骤**
1. 迁移：

```dart
onUpgrade: (db, oldVersion, newVersion) async {
  if (oldVersion < 2) await _createAttempts(db);
  if (oldVersion < 3) await _createRetellRecords(db);
  if (oldVersion < 4) {
    // 从未写入的两张表：直接删，避免误以为有多表数据源
    await db.execute('DROP TABLE IF EXISTS practice_sessions');
    await db.execute('DROP TABLE IF EXISTS speeches');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_attempts_speech_time '
      'ON attempts(speech_id, practiced_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_attempts_review '
      'ON attempts(needs_review, practiced_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_retell_speech_time '
      'ON retell_records(speech_id, practiced_at DESC)',
    );
  }
},
```

2. 查询改造：

```dart
Future<List<MapEntry<String, int>>> topWrongWords({int limit = 10}) async {
  final db = await database;
  final since = DateTime.now()
      .subtract(const Duration(days: 90))
      .millisecondsSinceEpoch;
  final rows = await db.query(
    'attempts',
    columns: ['wrong_words'],
    where: 'practiced_at >= ? AND wrong_words IS NOT NULL AND wrong_words != ""',
    whereArgs: [since],
    orderBy: 'practiced_at DESC',
    limit: 2000, // 控制内存上界；词频榜不需要全史
  );
  // …原有聚合逻辑不变
}
```

3. `overview()`：

```dart
final rows = await db.rawQuery(
  'SELECT COUNT(*) AS c, AVG(score) AS a, '
  'COUNT(DISTINCT date(practiced_at/1000,"unixepoch","localtime")) AS d '
  'FROM attempts WHERE practiced_at >= ?', [startOfDay]);
final all = await db.rawQuery(
  'SELECT COUNT(DISTINCT date(practiced_at/1000,"unixepoch","localtime")) AS d '
  'FROM attempts');
```

**所需资源**
- 人日：2
- 依赖：无
- 影响文件：`services/db/app_database.dart`（+ 迁移测试）

**预期效果**
- 1000 条记录下 `reviewItems` / `topWrongWords` < 20 ms（`debugPrint` 打时间戳对比）。
- 表结构与实际数据源一致，不再有"幽灵表"。

**风险与坑**
- 已安装用户升级时 drop 表是安全的（两张表本来就空），但**必须保留 `onCreate` 里的建表语句**给全新安装 —— 否则新装用户建表逻辑与 v4 不一致。建议 `onCreate` 直接调用最新 schema，`onUpgrade` 只做增量。
- `date(practiced_at/1000,'unixepoch','localtime')` 依赖设备时区；跨时区用户"学习天数"会漂移。若要严格，改成存 `day_key TEXT`（`yyyy-MM-dd`）列，写入时按本地日期落库。

---

### P0-7 文档与实现对齐

**要解决的问题**
`README.md:8-12` 声称"聆听 / 逐词高亮 / 趋势"，代码里三者均未实现；`README.md:87-93` 的"已知待办"已过时（孤立音频已处理、`build/` 已清）。

**解决措施**
1. 功能表改为"已实现 / 计划中"两栏，逐条对应到文件。
2. 新增"能力边界"小节：仅英文、仅 tiny.en、无音素级评分、无云端同步。
3. 把 `docs/IMPROVEMENT_PLAN.md`、本文件纳入 README 的文档索引。

**实施步骤**
1. 对照 `lib/features/` 与 `lib/services/` 逐条核对，标 `✅ 已实现` / `🚧 计划中（P2-3）`。
2. "已知待办"改为链接到 `docs/IMPROVEMENT_PLAN.md` 的对应编号。
3. PR 模板加一条自检："功能表是否随代码改动"。

**所需资源**
- 人日：0.5
- 依赖：无

**预期效果**
- 任何人读 README 能在 5 分钟内判断"这个 App 现在能干什么、不能干什么"。

**风险与坑**
- 文档漂移是持续性问题，光改一次没用；必须绑 CI（P2-7 的 PR 模板自检）才不复发。

---

## 阶段 P1 · 学习闭环（27 人日）

### P1-1 录音落盘 + 「原声 / 我的」A-B 对比回放

**要解决的问题**
`ShadowingRecorder` 只把 PCM 流喂给 VAD 与 Whisper（`shadowing_recorder.dart:146`），**不落盘**。用户读完只看得到红绿字，听不到自己刚才是怎么读的 —— 而"对比"是 ELSA / Speechling / 流利说 的核心信任来源。

**解决措施**
1. `ShadowingRecorder.start()` 新增 `captureAudio: bool`；在 `stream.listen` 里把 `Uint8List` 追加到 `BytesBuilder`（`pcm16BytesToSamples` 之前，保留原始字节）。
2. 停止时按 VAD 实际语音区间裁剪，写成 16 kHz / 单声道 / 16-bit WAV（44 字节头 + PCM，无需第三方库），落到 `getApplicationSupportDirectory()/recordings/<speechId>/<sentenceIndex>_<ts>.wav`。
3. `attempts` 表加列 `audio_path TEXT`（v5 迁移）。
4. 结果面板加 A-B 播放器：`[听原声] [听我的]`，两段等长区间，可反复切换；默认先播原声再自动播用户录音（"对比模式"）。

**实施步骤**
1. 新增 `lib/services/asr/wav_writer.dart`：

```dart
import 'dart:typed_data';

/// 16kHz / 单声道 / 16-bit PCM → WAV（44 字节标准头）
class WavWriter {
  static Uint8List encode(Uint8List pcm16, {int sampleRate = 16000}) {
    const channels = 1, bits = 16;
    final dataLen = pcm16.lengthInBytes;
    final byteRate = sampleRate * channels * bits ~/ 8;
    final header = ByteData(44)
      ..setUint32(0, 0x46464952, Endian.little)     // 'RIFF'
      ..setUint32(4, 36 + dataLen, Endian.little)   // 文件长度-8
      ..setUint32(8, 0x45564157, Endian.little)     // 'WAVE'
      ..setUint32(12, 0x20746D66, Endian.little)    // 'fmt '
      ..setUint32(16, 16, Endian.little)            // fmt 块长度
      ..setUint16(20, 1, Endian.little)             // PCM
      ..setUint16(22, channels, Endian.little)
      ..setUint32(24, sampleRate, Endian.little)
      ..setUint32(28, byteRate, Endian.little)
      ..setUint16(32, channels * bits ~/ 8, Endian.little)
      ..setUint16(34, bits, Endian.little)
      ..setUint32(36, 0x61746164, Endian.little)    // 'data'
      ..setUint32(40, dataLen, Endian.little);
    return (BytesBuilder()
          ..add(header.buffer.asUint8List())
          ..add(pcm16))
        .takeBytes();
  }

  /// 按时间区间裁剪（用于去掉句首句尾静音）
  static Uint8List trim(Uint8List pcm16,
      {required double fromSec, required double toSec, int sampleRate = 16000}) {
    final bytesPerSample = 2;
    var from = (fromSec * sampleRate * bytesPerSample).floor();
    var to = (toSec * sampleRate * bytesPerSample).ceil();
    from = from.clamp(0, pcm16.length);
    to = to.clamp(from, pcm16.length);
    return Uint8List.sublistView(pcm16, from, to);
  }
}
```

2. `shadowing_recorder.dart` 改动点（最小侵入）：

```dart
final _pcm = BytesBuilder(copy: false);
double? _firstSpeechSec, _lastSpeechSec;

// stream.listen 内，取 samples 之前先留档
_pcm.add(Uint8List.fromList(data));
...
// _drainVad 拿到段起止时记录区间
_firstSpeechSec ??= startSec;
_lastSpeechSec = endSec;

// stop() 末尾
Future<String?> _flushAudio() async {
  if (!_capture || _pcm.isEmpty) return null;
  final raw = _pcm.takeBytes();
  final from = (_firstSpeechSec ?? 0) - 0.2;
  final to = (_lastSpeechSec ?? raw.length / 32000) + 0.3;
  final clipped = WavWriter.trim(raw, fromSec: from, toSec: to);
  final file = File(await _nextPath()); // <support>/recordings/...
  await file.writeAsBytes(WavWriter.encode(clipped), flush: false);
  return file.path;
}
```

3. `_persistAttempt` 增加 `'audio_path': path`；DB v5 迁移 `ALTER TABLE attempts ADD COLUMN audio_path TEXT`。
4. 结果面板（`shadowing_detail_page.dart:851 _resultPanel`）加对比条：一个 `AudioPlayer` 切 `setFilePath(originalAsset)` / `setFilePath(userWav)`，`seek` 到句首，按钮文案随当前源变化。
5. 存储治理：`recordings/` 只保留最近 200 条 / 30 天，超限按 `practiced_at` 淘汰（避免用户练一年后占满存储）。

**所需资源**
- 人日：4（录音落盘 1.5 + DB 0.5 + 对比 UI 1.5 + 清理策略 0.5）
- 依赖：`just_audio`（已有，支持 `setFilePath`）；`record`（已有）
- 影响文件：`wav_writer.dart`(新)、`shadowing_recorder.dart`、`app_database.dart`、`shadowing_detail_page.dart`、`retell_page.dart`

**预期效果**
- 每次跟读/复述都能一键对比原声与本人录音；单句 WAV 约 60~150 KB，200 条 ≈ 20 MB 上限。
- 复述模式同理复用（90 s ≈ 2.8 MB，需单独设保留 20 条上限）。

**风险与坑**
- **必须用 VAD 区间裁剪**：不裁的话静音段会把"我的录音"拉长，A-B 对比节奏全乱。
- `BytesBuilder(copy: false)` 会吞掉传入 buffer 的所有权，`record` 的 stream 可能复用 buffer —— 保守用 `Uint8List.fromList(data)` 拷一份（每 20 ms 一次，开销可忽略）。
- 录音文件是用户隐私数据，备份/导出功能（若有）默认排除，且隐私政策要写明"仅存本机"。

---

### P1-2 生词本：查词 → 收藏 → 单词卡复习

**要解决的问题**
`DictionaryPopup` 查完即走，词条不落地。用户每天产生的"错词/生词"是最有价值的个人数据，现在完全没有沉淀，也没有任何跨演讲的词汇资产。

**解决措施**
1. 新建 `vocab` 表（单词级），字段同时容纳"收藏来源"和后续 SRS 状态（一次建好，避免 P1-3 再迁移）。
2. 弹窗加「☆ 加入生词本」；跟读出错时可选"自动收录错词"（设置项）。
3. 生词本页：列表（按到期/最近/字母排序）+ 卡片详情（音标、释义、来源原句、发音、跳回原句）。
4. 单词卡复习复用 P1-3 排程，本项只做"收藏 + 浏览"。

**实施步骤**
1. 迁移 v5（与 P1-1 同批）：

```sql
CREATE TABLE vocab (
  word            TEXT PRIMARY KEY,          -- 小写归一
  phonetic        TEXT,
  zh              TEXT,                       -- 主释义快照
  speech_id       TEXT,                       -- 首次出现来源
  sentence_index  INTEGER,
  created_at      INTEGER NOT NULL,
  -- SRS 状态（P1-3 使用）
  ease            REAL    NOT NULL DEFAULT 2.5,
  interval_days   INTEGER NOT NULL DEFAULT 0,
  reps            INTEGER NOT NULL DEFAULT 0,
  lapses          INTEGER NOT NULL DEFAULT 0,
  due_at          INTEGER,                    -- NULL = 未进入复习
  state           INTEGER NOT NULL DEFAULT 0  -- 0 新词 1 学习中 2 复习中
);
CREATE INDEX idx_vocab_due ON vocab(state, due_at);
```

2. `DictionaryPopup` 底部按钮区加收藏；写入时把 `ContextSentence` 一并存下，日后复习能带语境。
3. 新增 `lib/features/vocab/vocab_page.dart` + `services/vocab_repository.dart`（`add/remove/list/dueQueue`）。
4. 入口：`ShellPage` 的"统计"页顶部加"生词本（N）"卡片跳转；统计页错词 TOP 每行可点"加入"。
5. 导出（可选 0.5 人日）：CSV 输出 `word,phonetic,zh,source`，方便导入 Anki。

**所需资源**
- 人日：4
- 依赖：`DictionaryService`（已有，复用释义）
- 影响文件：`app_database.dart`、`vocab_repository.dart`(新)、`vocab_page.dart`(新)、`dictionary_popup.dart`、`stats_page.dart`

**预期效果**
- 查过的词可回看；错词 TOP 榜可一键转生词本；生词总量、本周新增可见。
- 为 P1-3 提供数据基础（无需二次迁移）。

**风险与坑**
- 释义快照 vs 实时查询：存 `zh` 快照能让词表离线可读，但词典更新后可能过时 —— 列表页展示快照，详情页每次实时查（`DictionaryService.lookup`）以最新为准。
- 一词多义：`vocab` 主键是 `word`，同一词在不同语境只存一条（来源记首次），这是刻意取舍；若要"语境多卡"需主键改 `(word, sentence_context_hash)`，成本翻倍，不建议现阶段做。

---

### P1-3 句子级 SRS 队列：用排程替代布尔标记

**要解决的问题**
现在只有 `attempts.needs_review = 1` 这个布尔值：要么练、要么不练，没有"什么时候该练"；`_afterSentence` 里仅在"连错 3 次 + 用户选了重复模式"时才置位，导致复习队列长期为空或长期堆积。

**解决措施**
1. 用 SM-2（简版）维护每个 `(speech_id, sentence_index)` 的排程状态，存在新表 `review_cards`。
2. 每次评分后按分数映射 grade（0~5），更新 `ease / interval / due_at`。
3. "今日复习"= `due_at <= now` 的卡片 + 每日新词上限；首页/统计页显示"今日待复习 N 句"，点击进入顺序练习流。
4. `needs_review` 保留为"错题"语义展示，不再承担排程职责。

**实施步骤**
1. 建表：

```sql
CREATE TABLE review_cards (
  speech_id       TEXT NOT NULL,
  sentence_index  INTEGER NOT NULL,
  ease            REAL    NOT NULL DEFAULT 2.5,
  interval_days   INTEGER NOT NULL DEFAULT 1,
  reps            INTEGER NOT NULL DEFAULT 0,
  lapses          INTEGER NOT NULL DEFAULT 0,
  due_at          INTEGER NOT NULL,
  last_score      INTEGER,
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (speech_id, sentence_index)
);
CREATE INDEX idx_review_due ON review_cards(due_at);
```

2. 纯函数排程器（可单测，不碰 DB）：

```dart
class SrsCard {
  final double ease; final int intervalDays; final int reps; final int lapses;
  const SrsCard({this.ease = 2.5, this.intervalDays = 1, this.reps = 0, this.lapses = 0});
}

/// 分数 → SM-2 质量等级（0~5）
int gradeOf(int score) {
  if (score >= 90) return 5;
  if (score >= 80) return 4;
  if (score >= 70) return 3;
  if (score >= 60) return 2;
  if (score >= 40) return 1;
  return 0;
}

({SrsCard card, int dueInDays}) review(SrsCard c, int grade) {
  var ease = c.ease, interval = c.intervalDays, reps = c.reps, lapses = c.lapses;
  if (grade < 3) {
    reps = 0;
    lapses += 1;
    interval = 1;                      // 忘了 → 明天再来
    ease = (ease - 0.2).clamp(1.3, 2.8);
  } else {
    reps += 1;
    if (reps == 1) {
      interval = 1;
    } else if (reps == 2) {
      interval = 3;
    } else {
      interval = (interval * ease).round().clamp(1, 180);
    }
    ease = (ease + (0.1 - (5 - grade) * (0.08 + (5 - grade) * 0.02)))
        .clamp(1.3, 2.8);
  }
  return (card: SrsCard(ease: ease, intervalDays: interval, reps: reps, lapses: lapses),
          dueInDays: interval);
}
```

3. `_finalizeScoring` 末尾接一行：`await ReviewRepo.upsertFromScore(speechId, index, score)`；`_afterSentence` 里"连错 3 次"的分支删掉（改由 grade 驱动）。
4. 今日队列查询：

```sql
SELECT speech_id, sentence_index, due_at FROM review_cards
WHERE due_at <= ?
ORDER BY due_at ASC LIMIT 30;
```

5. 新增 `features/review/review_session_page.dart`：按队列顺序逐句进入 `ShadowingDetailPage(initialIndex: i)`，完成一句自动返回下一句（复用已有 `initialIndex` 参数）。
6. 设置页加"每日新句上限 / 复习上限 / 是否开启排程"。

**所需资源**
- 人日：5（排程 1.5 + DB 1 + 队列页 1.5 + 接入 1）
- 依赖：无新依赖
- 影响文件：`app_database.dart`、`srs.dart`(新)、`review_repository.dart`(新)、`review_session_page.dart`(新)、`shadowing_detail_page.dart`、`stats_page.dart`、`settings_page.dart`

**预期效果**
- 每天打开 App 有明确任务（"今日 12 句待复习"），错句按 1/3/7/16 天曲线重现。
- 7 天后可观测：复习按时完成率、平均复习次数、错句复发率下降。

**风险与坑**
- SM-2 对"朗读练习"并非最优（它是词汇记忆模型），但比布尔标记好一个数量级；若要更准，可换 FSRS（`fsrs` 算法有公开实现），接口不变，留好 `ease/interval` 抽象即可平滑替换。
- 队列会因用户断更而堆积：**必须设上限**（如每日 30 句），否则第 10 天打开看到 200 句直接劝退。
- 排程更新要与"评分落库"同一事务，否则中途崩溃会出现 `attempts` 有记录但卡片未更新。

---

### P1-4 断点续练：篇内进度 + 收藏 / 最近

**要解决的问题**
一篇演讲 46 句，用户练到第 20 句退出，下次进入 `ShadowingDetailPage(initialIndex: 0)` 又从第 1 句开始；内容库也没有"完成度"和"最近练习"，找不回上次的位置。

**解决措施**
1. 新表 `speech_progress`：`last_index`、`completed_count`、`updated_at`。
2. 每次 `_nextSentence` / `_jumpToSentence` 写一次（节流：`updated_at` 差 > 2 s 才写）。
3. 内容库卡片加进度环（`LinearProgressIndicator` 或 `CircularProgressIndicator`）+ "继续第 N 句"副标题；顶部加"最近练习"横条。
4. 收藏用 `speech_favorite` 布尔列并入同表，避免再建表。

**实施步骤**
1. 迁移：

```sql
CREATE TABLE speech_progress (
  speech_id       TEXT PRIMARY KEY,
  last_index      INTEGER NOT NULL DEFAULT 0,
  completed_count INTEGER NOT NULL DEFAULT 0,
  favorite        INTEGER NOT NULL DEFAULT 0,
  updated_at      INTEGER NOT NULL
);
CREATE INDEX idx_progress_updated ON speech_progress(updated_at DESC);
```

2. `SpeechProgressRepo.touch(speechId, index, sentenceCount)`：`UPSERT`，`completed_count = MAX(completed_count, index+1)`。
3. `library_page.dart` 改为 `FutureBuilder`/`Stream`：先取 `listProgress()`，卡片右侧画 `completed_count/len` 的环，副标题"继续第 N 句 · 上次 3 小时前"。
4. 详情页 `initialIndex` 默认改为 `progress?.last_index ?? 0`；`ShadowingDetailPage` 在 `initState` 里 `_index = initialIndex`（当前已支持传参，只需把调用方改成读进度）。
5. 顶部"最近练习"：`ORDER BY updated_at DESC LIMIT 3`，横向卡片。

**所需资源**
- 人日：3
- 依赖：无
- 影响文件：`app_database.dart`、`speech_progress_repo.dart`(新)、`library_page.dart`、`speech_detail_page.dart`、`stats_page.dart`（可选加"最近"）

**预期效果**
- 退出再进入直接回到断点；内容库能看出每篇练了多少。
- 长内容（10 分钟以上）变得可行 —— 这是 P2 扩内容的前提。

**风险与坑**
- `initialIndex` 与统计页"一键重练"冲突：重练要"跳到指定句"而非"断点"，所以必须显式区分调用来源（`initialIndex` 优先，其次读断点）。
- 收藏与进度同表会让"仅收藏"清空进度的语义变怪：`last_index` 用 `NULL`-able 或加 `has_progress` 标记更稳。

---

### P1-5 统计升级：趋势曲线 + 连续打卡 + 目标提醒

**要解决的问题**
统计页只有 3 个数字 + 错词榜 + 复习列表；README 承诺的"趋势"没有图形；无连续打卡（streak）、无每日目标、无提醒 —— 缺少"每天都来"的机制设计。

**解决措施**
1. 日粒度聚合表 `daily_stats`（或直接 SQL 聚合 `attempts`，数据量小时够用；这里选后者，少一张表）。
2. 折线图用 `fl_chart`（成熟、维护活跃）：近 7 / 30 天句数与均分双轴。
3. Streak：按 `date(loacltime)` 连续天数计算，断一天归零，展示"最长连续"。
4. 每日目标（默认 5 句）+ 本地通知（`flutter_local_notifications` 定时 20:00，内容"今天还差 2 句"）。
5. 维度雷达（可选，P1 不做）：等 P2-5 有四维分再上。

**实施步骤**
1. `pubspec.yaml` 加 `fl_chart: ^0.69.0`、`flutter_local_notifications: ^17.2.0`（版本以 pub 最新稳定版为准，注意与 Flutter 3.29 的兼容性）。
2. `AppDatabase` 加：

```dart
/// 近 N 天：日期 → (句数, 均分)
Future<List<({String day, int count, double avg})>> dailySeries({int days = 30}) async {
  final db = await database;
  final since = DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch;
  final rows = await db.rawQuery(
    'SELECT date(practiced_at/1000,"unixepoch","localtime") AS d, '
    'COUNT(*) AS c, AVG(score) AS a FROM attempts '
    'WHERE practiced_at >= ? GROUP BY d ORDER BY d ASC', [since]);
  return [for (final r in rows) (day: r['d'] as String, count: r['c'] as int, avg: (r['a'] as num).toDouble())];
}
```

3. `services/streak.dart`：输入 `List<String> days`（升序 `yyyy-MM-dd`），输出 `current / longest`；纯函数可单测。
4. `stats_page.dart` 重构为三段：今日卡（含目标环形进度）→ 30 天折线 → 错词/复习。图表用 `LineChart` + 两条 `LineChartBarData`，均分单独右轴。
5. 通知：Android 需在 `AndroidManifest.xml` 加 `POST_NOTIFICATIONS`，首次开启时请求；iOS 加 `UNUserNotificationCenter` 授权。用 `zonedSchedule` + `matchDateTimeComponents: DateTimeComponents.time` 做每日重复。
6. 设置页：目标句数（3/5/10/20）、提醒开关与时间。

**所需资源**
- 人日：4（图表 1.5 + streak/目标 1 + 通知 1 + 打磨 0.5）
- 依赖：`fl_chart`、`flutter_local_notifications`、`timezone`（通知定时需要）
- 影响文件：`app_database.dart`、`streak.dart`(新)、`stats_page.dart`、`settings_page.dart`、`settings_controller.dart`、`AndroidManifest.xml`、`ios/Runner/AppDelegate.swift`

**预期效果**
- 统计页能看出"哪几天断了、均分在涨还是跌"；连续打卡数字可分享。
- 通知送达率 ≥ 95%（本地通知，无服务端依赖）。

**风险与坑**
- `flutter_local_notifications` 在 Android 13+ 必须动态申请通知权限，被拒后要引导到系统设置，否则"提醒功能静默失效"。
- 时区：`zonedSchedule` 必须传 `tz.local` 且启动时 `tz.initializeTimeZones()`，否则定时会按 UTC 触发（常见坑，表现是"提醒时间差 8 小时"）。
- 折线图在 0 数据日会断裂，需要按日期补齐 0 值，不能只画有数据的点。

---

### P1-6 评分可信度：稳定化 + 置信度 + 混淆音提示

**要解决的问题**
单次评分直接落库展示：同一句读三遍可能是 62 / 78 / 55，用户无法判断是"我进步了"还是"识别抖了"；出错只有红字，不知道"错在哪、怎么改"；薄弱的识别结果（超短句、语速异常）与正常结果同等呈现。

**解决措施**
分三块，全部可在现有 `aligner` + `attempts` 之上完成，不动识别引擎：
1. **稳定化**：结果页显示"本次 / 最好 / 近 5 次均值"三个数；趋势与统计用"近 5 次滑动均值"，单次极端值不污染曲线。
2. **置信度**：三条规则打分（高/中/低）——参考词数 < 3、识别为空、语速 = 词数 / 录音时长 落在 (0.8, 4.5) 词/秒之外，任一命中即标"识别可能不准，建议重读"。
3. **混淆音提示**：内置最小对立对表（约 20 组），错词命中即给中文提示文案。

**实施步骤**
1. `AppDatabase` 加查询：

```dart
/// 某句的历史最优与近 N 次均值
Future<({int? best, double? recentAvg, int attempts})> sentenceHistory(
    String speechId, int index, {int window = 5}) async {
  final db = await database;
  final rows = await db.query('attempts',
      columns: ['score'], where: 'speech_id = ? AND sentence_index = ?',
      whereArgs: [speechId, index], orderBy: 'practiced_at DESC', limit: window);
  if (rows.isEmpty) return (best: null, recentAvg: null, attempts: 0);
  final scores = [for (final r in rows) r['score'] as int];
  final best = await db.rawQuery(
      'SELECT MAX(score) AS m FROM attempts WHERE speech_id=? AND sentence_index=?',
      [speechId, index]);
  final avg = scores.reduce((a, b) => a + b) / scores.length;
  return (best: best.first['m'] as int?, recentAvg: avg, attempts: scores.length);
}
```

2. 结果面板顶部改为三段式：`本次 78`｜`最好 85`｜`近 5 次 74`；低于历史最优 15 分以上时提示"这次可能是识别抖动，可以再读一遍"。
3. 置信度计算（纯函数放 `services/confidence.dart`）：

```dart
enum Confidence { high, medium, low }

Confidence judge({required int refWords, required String recognized, required double seconds}) {
  if (recognized.trim().isEmpty) return Confidence.low;
  if (refWords < 3) return Confidence.low;              // 太短，对齐不可靠
  final wps = refWords / (seconds <= 0 ? 1 : seconds);  // 词/秒
  if (wps < 0.8 || wps > 4.5) return Confidence.low;    // 太慢/太快，多为例外
  if (wps < 1.2 || wps > 3.6) return Confidence.medium;
  return Confidence.high;
}
```

4. 混淆音表（`data/phoneme_hints.dart`）：

```dart
/// 词 → 针对性提示（按最小对立对组织，后续可扩到音素级）
const Map<String, String> kWordHints = {
  'think': 'th /θ/ 舌尖轻触上齿，别读成 s',
  'this':  'th /ð/ 声带要振动，别读成 z',
  'very':  'v 上齿咬下唇，别读成 w',
  'west':  'w 双唇收圆，别读成 v',
  'rice':  'r 舌尖不碰上腭，别读成 l',
  'life':  'l 舌尖抵上齿龈，别读成 r',
  'ship':  '短音 /ɪ/，别读成长音 /iː/',
  'sheep': '长音 /iː/，别读成短音 /ɪ/',
  // …
};
```

命中规则：错词包含该词（或该词的变形）→ 结果面板在错词下方显示一条提示，最多 2 条。
5. 统计口径切换：`stats_page` 的"今日均分"改为按句取"该句近 5 次均值"再平均，避免同一句反复重读拉偏。

**所需资源**
- 人日：3（历史查询 0.5 + 三数展示 0.5 + 置信度 0.5 + 提示表 1 + 统计口径 0.5）
- 依赖：无
- 影响文件：`app_database.dart`、`confidence.dart`(新)、`phoneme_hints.dart`(新)、`shadowing_detail_page.dart`、`stats_page.dart`

**预期效果**
- 同句重复练习的展示分波动 < 8 分（用同一段录音回放验证）。
- 每次出错至少有一条可执行的纠正建议（覆盖率：常见混淆词命中率 ≥ 70%）。

**风险与坑**
- "最好成绩"会让人停留在舒适区：建议默认展示"近 5 次均值"为主，最好成绩放小字。
- 提示表本质是查表，覆盖有限；P2-5 上音素级评分后应替换为真正的音素级诊断，这张表作为降级兜底。

---

### P1-7 解码移出 UI isolate

**要解决的问题**
`shadowing_recorder.dart:217` 在 stream 的 `listen` 回调里同步调用 `_asr.decodeSegment(segSamples)`。Whisper tiny.en 解码 3~5 s 音频在中端机上约 200~600 ms，这段时间主线程被占，表现为波形卡住、按钮无响应；复述 90 s 会连续触发多次。

**解决措施**
两个方案，按"是否必须实时看到识别文字"决策：

| 方案 | 做法 | 内存 | UI 体验 | 工作量 |
| --- | --- | --- | --- | --- |
| A 长驻解码 isolate（推荐） | `Isolate.spawn` 一个 worker，内部自建 `OfflineAsrService`，用 `SendPort` 收发 `TransferableTypedData` | +~95 MB（decoder 加载两份） | 实时字幕保留 | 2 人日 |
| B 停止后批量解码 | 录音期只做 VAD + 缓存 PCM 段，`stop()` 后统一解码 | 不变 | 录音期无实时字幕，停止后 0.5~1 s 出结果 | 1 人日 |

**推荐**：跟读用 A（单句，实时性重要），复述用 B（长录音，实时字幕价值低、内存省）。低端机（`ActivityManager.isLowRamDevice` / 可用内存 < 1.5 GB）统一降级到 B。

**实施步骤**
1. 新增 `lib/services/asr/decode_worker.dart`：

```dart
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'model_installer.dart';

class DecodeWorker {
  Isolate? _isolate;
  SendPort? _tx;
  final _rx = ReceivePort();
  final Map<int, Completer<String>> _pending = {};
  int _seq = 0;

  Future<void> start(ModelPaths paths) async {
    _rx.listen((msg) {
      if (msg is SendPort) {
        _tx = msg;
      } else if (msg is List && msg.length == 2) {
        _pending.remove(msg[0] as int)?.complete(msg[1] as String);
      }
    });
    _isolate = await Isolate.spawn(
      _workerMain,
      (reply: _rx.sendPort, paths: paths),
      debugName: 'asr-decode',
    );
  }

  Future<String> decode(Float32List samples) {
    final tx = _tx;
    if (tx == null) throw StateError('解码 worker 未就绪');
    final id = _seq++;
    final c = Completer<String>();
    _pending[id] = c;
    // 零拷贝把样本交给 isolate
    tx.send([id, TransferableTypedData.fromList([samples])]);
    return c.future;
  }

  void dispose() { _isolate?.kill(priority: Isolate.immediate); _rx.close(); }
}

/// isolate 入口：必须顶层函数
void _workerMain(({SendPort reply, ModelPaths paths}) args) async {
  sherpa.initBindings(); // 同步版即可，isolate 内无 binding 初始化限制
  final asr = _WorkerAsr();
  await asr.load(args.paths.newTier());
  final inbox = ReceivePort();
  args.reply.send(inbox.sendPort);
  await for (final msg in inbox) {
    if (msg is List && msg.length == 2) {
      final data = (msg[1] as TransferableTypedData).materialize();
      args.reply.send([msg[0] as int, asr.decode(data.asFloat32List())]);
    } else if (msg == 'quit') {
      break;
    }
  }
  asr.dispose();
  inbox.close();
}
```

> `_WorkerAsr` 是 `OfflineAsrService` 的精简拷贝（isolate 内不能复用带 Flutter 依赖的类，`OfflineAsrService` 只依赖 `sherpa_onnx`，可直接复用 —— 若无 Flutter 依赖就不必拷贝）。

2. `ShadowingRecorder` 增加 `DecodeMode { liveIsolate, batchAfterStop, sync }`；`_drainVad` 改为 `await` 或"发出去不等结果、结果回来再回调"。
3. 复述页（`retell_page.dart`）切 `batchAfterStop`：录音期只累计 `List<Float32List> _segments`，`_finish()` 时串行解码拼接 `_liveSpoken`。
4. 用 DevTools 时间线验证：录音 10 s 期间最长帧 < 16 ms（A）/ 无掉帧（B）。

**所需资源**
- 人日：2
- 依赖：无新依赖（`sherpa_onnx` 支持 isolate 内初始化）
- 影响文件：`decode_worker.dart`(新)、`asr_service.dart`（抽出无 Flutter 依赖的 core）、`shadowing_recorder.dart`、`retell_page.dart`

**预期效果**
- 录音期无 > 50 ms 卡顿；波形与 VAD 状态实时更新。
- 复述 90 s 从"边录边卡"变成"录完 1 s 内出结果"。

**风险与坑**
- 内存翻倍是真问题：低端机 decoder 加载两份可能被 LMK 杀掉。**必须做设备分级**，并暴露开关（设置页"实时识别"）。
- `TransferableTypedData` 传递后原 buffer 失效，调用方不能复用同一 `Float32List`。
- isolate 崩溃（ONNX OOM）不会抛到主 isolate，需要 `onError/onExit` 监听并降级回同步模式，否则表现为"一直转圈"。

---

### P1-8 首启引导 + 权限说明 + 隐私页

**要解决的问题**
首次点录音直接触发系统麦克风弹窗，没有任何前置解释（用户"不知道为什么、凭什么"）；无引导页说明产品怎么用、数据在哪；无隐私政策入口 —— 商店审核（尤其 iOS）会因此被拒。

**解决措施**
1. 3 页 onboarding（滑屏）：能做什么 → 怎么练（听→跟读→看反馈→复习）→ 数据只在本机（附权限说明）。
2. 权限预请求页：解释"需要麦克风录音做本地识别，录音不会上传"，用户点"允许"后再调系统弹窗；被拒时给"去设置"引导（`openAppSettings`）。
3. 首次进入跟读时若模型未装，串联 P0-4 的安装页。
4. 设置页加"隐私政策""开源许可"入口。

**实施步骤**
1. `shared_preferences` 存 `onboarded_v1`；`app.dart` 首帧判断，未完成则进 `OnboardingPage`。
2. 权限流程封装 `services/permission_flow.dart`：

```dart
/// 返回值：true=已授权，false=用户拒绝
Future<bool> ensureMicPermission(BuildContext ctx) async {
  final rec = AudioRecorder();
  if (await rec.hasPermission()) return true;
  if (!ctx.mounted) return false;
  final ok = await showDialog<bool>(context: ctx, builder: (_) => const _MicExplainDialog());
  if (ok != true) return false;
  return await rec.hasPermission(); // 系统弹窗在这一步
}
```

3. 被拒兜底：`permission_handler` 的 `openAppSettings()`，或提示手动路径（Android: 设置→应用→权限）。
4. 隐私页：静态 Markdown 渲染（`flutter_markdown` 或直接 `Text` 分段），内容含"录音/识别/评分全部本机完成；词典发音首次联网下载（有道音源），其余不联网"。
5. `AndroidManifest.xml` / `Info.plist` 文案与文案页保持一致。

**所需资源**
- 人日：2
- 依赖：`permission_handler: ^11.3.1`（可选，用于跳系统设置）
- 影响文件：`onboarding_page.dart`(新)、`permission_flow.dart`(新)、`privacy_page.dart`(新)、`app.dart`、`main.dart`、`settings_page.dart`

**预期效果**
- 首次录音授权率提升（有解释的预请求通常比裸弹窗高 15~25 个百分点）。
- 具备上架所需的隐私说明与权限文案一致性。

**风险与坑**
- **不要滥用 `permission_handler`**：`record` 自带 `hasPermission()` 就能弹窗，`permission_handler` 只用于"跳到系统设置"这一个场景，避免两套权限状态打架。
- 引导页不要放"必须同意才能用"的协议墙（国内合规需可关闭），否则审核与体验双输。

---

## 阶段 P2 · 内容规模化与专业性（53 人日）

### P2-1 内容管线升级：词级时间戳 + 修复 clips 丢失

**要解决的问题**
两个问题叠加：
1. 内容 JSON 只有句级 `startTime/endTime`，没有词级时间，P2-3 的逐词高亮与点词跳转无法实现。
2. **隐藏地雷**：`tools/generate_timestamps.dart:181-198` 输出的 JSON 字段只有 `id/title/speaker/level/durationMs/coverUrl/audioPath/sentences`，**不包含 `clips`**。也就是说，现在对已有演讲重跑一次工具，会直接清空手写的 4 段复述关键点（`matt_cutts_30_days.json` 里 4 个 clip、26 个 keyPoint）。

**解决措施**
1. 工具升级为"增量、可批量、保留人工字段"：
   - 读取已有 JSON 的 `clips` / 人工校对的 `translation`，生成时原样写回。
   - 新增 `words: [{w, s, e}]`（句内词级起点/终点）；未对齐词用前后词线性插值。
   - 支持 `--id=xxx` / `--all` 参数，按 id 覆盖写入，不再硬编码 `speechIndex = 0`。
   - 生成前做断言：`words.length == tokenize(text).length`，否则该句降级为"整句时间 + 词等分"。
2. 增加校对钩子：输出 `report.md`（对齐率 < 90% 的句子清单），人工只改这几句。

**实施步骤**
1. `main()` 参数化：

```dart
void main(List<String> argv) {
  final ids = _parseIds(argv); // --id=a,b 或 --all
  for (final id in ids) {
    final speech = kSpeechLibrary.firstWhere((s) => s.id == id);
    _generateFor(speech);
  }
}
```

2. 词级时间写入（在"聚合到句子"之后追加）：

```dart
/// 句内词 → [start,end]；未对齐词用相邻已对齐词线性插值
List<Map<String, dynamic>> wordsOfSentence(int s) {
  final refsOfS = refs.where((r) => r.sentence == s).toList();
  final out = <Map<String, dynamic>>[];
  for (var k = 0; k < refsOfS.length; k++) {
    final m = refsOfS[k].match;
    double st, et;
    if (m != null) {
      st = m.fromMs / 1000.0;
      et = m.toMs / 1000.0;
    } else {
      // 插值：取前一个已对齐词的结束、后一个已对齐词的开始，按词序等分
      final prevEnd = k > 0 ? (out[k - 1]['e'] as double) : starts[s];
      final nextStart = refsOfS.skip(k + 1)
          .map((r) => r.match)
          .whereType<HWord>()
          .firstOrNull
              ?.fromMs
              .toDouble() ?? ends[s] * 1000;
      final gap = (nextStart / 1000.0 - prevEnd) / 2;
      st = prevEnd;
      et = prevEnd + (gap > 0.02 ? gap : 0.12);
    }
    out.add({'w': refsOfS[k].word, 's': double.parse(st.toStringAsFixed(3)),
             'e': double.parse(et.toStringAsFixed(3))});
  }
  return out;
}
```

3. 合并人工字段：

```dart
Map<String, dynamic>? old;
final existing = File(outPath);
if (existing.existsSync()) {
  old = jsonDecode(existing.readAsStringSync()) as Map<String, dynamic>;
}
out['clips'] = old?['clips'] ?? [];           // ← 关键：不再清空
// translation 也保留人工校对版本
for (var s = 0; s < sentences.length; s++) {
  sentences[s]['translation'] = old?['sentences']?[s]?['translation']
      ?? speech.sentences[s].chinese;
}
```

4. 生成前校验 + 报告：

```dart
final covered = words.where((w) => /* 已对齐 */ true).length;
if (covered / words.length < 0.9) warnings.add('句 ${s + 1} 词级对齐率偏低');
```

5. 文档化：`tools/README.md` 写清"whisper-cli -ojf 产物 → 本脚本 → assets/content"，以及"重跑安全：保留 clips/translation"。

**所需资源**
- 人日：5（工具改造 2.5 + 插值/校验 1 + 批量与报告 1 + 文档 0.5）
- 依赖：`whisper.cpp`（`tools/whisper/`，已有）
- 影响文件：`tools/generate_timestamps.dart`、`tools/README.md`(新)、`assets/content/*.json`

**预期效果**
- 新演讲从音频到入库 ≤ 15 分钟；词级时间戳覆盖 100% 句子（插值兜底）。
- 重跑工具不再破坏人工数据（回归测试：跑两次，`clips` 内容字节一致）。

**风险与坑**
- `durationMs` 现在写的是 `speech.duration`（硬编码 210 s），与真实音频长度可能不符 → 用 `player` 解析的时长或 whisper 最后一个 token 覆盖。
- 插值产生的词级时间在长停顿处会漂移；对"点词发音"够用（±0.2 s），对卡拉OK式高亮需人工抽查 10% 句子。
- **先写回归用例再改工具**：拿现有 JSON 跑一遍，断言 `clips.length == 4`，否则容易"改完才发现又清了一次"。

---

### P2-2 内容运营：20~50 篇分级演讲 + 搜索筛选

**要解决的问题**
内容只有 1 篇，练完即走。这是唯一无法靠代码优雅度弥补的短板，也是最直接的留存瓶颈。

**解决措施**
1. 选片标准（可执行清单）：时长 3~6 分钟、语速 120~170 wpm、口音明确（美音为主，掺 20% 英音/澳音）、版权可商用（TED 官方 CC BY-NC-ND 需注意；建议自录/公有领域/授权素材）。
2. 分级规则：`入门 = 高频词占比 > 85% 且语速 < 140 wpm`；`进阶 = 其余`。用脚本按 ECDICT 词频自动打标，人工复核。
3. 内容库改造：搜索框 + 标签筛选（难度/时长/主题/口音）+ 排序（最近/完成度/难度）。
4. 每篇内容的生产模板与工时表（转写校对 30~60 min + 关键点标注 20 min + 音频处理 10 min）。

**实施步骤**
1. 先做 5 篇试点（含 1 篇英音、1 篇快语速），验证 P2-1 管线与 P2-3 词级交互。
2. 打标脚本 `tools/tag_level.dart`：读 JSON → 算高频词覆盖 + wpm → 输出 `level`，人工确认后回写。
3. `library_page.dart` 重构：顶部 `SearchBar` + `FilterChip` 行；数据源从 `kSpeechLibrary` 改为 `SpeechRepo（内置 + 远端 manifest）`，为 P2-4 铺路。
4. 内容清单维护在 `assets/content/index.json`（id/title/speaker/level/duration/tags/cover），App 启动读 index 而不是 import 常量 —— 这一步是"能扩到 50 篇"的架构前提（`kSpeechLibrary` 硬编码列表不适合规模化）。

**所需资源**
- 人日：8（内容生产按 5 篇/人日估；代码改造 3）
- 依赖：音频素材版权、转写工具
- 影响文件：`library_page.dart`、`speech_repository.dart`(新)、`assets/content/index.json`(新)、`data/speech_library.dart`（降级为 seed 数据）

**预期效果**
- 20 篇可练（累计约 90 分钟素材）；按难度/时长可筛；搜索 200 ms 内出结果。
- 内容新增不再需要改 Dart 代码（只加 JSON + index 条目）。

**风险与坑**
- **版权是第一风险**：TED 演讲音频默认 CC BY-NC-ND，商用/改作受限。上线前必须逐条确认授权，或改用可商用素材（LibriVox、自有录制、授权播客）。
- `kSpeechLibrary` 是 `const` 列表，`generate_timestamps.dart` 直接 import 它 —— 迁移到 `index.json` 时工具也要一起改，否则内容管线断链。
- 每篇都要人工标注 keyPoints，这是**内容成本的大头**，不能只算音频和转写。

---

### P2-3 词级交互：逐词高亮 + 点词跳转发音

**要解决的问题**
没有词级时间戳（P2-1 解决数据侧），UI 侧也缺交互：现在点词只弹词典，无法"听这个词在原声里怎么读"，也没有跟读时的卡拉OK式高亮。

**解决措施**
1. 数据驱动：`TranscriptSentence` 增加 `List<WordTime> words`，`fromJson` 兼容缺失（老 JSON 无 `words` 时降级为句级）。
2. 播放高亮：`positionStream` → 二分查找当前词 → `RichText` 逐词着色（未读灰、已读主色、当前词加底）。
3. 点词交互：单击 → 播放该词原声片段（`seek(word.s - 0.15)`，`end = word.e + 0.15`）；长按 → 词典弹窗（复用 `DictionaryPopup`）。这两个手势要区分（`onTap` vs `onLongPress`），并在引导里说明。

**实施步骤**
1. 模型层：

```dart
class WordTime {
  final String word; final double start; final double end;
  const WordTime({required this.word, required this.start, required this.end});
  factory WordTime.fromJson(Map<String, dynamic> j) =>
      WordTime(word: j['w'] as String,
               start: (j['s'] as num).toDouble(),
               end: (j['e'] as num).toDouble());
}
```

2. `TappableText` 改为接收 `List<WordTime>` + `currentIndex`，内部按词渲染 `TextSpan` 并用 `GestureRecognizer` 绑定点击（注意 `TextSpan.recognizer` 需要 dispose，建议用 `WidgetSpan` + `InkWell` 或自建 `Wrap` 布局，后者更省心）。
3. 高亮控制器：`SentenceHighlighter` 订阅 `positionStream`，`binarySearch(words, pos)` 求当前词下标，仅在变化时 `notifyListeners()`（避免每 200 ms 重建）。
4. 点词播放：复用单个 `AudioPlayer` 实例，`await player.seek(...); player.play();` 并在 `end + 0.2` 处暂停（用 `positionStream` 判断，参考 `retell_page._onPosition` 已有写法）。
5. 跟读页的"实时对齐视图"（`_liveWordsView`）也接同一套高亮，形成"原声读→我跟读"的视觉一致。

**所需资源**
- 人日：4
- 依赖：无（`just_audio` 已有）
- 影响文件：`models/speech.dart`（重建，含 `WordTime`）、`tappable_text.dart`、`sentence_highlighter.dart`(新)、`shadowing_detail_page.dart`、`listening_page.dart`

**预期效果**
- 点任意词 300 ms 内听到该词原声（±0.15 s 精度）；播放时词级高亮误差 < 150 ms。
- 用户查词路径从"输入单词"变成"点一下"，与 VoiceTube 的交互对齐。

**风险与坑**
- 密集手势：一句话 20 个词各自一个 `GestureDetector` 会拖慢滚动；用 `Wrap` + `Text` 而非 `RichText` 时注意换行断词位置（英文按空格断，需保留空格宽度）。
- 高频 `setState` 是性能陷阱：高亮状态必须走 `ValueNotifier` + 局部 `AnimatedBuilder`，不能整页 `setState`。
- 词级时间与句级时间可能有 50~100 ms 不一致（插值导致），点词播放时用词级时间，句循环用句级时间，二者不要混用。

---

### P2-4 按需内容包：模型与音频首次使用时下载

**要解决的问题**
99 MB 模型 + 3 MB 音频随包分发，安装包体积大、首启慢，且每加一篇内容都要重新发版。

**解决措施**
1. 引入"内容包"概念：`manifest.json`（远端）描述 `{id, version, size, sha256, url, type: audio|model|content}`。
2. App 内 `ContentInstaller`：下载 + 断点续传 + sha256 校验 + 解压 + 落盘到 `support/content/<id>/`。
3. 模型同样走该通道（首次跟读前下载 tiny.en），首装包可降到 30 MB 以内。
4. 存储管理页：已下载内容列表、单条删除、总占用。

**实施步骤**
1. 远端结构：

```
https://cdn.example.com/ted/
  manifest.json
  content/matt_cutts_30_days.json
  audio/matt_cutts_30_days.mp3
  models/tiny.en-encoder.int8.onnx
  models/tiny.en-decoder.int8.onnx
```

```json
{
  "version": 3,
  "items": [
    {"id":"matt_cutts_30_days","type":"audio","v":1,"size":3047546,
     "sha256":"...","url":"audio/matt_cutts_30_days.mp3"},
    {"id":"tiny.en-decoder.int8.onnx","type":"model","v":1,"size":89853865,
     "sha256":"...","url":"models/tiny.en-decoder.int8.onnx"}
  ]
}
```

2. 下载器（`http` + `RandomAccessFile` 支持 Range 续传）：

```dart
Future<File> download(ManifestItem item, {void Function(double)? onProgress}) async {
  final target = File(await _pathFor(item));
  var downloaded = await target.exists() ? await target.length() : 0;
  final req = http.Request('GET', Uri.parse(item.url))
    ..headers['Range'] = 'bytes=$downloaded-';
  final resp = await req.send();
  if (resp.statusCode != 206 && downloaded > 0) downloaded = 0; // 服务端不支持续传
  final sink = target.openWrite(mode: FileMode.append);
  var got = downloaded;
  await for (final chunk in resp.stream) {
    sink.add(chunk);
    got += chunk.length;
    onProgress?.call(got / item.size);
  }
  await sink.close();
  if (await _sha256(target) != item.sha256) {
    await target.delete();
    throw StateError('校验失败，请重试');
  }
  return target;
}
```

3. 分发：对象存储 + CDN（国内需备案域名；若只发海外可用 GitHub Release）。manifest 带版本号，App 启动比对增量更新。
4. `AssetManifest` 依赖全部改为文件系统读取；`rootBundle.load` 只保留词典与 index。

**所需资源**
- 人日：5
- 依赖：`http`/`dio`、`crypto`（sha256）、对象存储 + CDN（运营成本）
- 影响文件：`content_installer.dart`(新)、`manifest.dart`(新)、`model_installer.dart`（改为走 installer）、`storage_page.dart`(新)、`pubspec.yaml`

**预期效果**
- 首装 APK < 30 MB；模型/内容增量更新不发版。
- 弱网可续传（断点续传到字节级），失败重试成功率 > 95%。

**风险与坑**
- **离线定位冲突**：产品主打"完全离线"，按需下载意味着"首次需要联网"。必须在商店描述与引导页讲清楚："练习过程离线；素材安装需联网一次"。否则用户会认为被欺骗。
- 国内 CDN 需备案与合规，海外 CDN 在大陆慢；这是运营决策，不是纯技术问题。
- sha256 校验失败要能自愈（删文件重下），否则用户会永久卡在"文件损坏"。

---

### P2-5 评分引擎升级：四维分 + 音素级诊断

**要解决的问题**
当前只有"词串命中率"一维，无法区分"读错音"与"少读词"，也无法评价流利度与韵律；这正是用户觉得"分数不可信"的根因。

**解决措施**
三种路线，按投入/风险分层：

| 路线 | 内容 | 成本 | 数据出境 | 精度 |
| --- | --- | --- | --- | --- |
| A 端侧四维（推荐先做） | 用现有识别结果 + 时间信息算 accuracy / fluency / completeness / 语速与停顿 | 1 周 | 否 | 中（韵律只能粗估） |
| B 云端 Azure 发音评估 | 上传 16 kHz WAV，直接返回四维 + 音素级误差 | 3~5 天接入 | **是** | 高 |
| C 端侧音素级 GOP | wav2vec2 phoneme CTC + onnxruntime + 强制对齐，自算 GOP | 2~3 周，+95~300 MB | 否 | 高（需调参） |

**推荐组合**：先做 A（覆盖 80% 价值、零风险），把 B 作为"精修/高级"可选功能（明确弹窗告知上传），C 视长期定位再定。

**实施步骤（路线 A）**
1. 四个维度定义与算法：
   - `accuracy` = 现有 `correct / total`（保留，但加权：实词权重 1.0，功能词 0.6，避免 "the/a" 拉低分数）。
   - `completeness` = `已读词 / 参考词`（missed 不计入）。
   - `fluency` = 基于 VAD 段内静音占比 + 语速偏离度：`1 - min(0.5, |wpm - 目标wpm| / 目标wpm * 0.5)`，目标 wpm 取原声片段实测值（P2-1 已能算）。
   - `prosody`（粗估）= 重音位置匹配率：先不做，占位显示"—"，避免给假数据。
2. `services/scoring/score_engine.dart` 输出统一结构：

```dart
class ScoreBreakdown {
  final int accuracy, fluency, completeness;   // 0~100
  final int? prosody;                          // null = 未实现，UI 显示 "—"
  final double wpm;
  final int pauseCount;
  final String engine;                         // 'local-v1' / 'azure'
  const ScoreBreakdown({required this.accuracy, required this.fluency,
      required this.completeness, this.prosody, required this.wpm,
      required this.pauseCount, required this.engine});
  int get overall => ((accuracy * 0.5 + fluency * 0.3 + completeness * 0.2)).round();
}
```

3. `attempts` 表加列：`fluency INTEGER, completeness INTEGER, wpm REAL, engine TEXT`（v6 迁移），保留 `score` 作为 `overall` 兼容旧逻辑。
4. 结果页改四维条形图（横向进度条），overall 大数字，标注引擎（"本地评分"）。
5. 路线 B 接入（可选开关）：`services/scoring/azure_pronunciation.dart`，`POST` 到 `https://<region>.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1?language=en-US` 带 `Pronunciation-Assessment` header（Base64 JSON 配置）；解析 `NBest[0].PronunciationAssessment`。**必须**：只在用户显式开启时上传、上传前弹窗告知、文本与录音不落任何服务端日志（业务侧承诺）。
6. 路线 C 预留接口：`ScoreEngine` 抽象成接口，三实现可切换，`engine` 字段落库便于 A/B 对比。

**所需资源**
- 人日：A 5 + B 3 + C 15（不建议现在做）
- 依赖：A 无；B `http` + Azure 订阅（按次计费）；C `onnxruntime` + phoneme 模型 + CMUdict
- 影响文件：`score_engine.dart`(新)、`azure_pronunciation.dart`(新/可选)、`app_database.dart`、`shadowing_detail_page.dart`、`retell_page.dart`、`settings_page.dart`

**预期效果**
- 四维分能区分"读错音"（accuracy 低、completeness 高）与"漏读"（两者都低）；
- 与 Azure 参考实现在 20 条样本上 overall 偏差 < 10 分（作为验收基准）；音素级诊断仅在 B/C 路径提供。

**风险与坑**
- **不要给假维度**：prosody 算不出来就显示"—"，比编一个数更可信。
- Azure 上传录音涉及个人信息，国内合规需单独告知与授权，且要提供"纯本地模式"开关；离线是产品卖点，不能为了精度牺牲定位。
- 换引擎会让历史分数不可比：`engine` 字段必须落库，统计页按 engine 分组，或统一重算历史分（不推荐，数据会被污染）。

---

### P2-6 架构重构：Riverpod + go_router + 分层

**要解决的问题**
`shadowing_detail_page.dart` 1298 行（占 lib 19%），状态机（`Phase` 7 态）与 UI 混写；全局单例 `AppDatabase.instance` / `DictionaryService.instance` 无法在测试里替换；页面跳转直接 `Navigator.push`，深链与返回栈不可控。

**解决措施**
分三步走，**不一次性大爆炸**：
1. 第一步（低风险）：抽状态机为纯 Dart 类 `ShadowingSession`（无 `BuildContext`），页面只做 `AnimatedBuilder` 渲染。这一步不需要引入 Riverpod，收益最大。
2. 第二步：引入 `flutter_riverpod`，把 `settings / database / vocab / speech_repo / content_installer` 变成 Provider，消除单例；页面用 `ConsumerWidget`。
3. 第三步：引入 `go_router`，路由表集中声明（`/library/:id/shadowing/:index`），支持深链（通知点击直达某句）与 `PopScope` 拦截录音中返回。

**实施步骤**
1. 目标目录：

```
lib/
  app/            # app.dart, router.dart, providers.dart
  core/           # theme, widgets, utils
  data/           # models, repositories, db
  services/       # asr, tts, audio, installer
  features/
    library/  shadowing/  retell/  listening/  review/  vocab/  stats/  settings/
      ├── <name>_page.dart
      ├── <name>_controller.dart   # 状态机/逻辑
      └── widgets/                 # 页面私有组件
```

2. 状态机抽离示例：

```dart
class ShadowingSession extends ChangeNotifier {
  ShadowingSession({required this.speech, required this.repo, required this.scorer});
  Phase phase = Phase.idle;
  int index = 0;
  List<AlignedWord> aligned = const [];

  Future<void> startRecording() async { /* 原 _startRecording 逻辑 */ }
  Future<void> finalize() async { /* 原 _finalizeScoring 逻辑，含落库 */ }
  void next() { /* ... */ }
}
```

页面：

```dart
class ShadowingDetailPage extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(shadowingSessionProvider(speechId));
    return AnimatedBuilder(animation: s, builder: (_, __) => _scaffold(s));
  }
}
```

3. Provider 化单例：

```dart
final dbProvider = Provider<AppDatabase>((ref) => AppDatabase.instance);
final vocabRepoProvider = Provider((ref) => VocabRepository(ref.watch(dbProvider)));
```

测试里 `ProviderScope(overrides: [dbProvider.overrideWithValue(fakeDb)])`。
4. 路由表 + 深链；`PopScope(canPop: !session.isRecording)` 防误退（当前 `dispose` 会 `unawaited(stop())`，录音中直接返回可能丢数据）。
5. 每步一个 PR，每步都跑 `flutter analyze` + 现有测试 + 手工冒烟（跟读/复述/统计/设置四条主路径）。

**所需资源**
- 人日：10（状态机 3 + Riverpod 3 + router 2 + 回归 2）
- 依赖：`flutter_riverpod: ^2.5.1`、`go_router: ^14.2.0`
- 影响文件：全 `lib/`（分步进行，单 PR < 400 行 diff）

**预期效果**
- 最大单文件 < 400 行；`ShadowingSession` 可脱离 Flutter 单测（`flutter test` 里不需要 `pumpWidget`）。
- 录音中误返回会二次确认；通知可直达指定句。

**风险与坑**
- **不要在 P0/P1 之前做**：现在重构会与 P1 的新功能（录音/生词/SRS）大面积冲突，返工成本远大于收益。
- Riverpod 与现有 `InheritedNotifier`（`SettingsScope`）会短暂共存，必须定一个迁移顺序（先 settings → 再 db → 最后页面），否则 `SettingsScope.of(context)` 返回 null 的旧代码会静默失效。
- `just_audio` 实例生命周期要与页面解绑（放 `Provider.autoDispose` + `ref.onDispose`），否则重构后容易出现"两个 player 同时播"。

---

### P2-7 测试与 CI

**要解决的问题**
只有 1 个 widget 测试 + 11 条纯 Dart 断言；评分、对齐、DB、状态机这些"最容易错"的部分没有任何回归保护；没有 CI，靠人工记得跑测试。

**解决措施**
1. 测试分层：纯逻辑单测（aligner / srs / streak / confidence / scorer）→ 仓储测试（sqflite FFI 内存库）→ widget 测试（关键交互）→ 集成测试（一条主流程）。
2. CI 三件事：`dart format --set-exit-if-changed`、`flutter analyze`、`flutter test`（matrix: ubuntu + windows）。
3. 覆盖率门槛：核心逻辑 ≥ 60%，不追求全库。

**实施步骤**
1. 单测（无需设备）：

```dart
// test/unit/srs_test.dart
test('答对 3 次后间隔按 ease 增长', () {
  var c = const SrsCard();
  for (var i = 0; i < 3; i++) {
    c = review(c, 5).card;
  }
  expect(c.intervalDays, greaterThanOrEqualTo(6));
  expect(c.ease, greaterThan(2.5));
});

test('答错清零并明天再练', () {
  final r = review(const SrsCard(intervalDays: 10, reps: 4), 1);
  expect(r.card.intervalDays, 1);
  expect(r.card.reps, 0);
  expect(r.card.lapses, 1);
});
```

2. 仓储测试（`sqflite_common_ffi`，Windows/CI 都能跑）：

```dart
setUpAll(() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
});
test('topWrongWords 只统计近 90 天', () async { /* … */ });
```

3. 集成测试（`integration_test`）：启动 → 选演讲 → 用 mock recorder 注入固定识别文本 → 断言评分与落库。录音层抽 `RecorderPort` 接口以便注入 fake（P2-6 的副产品）。
4. CI 配置 `.github/workflows/ci.yml`：

```yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    strategy:
      matrix: { os: [ubuntu-latest, windows-latest] }
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { channel: stable }
      - run: flutter pub get
      - run: dart format --set-exit-if-changed lib test
      - run: flutter analyze
      - run: flutter test --coverage
```

5. 本机注意：README 里提到的"用户名含撇号 + 代理变量"两坑在 CI 上不存在（干净路径、无代理），但**本地跑测试仍要走 `tools/run_tests.ps1`**，CI 与本地命令要保持等价（否则"CI 绿本地红"会消耗信任）。

**所需资源**
- 人日：6（单测 2 + 仓储 1.5 + 集成 1.5 + CI 1）
- 依赖：`sqflite_common_ffi`、`integration_test`（SDK）、`mocktail`
- 影响文件：`test/**`、`.github/workflows/ci.yml`、`tools/run_tests.ps1`（对齐参数）

**预期效果**
- CI 全绿，PR 阶段就能拦住"评分算法改坏了"这类回归。
- 覆盖率核心逻辑 ≥ 60%（`lcov` 报告可查）。

**风险与坑**
- widget 测试里的 `BackdropFilter` + 动画会导致 `pumpAndSettle` 超时，需要 `pump(Duration)` 手动推进；玻璃 UI 的测试要避开 `pumpAndSettle`。
- `sherpa_onnx` 在测试环境无法初始化原生库，**所有涉及 ASR 的测试必须注入 fake**，否则 CI 直接崩。

---

### P2-8 发布就绪：包名/签名/版本/崩溃上报/i18n

**要解决的问题**
`applicationId = com.example.ted_companion`（商店不接受 `com.example`）、release 用 debug 签名（无法上传、无法升级）、版本恒为 `0.1.0+1`、无崩溃上报、全中文硬编码（无法出海）。

**解决措施**
1. 包名与签名：改 `com.<组织>.tedcompanion`（**一旦上架不可更改**），生成 keystore 并写入 `key.properties`（不入库），`build.gradle.kts` 的 release 指向正式签名。
2. 版本策略：`major.minor.patch+build`，每个上架包 build 号自增；CI 里由 tag 驱动。
3. 崩溃上报：`sentry_flutter`，**默认关闭，首次启动询问**（离线产品不宜默认上传）。
4. i18n：`flutter_localizations` + `intl`，把 widget 里的中文字符串抽到 `l10n/app_zh.arb` / `app_en.arb`，至少支持中/英。
5. 商店材料：隐私政策页、权限说明、截图（6 张）、应用描述。

**实施步骤**
1. 包名 + 签名：

```kotlin
// android/app/build.gradle.kts
val keystoreProps = java.util.Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
android {
    defaultConfig { applicationId = "com.yourorg.tedcompanion" }
    signingConfigs {
        create("release") {
            storeFile = keystoreProps["storeFile"]?.let { file(it) }
            storePassword = keystoreProps["storePassword"] as String?
            keyAlias = keystoreProps["keyAlias"] as String?
            keyPassword = keystoreProps["keyPassword"] as String?
        }
    }
    buildTypes { release { signingConfig = signingConfigs.getByName("release") } }
}
```

2. i18n：

```yaml
flutter:
  generate: true
dependencies:
  flutter_localizations: { sdk: flutter }
  intl: ^0.19.0
```

`l10n.yaml` + `MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates, supportedLocales: const [Locale('zh'), Locale('en')])`；文案用 `AppLocalizations.of(context)!.startRecording`。
3. Sentry（可开关）：

```dart
await SentryFlutter.init((o) {
  o.dsn = const String.fromEnvironment('SENTRY_DSN');
  o.tracesSampleRate = 0.1;
  o.beforeSend = (e, {hint}) => prefs.crashReport ? e : null; // 用户未同意则丢弃
}, appRunner: () => runApp(...));
```

4. 版本：`pubspec.yaml version: 1.0.0+1`，CI 按 tag 注入 `--build-name/--build-number`。
5. 清单核对：iOS `Info.plist` 的 `NSMicrophoneUsageDescription` 已有且文案准确（已核实），无需改；Android `label` 与图标需替换为正式素材（当前是 Flutter 默认图标）。

**所需资源**
- 人日：5（签名/包名 1 + i18n 2 + Sentry 0.5 + 商店材料 1.5）
- 依赖：`sentry_flutter`、`flutter_localizations`、`intl`；keystore（需组织信息，**丢失即无法更新**）
- 影响文件：`build.gradle.kts`、`key.properties`(不入库)、`l10n.yaml`、`lib/l10n/*.arb`、全页面文案、`app.dart`、`main.dart`、`pubspec.yaml`

**预期效果**
- 可产出可上传的 release AAB；崩溃率可观测（同意率内的样本）。
- 中英双语可切换；新增语言只加 arb 文件。

**风险与坑**
- **包名与 keystore 是不可逆的**：包名上传后不能改；keystore 丢失 = 永远无法更新同一应用。必须把 keystore 与口令存进团队密码库并备份两处。
- 隐私政策必须写清"词典发音首次联网下载（有道音源）、素材安装需联网、其余本地"——与实际行为一致，否则应用商店与合规都会卡。
- i18n 抽取会大面积改 widget，建议与 P2-6 重构合并做（都要动页面），避免两次全量踩点。

---

## 汇总

### 工时与依赖

| 阶段 | 项数 | 人日 | 关键前置 |
| --- | --- | --- | --- |
| P0 | 7 | 12 | 无 |
| P1 | 8 | 27 | P0-4（安装器）、P0-6（DB 迁移基线） |
| P2 | 8 | 53 | P1-1（录音）、P1-3（SRS）、P2-1（词级数据） |
| 合计 | 23 | 92 | — |

### 新增依赖清单

| 依赖 | 用于 | 项 |
| --- | --- | --- |
| `fl_chart` | 趋势图 | P1-5 |
| `flutter_local_notifications` + `timezone` | 每日提醒 | P1-5 |
| `permission_handler` | 跳系统设置 | P1-8 |
| `http` / `dio` + `crypto` | 按需下载与校验 | P2-4 |
| `flutter_riverpod` + `go_router` | 状态管理与路由 | P2-6 |
| `sqflite_common_ffi` + `mocktail` | 测试 | P2-7 |
| `sentry_flutter` | 崩溃上报（可关） | P2-8 |
| `flutter_localizations` + `intl` | 中英双语 | P2-8 |
| `onnxruntime`（仅路线 C） | 音素级评分 | P2-5 |

### 顺序约束（必须遵守的三条）

1. **P0-6 先于所有 DB 改动**：P1-1（`audio_path`）、P1-2（`vocab`）、P1-3（`review_cards`）、P1-4（`speech_progress`）都在 v4 之后做增量迁移，否则迁移链会乱。
2. **P2-1 先于 P2-3**：没有 `words` 时间戳，词级高亮与点词跳转无数据可依。
3. **P2-6 在全量 i18n 之前**：两者都要动所有页面，合并做一次，避免二次踩点。

### 上线前硬门槛（不可省）

- 包名不得为 `com.example.*`；release 必须正式签名（P2-8）
- 隐私政策与实际行为一致：录音/识别/评分本机；词典发音与素材安装需联网（P1-8、P2-4、P2-8）
- 内容版权逐条确认（P2-2）
- `flutter analyze` 0 error、CI 绿、主流程手工冒烟通过（P2-7）
