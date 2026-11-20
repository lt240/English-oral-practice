# -*- coding: utf-8 -*-
"""按客观指标（平均词长）重算 14 篇内容的难度分级。

依据：平均词长（字符数/词）是词汇复杂度的稳健代理，不受 ASR 机械断句影响
（句长对 ASR 稿失真，故不采用）。分级阈值基于实测分布：
  difficulty 1（入门）: 均词长 < 4.15
  difficulty 2（进阶）: 4.15 ~ 4.45
  difficulty 3（高级）: >= 4.45
level 标签同步映射：1→入门 2→进阶 3→高级
"""
import json, glob, os, re

def avg_word_len(text):
    words = re.findall(r"[A-Za-z']+", text)
    if not words:
        return 0.0
    return sum(len(w) for w in words) / len(words)

def difficulty_of(wl):
    if wl < 4.15:
        return 1
    if wl < 4.45:
        return 2
    return 3

LEVEL = {1: '入门', 2: '进阶', 3: '高级'}

def main():
    results = []
    for f in sorted(glob.glob('assets/content/*.json')):
        if f.endswith(('index.json', 'media_manifest.json')):
            continue
        j = json.load(open(f, encoding='utf-8'))
        sents = j.get('sentences', [])
        if not sents:
            continue
        all_text = ' '.join(s.get('text', '') for s in sents)
        wl = avg_word_len(all_text)
        d = difficulty_of(wl)
        old = j.get('difficulty')
        j['difficulty'] = d
        j['level'] = LEVEL[d]
        # 记录重算依据，便于追溯
        j['difficultyNote'] = '均词长 %.2f 客观分级' % wl
        json.dump(j, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
        results.append((os.path.basename(f)[:-5], old, d, wl))
    results.sort(key=lambda r: -r[3])
    print('%-26s %5s -> %s  %s' % ('篇目', '原难度', '新难度', '均词长'))
    for name, old, new, wl in results:
        print('%-26s %5s -> %s  %.2f' % (name, old, new, wl))

if __name__ == '__main__':
    main()
