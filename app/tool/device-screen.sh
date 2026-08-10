#!/bin/sh
# Read what is on a phone's screen, with nobody holding the phone.
#
#   tool/device-screen.sh android
#   tool/device-screen.sh ios
#   WAIT=90 tool/device-screen.sh ios     # while somebody walks through the app
#
# Both arms end the same way: files under build/device-screen/ that say what the screen shows.
# Neither one asks anybody to tap, unlock or look — a session with no human next to it can run
# them and read the answer.
#
# What that answer cannot be, on its own, is a screen reached by pressing something: the app opens
# on the same screen every time, and nothing here presses anything. So the iOS probe goes on
# reading for a couple of minutes, and WAIT is how long this waits before fetching what it wrote —
# long enough for somebody to walk through the app with the phone in their hand, if there is
# somebody to ask. Every stop they make is in the file, one reading after another.
#
# Why not `flutter run`: it finds the Dart VM over mDNS, so it needs the terminal to hold the
# local-network permission. A sandboxed shell cannot be granted one, and the run dies at
# "SocketException ... port = 5353" — over the cable as much as over Wi-Fi. The two device
# toolchains below do not go near it.
#
# Both arms run lib/probe_screen.dart, which is the real app with its semantics switched on.
# Flutter draws its own pixels, so an app that nothing is reading aloud exposes one blank view to
# the system and no words at all — turning semantics on from inside is what gives either system
# something to read.
#
# What each one can take from there differs, because the systems do:
#
#   Android  `adb` reads the running app from outside — the pixels and the view tree both.
#   iOS      nothing outside the app can see in, so the file the probe writes is the answer, and
#            `devicectl` fetches it. Release, because a debug build will not start without Xcode
#            attached, and there is no screenshot on this road at all.
set -eu

BUNDLE=work.amenbo.viewer
OUT=build/device-screen
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
WAIT=${WAIT:-9}

usage() {
  echo "usage: tool/device-screen.sh <android|ios>" >&2
  exit 2
}

[ $# -eq 1 ] || usage
cd "$(dirname "$0")/.."
mkdir -p "$OUT"

case "$1" in
android)
  [ -x "$ADB" ] || { echo "no adb at $ADB (set ADB=...)" >&2; exit 1; }
  flutter build apk --debug -t lib/probe_screen.dart
  "$ADB" install -r build/app/outputs/flutter-apk/app-debug.apk
  "$ADB" shell monkey -p "$BUNDLE" -c android.intent.category.LAUNCHER 1 >/dev/null
  # The first frame is not the answer: what a screen settles into is. A debug build has to warm
  # up before it draws anything at all, so this waits longer than it looks like it should.
  sleep 12
  "$ADB" exec-out screencap -p > "$OUT/android.png"
  "$ADB" shell uiautomator dump /sdcard/window_dump.xml >/dev/null
  "$ADB" pull /sdcard/window_dump.xml "$OUT/android-tree.xml" >/dev/null
  "$ADB" shell rm /sdcard/window_dump.xml
  echo "wrote $OUT/android.png and $OUT/android-tree.xml"
  ;;
ios)
  UDID=${UDID:-$(flutter devices --machine \
    | sed -n 's/.*"id": "\(000[0-9A-Za-z-]*\)".*/\1/p' | head -1)}
  [ -n "$UDID" ] || { echo "no iPhone on the cable (set UDID=...)" >&2; exit 1; }
  flutter build ios -t lib/probe_screen.dart --release
  xcrun devicectl device install app --device "$UDID" build/ios/iphoneos/Runner.app >/dev/null
  xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE" >/dev/null
  # The probe writes every three seconds, so waiting out more than one reading is what makes the
  # file say whether the screen settled. The default is the two that answer the screen it opens
  # on; a longer WAIT is for a walk through the app.
  sleep "$WAIT"
  rm -f "$OUT/ios-tree.txt"
  xcrun devicectl device copy from --device "$UDID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source tmp/screen.txt --destination "$OUT/ios-tree.txt" >/dev/null
  echo "wrote $OUT/ios-tree.txt"
  echo "note: the phone is now holding the probe, not the app — 'make ipa' and reinstall to undo"
  ;;
*)
  usage
  ;;
esac
