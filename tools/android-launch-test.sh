#!/usr/bin/env bash
# Install the APK on a running emulator, start it, and fail if it crashes or
# logs an unhandled Dart exception during the first 20 seconds.
set -u
APK="$1"; PKG=dev.un4ckn0wl3z.streammkv
adb install -r "$APK" || exit 1
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
sleep 20
PID=$(adb shell pidof "$PKG" | tr -d '\r')
echo "pid=$PID"
if [ -z "$PID" ]; then
  adb logcat -d | grep -A30 "FATAL EXCEPTION" | head -60
  echo "::error::The app is not running (crashed?)"; exit 1
fi
adb logcat -d --pid="$PID" > launch.log
grep -E " (E|F) " launch.log | head -60 || true
if grep -qE "Unhandled Exception|FATAL EXCEPTION|Fatal signal" launch.log; then
  echo "::error::The app does not start cleanly"; exit 1
fi
echo "App started OK"
