# -*- coding: utf-8 -*-
"""
强制对齐：把逐句文稿的时间戳 + 词级 words[] 对齐到真实音频时间轴。

两种模式，自动选择：
1. 有 ffmpeg（--ffmpeg 指定）：解码 mp4 → 16k 单声道 PCM，
   计算 20ms 帧能量，检测静音段作为句子边界锚点，
   再按音素时长权重把句子/词铺进有效语音区间。
2. 无 ffmpeg：用音素时长模型（音节数、功能词弱读、标点停顿）
   替代原来的「按词数均分」，句级与词级精度都显著提升。

用法（内容管线的第 3 步）：
    py -3 tools/align_content.py
    py -3 tools/align_content.py --ffmpeg C:\\Users\\Public\\ffmpeg.exe
之后必须重跑 dart run tools/build_content.dart。

已标注 timingSource=aligned 的篇目（Matt Cutts 精确对齐稿）保留原句级时间戳，
只补词级 words[]，不覆盖人工校对结果。
"""
import argparse
import array
import json
import os
import re
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTENT = os.path.join(ROOT, "assets", "content")
INDEX = os.path.join(CONTENT, "index.json")

FUNCTION_WORDS = {
    "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for",
    "with", "as", "is", "am", "are", "was", "were", "be", "been", "it", "its",
    "that", "this", "these", "those", "i", "you", "he", "she", "we", "they",
    "my", "your", "his", "her", "our", "their", "do", "does", "did", "have",
    "has", "had", "will", "would", "can", "could", "should", "not", "so", "if",
    "just", "up", "out", "about", "from", "by", "than", "then", "there", "here",
}


def syllables(word):
    w = re.sub(r"[^a-z]", "", word.lower())
    if not w:
        return 1
    n = len(re.findall(r"[aeiouy]+", w))
    if w.endswith("e") and n > 1 and not w.endswith(("le", "ee", "ye")):
        n -= 1
    return max(1, n)


def word_weight(word):
    """词的发音时长权重（秒），含词尾标点带来的停顿。"""
    clean = re.sub(r"[^A-Za-z']", "", word)
    base = 0.16 + 0.095 * syllables(clean)
    if clean.lower() in FUNCTION_WORDS:
        base *= 0.55
    if len(clean) > 8:
        base *= 1.10
    pause = 0.0
    m = re.search(r"([,;:!?\.]+)$", word)
    if m:
        pause = 0.22 if any(c in ".!?" for c in m.group(1)) else 0.11
    return base + pause


def split_words(text):
    return [w for w in text.split() if w]


def sentence_weights(sentences):
    out = []
    for s in sentences:
        words = split_words(s["text"])
        out.append(sum(word_weight(w) for w in words))
    return out


def build_words(text, start, end):
    """句内按音素权重分配每个词的精确起止。"""
    words = split_words(text)
    if not words:
        return []
    ws = [word_weight(w) for w in words]
    total = sum(ws) or 1.0
    span = max(0.0, end - start)
    out = []
    cur = start
    for w, weight in zip(words, ws):
        dur = span * weight / total
        out.append({
            "w": w,
            "s": round(cur, 3),
            "e": round(cur + dur, 3),
        })
        cur += dur
    return out


def pcm_energies(ffmpeg, audio_path, frame_ms=20):
    """解码音频并返回每帧 RMS 能量与帧长（秒）。"""
    if not os.path.isfile(audio_path):
        raise FileNotFoundError(audio_path)
    # -vn 禁视频、-map 0:a:0 强制取第一条音轨；
    # 部分 B站 mp4 带画面轨，不显式指定会让 ffmpeg 选不输出到 s16le 的流。
    cmd = [ffmpeg, "-v", "error", "-i", audio_path,
           "-vn", "-map", "0:a:0",
           "-ac", "1", "-ar", "16000", "-f", "s16le", "-"]
    res = subprocess.run(cmd, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, timeout=300)
    if res.returncode != 0:
        raise RuntimeError(res.stderr.decode("utf-8", "replace")[:200])
    samples = array.array("h")
    samples.frombytes(res.stdout)
    n = 16000 * frame_ms // 1000
    energies = []
    acc = 0
    count = 0
    for v in samples:
        acc += v * v
        count += 1
        if count == n:
            energies.append(acc / n)
            acc = 0
            count = 0
    return energies, frame_ms / 1000.0


def speech_span(energies, frame_s):
    """返回 (语音起始秒, 语音结束秒, 静音边界列表)。"""
    if not energies:
        return None
    ordered = sorted(energies)
    peak = ordered[int(len(ordered) * 0.95)] or 1.0
    thresh = peak * 0.05
    active = [e > thresh for e in energies]
    # 合并短静音（< 180ms），避免把词间停顿误判成句边界
    fill = max(1, int(0.18 / frame_s))
    i = 0
    while i < len(active):
        if active[i]:
            i += 1
            continue
        j = i
        while j < len(active) and not active[j]:
            j += 1
        if j - i <= fill and i > 0 and j < len(active):
            for k in range(i, j):
                active[k] = True
        i = j
    # 提取连续语音段与静音中点（句子边界候选）
    segments = []
    start = None
    for idx, on in enumerate(active):
        if on and start is None:
            start = idx
        elif not on and start is not None:
            if (idx - start) * frame_s > 0.30:
                segments.append((start * frame_s, idx * frame_s))
            start = None
    if start is not None:
        segments.append((start * frame_s, len(active) * frame_s))
    if not segments:
        return None
    boundaries = []
    for a, b in zip(segments, segments[1:]):
        boundaries.append((a[1] + b[0]) / 2)
    return segments[0][0], segments[-1][1], boundaries


def snap_to_boundary(t, boundaries, tolerance=0.75):
    """把句子边界吸附到最近的静音中点。"""
    best = t
    delta = tolerance
    for b in boundaries:
        d = abs(b - t)
        if d < delta:
            delta = d
            best = b
    return best


def align_one(path, ffmpeg=None, verbose=True):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    sentences = data.get("sentences") or []
    if not sentences:
        return None
    duration = data.get("durationMs", 0) / 1000.0
    if duration <= 0:
        return None

    # 用户逐字稿自带真实 [mm:ss] 时间码，比任何估算/能量对齐都准；
    # 这里只补词级 words[]，绝不覆盖句级时间。
    if data.get("timingSource") == "asr_timecode":
        for s in sentences:
            s["words"] = build_words(s["text"], s["startTime"], s["endTime"])
        data["sentences"] = sentences
        data["alignmentNote"] = "用户提供逐字稿的真实时间码 + 音素权重词级插值"
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        if verbose:
            print("  %-28s %-9s %3d 句  %s" %
                  (data["id"], "asr", len(sentences), data["alignmentNote"]))
        return "asr"

    audio = os.path.join(ROOT, data.get("audioPath", "").replace("/", os.sep))
    span = None
    if ffmpeg:
        try:
            energies, frame_s = pcm_energies(ffmpeg, audio)
            span = speech_span(energies, frame_s)
        except Exception as e:
            print("  音频解码失败，回退音素模型：%s" % str(e)[:100])

    already_aligned = data.get("timingSource") == "aligned"
    weights = sentence_weights(sentences)
    total_w = sum(weights) or 1.0

    if span:
        speech_start, speech_end, boundaries = span
        # 音频里的有效语音区间（掐掉片头片尾空白）
        available = max(0.1, speech_end - speech_start)
        mode = "audio"
    else:
        speech_start, available = 0.0, duration
        boundaries = []
        mode = "phonetic"

    result = []
    cursor = speech_start
    for i, (s, w) in enumerate(zip(sentences, weights)):
        raw_end = cursor + available * w / total_w
        end = snap_to_boundary(raw_end, boundaries) if boundaries else raw_end
        if end <= cursor + 0.05:
            end = raw_end
        if already_aligned:
            start, end = s["startTime"], s["endTime"]
        else:
            start = cursor
        result.append({
            "text": s["text"],
            "translation": s.get("translation", ""),
            "startTime": round(start, 3),
            "endTime": round(end, 3),
            "words": build_words(s["text"], start, end),
        })
        cursor = end if not already_aligned else end

    data["sentences"] = result
    data["timingSource"] = "aligned" if already_aligned else mode
    data["alignmentNote"] = (
        "人工校对句级时间戳 + 音素权重词级插值" if already_aligned else
        "音频能量静音锚点 + 音素时长强制对齐" if mode == "audio" else
        "音素时长模型对齐（未提供 ffmpeg，未使用音频信号）"
    )
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    if verbose:
        print("  %-28s %-9s %3d 句  %s" %
              (data["id"], mode, len(result), data["alignmentNote"]))
    return mode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ffmpeg", default=None, help="ffmpeg 可执行文件路径")
    args = ap.parse_args()

    ffmpeg = args.ffmpeg
    if not ffmpeg:
        for cand in [r"C:\Users\Public\ffmpeg.exe", "ffmpeg"]:
            if os.path.isfile(cand) or cand == "ffmpeg":
                ffmpeg = cand
                break

    with open(INDEX, encoding="utf-8") as f:
        index = json.load(f)
    print("强制对齐（ffmpeg=%s）" % ffmpeg)
    modes = {}
    for e in index["entries"]:
        p = os.path.join(CONTENT, e["file"])
        if not os.path.isfile(p):
            continue
        m = align_one(p, ffmpeg=ffmpeg)
        if m:
            modes[m] = modes.get(m, 0) + 1
    print("完成：%s" % (", ".join("%s %d 篇" % (k, v) for k, v in modes.items()) or "无"))
    print("下一步：dart run tools/build_content.dart")


if __name__ == "__main__":
    main()
