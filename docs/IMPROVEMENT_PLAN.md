# TED 跟读助手 · 差距分析与改进计划

> 对照对象：ELSA Speak、流利说、每日英语听力、VoiceTube / TED 官方 App、墨墨背单词、Speechling、Azure AI Speech 发音评估。
> 分析基线：`2b70d84` 单次提交、lib 共 6696 行、内容库 1 篇演讲。

## 一句话结论

引擎和交互骨架已经跑通（VAD 断句 → 端侧 Whisper → 逐词对齐 → 落库统计），**但产品还没闭环**：内容只有 1 篇、评分只有"读对的词占比"、练习完听不到自己的声音、复习靠布尔标记、深色模式是坏的。当前阶段的价值是"验证技术路线可行"，离"能留住人"还差三层：内容厚度、反馈科学性、学习闭环。

---

## 一、现状基线（核实过的事实）

| 项 | 事实 | 位置 |
| --- | --- | --- |
| 内容量 | 1 篇演讲 / 46 句 / 约 3.5 分钟 | `assets/content/matt_cutts_30_days.json` |
| 孤立素材 | `meg_jay_30_not_20.mp3` 11.1 MB 无文稿、未接入，仍被打进包 | `assets/audio/` |
| 时间戳粒度 | 仅句级 `startTime/endTime`，无词级 | 内容 JSON |
| 词级模型 | `WordToken` / `SubtitleCue` 全库零引用（死代码） | `lib/models/speech.dart` |
| 聆听模式 | 占位壳：硬编码英文占位文案、快进/快退空回调、未挂进导航 | `lib/features/listening/listening_page.dart` |
| 评分算法 | 编辑距离命中率 `correct/total`；复述为关键词实词覆盖率 | `services/aligner.dart:352`、`services/retell_scorer.dart` |
| 录音留存 | 只开 PCM 流做识别，**不落盘**，无法回放 | `services/shadowing_recorder.dart:135` |
| 模型分发 | 99 MB 随包；`main()` 里先 `await` 全量复制再 `runApp` | `lib/main.dart:21`、`services/asr/model_installer.dart` |
| 数据库 | 4 张表，`speeches` / `practice_sessions` 从未写入；`attempts` 无索引 | `services/db/app_database.dart` |
| 死代码 | `StatsService.recordAttempt` 从未调用，与 `AppDatabase` 统计双轨并行 | `services/stats_service.dart` |
| 主题 | `AmbientBackground` 写死浅色渐变；卡片硬编码 `Colors.white` / `AppColors.textPrimary` | `core/widgets/ambient_background.dart:22` |
| 测试 | 1 个 widget 测试 + 11 条纯 Dart 断言，无 DB / 状态机 / 集成 / golden | `test/` |
| 工程化 | 无 CI；`applicationId=com.example.ted_companion`；release 用 debug 签名；`build/` 6.0 GB | `android/app/build.gradle.kts:19,36` |
| 文档漂移 | README 声称"聆听、逐词高亮、趋势"，代码里三者均未实现 | `README.md:8-12` |

---

## 二、需要改进的地方（对照成熟产品的做法）

### A. 内容与学习闭环（最影响留存）

| # | 差距 | 现状 | 成熟产品怎么做 | 影响 |
| --- | --- | --- | --- | --- |
| A1 | 内容太少 | 1 篇 / 3.5 分钟，练完即走光 | TED 官方、VoiceTube：数千条分级内容 + 每日更新 + 难度/口音/主题筛选 | 致命。没有"明天还来"的理由 |
| A2 | 无生词本 | 查词弹窗只给释义和发音，关掉即失 | 欧路、墨墨：查词→收藏→按 SRS 复习→导出 Anki | 高。错词数据已落库却没沉淀成资产 |
| A3 | 无间隔重复 | `needs_review` 布尔标记 + 手动"一键重练" | 墨墨/扇贝：SM-2 / FSRS 排程，按遗忘曲线推今日任务 | 高。复习全靠自觉 |
| A4 | 无断点续练 | 只能从第 1 句或统计页跳单句 | 每日英语听力：记住上次位置、篇内进度百分比 | 中高。长内容必然中途退出 |
| A5 | 统计太薄 | 今日句数 / 均分 / 天数 + 错词 TOP | 流利说：周/月趋势、连续打卡、目标达成率、维度雷达 | 中。反馈不足以驱动坚持 |
| A6 | 听不到自己 | 录音不落盘 | ELSA、Speechling、流利说：原声 ↔ 我的录音 A-B 对比回放为标配 | 高。跟读的核心闭环缺一半 |
| A7 | 聆听页是空壳 | 静态文案 + 两个空回调按钮 | VoiceTube：句级字幕同步、单句循环、A-B 复读、点词跳转 | 中。占了 README 的功能位却不生效 |

### B. 评分与反馈（决定"专业感"）

| # | 差距 | 现状 | 成熟做法 | 影响 |
| --- | --- | --- | --- | --- |
| B1 | 单一维度、纯文本比对 | 只算词串命中率；同音异形（write/right）、连读、弱读、吞音一律判错 | ELSA：音素级 GOP 打分；Azure 发音评估输出 accuracy / fluency / completeness / prosody 四维 + 音素级错误定位 | 高。分数不可信 → 用户不信 |
| B2 | 复述靠硬编码同义词 | 每条要点配 3~4 个说法，换种表达即判漏 | 语义相似度（embedding）+ LLM 重述比对 | 中高。复述分数区分度差 |
| B3 | 识别限制 | 仅 `tiny.en`（base.en 未随包、档位被禁用）；非英文不可用 | 多口音/多语言模型 + 可选更大模型下载 | 中 |
| B4 | 解码阻塞 UI | `decodeSegment` 在 stream listener 内同步执行 | 放 isolate / Isolate.run，或改用流式识别 | 中。长复述时掉帧 |
| B5 | 无可执行反馈 | 错词只标红 | "／θ／ 读成了／s／，注意舌尖抵齿"这类发音提示 | 中高。用户知道错，不知道怎么改 |
| B6 | 分数不稳定 | 单次结果直接落库展示 | 同句取最优/近 N 次滑动均值，标注识别置信度 | 中。受识别噪声干扰 |

### C. 体验与打磨

| # | 差距 | 现状 | 成熟做法 |
| --- | --- | --- | --- |
| C1 | 深色模式是坏的 | 背景层写死浅色渐变，仅换 `textTheme` → 浅底浅字；多处硬编码 `Colors.white` / `AppColors.textPrimary` | 全部走主题 token（`Theme.of(context).colorScheme`），背景/玻璃/文字三处同源 |
| C2 | 首启慢且无反馈 | 99 MB 全量复制在 `runApp` 之前，黑屏数秒 | 按需下载（首次跟读时提示安装 + 进度 + 可取消），或异步预热 + 首帧先出 |
| C3 | 玻璃质感开销 | 列表每张卡一个 `BackdropFilter(blur 40)`，背景 4 个 `ImageFiltered(blur 70)` | 限制同时可见模糊层数、静态化背景、`RepaintBoundary`；成熟玻璃 UI 只对固定容器用实时模糊 |
| C4 | 无引导/无目标 | 首次点录音才弹系统权限；无 onboarding、无每日目标 | 首启 3 页引导（含"数据不出本机"）+ 目标设置 + 本地提醒 |
| C5 | 无搜索/收藏/最近 | 内容库是静态 `ListView` | 搜索、标签筛选、收藏夹、最近练习 |
| C6 | 无多语言界面 | 中文硬编码在 widget 字符串里 | `flutter_localizations` + `intl`，至少中/英 |

### D. 工程质量与交付

| # | 差距 | 现状 | 成熟做法 |
| --- | --- | --- | --- |
| D1 | 无分层、无状态管理 | 全局单例 + `InheritedNotifier`；`shadowing_detail_page.dart` 1298 行（占 lib 19%），状态机与 UI 混写 | Riverpod/Bloc + repository 分层；页面 <400 行；状态机抽成可单测的纯类 |
| D2 | 测试覆盖不足 | 1 widget + 11 条断言 | 评分/对齐/DB/状态机单测 + `integration_test` 主流程 + golden |
| D3 | 无 CI | 无 `.github/workflows` | `flutter analyze` + `dart format --set-exit-if-changed` + test 矩阵（至少 Win/Ubuntu） |
| D4 | 未做发布准备 | `com.example.*`、debug 签名、`0.1.0+1`、无隐私政策 | 正式包名/签名/版本号规范、隐私政策页（录音权限说明） |
| D5 | 数据层粗糙 | 2 张表从未写入；`attempts` 无索引；`topWrongWords` 全表拉进内存聚合；`resolveReview` 更新整篇同句所有行 | 表收敛 + 索引 `(speech_id, practiced_at)` + SQL 聚合 + 唯一约束 |
| D6 | 无异常可观测 | `debugPrint` 日志 | Sentry/Firebase Crashlytics（可 opt-in），关键路径埋点 |
| D7 | 仓库卫生 | `build/` 6.0 GB、根目录 `.bak`、11 MB 孤立音频入包 | `flutter clean`、孤立素材出包、`.gitignore` 补全 |

---

## 三、计划表

工作量按 1 名熟悉 Flutter 的开发者估算（人日）。

### P0 · 修正确性（第 1–2 周）目标：说到的都成立

| # | 任务 | 对应差距 | 验收标准 | 人日 |
| --- | --- | --- | --- | --- |
| P0-1 | 深色模式修复：背景/玻璃/文字统一走主题 token | C1 | 深色模式下连续 5 个页面无低对比文本（对比度 ≥ 4.5:1） | 2 |
| P0-2 | 聆听模式二选一：实装（句级同步 + 单句循环 + A-B + 变速）或从 README/导航下线 | A7 | 二选一后 README 功能表与运行行为一致 | 3 |
| P0-3 | 删除死代码：`models/speech.dart`、`audio_player_service.dart`、`StatsService`、`listening` 占位 | D7 | `flutter analyze` 0 条 unused 提示 | 1 |
| P0-4 | 首启体验：模型异步预热 + 首次跟读前安装引导（进度/取消），移出 `main()` 阻塞 | C2 | 冷启动到首帧 < 1.5 s（中端安卓） | 3 |
| P0-5 | 素材出包：移除孤立的 11 MB 音频；`flutter clean` 回收 6 GB | D7 | 安装包体积下降 ≥ 11 MB | 0.5 |
| P0-6 | DB 收敛：删除从未写入的 `speeches`/`practice_sessions`，补索引，聚合下推 SQL | D5 | `reviewItems` / `topWrongWords` 走索引；1000 条记录查询 < 20 ms | 2 |
| P0-7 | 文档与实现对齐（README 功能表、已知限制） | — | README 与代码逐条可核对 | 0.5 |

**里程碑 M0**：深色模式正常、无死代码、冷启动 < 1.5 s、文档可信。

### P1 · 学习闭环（第 3–7 周）目标：练完有反馈、明天有任务

| # | 任务 | 对应差距 | 验收标准 | 人日 | 参考 |
| --- | --- | --- | --- | --- | --- |
| P1-1 | 录音落盘 + 「原声 / 我的」A-B 对比回放（波形对齐起点） | A6 | 每次跟读可回放本人录音并与原声切换对比 | 4 | Speechling、流利说 |
| P1-2 | 生词本：查词收藏 → 单词卡片复习（含发音、原句语境） | A2 | 收藏词可在独立页复习；错词自动入本 | 4 | 欧路、墨墨 |
| P1-3 | 句子级 SRS 队列：以 SM-2 简版替代 `needs_review` 布尔值 | A3 | 每日自动生成"今日复习"清单（新词/到期分离） | 5 | 墨墨/扇贝 |
| P1-4 | 进度记忆：每篇上次句位置 + 完成度 + 收藏/最近练习 | A4、C5 | 重新进入直接回到断点；内容库显示完成度环 | 3 | 每日英语听力 |
| P1-5 | 统计升级：7/30 天趋势曲线、连续打卡、目标与本地提醒 | A5 | 统计页有趋势图 + streak；可设每日句数目标 | 4 | 流利说 |
| P1-6 | 评分可信度：同句取最优/滑动均值、展示识别置信度、错词给常见混淆音提示 | B5、B6 | 同一句重复练习分数波动 < 8 分 | 3 | ELSA |
| P1-7 | 解码移出 UI isolate | B4 | 复述 90 s 期间无 > 50 ms 卡顿（DevTools 时间线） | 2 | — |
| P1-8 | 首启引导 + 权限说明 + 隐私页 | C4、D4 | 首启 3 页引导；权限弹窗前有解释文案 | 2 | — |

**里程碑 M1**：完整闭环 = 听原声 → 跟读 → 看逐词反馈 → 听自己 → 错词入本 → 次日按曲线复习。此时产品可以给真实用户试用。

### P2 · 内容规模化与专业性（第 8–14 周）目标：值得付费/长期用

| # | 任务 | 对应差距 | 验收标准 | 人日 | 参考 |
| --- | --- | --- | --- | --- | --- |
| P2-1 | 内容管线升级：`generate_timestamps` 批量产出**词级**时间戳（whisper.cpp 对齐已有基础） | A1、词级缺失 | 新演讲从音频到入库 ≤ 15 分钟/篇，词级时间戳覆盖 100% 句子 | 5 | — |
| P2-2 | 内容运营：20–50 篇分级演讲 + 标签/搜索/筛选 + 难度曲线 | A1、C5 | 20 篇可练；支持按难度/时长/主题筛选 | 8 | TED 官方、VoiceTube |
| P2-3 | 解锁词级交互：逐词高亮、点词跳到该词发音、单句 A-B | A7 | 点击任意词可播放该词原声片段（±0.4 s） | 4 | VoiceTube |
| P2-4 | 按需内容包：模型与音频改为首次使用时下载 + 校验 + 断点续传 | C2 | 首装包 < 30 MB，素材可增量拉取 | 5 | 每日英语听力 |
| P2-5 | 评分引擎升级：接音素级打分（端侧强制对齐，或 Azure 发音评估作可选在线增强），输出准确/流利/完整/韵律四维 | B1、B2 | 与 Azure 参考实现同一样本四维分偏差 < 10 分 | 10 | ELSA、Azure |
| P2-6 | 架构重构：Riverpod + go_router + repository 分层，拆分 1298 行页面，状态机抽纯类 | D1 | 单文件 < 400 行；状态机可脱离 widget 单测 | 10 | flutter/samples、Very Good CLI |
| P2-7 | 测试与 CI：单测补到核心逻辑 ≥ 60%、主流程 integration_test、GitHub Actions 三件事 | D2、D3 | CI 绿；覆盖率达标；PR 必须过 analyze+format+test | 6 | — |
| P2-8 | 发布就绪：正式包名/签名/版本策略、崩溃上报、i18n 中英 | D4、D6、C6 | 可出 release 包并通过商店预检清单 | 5 | — |

**里程碑 M2**：20+ 篇可练内容、词级交互、四维评分、可发布安装包。

---

## 四、取舍建议（如果只能做三件事）

1. **加内容**（P2-1 + P2-2 提前）：这是唯一无法靠代码优雅度弥补的短板。1 篇 → 20 篇的价值远大于任何重构。
2. **让用户听到自己**（P1-1）：跟读类产品的信任来自"我确实进步了"，录音对比是最低成本的高感知功能，4 人日。
3. **把复习变成系统行为**（P1-3）：错词数据已经在库里，加 SRS 排程就能把"一次性练习"变成"每日打开"。

架构重构（P2-6）建议放在内容与闭环之后：当前 6700 行的体量重构收益有限，等 P1 引入新模块时再顺手分层，避免"先重构再返工"。

---

## 五、参考坐标

- **ELSA Speak** — 音素级发音评分、IPA 音标反馈、错误模式追踪
- **Azure AI Speech Pronunciation Assessment** — accuracy / fluency / completeness / prosody 四维 + 音素级错误定位（可作为评分能力的验收基准）
- **流利说** — 多维打分 + 录音对比 + 课程化路径
- **每日英语听力** — 逐句循环、A-B 复读、离线下载、生词本
- **VoiceTube / TED 官方 App** — 句级同步字幕、点词跳转、单句循环
- **Speechling** — 录音与原声对比、真人点评闭环
- **墨墨背单词 / 扇贝** — SM-2 / FSRS 间隔重复排程
- **flutter/samples、Very Good CLI** — 分层、测试矩阵、CI 骨架
