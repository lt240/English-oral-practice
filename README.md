# ted_companion · TED 跟读助手

本地离线运行的 TED 演讲跟读练习 App（Flutter，Android / iOS / Windows）。
录音、语音识别、逐词评分、查词释义全部在本机完成，录音与练习记录不上传。
单词真人发音首次会向有道请求音频（仅发送单词本身），之后离线缓存；其余功能可离线使用。

> 本版按 `docs/IMPROVEMENT_PLAN.md` / `docs/SOLUTIONS.md` 做了 P0 正确性修复、
> P1 学习闭环与 P2 内容规模化改造。测验清单见 `docs/TEST_TASKS.md`。

## 功能状态（与代码逐条可核对）

### 已实现

| 模块 | 能力 |
| --- | --- |
| 内容库 | 14 篇内容，**全部带逐句文稿、共 2424 句**，每句含词级时间戳与中文译文；中文主题分组、英文文字封面、搜索、主题/难度筛选、完成度进度环、最近练习 |
| 内容管线 | `assets/content/index.json` + 每篇 JSON → `tools/build_content.dart` 编译成 Dart 常量；新增内容不改 Dart 代码 |
| 音频 | 13 个 mp4 由 `tools/import_media.py` 从「TED音频」目录导入为 ASCII 文件名并登记真实时长 |
| 聆听模式 | 句级字幕同步、逐词高亮、点句/点词跳播、单句循环、A-B 复读、0.75~1.5x 变速、快进快退、译文开关、主题问题 |
| 跟读 | VAD 断句 → sherpa-onnx / Whisper 端侧识别 → 归一化 + 同音容错的逐词对齐 → 评分、错词/漏读/多读标色、发音提示、识别可信度 |
| 模型智能化 | 文本归一化（缩写/数字/填充词/转写噪声）、同音异形表、发音近似键、单字符编辑距离容错；可切换 base.en 精准档（需自备模型文件） |
| 断点续读 | 每篇记录上次句位置，详情页「继续第 N 句」、内容库进度环、跟读/聆听自动恢复 |
| 统计升级 | 今日句数/均分、连续打卡、学习天数、每日目标（可设 5/10/20/30 句）、7/30 天趋势图、错词 TOP、SRS 复习队列 |
| 生词本 | 错词自动入本、查词手动收藏、SM-2 复习、TTS 朗读、来源原句、导出 CSV 到剪贴板 |
| SRS | 句子级与词级 SM-2 排程（1/3/7/16 天），今日到期队列 |
| 词典 | ECDICT 90,021 条中英释义 + CMU 美式 IPA 125,955 条（`/ˈ.../`，覆盖中文词典 61.6%） |
| 深色模式 | `AppSurface` 语义层统一背景/玻璃/文字，深色下无浅底浅字 |
| 数据库 | v4：删除两张从未写入的空表、5 个索引、SQL 聚合下推、新增 progress/vocab/review_cards |
| 首启 | 99MB 模型复制移到首帧之后异步执行，不再阻塞冷启动 |

### 待补 / 已知限制

- **14 篇全部带逐句文稿（共 2424 句）**，统一为「官方逐字稿 + Whisper 词级对齐」：
  - 文本来自 TED / TEDx 官方公开逐字稿（`tools/transcripts_source.json` 固化）；
  - 时间戳由 `whisper.cpp` base.en 模型逐词转写后，与官方稿做序列对齐融合，**每句、每词都有真实起止时间**（`timingSource=whisper_word`）；
  - 中文译文全覆盖，逐句对应；复述模式每篇配 11~14 段 `clips`（`summary` + `keyPoints`）。
  - 已知残留：融合在「数字 + 连字符」跨段边界时仍可能丢词，已人工补回关键数字；个别句译文与英文存在半句错位，不影响跟读评分。
- **原「音频待补」已补齐**：`esfahani_more_than_happy` 已从新素材 `【TED演讲】生活不只是快乐,怎样的人生更有意义_.mp4` 提取 AAC 音轨（724.79 秒），三种模式恢复可用。
- **强制对齐**：`tools/align_content.py` 用 ffmpeg 解码 16k PCM → 20ms 帧能量 → 静音段作为句边界锚点，再按音素时长权重（音节数、功能词弱读、标点停顿）把句子与词铺进真实语音区间，产出每句 `words[]` 词级时间戳。无 ffmpeg 时自动回退纯音素模型。每篇 JSON 的 `timingSource` / `alignmentNote` 标明了实际使用的方式。
- 深色模式已按反馈调成**微暖深紫棕**底 + 微暖白字（`AppSurface`）。
- `base.en` 模型文件未随包；设置页开关会在文件缺失时自动回退 tiny.en。
- iOS 未在真机验证；本次交付 Android 安装包。

## 环境与运行

实测 Flutter 3.47.5 / Dart 3.13.4，`pubspec.yaml` 要求 Dart >= 3.7、Flutter >= 3.29。

```bash
flutter pub get
flutter run
```

### 本机环境坑（已踩过，附解法）

1. **用户名含撇号** `C:\Users\L't\...`：Flutter 测试运行器把项目路径塞进单引号字符串不转义，
   `flutter test` 直接语法错误。用 `C:\dev\TED` 目录联接（junction，已存在）或在无撇号副本构建。
   本机受限 shell 中 `flutter.bat` 也无法调用，用 `tools/flutter_cli.ps1` 直连 Dart 快照：
   `powershell -ExecutionPolicy Bypass -File tools/flutter_cli.ps1 analyze`
2. **代理变量**：`HTTP_PROXY` 有值但缺 `NO_PROXY`，flutter_tester 的本地 WebSocket 握手会失败。
   跑测试前清空代理并设 `NO_PROXY=localhost,127.0.0.1`（`tools/run_tests.ps1` 已处理）。
3. **Windows Defender 误报**：`gen_snapshot.EXE`（AOT 编译器）被拦截，
   `flutter build apk --release` 会失败；`--debug` 不走 AOT，可正常出包。
   若需要 release 包，需在本机 Defender 中为 `D:\flutter\bin\cache\artifacts\engine\...` 添加排除项。
4. **Flutter 3.47.x 测试缓存冲突**：Windows 上偶发
   `PathExistsException ... NativeAssetsManifest.json`，是测试工具复制缓存时的竞态。
   `tools/run_tests.ps1` 会先清理该陈旧清单，避免测试在启动阶段崩溃。

## 跑测试

```bash
dart run test/verify_core.dart                 # 39 项纯 Dart 逻辑断言
dart analyze                                  # 静态分析
powershell -ExecutionPolicy Bypass -File tools/run_tests.ps1   # widget 测试（自动处理坑 1/2）
```

## 新增内容（后续下载的素材也放「TED音频」）

素材目录：默认为**仓库的同级目录** `../TED音频`（可用 `--source` 参数覆盖），脚本不依赖固定用户名路径。

```bash
# 1. 把下载的音频放进素材目录（注意：B站「视频流」可能没有音轨，
#    用 ffmpeg -i 检查是否含 Audio: aac；纯视频流无法播放，UI 会标「音频待补」）
# 2. 导入并登记真实时长（有 ffmpeg 时自动优先用 ffmpeg 校准）
py -3 tools/import_media.py
# 3. 为新增的 assets/audio/ted_XX.mp4 写一份 assets/content/<id>.json
#    （字段见现有 JSON；英文句子须来自官方逐字稿）
# 4. 在 assets/content/index.json 的 entries 里登记，重跑内容种子脚本
py -3 tools/seed_content.py
# 5. 强制对齐（强烈建议；无 ffmpeg 会自动回退音素时长模型）
py -3 tools/align_content.py --ffmpeg C:\Users\Public\ffmpeg.exe
# 6. 若提供了新的逐字稿合集 docx：提取 → 导入完整稿（节选稿会被完整稿替换，可匹配的旧译文保留）
py -3 tools/extract_transcripts.py
copy C:\Users\Public\ted_transcripts.json tools\transcripts_source.json
py -3 tools/import_transcripts.py
py -3 tools/align_content.py --ffmpeg C:\Users\Public\ffmpeg.exe   # 补词级时间戳
# 7. 编译成 Dart 常量并在 pubspec.yaml 的 assets 中声明新音频
dart run tools/build_content.dart
# 8. 构建安装包（整条命令要用引号包住，--debug 会被 PowerShell 吞掉）
powershell -ExecutionPolicy Bypass -File tools/flutter_cli.ps1 "build apk --debug"
# 正式发布包（先给 Defender 排除 gen_snapshot；按 ABI 拆分，避免单包塞 3 套原生库）
flutter build apk --release --split-per-abi
```

## 目录结构

| 路径 | 作用 |
| --- | --- |
| `lib/features/` | 页面：内容库、详情、跟读、复述、聆听、统计、生词本、设置 |
| `lib/services/` | ASR/文本归一化、录音、对齐、词典、TTS、数据库、SM-2、设置 |
| `lib/data/speech_library.dart` | 内容模型；`speech_library.g.dart` 为生成的内容常量 |
| `lib/core/theme/app_surface.dart` | 明暗主题语义色（唯一取色入口） |
| `assets/content/` | 内容 JSON、`index.json`、`media_manifest.json` |
| `assets/audio/` | 原声音频（mp3 / mp4 音轨） |
| `assets/models/` | 端侧 VAD / Whisper 模型 |
| `assets/dict/` | `dict.json.gz`（中英释义）、`us_ipa.json.gz`（美式 IPA） |
| `tools/` | 素材导入、内容种子、**强制对齐**、内容编译、美式 IPA 构建、构建/测试脚本 |

## 数据来源与许可

- 演讲文稿：TED / TEDx 官方公开逐字稿（中文为对照翻译）；8 篇补自用户提供的
  《TED演讲原文合集（13篇逐字稿）.docx》语音识别稿（源文件固化在 `tools/transcripts_source.json`）
- 中英词典：ECDICT（MIT License）
- 美式发音：CMU Pronouncing Dictionary（cmusphinx/cmudict，公共领域）→ IPA
- 音频素材：用户提供的「TED音频」目录

## 离线模型

> **本仓库不包含大体积模型**（GitHub 单文件上限 100 MB）。首次运行前请自行放入 `assets/models/`：

| 文件 | 大小 | 说明 | 是否入库 |
| --- | --- | --- | --- |
| `silero_vad.onnx` | 0.6 MB | VAD，运行必需 | 是 |
| `tiny.en-tokens.txt` | 0.8 MB | 词表，运行必需 | 是 |
| `tiny.en-encoder.int8.onnx` | 12.3 MB | 快速档 | 否，需自备 |
| `tiny.en-decoder.int8.onnx` | 85.7 MB | 快速档 | 否，需自备 |
| `base.en-*` | — | 精准档，可选 | 否，需自备 |

模型可从 sherpa-onnx 官方发布页（`k2-fsa/sherpa-onnx`）下载对应的 `sherpa-onnx-whisper-tiny.en` / `base.en` 版本，解压后放入 `assets/models/`。
缺失时 App 仍可启动，跟读功能会提示模型未就绪（设置页可切换档位）。

## 音频素材

`assets/audio/*.mp4`（共 113 MB）**未入库**。请把 TED 视频/音频按 `assets/content/media_manifest.json` 中的文件名放入 `assets/audio/`，再运行 `py -3 tools/import_media.py` 校准时长。缺少音频时内容库对应篇目会标「音频待补」，文稿浏览与复述不受影响。

## 正式包名与签名

- `android/app/build.gradle.kts`：`applicationId` / `namespace` = `com.tedmate.companion`
  （不再是 `com.example.*`）。**换包名后，旧包不会覆盖安装，需要先卸载旧版**。
- `android/app/tedmate-release.jks`：release keystore，别名 `tedmate`，
  有效期 10000 天；口令写在 `android/key.properties`。
  这两个文件已加入 `.gitignore`，**请自行备份**：keystore 丢失后无法给同一包名发更新。
- `key.properties` 不存在时 Gradle 自动回退 debug 签名，clone 后仍可构建。
- `android/gradle.properties` 设了 `kotlin.incremental=false`，绕开 Windows 上
  Defender / 实时扫描锁住 Kotlin 增量缓存 `.tab` 文件导致的构建失败。
