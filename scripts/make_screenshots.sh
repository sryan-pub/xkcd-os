#!/bin/bash
# App Store screenshots from Simulators, using the -screenshot launch hook (DebugMode.swift;
# Debug and Simulator builds only).
# Usage: scripts/make_screenshots.sh <Release-iphonesimulator .app> <output dir> [device udid:name ...]
# Default devices: iPhone 17 Pro (6.3", the size App Store Connect asks for) and iPad Pro 13-inch (M5) (13").
set -euo pipefail
APP=$1; OUT=$2; shift 2
BUNDLE=app.xkcdrevival.reader
DEVICES=("$@")
[ ${#DEVICES[@]} -eq 0 ] && DEVICES=("C8B8EBC8-CC5E-41F3-8257-BBBC75359FD3:iphone63" "55DBDBD9-72F8-4017-A820-0882F6098FFF:ipad13")
# name|appearance|scene ("grid" = no scene)
SCENES=(
  "1-grid|light|grid"
  "2-comic|light|comic 2347"
  "3-alt|light|alt 1053"
  "4-explain|light|explain ${EXPLAIN_COMIC:-936}"
  "5-dark|dark|grid"
  "6-dark-comic|dark|comic 1205"
)
mkdir -p "$OUT"
for entry in "${DEVICES[@]}"; do
  udid=${entry%%:*}; name=${entry##*:}
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi
  xcrun simctl uninstall "$udid" "$BUNDLE" 2>/dev/null || true   # fresh state: nothing read, no prompts answered
  xcrun simctl install "$udid" "$APP"
  for s in "${SCENES[@]}"; do
    IFS='|' read -r file look scene <<<"$s"
    xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
    xcrun simctl ui "$udid" appearance "$look"
    if [ "$scene" = grid ]; then
      xcrun simctl launch "$udid" "$BUNDLE" -debugMode NO -screenshot "" >/dev/null
      sleep 8
    else
      xcrun simctl launch "$udid" "$BUNDLE" -debugMode NO -screenshot "$scene" >/dev/null
      sleep 12
    fi
    xcrun simctl io "$udid" screenshot "$OUT/$name-$file.png" >/dev/null
    echo "$OUT/$name-$file.png"
  done
  xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
  xcrun simctl ui "$udid" appearance light
done
