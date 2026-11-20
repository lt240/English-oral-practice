# -*- coding: utf-8 -*-
"""
素材导入脚本：把「TED音频」目录里的音频/视频登记进 App 内容库。

用法（在 TED 项目根目录执行）：
    py -3 tools/import_media.py

做的事：
1. 扫描素材目录（默认 C:\\Users\\L't\\Desktop\\TED音频）里的 mp4/mp3/m4a
2. 复制为 ASCII 文件名 assets/audio/ted_XX.<ext>，避免 Android aapt 不支持中文/特殊字符资源名
3. 解析 mp4 mvhd 得到真实时长
4. 生成 assets/content/media_manifest.json（中文原名 ↔ App 内路径 ↔ 时长）

后续新增内容：把下载的文件放进素材目录 → 重跑本脚本 →
在 assets/content/index.json 里为新的 ted_XX 补一份文稿 JSON 即可。
"""
import json
import os
import re
import shutil
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(os.path.dirname(ROOT), "TED音频")
AUDIO_DIR = os.path.join(ROOT, "assets", "audio")
MANIFEST = os.path.join(ROOT, "assets", "content", "media_manifest.json")
EXTS = (".mp4", ".m4a", ".mp3", ".aac", ".wav")


def mp4_duration(path):
    """从 mvhd box 读取时长（秒）；失败返回 None。"""
    try:
        with open(path, "rb") as f:
            data = f.read()
        i = data.find(b"mvhd")
        if i < 0:
            return None
        p = i + 4  # 跳过 type
        version = data[p]
        p += 4  # version + flags
        if version == 1:
            p += 16  # creation + modification (8+8)
            timescale = struct.unpack(">I", data[p:p + 4])[0]
            duration = struct.unpack(">Q", data[p + 4:p + 12])[0]
        else:
            p += 8  # creation + modification (4+4)
            timescale = struct.unpack(">I", data[p:p + 4])[0]
            duration = struct.unpack(">I", data[p + 4:p + 8])[0]
        if timescale <= 0:
            return None
        return round(duration / timescale, 2)
    except Exception:
        return None


def ffmpeg_path():
    for cand in [r"C:\Users\Public\ffmpeg.exe", "ffmpeg"]:
        if cand == "ffmpeg" or os.path.isfile(cand):
            return cand
    return None


def probe_duration(path, ffmpeg=None):
    """优先用 ffmpeg 读真实时长（能识别 mvhd.duration=0 的流式 mp4），
    失败再回退到解析 mvhd box。"""
    if ffmpeg:
        try:
            r = subprocess.run(
                [ffmpeg, "-hide_banner", "-i", path],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
            m = re.search(rb"Duration: (\d+):(\d+):(\d+\.\d+)", r.stderr)
            if m:
                return round(int(m[1]) * 3600 + int(m[2]) * 60
                             + float(m[3]), 2)
        except Exception:
            pass
    return mp4_duration(path)


def main():
    global SOURCE
    if len(sys.argv) > 1:
        SOURCE = sys.argv[1]
    if not os.path.isdir(SOURCE):
        print("素材目录不存在：%s" % SOURCE)
        return 1
    os.makedirs(AUDIO_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)

    files = sorted(
        [f for f in os.listdir(SOURCE) if f.lower().endswith(EXTS)],
        key=lambda x: x,
    )

    # 保留已有映射：绝不能按文件名排序重新编号，否则会把 ted_01..13
    # 覆盖成完全不同的演讲。新文件才分配下一个空闲编号。
    old = {"media": []}
    if os.path.isfile(MANIFEST):
        try:
            with open(MANIFEST, encoding="utf-8") as f:
                old = json.load(f)
        except Exception:
            pass
    by_source = {
        m.get("source"): m.get("asset")
        for m in old.get("media", [])
        if m.get("source") and m.get("asset")
    }
    used_assets = set(os.listdir(AUDIO_DIR))
    max_idx = 0
    for asset_name in used_assets:
        m = re.match(r"ted_(\d+)\.", asset_name)
        if m:
            max_idx = max(max_idx, int(m.group(1)))
    index = max_idx
    ff = ffmpeg_path()
    out = []
    seen_sources = set()
    seen_copies = set()

    for name in files:
        src = os.path.join(SOURCE, name)
        ext = os.path.splitext(name)[1].lower()
        seen_sources.add(name)

        # 「xxx (1).mp4」这类重复下载直接跳过
        base = re.sub(r" \(\d+\)$", "", os.path.splitext(name)[0])
        dupe_key = (base, os.path.getsize(src))
        if dupe_key in seen_copies:
            print("跳过重复文件：%s" % name)
            continue
        seen_copies.add(dupe_key)

        asset_rel = by_source.get(name)
        target_name = os.path.basename(asset_rel) if asset_rel else None
        if not target_name:
            index += 1
            target_name = "ted_%02d%s" % (index, ext)
            while target_name in used_assets:
                index += 1
                target_name = "ted_%02d%s" % (index, ext)
            used_assets.add(target_name)

        target = os.path.join(AUDIO_DIR, target_name)
        if not os.path.exists(target):
            ok = False
            if ff and ext in (".mp4", ".m4a"):
                # 只提取音轨，避免把整段视频（几十 MB）塞进安装包
                cmd = [
                    ff, "-hide_banner", "-loglevel", "error", "-y",
                    "-i", src, "-vn", "-map", "0:a:0", "-c:a", "copy",
                    "-movflags", "+faststart", target,
                ]
                try:
                    res = subprocess.run(cmd, timeout=180)
                    ok = res.returncode == 0 and os.path.exists(target) \
                        and os.path.getsize(target) > 0
                except Exception:
                    ok = False
                if ok:
                    print("提取音轨 %s -> %s" % (name, target_name))
                elif os.path.exists(target):
                    os.remove(target)
            elif ext in (".mp3", ".m4a"):
                shutil.copy2(src, target)
                ok = True
            if not ok:
                print("跳过（无音轨或提取失败）：%s" % name)
                out.append({
                    "source": name,
                    "asset": None,
                    "durationSeconds": None,
                    "sizeBytes": os.path.getsize(src),
                    "note": "无音轨或提取失败",
                })
                continue

        dur = probe_duration(target if os.path.exists(target) else src, ff) \
            if ext in (".mp4", ".m4a", ".mp3") else None
        out.append({
            "source": name,
            "asset": "assets/audio/" + target_name,
            "durationSeconds": dur,
            "sizeBytes": os.path.getsize(target)
            if os.path.exists(target) else 0,
        })
        print("  %-42s 时长=%s 秒" % (name[:40], dur))

    # 当前素材目录里暂时没有、但 App 仍在用的旧音轨要保留登记
    out_sources = {m.get("source") for m in out}
    for m in old.get("media", []):
        if m.get("source") not in seen_sources \
                and m.get("source") not in out_sources:
            out.append(m)

    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump({"sourceDir": SOURCE, "media": out}, f,
                  ensure_ascii=False, indent=2)
    print("\n已登记 %d 个素材 -> %s" % (len(out), MANIFEST))
    return 0


if __name__ == "__main__":
    sys.exit(main())
