#!/usr/bin/env python3
"""Checks that comics opened from far down the list come to rest centred on their page.

On iOS 18 the page row could stop part-way between two comics after an old comic was opened
(usually with the dice), leaving a strip of the next comic showing. This opens a set of old
comics in a Simulator the way the dice does, screenshots each once it settles, and measures
from the screenshot whether it's centred.

  python3 scripts/check_pager_alignment.py <simulator UDID> [--app XKCDReader.app] [--rounds N]
  python3 scripts/check_pager_alignment.py --image screenshot.png [--scale 3]

Build a Release copy for the Simulator first (Debug is too slow to compare), e.g.
  xcodebuild -scheme XKCDReader -configuration Release -destination 'id=<UDID>' \\
      -derivedDataPath build/DerivedData-sim CODE_SIGNING_ALLOWED=NO build
The app is started with `-debugMode YES -pagerCheck "<numbers>"` (see DebugMode.swift), in
light mode, portrait. Exits 1 if any comic is off-centre, or still missed after two retries.
"""
import argparse
import datetime
import os
import subprocess
import sys
import tempfile
import time

BUNDLE = "app.xkcdrevival.reader"
# Old comics, deep in the row of pages where a misplaced row ends up furthest off, that fill the
# width of an iPhone screen and are drawn with a border, so their outermost dark pixels are the
# picture's own edges.
COMICS = [53, 162, 303, 386, 520, 627, 827, 936, 1010, 1337]
SETTLE_SECONDS = 2.8
HOLD_SECONDS = 6  # how long the app keeps each comic open (ComicGridScreen.runPagerCheck)


def load_gray(path):
    """Returns (width, height, rows of 0-255 grey), using macOS's sips to make a plain BMP."""
    bmp = os.path.join(tempfile.mkdtemp(), "shot.bmp")
    subprocess.run(["sips", "-s", "format", "bmp", path, "--out", bmp], check=True, capture_output=True)
    data = open(bmp, "rb").read()
    offset = int.from_bytes(data[10:14], "little")
    width = int.from_bytes(data[18:22], "little", signed=True)
    height = int.from_bytes(data[22:26], "little", signed=True)
    step = int.from_bytes(data[28:30], "little") // 8
    if step not in (3, 4):
        sys.exit(f"unexpected BMP depth in {path}")
    stride = (width * step + 3) & ~3
    rows = []
    for r in range(abs(height)):
        line = data[offset + r * stride:offset + r * stride + width * step]
        rows.append([(line[i] + line[i + 1] + line[i + 2]) // 3 for i in range(0, width * step, step)])
    if height > 0:  # stored bottom-up
        rows.reverse()
    return width, abs(height), rows


def measure(path, scale):
    """Clear margins left and right of the comic, in points, and whether that is centred.

    The viewer insets every comic by 14 points on both sides, so a comic that fills the width
    has equal margins. A row resting between two pages gives unequal ones, and once it is off by
    more than the margin, drawing from the neighbouring comic right at one edge.
    """
    width, height, rows = load_gray(path)
    band = rows[int(height * 0.16):int(height * 0.84)]  # leave out the buttons
    dark = [False] * width
    for row in band:
        for x, v in enumerate(row):
            if v < 110:
                dark[x] = True
    if True not in dark:
        return None, None, False
    left = dark.index(True) / scale
    right = dark[::-1].index(True) / scale
    centred = abs(left - right) <= 2 and min(left, right) >= 10
    return left, right, centred


def report(path, scale, measured=None):
    left, right, centred = measured or measure(path, scale)
    name = os.path.basename(path)
    if left is None:
        print(f"{name}: no comic found -> OFF-CENTRE")
    else:
        print(f"{name}: margins left {left:.1f} pt, right {right:.1f} pt -> {'centred' if centred else 'OFF-CENTRE'}")
    return centred


def logged_time(line):
    """When the app logged a compact `log stream` line, which can reach us seconds late."""
    try:
        return datetime.datetime.strptime(line[:23], "%Y-%m-%d %H:%M:%S.%f").timestamp()
    except ValueError:
        return time.time()


def run_round(udid, comics, out, label, scale):
    """Launches the app with the comics to open and screenshots each as it settles.

    Returns {comic: centred} for the comics it got a screenshot of in time.
    """
    log = subprocess.Popen(
        ["xcrun", "simctl", "spawn", udid, "log", "stream", "--style", "compact",
         "--predicate", 'eventMessage BEGINSWITH "PagerCheck"'],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
    try:
        time.sleep(1)
        subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE,
                        "-debugMode", "YES", "-pagerCheck", " ".join(map(str, comics))],
                       check=True, capture_output=True)
        results = {}
        deadline = time.time() + 60 + 9 * len(comics)
        for line in log.stdout:
            if time.time() > deadline:
                print("timed out waiting for the app")
                break
            if "PagerCheck done" in line:
                break
            if "PagerCheck opened" not in line:
                continue
            num = int(line.rsplit(" ", 1)[-1])
            opened = logged_time(line)
            lag = time.time() - opened
            time.sleep(max(0, SETTLE_SECONDS - lag))
            shot = os.path.join(out, f"{label}-comic{num}.png")
            attempt = shot + ".tmp.png"
            # Measure once two screenshots in a row agree, since a comic still downloading shows
            # only a spinner. On a slow machine (like a CI runner) the log line can arrive late
            # and screenshots are slow, so a shot that ends after the app moves on doesn't count.
            last = measured = None
            shots = blank = 0
            while time.time() - opened < HOLD_SECONDS - 1:
                subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", attempt], check=True, capture_output=True)
                if time.time() - opened > HOLD_SECONDS - 0.2:
                    break
                shots += 1
                current = measure(attempt, scale)
                blank += current[0] is None
                if current[0] is not None:
                    measured = current
                    os.replace(attempt, shot)
                    if current == last:
                        break
                last = current
                time.sleep(0.3)
            if os.path.exists(attempt):
                os.remove(attempt)
            if measured is None:
                print(f"comic {num}: missed (log line {lag:.1f} s late, {shots} screenshots in time, {blank} with no comic)")
                continue
            results[num] = report(shot, scale, measured)
        return results
    finally:
        log.terminate()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("udid", nargs="?", help="Simulator to run in")
    parser.add_argument("--app", help="XKCDReader.app to install first")
    parser.add_argument("--rounds", type=int, default=1, help="times to go through the comics")
    parser.add_argument("--image", help="only measure this screenshot")
    parser.add_argument("--scale", type=float, default=3, help="pixels per point (3 on iPhones)")
    args = parser.parse_args()

    if args.image:
        return 0 if report(args.image, args.scale) else 1
    if not args.udid:
        parser.error("give a Simulator UDID, or --image")

    if args.app:
        subprocess.run(["xcrun", "simctl", "install", args.udid, args.app], check=True)
    subprocess.run(["xcrun", "simctl", "ui", args.udid, "appearance", "light"], check=True)
    # Skip the first-launch offer of new-comic alerts, which would sit over the comics.
    subprocess.run(["xcrun", "simctl", "spawn", args.udid, "defaults", "write", BUNDLE,
                    "askedAboutNewComicAlerts", "-bool", "YES"], check=True)
    out = tempfile.mkdtemp(prefix="pager-check.")
    results = []
    missed = 0
    for round_no in range(1, args.rounds + 1):
        got = run_round(args.udid, COMICS, out, f"round{round_no}", args.scale)
        for retry in (1, 2):
            missing = [c for c in COMICS if c not in got]
            if not missing:
                break
            print(f"trying again for {' '.join(map(str, missing))}")
            got.update(run_round(args.udid, missing, out, f"round{round_no}-retry{retry}", args.scale))
        results += got.values()
        missed += len(COMICS) - len(got)
    off = results.count(False)
    print(f"{off} of {len(results)} comics off-centre, {missed} missed. Screenshots: {out}")
    return 0 if results and off == 0 and missed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
