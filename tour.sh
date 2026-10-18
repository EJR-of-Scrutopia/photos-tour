#!/bin/bash
# The Photos tour: runs on any Mac with Xcode, or on a GitHub-hosted macOS runner (see .github/workflows).
#
#   ./tour.sh                          iPhone 15 Pro on the newest iOS 17 runtime, light then dark
#   DEVICE_TYPE=iPhone-15-Pro-Max ./tour.sh
#   IOS=16 ./tour.sh                   the same on an iOS 16 runtime (iPhone 14 Pro), if one can be installed
#   SKIP_SEED=1 ./tour.sh              re-run without adding the test photos again
#   STEPS_LIGHT=library,views ./tour.sh   only some steps (library views viewer context foryou albums search delete deleted)
#   STEPS_DARK=none ./tour.sh          skip the dark-mode pass
#
# Output: ~/photos-tour-out/<model>-iOS<version>-<light|dark>/ (screenshots, element trees, elements.json,
# tour-log.txt, meta.json), the xcodebuild logs, and ~/photos-tour-out.zip to copy back to the PC.
# Everything it writes is inside this folder, ~/photos-tour-out(.zip), Xcode's DerivedData and the simulator.
# Bash 3.2 (macOS /bin/bash): no arrays, no ${x,,}. No `set -e`: every step reports and carries on or exits itself.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HOME/photos-tour-out"
IOS="${IOS:-17}"
# The iPhone 15 Pro needs iOS 17 or later; the iPhone 14 Pro has the same 393 x 852 point screen.
if [ "$IOS" -ge 17 ] 2>/dev/null; then DEFAULT_DEVICE=iPhone-15-Pro; else DEFAULT_DEVICE=iPhone-14-Pro; fi
DEVICE_TYPE="${DEVICE_TYPE:-$DEFAULT_DEVICE}"
say() { echo "== $*"; }

xcodebuild -version || {
  echo "Xcode is not installed or not set up (sudo xcode-select -s /Applications/Xcode.app; sudo xcodebuild -runFirstLaunch)."
  exit 1; }
case "$(DevToolsSecurity -status 2>/dev/null)" in
  *enabled*) ;;
  *) say "WARNING: developer mode is off; if the tests hang waiting for authorisation, run: sudo DevToolsSecurity -enable" ;;
esac

# `simctl list runtimes` lines read: iOS 17.5 (17.5 - 21F79) - com.apple.CoreSimulator.SimRuntime.iOS-17-5
find_runtime() {
  xcrun simctl list runtimes | grep -E "^iOS ${IOS}\." | grep -v -i unavailable | tail -1 |
    grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+'
}
RUNTIME="$(find_runtime)"
if [ -z "$RUNTIME" ]; then
  say "no iOS ${IOS} simulator runtime yet; asking Xcode to download one (about 7 GB)"
  # -buildVersion takes an OS version on recent Xcodes and a build number on others, so both are tried.
  case "$IOS" in
    17) BUILDS="17.5 21F79 17.4 21E213 17.2 21C62 17.0.1 21A342" ;;
    16) BUILDS="16.4 20E247 16.2 20C52 16.0 20A360" ;;
    *)  BUILDS="${IOS}.5 ${IOS}.4 ${IOS}.2 ${IOS}.0" ;;
  esac
  for build in $BUILDS; do
    say "xcodebuild -downloadPlatform iOS -buildVersion $build"
    xcodebuild -downloadPlatform iOS -buildVersion "$build" && break
  done
  RUNTIME="$(find_runtime)"
fi
[ -n "$RUNTIME" ] || { echo "No iOS ${IOS} runtime could be installed. See README.md, 'No runtime'."; exit 2; }
say "runtime $RUNTIME"

NAME="Tour ${DEVICE_TYPE} iOS ${IOS}"
UDID="$(xcrun simctl list devices | grep -F "$NAME (" | head -1 | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')"
if [ -z "$UDID" ]; then
  UDID="$(xcrun simctl create "$NAME" "com.apple.CoreSimulator.SimDeviceType.${DEVICE_TYPE}" "$RUNTIME")" || {
    echo "Could not create the simulator. Device types available:"; xcrun simctl list devicetypes | grep -i iphone; exit 3; }
fi
say "simulator $NAME $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b || { echo "The simulator did not boot."; exit 3; }
open -a Simulator --args -CurrentDeviceUDID "$UDID" 2>/dev/null || true
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 2>/dev/null || true
xcrun simctl ui "$UDID" appearance light

# iOS 16 and later lock Hidden and Recently Deleted behind Face ID or the passcode. The simulator has no passcode,
# so its lock can neither be opened nor switched off (run 7, 18 October 2026). Enrol the simulator's Face ID
# instead; run_tour answers every Face ID prompt with a match while a pass runs.
xcrun simctl spawn "$UDID" notifyutil -s com.apple.BiometricKit.enrollmentChanged '1'
xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit.enrollmentChanged
say "Face ID enrolment state: $(xcrun simctl spawn "$UDID" notifyutil -g com.apple.BiometricKit.enrollmentChanged 2>&1)"

if [ "${SKIP_SEED:-0}" != "1" ]; then
  say "making the test photos"
  mkdir -p "$HERE/.tools"
  # Compiled rather than interpreted where possible: faster, and clear of the interpreter's JIT quirks. Swift 5
  # mode pinned: the script's mutable top-level globals are errors in Swift 6 mode.
  if xcrun swiftc -swift-version 5 -O -o "$HERE/.tools/seed" "$HERE/seed.swift"; then
    "$HERE/.tools/seed" "$HERE/seed" 30 || { echo "seed failed"; exit 4; }
  else
    swift -swift-version 5 "$HERE/seed.swift" "$HERE/seed" 30 || { echo "seed.swift failed"; exit 4; }
  fi
  xcrun simctl addmedia "$UDID" "$HERE"/seed/*.JPG "$HERE"/seed/*.PNG || echo "addmedia of the photos failed (see above)"
  say "recording three short videos of the simulator screen"
  # simctl itself, not xcrun, gets the SIGINT that ends a recording.
  SIMCTL="$(xcrun -f simctl)"
  for i in 1 2 3; do
    "$SIMCTL" io "$UDID" recordVideo --codec=h264 --force "$HERE/seed/clip$i.mp4" &
    PID=$!
    sleep 2
    # Something must change on screen during the recording, or the clip is one frame long.
    xcrun simctl ui "$UDID" appearance dark; sleep 1
    xcrun simctl ui "$UDID" appearance light; sleep 1
    kill -INT "$PID" 2>/dev/null
    # Never wait for ever: if the recorder ignores SIGINT (a script's background jobs start with it ignored, so
    # this relies on simctl handling it itself), terminate it after ten seconds; that clip may then be unusable.
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
    if kill -0 "$PID" 2>/dev/null; then
      echo "recordVideo did not stop on SIGINT; terminating it"
      kill -TERM "$PID" 2>/dev/null; sleep 2; kill -KILL "$PID" 2>/dev/null
    fi
    wait "$PID" 2>/dev/null
  done
  ls "$HERE"/seed/clip*.mp4 >/dev/null 2>&1 && xcrun simctl addmedia "$UDID" "$HERE"/seed/clip*.mp4 ||
    echo "no videos added (see above)"
  say "opening Photos once so it indexes the library"
  xcrun simctl launch "$UDID" com.apple.mobileslideshow >/dev/null
  sleep 25
  xcrun simctl terminate "$UDID" com.apple.mobileslideshow 2>/dev/null || true
fi

XCODEGEN="$(command -v xcodegen || true)"
if [ -z "$XCODEGEN" ]; then
  # The release zip holds xcodegen/bin/xcodegen beside xcodegen/share/xcodegen (its setting presets).
  XCODEGEN="$HERE/.tools/xcodegen/bin/xcodegen"
  if [ ! -x "$XCODEGEN" ]; then
    say "fetching XcodeGen"
    mkdir -p "$HERE/.tools"
    curl -fsSL -o "$HERE/.tools/xcodegen.zip" https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip &&
      unzip -oq "$HERE/.tools/xcodegen.zip" -d "$HERE/.tools" || { echo "Could not fetch XcodeGen"; exit 5; }
    [ -x "$XCODEGEN" ] || XCODEGEN="$(find "$HERE/.tools" -type f -name xcodegen -perm -u+x | head -1)"
  fi
fi
[ -n "$XCODEGEN" ] && [ -x "$XCODEGEN" ] || { echo "No xcodegen binary in $HERE/.tools (see the zip's layout)"; exit 5; }
say "XcodeGen $("$XCODEGEN" --version 2>&1 | tail -1)"
(cd "$HERE" && "$XCODEGEN" generate) || { echo "XcodeGen failed"; exit 6; }

mkdir -p "$OUT"

# Where Photos keeps its album-lock setting: no documented key exists (October 2026), so record every name with
# "ContentPrivacy" in it (the Settings switch is PhotosContentPrivacySwitch) and the Photos preferences around the
# light pass, whose unlock step flips the switch.
probe_defaults() {  # $1 label
  xcrun simctl spawn "$UDID" defaults read com.apple.mobileslideshow > "$OUT/defaults-mobileslideshow-$1.txt" 2>&1
  grep -ril "ContentPrivacy" "$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/Preferences" \
    "$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Containers" > "$OUT/privacy-files-$1.txt" 2>/dev/null
}
ROOT="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
print(next((r.get("runtimeRoot", "") for r in json.load(sys.stdin)["runtimes"] if r["identifier"] == sys.argv[1]), ""))
' "$RUNTIME")"
{
  echo "runtime root: $ROOT"
  grep -r -a -o -h -E "[A-Za-z_.]*ContentPrivacy[A-Za-z_.]*" "$ROOT"/System/Library/PrivateFrameworks/*Photo* \
    "$ROOT"/System/Library/Frameworks/Photos* "$ROOT"/System/Library/PreferenceBundles \
    "$ROOT"/Applications/MobileSlideShow.app "$ROOT"/Applications/Preferences.app 2>/dev/null | sort | uniq -c | sort -rn | head -80
} > "$OUT/lock-probe.txt"
# Run 9 found the name, ContentPrivacyEnabled, but not its preferences domain: the strings stored beside it in
# the binary that holds it usually include the domain.
grep -r -l -a "ContentPrivacyEnabled" "$ROOT"/System/Library/PrivateFrameworks/*Photo* \
  "$ROOT"/System/Library/Frameworks/Photos* "$ROOT"/System/Library/PreferenceBundles \
  "$ROOT"/Applications/MobileSlideShow.app "$ROOT"/Applications/Preferences.app 2>/dev/null | while read -r f; do
  echo "-- $f"
  strings -a "$f" | grep -n -B12 -A12 -E "^_?ContentPrivacyEnabled$" | head -60
done >> "$OUT/lock-probe.txt"
say "lock probe: $(wc -l < "$OUT/lock-probe.txt" | tr -d ' ') lines"
probe_defaults before
# Even with Face ID enrolled, a tap on a locked album does nothing on the simulator (runs 8 and 9), so the lock is
# set off in the domains it most likely lives in. Settings > Photos then shows the switch off if one was right.
for domain in com.apple.mobileslideshow com.apple.Photos com.apple.photos.shareddefaults; do
  xcrun simctl spawn "$UDID" defaults write "$domain" ContentPrivacyEnabled -bool NO
done

xcodebuild_test() {  # $1 light|dark, $2 steps, $3 log file, then extra build settings
  local appearance="$1" steps="$2" log="$3"
  shift 3
  rm -rf "$HERE/results-$appearance.xcresult"
  # TEST_RUNNER_X reaches the test runner as X. Parallel testing is off: it would run on clones of the
  # simulator, which have none of the seeded photos.
  TEST_RUNNER_TOUR_APPEARANCE="$appearance" TEST_RUNNER_TOUR_STEPS="$steps" TEST_RUNNER_TOUR_OUT="$OUT" \
    xcodebuild test -project "$HERE/PhotosTour.xcodeproj" -scheme Tour -destination "id=$UDID" \
    -parallel-testing-enabled NO -resultBundlePath "$HERE/results-$appearance.xcresult" "$@" > "$log" 2>&1
}
run_tour() {  # $1 light|dark, $2 steps ("none" skips the pass)
  [ "$2" = "none" ] && return 0
  say "tour in $1 mode: $2"
  xcrun simctl ui "$UDID" appearance "$1"
  sleep 2
  local log="$OUT/xcodebuild-$1-${DEVICE_TYPE}-iOS${IOS}.log"
  local stamp="$OUT/.started-$1"
  touch "$stamp"
  # A match with no Face ID prompt showing does nothing, so the loop runs for the whole pass.
  ( while :; do
      xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit_Sim.pearl.match >/dev/null 2>&1
      sleep 1
    done ) &
  local faceid=$!
  # Photos' own log, for whatever it says when a tap on Recently Deleted does nothing (run 10).
  xcrun simctl spawn "$UDID" log stream --style compact --predicate 'process == "MobileSlideShow"' \
    > "$OUT/photos-log-$1.txt" 2>&1 &
  local photoslog=$!
  xcodebuild_test "$1" "$2" "$log" CODE_SIGNING_ALLOWED=NO
  local status=$?
  # The tour writes tour-log.txt from its first line, so none newer than the stamp means it never started.
  local tourlog
  tourlog="$(find "$OUT" -name tour-log.txt -newer "$stamp" | head -1)"
  if [ -z "$tourlog" ] && grep -qiE "code ?sign|signature" "$log"; then
    say "the tour never started and the log mentions signing; retrying with ad-hoc signing"
    mv "$log" "$log.unsigned"
    xcodebuild_test "$1" "$2" "$log" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
    status=$?
    tourlog="$(find "$OUT" -name tour-log.txt -newer "$stamp" | head -1)"
  fi
  kill "$faceid" "$photoslog" 2>/dev/null
  wait "$faceid" "$photoslog" 2>/dev/null
  say "xcodebuild exit status $status (65 is expected: XCUITest records a failure for each control it could not use)"
  grep -E "error:|\*\* TEST|Testing failed|Test session results" "$log" | head -20
  if [ -n "$tourlog" ]; then
    say "tour log $tourlog"
    grep -E "== step|NOT FOUND|menu:|zoom levels|grid items|activating|tour finished" "$tourlog" | head -120
  else
    say "the tour did not start; the end of $log:"
    tail -40 "$log"
  fi
}
run_tour light "${STEPS_LIGHT:-all}"
probe_defaults after-light
run_tour dark "${STEPS_DARK:-library,views,viewer,foryou,albums,search}"
xcrun simctl ui "$UDID" appearance light

(cd "$HOME" && rm -f photos-tour-out.zip && zip -qr photos-tour-out.zip photos-tour-out)
say "done: $(find "$OUT" -name '*.png' | wc -l | tr -d ' ') screenshots in $OUT, zipped to $HOME/photos-tour-out.zip"
