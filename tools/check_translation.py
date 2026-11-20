# -*- coding: utf-8 -*-
"""统计各篇内容的句子数与中译覆盖情况（用 translation 字段）。"""
import json, os, sys, io

# 强制 stdout 用 UTF-8，避免 Windows 控制台 GBK 乱码
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

d = r"C:\Users\L't\Desktop\TED\assets\content"
idx = json.load(open(os.path.join(d, "index.json"), encoding="utf-8"))

total_sent = 0
total_missing = 0
rows = []
for e in idx["entries"]:
    j = json.load(open(os.path.join(d, e["file"]), encoding="utf-8"))
    sents = j.get("sentences", [])
    missing = 0
    for s in sents:
        tr = (s.get("translation") or "").strip()
        if not tr:
            missing += 1
    total_sent += len(sents)
    total_missing += missing
    rows.append((j["id"], len(sents), missing))

print("id                         句子  无中译  有中译")
for rid, n, m in rows:
    print("%-26s %4d  %4d  %4d" % (rid, n, m, n - m))
print("=" * 50)
print("总句数:", total_sent, "| 无中译:", total_missing, "| 有中译:", total_sent - total_missing)
