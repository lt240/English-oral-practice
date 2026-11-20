# TED 跟读助手 · 问题排查报告（2026-11-13）

排查范围：`C:\Users\L't\Desktop\TED` 整个仓库（lib/ 30 个手写 Dart 文件、assets 内容与音频、android/ios 配置、dist 安装包、tools 与 docs）。
排查方式：静态分析 + 单元测试实跑 + 二进制/资源实测（MP4 原子解析、APK 解包统计）+ 逐模块代码走查。
本文只记录**经过证据核实**的问题；末尾列出已核实正常项与未覆盖项。

---

## 一、先给结论

| 级别 | 条目 | 一句话 |
| --- | --- | --- |
| P0 | 1 | 交付的 APK 是 **debug/JIT 构建**，不是 release |
| P0 | 2 | 「arm64」安装包里塞了 **3 套 ABI** 原生库，多占约 117 MB |
| P0 | 3 | `ted_12.mp4`（37 MB，只有视频轨）**打进包但没有任何内容引用** |
| P0 | 4 | 复述评分对 **13/14 篇无要点**，分数恒为 0（内容缺口，入口守卫失效） |
| P1 | 5 | 跟读录音在默认设置下**可能没有停止出口**，且无最长时长兜底 |
| P1 | 6 | 跟读页顶部进度条/时间**不跟随播放**（放原声的十几秒是静止的） |
| P1 | 7 | 复述录音前不停原声 → 麦克风录到原声，**要点覆盖率天然 100%** |
| P1 | 8 | `ShadowingRecorder` 释放有竞态，dispose 后仍会 `notifyListeners` |
| P1 | 9 | Whisper 解码在**主 isolate 同步执行**，每出一句卡一次 UI |
| P2 | 10 | 内容存在两份真相（运行时又去读 assets JSON） |
| P2 | 11 | 首启复制 99 MB 模型：内存峰值高 + 存储双份 |
| P2 | 12 | 对外文案「不依赖联网」与词典发音实际联网不符 |
| P2 | 13 | 列表页 `didChangeDependencies` 里全量查库 |
| P2 | 14 | 设置项枚举恢复无越界保护 |
| P3 | 15-17 | 监听页订阅未取消 / 无稿内容进度条恒 0（潜在）/ 词级刷新开销 |

其中 3、4 与 `docs/DATA_AUDIT_FIX_PLAN.md` 的 #8、#11 重叠（已登记为 🔴 但至今未解决）；1 的成因与 `README.md`「本机环境坑」第 3 条一致。

---

## 二、逐个问题的证据与建议

### P0-1 交付包是 debug 构建

**证据**（解包 `dist/TED-companion-arm64.apk`，474,381,370 字节，解压后 528.6 MB）：

- `lib/` 下**没有任何 `libapp.so`** → 说明走的是 JIT/debug 产物；
- 却存在 `assets/flutter_assets/kernel_blob.bin`（57.3 MB）与 `isolate_snapshot_data`（11.1 MB）——这两个只在 debug/JIT 包里出现；
- 还有 `lib/arm64-v8a/libVkLayer_khronos_validation.so`（14.5 MB），Vulkan 校验层同样只在 debug/profile 带。

**成因**：`README.md` 已记录——本机 Windows Defender 拦截 `gen_snapshot.exe`（AOT 编译器），`build apk --release` 必失败，只能用 `--debug` 出包。

**影响**：装出来的包启动慢、运行卡（JIT 解释执行）、体积比 release 大一截；而这份包被当成「交付的安装包」。

**建议**：给 `D:\flutter\bin\cache\artifacts\engine\...\gen_snapshot.exe` 加 Defender 排除项后跑 `build apk --release`；或把出包放到 CI/另一台机器，仓库里只提交构建脚本。验收标准：产物里出现 `lib/arm64-v8a/libapp.so`、没有 `kernel_blob.bin`。

---

### P0-2 单包里三套 ABI

**证据**（同一个 APK）：`lib/arm64-v8a` 77.6 MB、`lib/x86_64` 67.9 MB、`lib/armeabi-v7a` 49.6 MB，各含 `libflutter.so` + `libonnxruntime.so` + `libsherpa-onnx-*.so`。

**成因**：`android/app/build.gradle.kts` 没有 `abiFilters`，也没有用 `--split-per-abi`；`sherpa_onnx` 的 4 个 android 分包（arm64/armeabi/x86/x86_64）默认全部带入。

**影响**：真机只需要 arm64；多出来的 x86_64 + armeabi-v7a 约 117 MB 纯属行李。

**建议**：release 用 `flutter build apk --release --split-per-abi`（产出 3 个按 ABI 拆分的包），或在 `defaultConfig` 里写 `ndk { abiFilters += listOf("arm64-v8a") }`。验收：`arm64-v8a` 版 APK 里只剩一套 `lib/`。

---

### P0-3 `ted_12.mp4` 白占 37 MB

**证据**：

- `assets/audio/ted_12.mp4` = 39,143,004 字节，MP4 原子解析显示**只有 `vide` 轨、没有 `soun` 轨**；
- 遍历 14 篇内容 JSON：`esfahani_more_than_happy` 的 `audioPath` 为空，其余 13 篇引用 `ted_01..11,13`，**没有任何 JSON 引用 `ted_12.mp4`**（只有 `media_manifest.json` 的导入记录）；
- `pubspec.yaml` 却逐文件声明了 `assets/audio/ted_12.mp4` → 被无条件打进安装包。

**影响**：+37 MB 包体，0 功能。这篇在 App 里恒为「音频待补」，三种模式全禁用（降级做得对，但素材本身是坏文件）。

**建议**：从 `pubspec.yaml` 移除该行（或先重新下载带音轨的版本再替换）；`tools/import_media.py` 导入时应校验 `soun` 轨存在，缺失直接拒收并告警。

---

### P0-4 复述评分对 13/14 篇形同虚设

**证据**：

- 遍历内容 JSON 统计：只有 `matt_cutts_30_days` 带 `clips`（4 段、18 个 `keyPoints`）；其余 13 篇 `clips = 0`；
- `SpeechEntry.fromJson` 在 `clips` 为空时用 `RetellClip.deriveClips(sentences)` 兜底按时间切片（`lib/data/speech_library.dart:287-291`），这些兜底片段 **`keyPoints` 恒为空**；
- `RetellScorer.score` 在 `total == 0` 时 `score = 0`（`lib/services/retell_scorer.dart:199-200`）；
- `speech_detail_page.dart:268` 的入口守卫 `enabled: … && s.clips.isNotEmpty` **永远为真**（deriveClips 一定产出非空列表）→ 用户照样能点进复述模式；
- 结果页已有降级文案「所选范围没有配置要点，可对照下方识别原文自查」（`retell_page.dart:839-841`），所以不崩，但**拿不到分数**，学习闭环断掉。

**建议**：二选一——(a) 给 13 篇补 `clips/keyPoints`（`tools/build_content.dart` 管线已支持，缺的是内容）；(b) 若短期补不上，把入口守卫改为 `s.clips.any((c) => c.keyPoints.isNotEmpty)`，并在卡片上标「复述待配要点」，别让用户白练一轮。验收：任取 3 篇非 matt_cutts 的内容，走完复述应返回非 0 分或明确禁用。

---

### P1-5 跟读录音可能没有停止出口

**证据**：

- 录音面板只有在 `_settings.vadAutoStop == false` 时才渲染「结束录音并评分」按钮（`shadowing_detail_page.dart:865-872`）；`vadAutoStop` 默认 `true`（`settings_controller.dart:42`）；
- 自动结束依赖 VAD 的「说话中 → 不说话」状态跳变（`shadowing_recorder.dart:165-182`）；用户一直不开口、或环境底噪让 VAD 一直判「在说话」，就不会产生这个跳变；
- `_startRecording` 没有传 `maxDuration`（`shadowing_detail_page.dart:270-286`），而复述页传了 90 秒（`retell_page.dart:213`）。

**影响**：录音状态可能无限持续，界面上没有停止按钮，用户只能靠返回/切模式硬退（这次录音也就废了）。

**建议**：录音面板无条件保留一个「结束并评分」按钮（VAD 自动停只是加速，不该是唯一出口）；同时给跟读也加 `maxDuration`（如 30 秒）兜底。验收：开启静音自动停止、对着手机不说话 30 秒，应能自行结束或手动结束。

---

### P1-6 跟读页进度条不跟随播放

**证据**：`_playerBar()` 直接读 `_player.position` / `_player.duration`（`shadowing_detail_page.dart:638-707`），只有整棵树被 `setState` 时才刷新；而 `_onPosition` 在 `playingOriginal` 阶段**直接 return**（`:136-142`），在 `idle` 阶段也只在换句时 `setState`（`:144-157`）。

**影响**：播放原声的那十几秒里，进度条和时间刻度是静止的，拖过的位置也要等下一次重建才反映；用户会以为播放器卡住。

**建议**：把 Slider 与时间文本包进 `StreamBuilder<Duration>`（聆听页已经这么写，`listening_page.dart:487-530`），或把位置回调节流成 100~200 ms 的 `setState`。

---

### P1-7 复述录音会录到原声

**证据**：`_enterRetell` 直接调 `_startRetellRecording()`（`retell_page.dart:181-204`），全程没有 `_player.pause()`；播放只在 `_onPosition` 抵达所选范围末句时才暂停（`:124-131`）。

**影响**：用户听完一半就点「开始复述」时，扬声器还在放原演讲，麦克风把原声录进去 → ASR 输出≈原文 → 要点覆盖率 100%，分数虚高且完全无意义（等于自欺）。真机上外放尤其明显。

**建议**：开录前 `await _player.pause()`，并在录音期间隐藏/禁用回放控件；进阶做法是配置 `audio_session` 的录音 focus（录音时自动打断其他播放）。

---

### P1-8 录音器释放竞态

**代码**（`shadowing_recorder.dart:256-262`）：

```dart
void dispose() {
  unawaited(stop());   // 异步，未等待
  _asr.dispose();      // 立刻释放识别器
  _mic.dispose();      // 立刻释放麦克风
  super.dispose();
}
```

- 在途的 `stop()` 还会走到 `await _mic.stop()`（`:246`）→ 在已 dispose 的 recorder 上打平台方法；
- `stop()` 末尾 `notifyListeners()`（`:252`）在已 dispose 的 `ChangeNotifier` 上会抛（debug 下必现，release 静默）。

**影响**：退出跟读页时偶发异常/日志噪音，极端情况麦克风未真正释放（耗电、下次录音冲突）。

**建议**：`dispose()` 里改成 `await` 串行（Flutter 建议在 `dispose()` 前由页面 `await _recorder.stop()`，或给 stop 加 `_disposed` 标志并在 dispose 后跳过 `notifyListeners`）。

---

### P1-9 Whisper 解码阻塞 UI isolate

**证据**：`_micSub` 的监听回调里直接 `_drainVad()`（`shadowing_recorder.dart:146-185`），`_drainVad` 又是同步 `_asr.decodeSegment(...)`（`:205-223`）；`decodeSegment` 是 sherpa 原生同步调用（`asr_service.dart:43-58`）。

**影响**：每识别一句就阻塞主 isolate 数百毫秒到数秒 → 波形冻结、字幕跳动、麦克风事件在队列里堆积（VAD 时间戳与实际开口时间偏移）。

**建议**：把解码挪到独立 isolate（或 sherpa 的流式识别接口）；isolate 内单独持有 `OfflineRecognizer`，主 isolate 只做 VAD 分块与 UI 更新。验收：连续读 3 句，波形不应出现 ≥200 ms 的整帧停顿。

---

### P2-10 内容两份真相

`shadowing_detail_page._bootstrap()` 在页面打开时又 `rootBundle.loadString('assets/content/${id}.json')` 并解析（`:105-113`），而 `kSpeechLibrary`（`speech_library.g.dart`）已经有同一份编译期常量。

**风险**：忘记重跑 `tools/build_content.dart` 时，内容库列表（用 .g.dart）与跟读页（用 JSON）会显示不同的句数/时间戳，出现"列表 151 句、进去只有 145 句"这类幽灵 bug。**修**：统一走 .g.dart，或在 JSON 里写版本号、启动时比对不一致就报警。

### P2-11 首启复制 99 MB 模型

`model_installer.dart:85-105` 用 `rootBundle.load(asset)` **整文件读进内存**再 `writeAsBytes`：decoder 单文件 85.7 MB → 峰值约 90~170 MB RAM（`data.buffer.asUint8List` 还会再切一份视图），低端机有 OOM 风险；同时装完在 APK 内与私有目录各存一份（约 200 MB）。

**建议**：分块流式写（`AssetBundle.load` 走 `ByteData` 分段或改用 `ZipResource`），或把模型改为首次按需导入/下载。

（并发保护本身是对的：`copyBundledAssets()` 的 `_copying` 单飞能防止并发写坏文件。）

### P2-12 宣称"不依赖联网"，但词典发音要联网

`README.md` 第 2-4 行写「录音、语音识别、逐词评分、词典查询全部在本机完成，不上传数据、不依赖联网」，但 `word_pronunciation_service.dart:80-118` 首次播放单词时会访问 `dict.youdao.com/dictvoice` 下载 MP3，`AndroidManifest.xml` 也申请了 `INTERNET` 权限。此外该音源是第三方非公开接口，无授权与可用性保证。

**建议**：文案改为「除单词真人发音（首次需联网、之后离线缓存）外全程离线」，并在设置里给一个「不联网」开关；或换成本地 TTS（`flutter_tts` 已在依赖里）。

### P2-13 列表页重复查库

`library_page.dart:39-42` 把 `_refresh()`（两次 SQLite 查询 + `setState`）放在 `didChangeDependencies` 里，主题/媒体查询/字体缩放变化都会触发。**建议**：初值放 `initState`，返回时刷新已有 `_openListening`/`_openDetail` 的 await 路径。

### P2-14 设置枚举越界

`settings_controller.dart:88`：`RepeatMode.values[prefs.getInt(_kRepeatMode) ?? 0]`，写坏的偏好值 → `RangeError`；`main.dart` 的 try/catch 会吞掉，结果是"设置加载失败，全部回默认"。**建议**：加下标范围判断（`_kLastTrainMode` 在 `:92-95` 已经这么做了，照抄即可）。

### P3 小项

- `listening_page.dart:63-67`：`playingStream` / `positionStream` 两个 `listen()` 没有保存订阅、也没有取消；`_init` 里 `setState` 未判 `mounted`（页在音频 open 期间返回会抛 `setState after dispose`）。
- 无文稿内容（`bodyDurationSec == 0`）时聆听页进度条恒 0、无法拖动（`listening_page.dart:495-499`）——当前 14 篇都有文稿，属潜在问题。
- 聆听页逐词高亮：每个词变化都整页 `setState`，且句子用 `WidgetSpan` + 每词一个 `GestureDetector`（`:406-439`），300 句的长稿（`ted_meaning_of_life`）有 jank 风险。
- `word_pronunciation_service.dart:60`：`sub.cancel()` 只在成功路径执行，异常时泄漏订阅（影响小）。

---

## 三、已核实正常（避免误伤）

| 项 | 证据 |
| --- | --- |
| 静态分析 | `flutter analyze`：**No issues found**（93.6 s） |
| 单元测试 | `flutter test`（按 README 方式：`C:\dev\TED` junction + 清代理）：**8 个用例全通过**；`dart run test/verify_core.dart`：**39 通过 / 0 失败** |
| 音频与文稿时长一致性 | 13 个有音轨的 mp4 逐一解析 `mvhd`，与 JSON `durationMs` **误差 < 0.01 s**；`ted_10` 的 mvhd 版本 1 解析失败（脚本问题），但 JSON 值 1306.2 s 与 B 站标注一致 |
| 内容规模 | 14 篇、**1607 句**，与 README 声称一致；每句都有词级时间戳（12~16 词/句） |
| 无音轨素材的降级 | `speech_detail_page.dart:173-194, 246-271`：`audioMissing` 时三种模式全部禁用并给出说明，不会崩 |
| 模型并发复制 | `model_installer.dart:77-83` 的 `_copying` 单飞能避免并发写坏 85 MB 文件 |
| 内容库搜索/筛选 | `library_page.dart:87-106, 158-160`：搜索有 `onChanged` 触发重建，筛选逻辑按分类/主题/难度逐条生效 |

---

## 四、覆盖说明

- **已读代码**：`main.dart`、`app.dart`、`speech_library.dart`、`app_database.dart`、`srs.dart`、`settings_controller.dart`、`audio_player_service.dart`、`asr_service.dart`、`model_installer.dart`、`shadowing_recorder.dart`、`aligner.dart`、`retell_scorer.dart`、`word_pronunciation_service.dart`、`shadowing_detail_page.dart`（全）、`listening_page.dart`（全）、`speech_detail_page.dart`（全）、`retell_page.dart`（关键路径）、`library_page.dart`（前段+搜索）、`settings_page.dart`（识别精度段）。
- **未逐行读完**：`dictionary_service.dart`、`dictionary_popup.dart`、`text_normalizer.dart`、`tts_service.dart`、`stats_page.dart`、`vocab_page.dart`、`shadowing_page.dart`、`core/widgets/*`、`tools/*.py`、`speech_library.g.dart`（1.7 MB 生成物）。
  这几处**不代表没有问题**，只是本轮未做逐行审计。
- **未做真机验证**：本轮全部是静态 + 桌面/工具链层面的证据，没有 Android 真机或 iOS 运行记录；P1-5/6/7/9 的实际观感需真机复现确认。

---

## 五、复核后的修复状态（2026-11-13 晚）

| 条目 | 状态 | 说明 |
| --- | --- | --- |
| P0-1 debug 包 | 未修 | 需 Defender 排除 `gen_snapshot.exe` 或在 CI 出 release；当前 `dist/` 仍是 debug 包。 |
| P0-2 三套 ABI | 未改构建配置 | `README` 已补 `flutter build apk --release --split-per-abi`；是否强制只留 arm64 需你决定。 |
| P0-3 ted_12 白占包体 | 已修 | 旧的无音轨 37 MB 文件已替换为从新素材提取的 12.1 MB AAC 音轨（724.79 秒），重新加入 `pubspec.yaml`，三种模式恢复。 |
| P0-4 复述评分恒 0 | 已降级处理 | 新增 `hasRetellKeyPoints`，无要点篇目的复述入口置灰并提示「复述要点待配置」；未补 13 篇的内容要点。 |
| P1-5 录音无停止出口 | 已修 | 录音面板始终保留「结束录音并评分」，跟读增加 30 秒最大时长兜底。 |
| P1-6 跟读进度条不刷新 | 已修 | 播放条 Slider 与时间改用 `StreamBuilder<Duration>`。 |
| P1-7 复述录到原声 | 已修 | 开录前 `await _player.pause()`。 |
| P1-8 录音器释放竞态 | 已修 | `stop()` 幂等化；dispose 后不再 `notifyListeners`，异步停止后再释放 ASR/麦克风。 |
| P1-9 Whisper 阻塞 UI | 未修 | 需把解码移到独立 isolate，涉及 sherpa 识别器生命周期，建议单独一轮做并真机验证。 |
| P2-10 内容两份真相 | 已修 | 跟读页不再二次读取 assets JSON，统一使用 `kSpeechLibrary`。 |
| P2-11 模型整文件读内存 | 未修 | `rootBundle.load` 仍是整文件加载，需改分块/按需导入。 |
| P2-12 「不依赖联网」文案 | 已修 | README 改为「单词真人发音首次联网、其余离线」。 |
| P2-13 列表页重复查库 | 已修 | 移除 `didChangeDependencies` 中的全量刷新；返回路径已有 `_refresh()`。 |
| P2-14 设置枚举越界 | 已修 | `RepeatMode` 读取增加下标范围保护。 |
| P3 订阅/竞态 | 部分修复 | 聆听页订阅已保存并取消、`_init` 补 `mounted` 检查；词级高亮 jank 与无稿进度条仍待处理。 |
| 新增：8 篇识别稿误标「无中译」 | 已修 | 译文实际齐全；徽标改为「识别稿」，详情文案与 README/测试同步，8 篇 JSON 的 `source` 改为「语音识别逐字稿」，并重新生成 `speech_library.g.dart`。 |

**验证**：`flutter analyze` 无问题；`flutter test --no-pub` 8/8 通过；`dart run test/verify_core.dart` 39/39 通过。

### 文字-音频匹配专项修复

- 根因：`levitin_stay_calm`、`meg_jay_why_30`、`brewer_break_habit`、`esfahani_more_than_happy`、`robbins_five_seconds` 的原官方稿是**节选**（例如 Mel Robbins 仅 839 词 / 21 分钟），却被按整段音频拉伸，字幕自然越走越慢。
- 修复：用 `tools/transcripts_source.json` 中对应的完整逐字稿替换节选稿，按 `[mm:ss]` 时间码重新分配句子；能匹配上的旧节选句中文译文保留，完整稿新增句暂时留空。Esfahani 一篇额外使用了 docx 中的中文段落译文，覆盖率约 60%。
- 结果：5 篇语速回到 140–180 WPM（修复前 39–88 WPM），Esfahani 的 `ted_12` 从无音轨恢复为 12:04 音轨；全库 2322 句。
