# -*- coding: utf-8 -*-
"""分析逐字稿合集的分节结构，输出报告（UTF-8 文件，避免控制台乱码）。"""
import json
import re

SRC = r"C:\Users\Public\ted_transcripts.json"
REPORT = r"C:\Users\Public\transcripts_report.txt"

SECTION = re.compile(r"^第\s*(\d+)\s*篇")
TIME = re.compile(r"^\[(\d{1,2}):(\d{2})\]\s*(.*)$")
CJK = re.compile(r"[\u4e00-\u9fff]")


def main():
    data = json.load(open(SRC, encoding="utf-8"))
    paras = data["paragraphs"]

    sections = []
    cur = None
    for i, p in enumerate(paras):
        m = SECTION.match(p)
        if m:
            cur = {"no": int(m.group(1)), "title": p, "start": i,
                   "source": "", "paras": []}
            sections.append(cur)
            continue
        if cur is None:
            continue
        if p.startswith("原文件") or p.startswith("原文文件"):
            cur["source"] = p
            continue
        t = TIME.match(p)
        if t:
            sec = int(t.group(1)) * 60 + int(t.group(2))
            cur["paras"].append((sec, t.group(3), CJK.search(t.group(3)) is not None))
        elif CJK.search(p) and len(p) > 20:
            cur["paras"].append((None, p, True))

    lines = []
    lines.append("sections: %d" % len(sections))
    lines.append("total paragraphs: %d" % len(paras))
    for s in sections:
        timed = [x for x in s["paras"] if x[0] is not None]
        cjk = [x for x in s["paras"] if x[2]]
        eng_words = sum(len(x[1].split()) for x in timed)
        lines.append("")
        lines.append("=== 第%d篇 %s" % (s["no"], s["title"]))
        lines.append("source: %s" % s["source"][:200])
        lines.append("timed paragraphs: %d | cjk paragraphs: %d | english words: %d" %
                     (len(timed), len(cjk), eng_words))
        if timed:
            lines.append("time range: %02d:%02d .. %02d:%02d" %
                         (timed[0][0] // 60, timed[0][0] % 60,
                          timed[-1][0] // 60, timed[-1][0] % 60))
        lines.append("first 3:")
        for x in s["paras"][:3]:
            lines.append("   %s | %s" % (x[0], x[1][:160]))

    open(REPORT, "w", encoding="utf-8").write("\n".join(lines))
    print("report written:", REPORT)
    print("sections:", len(sections))


if __name__ == "__main__":
    main()
