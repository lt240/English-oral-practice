# TED 跟读助手 · 数据审计问题处理方案

> 基于你挖掘的 17 项问题清单，逐项给出处理状态与方案。
> 更新时间：2026-11-08

---

## 一、本轮已直接修复（可自动、且确定正确）

### ✅ #1~#7 音文同步问题（7 篇）

**根因澄清（关键）**：经数据核实，这 7 篇的句子时间戳（`startTime/endTime`）**本来就是「音频绝对时间」**——首句 `startTime` 就是片头时长（31/18/13/13/4/4/4.34 秒），末句 `endTime` 等于音频总时长。也就是说，**时间戳里已经包含了片头，本身是自洽的**。

真正的 bug 出在**上一轮代码**：进度条按「正文视角」扣了片头偏移，但句子高亮 `sentenceIndexAt()` 用的是绝对时间没扣偏移，**两者基准不一致**，导致「进度条位置对、文字高亮错位」，或者点句后进度条错乱。

**本轮修复**（`lib/features/listening/listening_page.dart` + `lib/data/speech_library.dart`）：
1. **统一时间轴基准**：内部（高亮/点句/点词/跳转）一律用「音频绝对时间」，句子时间戳直接匹配，不再做任何偏移换算。
2. **进度条「正文视角」**：进度条总量改为 `bodyDurationSec = 末句 endTime − 片头`，起点扣除片头、终点扣除文末空白——片头音乐和文末音乐都不再占据进度条。
3. 拖动进度条 seek 时，正确换算「正文进度 → 音频绝对位置」。

| 篇目 | 片头 | 修复前 | 修复后 |
|---|---|---|---|
| ted_mind_control | 31.0s | 进度条/高亮错位 31s | ✅ 片头不占进度条，高亮精准 |
| ted_true_confidence | 18.0s | 同上 | ✅ |
| ted_meaning_of_life | 13.0s | 同上 | ✅ |
| ted_not_personal | 13.0s | 同上 | ✅ |
| ted_why_meaning | 4.0s | 同上 | ✅ |
| ted_humility_water | 4.0s | 同上 | ✅ |
| matt_cutts_30_days | 4.34s + 文末空白 24.7s | 文末进度条空走 24.7s | ✅ 片头+文末都不占进度条 |

### ✅ #12 难度分级虚设

**根因**：`difficulty` 是拍脑袋的 1/2/3，`level` 只有「入门/进阶」两档且 UI 里根本没用。

**修复**：用**平均词长**（词汇复杂度的稳健代理，不受 ASR 机械断句影响）客观重算，写脚本 `tools/recalc_difficulty.py` 更新了 14 篇 JSON 的 `difficulty` + `level`（改为入门/进阶/高级三档），并加了 `difficultyNote` 字段记录依据。

关键变化：
- `ted_meaning_of_life`：3 → 1（均词长 4.05，确实偏简单）
- `levitin_stay_calm`、`meg_jay_why_30`、`robbins_five_seconds`：3 → 2
- `ted_not_personal`：2 → 1
- `matt_cutts` 保持 1（均词长 3.96，最简单，符合直觉）

> ⚠️ 说明：这是「词长客观近似」，**不是 CEFR 词汇分级**。要做真正的词汇难度分级，需要引入 CEFR/COCA 词频表，那属于 #15「逐句标注」的范畴，见下文方案。

### ✅ #14 内容源单一 / 「名人演讲」分类错误

**根因**：上一轮把 8 篇 ASR 稿（`speaker` 字段因未标注真实演讲者而统一记为 `"TED"`）**误判成了「名人演讲」**，实际上它们本质还是 TED 演讲。

**修复**：纠正分类逻辑——14 篇全部归入「TED 演讲」，「名人演讲」分类暂时**空置**（保留入口，等以后有真名人演讲内容再填）。分类依据改为「仅当 JSON 显式标注 `category: "celebrity"` 才归名人」。

---

## 二、需要素材 / 无法自动修复（已给方案，等你提供素材）

### ⏳ #8 esfahani 无音频 + 时间戳不可信（🔴 致命）

**现状**：`ted_12.mp4` 是无音轨的 HEVC 视频流（B 站分离出的画面，音频被剥离），`alignmentNote` 明确写「未提供 ffmpeg，未使用音频信号」，时间戳是纯音素模型推算，**完全不可信**。

**方案（需你提供素材）**：
1. 找 Emily Esfahani Smith《There's More to Life Than Being Happy》(TED 2017) 的**带音轨**版本（MP4/MP3 均可），替换 `assets/audio/ted_12.mp4`。
2. 用 `tools/align_content.py` 对音频重新做能量锚点 + 音素时长对齐，重算句子时间戳。
3. 若无素材，建议**暂时从内容库下线该篇**（`index.json` 里 `enabled: false`），避免用户点到一篇「能看字幕但不能听」的内容。

### ⏳ #10 英文原文质量问题（8 篇 ASR 稿）

**现状**：8 篇 `source: "语音识别逐字稿（无中译）"` 的英文原文是 ASR 打出来的，存在大小写不一致（"i" 未大写）、识别错误等。

**方案（需你提供素材）**：找这 8 篇的**官方 TED 逐字稿**（ted.com 有公开 transcript），替换 `text` 字段。但要注意：**替换后句数/句边界会变，需要重新做时间戳对齐**（用 `import_transcripts.py` + `align_content.py`），中文翻译也要重新对齐。这是一个较大的工作量，建议逐篇推进。

### ⏳ #11 复述模式字段缺失（14 篇全缺，🔴 致命）

**现状**：数据结构只支持「看字幕跟读」，没有复述模式所需的字段（`retellSentences`/`shadowSegments`/`hintText`/`keywords`/`summary`）。

**决策**：你已确认「暂不做复述模式」。这里记录方案备查：
- 若未来要做，需要为每篇补「复述要点」（每段的关键词、提示语），或者用现有句子做「隐去字幕复述」的简版（遮字幕→听音频复述→显示对照），后者不需要新数据。

---

## 三、需要决策 / 待确认

### ❓ #13 男女声切换无效

**根因（已定位）**：`TtsService` 已经**事实上废弃**了——上一轮把生词本发音从系统 TTS 改成了有道真人发音，跟读/复述用的是原声播放，所以「男女声切换」这个开关只剩设置页的一个布尔值，**没有任何地方真正调用它**。

**决策点**：男女声切换在当前架构下已经没有意义（示范发音是原声+有道真人音，不是系统 TTS）。两个方向：
- **A（推荐）**：从设置页移除「男女声」开关，避免误导用户。
- **B**：如果要保留，需要重新接通 TtsService，但系统 TTS 音色受手机 ROM 限制（很多手机只有女声），体验不可控。

### ❓ #9 时间戳来源可信度

**现状**：4 篇 audio 对齐（可信）、8 篇 asr_timecode（较可信，用户提供逐字稿真实时间码）、1 篇 phonetic（不可信，esfahani）。

**方案**：可在 UI 的详情页标注时间戳来源/可信度（如「逐字稿对齐」「语音识别稿，时间戳可能有偏差」），让用户知情。这是低成本、有诚意的做法，**建议做**，但要你确认是否现在做。

---

## 四、增强需求（🟢，低优先级，暂缓）

| # | 问题 | 方案 |
|---|---|---|
| #15 | 缺逐句标注（语法/连读/重音/生词高亮） | 需要 CEFR 词表 + 人工标注，工作量大，建议作为独立内容工程后续做 |
| #16 | topicQuestions 模板化（3 篇） | 为 `ted_humility_water`/`ted_not_personal`/`ted_self_criticism` 定制针对性问题，可随时做 |
| #17 | sourceMedia 乱码 | **已核实：当前 JSON 里 `sourceMedia` 是正常中文，无乱码**（可能已修复或只在某个临时环境出现过），无需处理 |

---

## 五、本轮改动清单（供 code review）

| 文件 | 改动 |
|---|---|
| `lib/features/listening/listening_page.dart` | 统一时间轴为绝对时间；进度条改用 `bodyDurationSec`（片头+文末都不占进度条）；修复 seek/高亮错位 |
| `lib/data/speech_library.dart` | `bodyDurationSec` 改为「末句 end − 片头」；分类 `fromCode` 纠正（不再把 ASR 稿误判为名人演讲） |
| `tools/build_content.dart` | `categoryCode` 纠正；保留 `audioOffsetSec` 生成 |
| `tools/recalc_difficulty.py`（新增） | 按均词长客观重算难度 |
| `assets/content/*.json`（14 篇） | 更新 `difficulty`/`level`/`difficultyNote` |
| `lib/data/speech_library.g.dart` | 重新生成（分类纠正 + 难度更新 + audioOffsetSec） |

**验证**：`flutter analyze` 全项目 **No issues found!**（0 error 0 warning）。

---

## 六、下一步建议（按优先级）

1. **#8 esfahani**：找带音轨素材替换，或先 `enabled: false` 下线该篇（避免坏体验）。
2. **#13 男女声**：确认是否从设置页移除（推荐 A）。
3. **#10 ASR 原文**：逐篇找官方逐字稿替换 + 重新对齐（工作量大，分篇推进）。
4. **#9 可信度标注**：详情页加「时间戳来源」提示。
