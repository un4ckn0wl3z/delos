#!/usr/bin/env bash
# Emulator check of background music: start a StreamMKV server on the host with one
# music library, have the app sign in and play (autotest.json hook), then look for the
# media session + media notification and take screenshots (app, notification shade,
# lock screen). Results go to music-test/ (uploaded as an artifact).
set -u
PKG=dev.un4ckn0wl3z.streammkv
OUT=music-test; mkdir -p "$OUT"
FILES=/sdcard/Android/data/$PKG/files

# the app must have run once so its external files folder exists
adb shell am force-stop "$PKG"
adb shell mkdir -p "$FILES"
printf '{"server":"http://10.0.2.2:8090","user":"ci","pass":"ci-pass-123","play":"music","offline":true}' > /tmp/autotest.json
adb push /tmp/autotest.json "$FILES/autotest.json"
adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null || true
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
sleep 45
adb exec-out screencap -p > "$OUT/1-app.png"
adb logcat -d | grep -iE "AUTOTEST|media session|audio_service|AudioService|flutter|MediaSession|System.err|AndroidRuntime|Exception" | grep -v "^.*System.err: \s*at (android|java|com.android|kotlin)" | tail -200 > "$OUT/logcat.txt"
adb shell dumpsys media_session > "$OUT/media_session.txt"
adb shell dumpsys notification --noredact > "$OUT/notification.txt"
adb shell cmd statusbar expand-notifications; sleep 2
adb exec-out screencap -p > "$OUT/2-shade.png"
adb shell cmd statusbar collapse
adb shell input keyevent 26; sleep 2; adb shell input keyevent 26; sleep 3   # lock, then wake to the lock screen
adb exec-out screencap -p > "$OUT/3-lockscreen.png"

cat "$OUT/logcat.txt" | tail -80
echo "---- media sessions for $PKG"
grep -A12 "package=$PKG" "$OUT/media_session.txt" | head -40
echo "---- notifications for $PKG"
grep -E "pkg=$PKG" -A3 "$OUT/notification.txt" | head -30
ok=1
grep -q "package=$PKG" "$OUT/media_session.txt" || { echo "::warning::no media session for the app"; ok=0; }
grep -A12 "package=$PKG" "$OUT/media_session.txt" | grep -q "state=PlaybackState {state=PLAYING\|state=3" || { echo "::warning::media session is not PLAYING"; ok=0; }
grep -q "pkg=$PKG.*" "$OUT/notification.txt" && grep -q "MediaStyle\|android.mediaSession" "$OUT/notification.txt" || { echo "::warning::no media notification"; ok=0; }
grep -q "AUTOTEST: offline playing=true file=true" "$OUT/logcat.txt" || { echo "::warning::saved song didn't play from the device"; ok=0; }
[ $ok = 1 ] && echo "Media session, notification and offline music OK" || exit 1
