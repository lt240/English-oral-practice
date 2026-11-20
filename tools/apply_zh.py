# -*- coding: utf-8 -*-
"""
把逐句中文译文写回内容 JSON 的 translation 字段。
译文以 Python 文件形式提供：tools/zh/{id}.py 中定义 ZH = [ "译1", "译2", ... ]
按句子顺序一一对应，数量必须与英文句子数一致。
"""
import json, os, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

ROOT = r"C:\Users\L't\Desktop\TED"
CONTENT = os.path.join(ROOT, "assets", "content")
ZH_DIR = os.path.join(ROOT, "tools", "zh")
sys.path.insert(0, ZH_DIR)

targets = [
    "ted_mind_control", "ted_true_confidence", "ted_why_meaning",
    "ted_humility_water", "ted_not_personal", "ted_believe_yourself",
    "ted_meaning_of_life", "ted_self_criticism",
]

for tid in targets:
    mod = __import__(tid)
    zh = mod.ZH
    jpath = os.path.join(CONTENT, tid + ".json")
    j = json.load(open(jpath, encoding="utf-8"))
    sents = j["sentences"]
    if len(zh) != len(sents):
        print("!! %s 译文数 %d != 句子数 %d" % (tid, len(zh), len(sents)))
        continue
    for s, t in zip(sents, zh):
        s["translation"] = t
    json.dump(j, open(jpath, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("%-26s %4d 句中译已写入" % (tid, len(zh)))

print("done")
