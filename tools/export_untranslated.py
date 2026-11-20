# -*- coding: utf-8 -*-
"""导出 8 篇无中译内容的英文句子，供逐句翻译。"""
import json, os, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

d = r"C:\Users\L't\Desktop\TED\assets\content"
idx = json.load(open(os.path.join(d, "index.json"), encoding="utf-8"))

# 8 篇无中译的 id（识别稿）
targets = [
    "ted_mind_control", "ted_true_confidence", "ted_why_meaning",
    "ted_humility_water", "ted_not_personal", "ted_believe_yourself",
    "ted_meaning_of_life", "ted_self_criticism",
]

out_dir = r"C:\Users\L't\Desktop\TED\tools\translations"
os.makedirs(out_dir, exist_ok=True)

for tid in targets:
    j = json.load(open(os.path.join(d, tid + ".json"), encoding="utf-8"))
    lines = []
    for i, s in enumerate(j["sentences"]):
        en = (s.get("text") or "").strip()
        lines.append("%d\t%s" % (i, en))
    with open(os.path.join(out_dir, tid + ".txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("%-26s %4d 句已导出" % (tid, len(lines)))
print("done ->", out_dir)
