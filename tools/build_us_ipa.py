# -*- coding: utf-8 -*-
"""
构建「标准美式英语发音词库」：CMU Pronouncing Dictionary → IPA。

数据来源：https://github.com/cmusphinx/cmudict（卡内基梅隆大学，公共领域）
原始文件由 tools/download_sources.ps1 下载到 tools/cmudict.dict。

输出：
  assets/dict/us_ipa.json.gz    { 小写单词: "/ipa/" }，约 13 万词条
  assets/dict/us_ipa_meta.json  来源、词条数、与中文词典覆盖率

用法：py -3 tools/build_us_ipa.py
"""
import gzip
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "tools", "cmudict.dict")
ECDICT = os.path.join(ROOT, "assets", "dict", "dict.json.gz")
OUT = os.path.join(ROOT, "assets", "dict", "us_ipa.json.gz")
META = os.path.join(ROOT, "assets", "dict", "us_ipa_meta.json")

# ARPAbet -> 通用美式 IPA
CONSONANTS = {
    "B": "b", "CH": "tʃ", "D": "d", "DH": "ð", "F": "f", "G": "ɡ",
    "HH": "h", "JH": "dʒ", "K": "k", "L": "l", "M": "m", "N": "n",
    "NG": "ŋ", "P": "p", "R": "ɹ", "S": "s", "SH": "ʃ", "T": "t",
    "TH": "θ", "V": "v", "W": "w", "Y": "j", "Z": "z", "ZH": "ʒ",
}
VOWELS = {
    "AA": "ɑ", "AE": "æ", "AH": "ə", "AO": "ɔ", "AW": "aʊ", "AY": "aɪ",
    "EH": "ɛ", "ER": "ɚ", "EY": "eɪ", "IH": "ɪ", "IY": "i",
    "OW": "oʊ", "OY": "ɔɪ", "UH": "ʊ", "UW": "u",
}
# 重读时的美式变体
STRESSED_VOWEL = {"AH": "ʌ", "ER": "ɝ"}


def to_ipa(phones):
    out = []
    for raw in phones:
        stress = ""
        p = raw
        if p and p[-1].isdigit():
            stress = p[-1]
            p = p[:-1]
        if p in VOWELS:
            if stress == "1":
                out.append("ˈ")
                out.append(STRESSED_VOWEL.get(p, VOWELS[p]))
            elif stress == "2":
                out.append("ˌ")
                out.append(VOWELS[p])
            else:
                out.append(VOWELS[p])
        elif p in CONSONANTS:
            out.append(CONSONANTS[p])
        # 未知音素（极少）直接跳过
    return "".join(out)


def main():
    if not os.path.isfile(SRC):
        print("缺少 tools/cmudict.dict，请先运行 tools/download_sources.ps1")
        return 1

    data = {}
    with open(SRC, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(";;;"):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            word = parts[0].lower()
            # WORD(2) / WORD(3) 是异读，只保留首选发音
            if re.search(r"\(\d+\)$", word):
                continue
            word = re.sub(r"[^a-z'\-]", "", word)
            if not word or word in data:
                continue
            ipa = to_ipa(parts[1:])
            if ipa:
                data[word] = ipa

    with gzip.open(OUT, "wt", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))

    # 与现有中文词典的覆盖率
    with gzip.open(ECDICT, "rt", encoding="utf-8") as f:
        zh = json.load(f)
    zh_words = set(zh.keys())
    covered = len(zh_words & set(data.keys()))

    meta = {
        "source": "CMU Pronouncing Dictionary (cmusphinx/cmudict), public domain",
        "notation": "General American English IPA",
        "entries": len(data),
        "ecdictEntries": len(zh_words),
        "coveredByUsIpa": covered,
        "coverage": round(covered / max(1, len(zh_words)), 4),
        "rawBytes": os.path.getsize(SRC),
        "compressedBytes": os.path.getsize(OUT),
    }
    with open(META, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    print("美式 IPA 词库生成：%s" % OUT)
    for k, v in meta.items():
        print("  %-20s %s" % (k, v))
    for w in ["hello", "world", "schedule", "either", "tomato", "data", "water", "new"]:
        print("  %-10s /%s/" % (w, data.get(w, "-")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
