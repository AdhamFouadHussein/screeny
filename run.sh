#!/bin/zsh
# Builds the Mac host, links the tablet over USB, and starts the extended display.
# Arguments are passed to screeny: --mbps N, --fps N, --scale 1|2
set -e

ROOT=${0:A:h}
ADB=${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb
APK=$ROOT/android/app/build/outputs/apk/debug/app-debug.apk
PORT=7878

if ! "$ADB" get-state >/dev/null 2>&1; then
    echo "No tablet found. Plug it in over USB, turn on USB debugging, and accept the prompt on the tablet."
    exit 1
fi

if ! "$ADB" shell pm path dev.screeny 2>/dev/null | grep -q package:; then
    "$ADB" install "$APK"
fi

swift build -c release --package-path "$ROOT/mac" 2>&1 | tail -1
"$ADB" reverse tcp:$PORT tcp:$PORT >/dev/null
"$ADB" shell am start -n dev.screeny/.MainActivity >/dev/null
exec "$ROOT/mac/.build/release/screeny" "$@"
