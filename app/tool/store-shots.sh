#!/bin/sh
# Take the pictures the two stores put next to the app.
#
#   tool/store-shots.sh ios
#   tool/store-shots.sh android
#
# Both arms end the same way: PNGs under store/screenshots/, at the size the store on that side
# asks for, of the app itself. Nothing is written on top of them and no frame is drawn around
# them, which is why one set in English is the whole set — a picture with no words burned into it
# does not have to be taken again for each language.
#
# Neither arm touches a real phone, and the Android one refuses to: it takes an emulator serial or
# starts an emulator, and a phone on the cable is passed over rather than used. Two reasons, and
# either one is enough. The sizes the stores ask for are not the sizes of the phones here. And this
# installs over the app and empties its copy of the backlog, which is not something to do to
# somebody's phone because it happened to be plugged in.
#
# The way into this app is a QR code through the camera, so a simulator can never be paired and
# would show the guide forever — lib/shot_screen.dart seeds the rows itself, which is what puts
# the backlog on a screen of whatever size a store has a slot for.
#
# Nothing here presses anything: a simulator's pixels belong to this machine, but its glass does
# not. So the app walks its own screens and stops at each one, leaving a file behind to say which
# screen is standing still. This waits for that file, takes the picture, and deletes it — which is
# what lets the next screen come up. Neither side is guessing how long a debug build takes to draw.
set -eu

BUNDLE=work.amenbo.viewer
OUT=store/screenshots
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
# 6.9 inches: 1320x2868, which is the size App Store Connect asks for. The iPhone on the cable
# here is a 12 mini, and 1125x2436 is not a slot either store still has.
SIM=${SIM:-iPhone 17 Pro Max}
# 1080x1920 — 9:16, which is the shape Play states for a phone. A taller emulator would draw a
# nicer picture and is a coin flip at the upload. Make it once, from an image that matches the
# machine (an x86 image will not start on an Apple Silicon Mac, and neither will an x86 emulator):
#
#   avdmanager create avd -n amenbo_shots_api34 -d pixel_5 \
#     -k "system-images;android-34;google_apis;arm64-v8a"
#   # then set hw.lcd.width=1080 hw.lcd.height=1920 hw.lcd.density=420 in its config.ini
AVD=${AVD:-amenbo_shots_api34}
SHOTS='front detail search guide'
# The app gives up on being photographed after three minutes; this gives up first, so a run that
# has gone wrong says so instead of ending with a directory of stale pictures.
PATIENCE=${PATIENCE:-150}

usage() {
  echo "usage: tool/store-shots.sh <android|ios>" >&2
  exit 2
}

[ $# -eq 1 ] || usage
cd "$(dirname "$0")/.."

# Which screen is standing still, or nothing at all. Written by the app, read from outside.
ready_ios() { cat "$CONTAINER/tmp/shot-ready.txt" 2>/dev/null || true; }
ready_android() { emu shell run-as "$BUNDLE" cat cache/shot-ready.txt 2>/dev/null || true; }

# adb, aimed at the emulator and never at whatever else is on the cable.
emu() { "$ADB" -s "$SERIAL" "$@"; }
booted_emulator() {
  "$ADB" devices | sed -n 's/^\(emulator-[0-9][0-9]*\)[	 ][	 ]*device$/\1/p' | head -1
}

# Waits for the app to say $1 is up, photographs it, and lets the app move on.
take() {
  want=$1
  n=$2
  waited=0
  while :; do
    up=$("ready_$PLATFORM" | tr -d '\r\n')
    [ "$up" = "$want" ] && break
    if [ -n "$up" ]; then
      echo "expected $want on the screen, the app says $up" >&2
      exit 1
    fi
    waited=$((waited + 1))
    if [ "$waited" -gt "$((PATIENCE * 4))" ]; then
      echo "waited $PATIENCE s for $want and it never came up" >&2
      exit 1
    fi
    sleep 0.25
  done
  "shoot_$PLATFORM" "$OUT/$PLATFORM/$n-$want.png"
  "clear_$PLATFORM"
  echo "wrote $OUT/$PLATFORM/$n-$want.png"
}

shoot_ios() { xcrun simctl io "$SIM" screenshot --type png "$1" >/dev/null; }
clear_ios() { rm -f "$CONTAINER/tmp/shot-ready.txt"; }

shoot_android() { emu exec-out screencap -p > "$1"; }
clear_android() { emu shell run-as "$BUNDLE" rm cache/shot-ready.txt; }

case "$1" in
ios)
  PLATFORM=ios
  mkdir -p "$OUT/ios"
  xcrun simctl boot "$SIM" 2>/dev/null || true
  xcrun simctl bootstatus "$SIM"
  # A store listing is not the place to show whatever the clock and the battery happened to be.
  xcrun simctl status_bar "$SIM" override \
    --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3
  flutter build ios --simulator --debug -t lib/shot_screen.dart
  xcrun simctl install "$SIM" build/ios/iphonesimulator/Runner.app
  CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
  rm -f "$CONTAINER/tmp/shot-ready.txt"
  xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$SIM" "$BUNDLE" >/dev/null
  ;;
android)
  PLATFORM=android
  mkdir -p "$OUT/android"
  [ -x "$ADB" ] || { echo "no adb at $ADB (set ADB=...)" >&2; exit 1; }
  SERIAL=$(booted_emulator)
  if [ -z "$SERIAL" ]; then
    "$(dirname "$ADB")/../emulator/emulator" -avd "$AVD" -no-boot-anim >/dev/null 2>&1 &
    waited=0
    while [ -z "$SERIAL" ]; do
      sleep 2
      waited=$((waited + 2))
      [ "$waited" -gt 180 ] && { echo "the $AVD emulator never came up" >&2; exit 1; }
      SERIAL=$(booted_emulator)
    done
  fi
  # An emulator answers adb before it has finished starting, and an install into that window fails.
  while [ "$(emu shell getprop sys.boot_completed | tr -d '\r')" != "1" ]; do sleep 2; done
  flutter build apk --debug -t lib/shot_screen.dart
  emu install -r build/app/outputs/flutter-apk/app-debug.apk
  emu shell run-as "$BUNDLE" rm -f cache/shot-ready.txt 2>/dev/null || true
  # The same reason the iOS arm pins its status bar: a store listing is not the place to show what
  # the clock and the battery happened to be, and an emulator draws its own oddities up there.
  emu shell settings put global sysui_demo_allowed 1
  demo() { emu shell am broadcast -a com.android.systemui.demo "$@" >/dev/null; }
  demo -e command enter
  demo -e command clock -e hhmm 0941
  demo -e command battery -e level 100 -e plugged false
  # `fully` is what takes the "no internet" mark off the wifi bars — an emulator has no network,
  # and the app in the picture is not the reason.
  demo -e command network -e wifi show -e level 4 -e fully true
  demo -e command network -e mobile show -e level 4 -e datatype none
  demo -e command notifications -e visible false
  emu shell am force-stop "$BUNDLE"
  # Started by name rather than with `monkey`, which finds nothing to launch on an emulator and
  # exits saying so in a way that reads like the app failing to start.
  ACTIVITY=$(emu shell cmd package resolve-activity --brief \
    -c android.intent.category.LAUNCHER "$BUNDLE" | tail -1 | tr -d '\r')
  [ -n "$ACTIVITY" ] || { echo "$BUNDLE has no launcher activity" >&2; exit 1; }
  emu shell am start -n "$ACTIVITY" >/dev/null
  ;;
*)
  usage
  ;;
esac

n=1
for shot in $SHOTS; do
  take "$shot" "$n"
  n=$((n + 1))
done

echo "the phone is now holding the screenshot build, not the app — reinstall to undo"
