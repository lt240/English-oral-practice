# -*- coding: utf-8 -*-
"""把用户提供的《TED演讲原文合集（13篇逐字稿）》导入内容库。

数据源：tools/transcripts_source.json（由 tools/extract_transcripts.py 从 docx 提取）。
每篇带 [mm:ss] 真实时间码，段首为语音停顿切分点。

策略：
- 用「原文件」名与 assets/content/*.json 的 sourceMedia 做模糊匹配，自动对应篇目；
- 已有官方逐字稿（带中译）的篇目**不覆盖**，保留质量更高的版本；
- 仅音频的 8 篇用 ASR 逐字稿补齐，长段落按 ~14 词切成字幕句、
  段内按真实时间码线性分配，产出 timingSource=asr_timecode；
- ASR 原文无标点、全小写，这里只做首字母大写 + 句末句号的美化
  （不改变词形，不影响跟读评分的归一化比对）；
- 该合集未提供这 8 篇的中文翻译，translation 留空，UI 会自动隐藏译文行。

运行顺序（在 seed_content.py 之后、build_content.dart 之前）：
    py -3 tools/seed_content.py
    py -3 tools/align_content.py --ffmpeg <ffmpeg>
    py -3 tools/import_transcripts.py
    dart run tools/build_content.dart
"""
import difflib
import glob
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "tools", "transcripts_source.json")
CONTENT = os.path.join(ROOT, "assets", "content")

SECTION = re.compile(r"^第\s*(\d+)\s*篇[\s　]+(.+)$")
TIME = re.compile(r"^\[(\d{1,2}):(\d{2})\]\s*(.*)$")
SOURCE_LINE = re.compile(r"^原文件[：:]\s*(.+?)\s*[｜|]")
MAX_WORDS = 14

# docx 篇号 → 内容 id（按《TED演讲原文合集》目录顺序）。
# 文件名匹配作为主路径，个别篇目因全角/半角差异匹配不上时用这张表兜底。
SECTION_TO_ID = {
    1: "levitin_stay_calm",
    2: "ted_true_confidence",
    3: "meg_jay_why_30",
    4: "ted_humility_water",
    5: "brewer_break_habit",
    6: "ted_self_criticism",
    7: "ted_believe_yourself",
    8: "ted_not_personal",
    9: "esfahani_more_than_happy",
    10: "ted_why_meaning",
    11: "ted_meaning_of_life",
    12: "robbins_five_seconds",
    13: "ted_mind_control",
}


def norm(s):
    return re.sub(r"[\s　\-_—–｜|【】《》\"'’‘“”?,.，。!！:：]", "", s).lower()


def load_sections():
    paras = json.load(open(SRC, encoding="utf-8"))["paragraphs"]
    sections = []
    cur = None
    for p in paras:
        m = SECTION.match(p)
        # 排除「第9篇《…》的视频文件不含音轨…」这类说明段落
        if m and len(p) < 45 and "的视频文件" not in p:
            cur = {"no": int(m.group(1)), "title": m.group(2).strip(),
                   "source": "", "cues": []}
            sections.append(cur)
            continue
        if cur is None:
            continue
        sm = SOURCE_LINE.match(p)
        if sm:
            cur["source"] = sm.group(1).strip()
            continue
        tm = TIME.match(p)
        if tm:
            cur["cues"].append((int(tm.group(1)) * 60 + int(tm.group(2)),
                                tm.group(3).strip()))
    return sections


def load_content():
    out = []
    for path in glob.glob(os.path.join(CONTENT, "*.json")):
        if os.path.basename(path) in ("index.json", "media_manifest.json"):
            continue
        try:
            data = json.load(open(path, encoding="utf-8"))
        except Exception:
            continue
        out.append((path, data))
    return out


def prettify(text):
    s = text.strip()
    if not s:
        return s
    s = s[0].upper() + s[1:]
    if s[-1] not in ".!?":
        s += "."
    return s


def split_para(text, max_words=MAX_WORDS):
    words = text.split()
    if not words:
        return []
    out = []
    for i in range(0, len(words), max_words):
        out.append(" ".join(words[i:i + max_words]))
    return out


def build_sentences(cues, duration):
    out = []
    for i, (start, text) in enumerate(cues):
        end = cues[i + 1][0] if i + 1 < len(cues) else duration
        if end <= start:
            end = start + 1.0
        pieces = split_para(text)
        if not pieces:
            continue
        span = (end - start) / len(pieces)
        for j, piece in enumerate(pieces):
            s = start + span * j
            e = start + span * (j + 1)
            out.append({
                "text": prettify(piece),
                "translation": "",
                "startTime": round(s, 3),
                "endTime": round(e, 3),
            })
    return out


def main():
    sections = load_sections()
    contents = load_content()
    print("逐字稿分节: %d 篇 | 内容文件: %d 篇" % (len(sections), len(contents)))

    filled = 0
    for sec in sections:
        if not sec["source"] or not sec["cues"]:
            continue
        key = norm(sec["source"])[:40]
        best, best_score, best_item = None, 0.0, None
        for path, data in contents:
            score = difflib.SequenceMatcher(
                None, key, norm(data.get("sourceMedia", ""))[:40]).ratio()
            if score > best_score:
                best, best_score, best_item = path, score, data
        # 文件名匹配不可靠时（或匹配到了别篇），改用篇号显式映射
        want_id = SECTION_TO_ID.get(sec["no"])
        if want_id and (best_score < 0.8 or best_item["id"] != want_id):
            for path, data in contents:
                if data.get("id") == want_id:
                    best, best_score, best_item = path, 1.0, data
                    break
        if best is None:
            print("  [跳过] 第%-2d篇 未匹配到内容 (%s)" %
                  (sec["no"], sec["title"][:20]))
            continue

        existing = best_item.get("sentences") or []
        scope = best_item.get("transcriptScope", "")
        if existing and scope in ("full", "excerpt", "asr_full"):
            print("  [保留] %-28s 已有完整稿 %d 句" %
                  (best_item["id"], len(existing)))
            continue

        duration = best_item.get("durationMs", 0) / 1000.0
        if duration <= 0:
            duration = sec["cues"][-1][0] + 60
        sentences = build_sentences(sec["cues"], duration)
        if not sentences:
            continue
        # 重跑导入时保留已有人工译文（按归一化文本精确匹配）
        old_zh = {
            norm(s.get("text", "")): s.get("translation", "")
            for s in existing
            if s.get("translation")
        }
        for s in sentences:
            s["translation"] = old_zh.get(norm(s["text"]), "")
        best_item["sentences"] = sentences
        best_item["hasTranscript"] = True
        best_item["transcriptScope"] = "asr"
        best_item["timingSource"] = "asr_timecode"
        best_item["alignmentNote"] = "用户提供逐字稿的真实时间码（ASR 原文，中文译文另行补齐）"
        best_item["source"] = "语音识别逐字稿"
        json.dump(best_item, open(best, "w", encoding="utf-8"),
                  ensure_ascii=False, indent=2)
        filled += 1
        print("  [补齐] %-28s %3d 句  匹配度 %.2f  第%d篇 %s" %
              (best_item["id"], len(sentences), best_score,
               sec["no"], sec["title"][:20]))

    print("完成：新补 %d 篇带文稿内容" % filled)
    print("下一步：dart run tools/build_content.dart")


if __name__ == "__main__":
    main()
