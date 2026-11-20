# -*- coding: utf-8 -*-
"""精确统计每个译文 .py 文件中 ZH 列表的元素数，用 ast 解析避免 import 语法错误。"""
import ast, sys, io, json, os
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

ZH_DIR = r"C:\Users\L't\Desktop\TED\tools\zh"
d = r"C:\Users\L't\Desktop\TED\assets\content"
targets = [
    "ted_mind_control", "ted_true_confidence", "ted_why_meaning",
    "ted_humility_water", "ted_not_personal", "ted_believe_yourself",
    "ted_meaning_of_life", "ted_self_criticism",
]
for tid in targets:
    p = os.path.join(ZH_DIR, tid + ".py")
    en = len(json.load(open(os.path.join(d, tid + ".json"), encoding="utf-8"))["sentences"])
    try:
        src = open(p, encoding="utf-8").read()
        tree = ast.parse(src)
        zh = None
        for node in tree.body:
            if isinstance(node, ast.Assign):
                for t in node.targets:
                    if isinstance(t, ast.Name) and t.id == "ZH":
                        zh = node.value
        if isinstance(zh, ast.List):
            n = len(zh.elts)
            print("%-24s 英文 %4d  译文元素 %4d  %s" % (tid, en, n, "OK" if en == n else "MISMATCH diff=%d" % (en - n)))
        else:
            print(tid, "ZH not a list literal")
    except SyntaxError as e:
        print("%-24s SYNTAX ERROR line %d: %s" % (tid, e.lineno, e.msg))
