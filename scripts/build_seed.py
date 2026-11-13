#!/usr/bin/env python3
"""Build XKCDReader/Resources/comics-seed.json: every xkcd comic plus image aspect ratio.

The original app got comics and their aspect ratios (for the mosaic layout) from a cache
server that no longer exists. This builds a file to bundle instead. Run it before a release;
the app fetches anything newer from xkcd.com itself.

Usage: python3 scripts/build_seed.py [--out PATH] [--workers 4]
Re-running reuses the existing file and only fetches comics it doesn't have yet.
Only the standard library is used.
"""
import argparse
import concurrent.futures as cf
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request

UA = "xkcd reader seed builder"
KNOWN_INTERACTIVE = {1193, 1331, 1446, 1525, 1608, 1663}
KEEP = ("num", "title", "safe_title", "alt", "transcript", "img", "day", "month", "year")


def get(url, rng=None, tries=4):
    for attempt in range(tries):
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        if rng:
            req.add_header("Range", f"bytes=0-{rng - 1}")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if attempt == tries - 1:
                raise
        except OSError:  # URLError, plus socket.timeout (not a TimeoutError before Python 3.10)
            if attempt == tries - 1:
                raise
        time.sleep(1.5 * (attempt + 1))


def image_size(b):
    """(width, height) from the start of a PNG, GIF or JPEG file, or None."""
    if b[:8] == b"\x89PNG\r\n\x1a\n" and len(b) >= 24:
        return struct.unpack(">II", b[16:24])
    if b[:6] in (b"GIF87a", b"GIF89a") and len(b) >= 10:
        return struct.unpack("<HH", b[6:10])
    if b[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(b):
            if b[i] != 0xFF:
                i += 1
                continue
            marker = b[i + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            seglen = struct.unpack(">H", b[i + 2:i + 4])[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", b[i + 5:i + 9])
                return w, h
            i += 2 + seglen
    return None


def fetch_comic(num):
    raw = get(f"https://xkcd.com/{num}/info.0.json")
    if raw is None:
        return None  # e.g. #404
    d = json.loads(raw)
    out = {k: d.get(k, "") for k in KEEP}
    out["isInteractive"] = bool(d.get("extra_parts")) or num in KNOWN_INTERACTIVE
    ratio = 1.0
    img = d.get("img") or ""
    if img.startswith("http") and not img.endswith("/"):
        for n in (4096, 65536, 1 << 20):
            head = get(img, rng=n)
            size = head and image_size(head)
            if size and size[1]:
                ratio = round(size[0] / size[1], 4)
                break
            if head is None or len(head) < n:
                break
    out["img_aspect_ratio"] = ratio
    return out


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--out", default=os.path.join(here, "..", "XKCDReader", "Resources", "comics-seed.json"))
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args()

    have = {}
    if os.path.exists(a.out):
        with open(a.out, "rb") as f:
            have = {c["num"]: c for c in json.loads(f.read())}
    latest = json.loads(get("https://xkcd.com/info.0.json"))["num"]
    todo = [n for n in range(1, latest + 1) if n not in have and n != 404]
    print(f"latest #{latest}, have {len(have)}, fetching {len(todo)}", file=sys.stderr)

    done = 0
    with cf.ThreadPoolExecutor(a.workers) as ex:
        for c in ex.map(fetch_comic, todo):
            done += 1
            if c:
                have[c["num"]] = c
            if done % 200 == 0:
                print(f"  {done}/{len(todo)}", file=sys.stderr)

    comics = [have[n] for n in sorted(have)]
    square = sum(1 for c in comics if c["img_aspect_ratio"] == 1.0)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "wb") as f:
        f.write(json.dumps(comics, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    print(f"wrote {len(comics)} comics ({square} with ratio 1.0) to {a.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
