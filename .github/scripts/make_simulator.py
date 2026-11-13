#!/usr/bin/env python3
"""Creates and boots a fresh iPhone simulator and prints its details for $GITHUB_OUTPUT.

  python3 .github/scripts/make_simulator.py newest   newest iOS runtime
  python3 .github/scripts/make_simulator.py 18       newest iOS 18 runtime

Prints found=false (and no UDID) when the image has no matching runtime.
"""
import json
import re
import subprocess
import sys


def simctl(*args):
    return subprocess.run(["xcrun", "simctl", *args], check=True, capture_output=True, text=True).stdout


def version_key(runtime):
    return tuple(int(p) for p in runtime["version"].split("."))


def main():
    want = sys.argv[1] if len(sys.argv) > 1 else "newest"
    runtimes = [r for r in json.loads(simctl("list", "runtimes", "-j"))["runtimes"]
                if r.get("platform") == "iOS" and r.get("isAvailable")]
    if want != "newest":
        runtimes = [r for r in runtimes if r["version"].split(".")[0] == want]
    if not runtimes:
        print(f"No iOS {want} simulator runtime on this image.", file=sys.stderr)
        print("found=false")
        return
    runtime = max(runtimes, key=version_key)

    # A plain iPhone, or failing that a Pro: the pager check measures at 3 pixels per point.
    phones = [d for d in runtime["supportedDeviceTypes"] if d.get("productFamily") == "iPhone"]
    device = None
    for pattern in (r"iPhone \d+", r"iPhone \d+ Pro"):
        matches = [d for d in phones if re.fullmatch(pattern, d["name"])]
        if matches:
            device = max(matches, key=lambda d: int(re.search(r"\d+", d["name"]).group()))
            break
    if device is None:
        sys.exit(f"No suitable iPhone for {runtime['name']}")

    udid = simctl("create", "CI " + device["name"], device["identifier"], runtime["identifier"]).strip()
    simctl("boot", udid)
    simctl("bootstatus", udid, "-b")
    print(f"Booted {device['name']} on {runtime['name']} ({udid})", file=sys.stderr)
    print("found=true")
    print(f"udid={udid}")
    print(f"name={device['name']}, {runtime['name']}")


if __name__ == "__main__":
    main()
