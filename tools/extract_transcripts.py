# -*- coding: utf-8 -*-
"""从用户提供的 docx 逐字稿合集提取全部段落文本（只读）。

输出：
  C:/Users/Public/ted_transcripts.json  { paragraphs: [...] }
  C:/Users/Public/ted_transcripts.txt   带行号的可读版本
"""
import glob
import json
import os
import xml.etree.ElementTree as ET
import zipfile

DESKTOP = r"C:\Users\L't\Desktop"
OUT_JSON = r"C:\Users\Public\ted_transcripts.json"
OUT_TXT = r"C:\Users\Public\ted_transcripts.txt"
W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"


def find_source():
    candidates = [p for p in glob.glob(os.path.join(DESKTOP, "*.docx"))
                  if "TED" in os.path.basename(p)]
    if not candidates:
        raise FileNotFoundError("桌面未找到含 TED 的 .docx")
    return candidates[0]


def main():
    src = find_source()
    print("source:", os.path.basename(src))
    with zipfile.ZipFile(src) as z:
        xml = z.read("word/document.xml")
    root = ET.fromstring(xml)
    paras = []
    for p in root.iter(W + "p"):
        text = "".join(t.text or "" for t in p.iter(W + "t")).strip()
        if text:
            paras.append(text)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump({"source": src, "paragraphs": paras}, f, ensure_ascii=False)
    with open(OUT_TXT, "w", encoding="utf-8") as f:
        for i, t in enumerate(paras):
            f.write("[%04d] %s\n" % (i, t))
    print("paragraphs:", len(paras))
    print("total chars:", sum(len(x) for x in paras))
    print("=== first 50 ===")
    for i, t in enumerate(paras[:50]):
        print("[%04d] %s" % (i, t[:150]))


if __name__ == "__main__":
    main()
