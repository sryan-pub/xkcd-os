#!/bin/sh
# Records a Time Profiler trace of the app running on a connected iPhone or iPad.
#
#   scripts/profile_on_phone.sh DEVICE_UDID [SECONDS] [OUTPUT.trace]
#
# The device must be unlocked with the app already open (a development-signed build).
# Use the hardware UDID from `xcrun xctrace list devices`. While it records, do the
# thing that stutters. Open the result in Instruments, or export it with
# `xcrun xctrace export --input OUTPUT.trace --toc`.
#
# Uses Time Profiler, which also records potential hangs. The Animation Hitches template
# crashes the command-line recorder in Xcode 26.3.
set -eu
DEVICE="${1:?usage: profile_on_phone.sh DEVICE_UDID [SECONDS] [OUTPUT.trace]}"
SECONDS_TO_RECORD="${2:-30}"
OUT="${3:-xkcd-$(date +%Y%m%d-%H%M%S).trace}"
exec xcrun xctrace record --template 'Time Profiler' --device "$DEVICE" --attach XKCDReader \
    --time-limit "${SECONDS_TO_RECORD}s" --output "$OUT"
