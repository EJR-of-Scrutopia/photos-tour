#!/bin/bash
# The Mac Photos tour: runs on a GitHub-hosted macos-14 runner (see .github/workflows/mac-photos-tour.yml) or on any
# Mac with Xcode and a logged-in desktop session.
#
#   ./mac/mac-tour.sh
#   STEPS_LIGHT=library,sidebar ./mac/mac-tour.sh   only some steps (library sidebar viewer select albums search delete deleted settings)
#   STEPS_DARK=none ./mac/mac-tour.sh               skip the dark pass
#   SKIP_SEED=1 ./mac/mac-tour.sh                   reuse the photos already made in ~/mac-photos-seed
#   WIN_W=1440 WIN_H=900                            wanted window size in points (clamped to the screen by the test)
#
# Order: seed photos, build the UI tests once, open Photos with the files (import strategy a), a UI-test pass that
# clicks the import UI and falls back to File > Import (b), an AppleScript import if the count is still short (c),
# then a light pass and a dark pass. Output: ~/mac-photos-tour-out/ (screenshots, element trees, elements.json,
# tour-log.txt, meta.json, xcodebuild logs, defaults dumps, heartbeat screenshots) and ~/mac-photos-tour-out.zip.
# Bash 3.2 (macOS /bin/bash): no arrays, no ${x,,}. No `set -e`: every step reports and carries on or exits itself.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HOME/mac-photos-tour-out"
SEED="$HOME/mac-photos-seed"
DERIVED="$HERE/derived"
WIN_W="${WIN_W:-1440}"
WIN_H="${WIN_H:-900}"
ARCH="$(uname -m)"
START="$(date +%s)"
# The workflow gives the job 40 minutes; passes are skipped or shortened to leave time for the zip and upload.
BUDGET="${TOUR_BUDGET_SECONDS:-2220}"
SIGN="none"
mkdir -p "$OUT/heartbeat"
exec > >(tee -a "$OUT/mac-tour-script.log") 2>&1

say() { echo "== $*"; }
time_left() { echo $(( BUDGET - ( $(date +%s) - START ) )); }

# Runs a command with a time limit (macOS has no `timeout`). The caller redirects the output to a file, never into
# $(...), so a straggling child cannot hold a pipe open.
run_to() {  # $1 seconds, then the command
  local secs="$1"
  shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watcher=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  pkill -P "$watcher" 2>/dev/null
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return $rc
}

kill_photos() {
  pkill -x Photos 2>/dev/null
  sleep 2
  pkill -9 -x Photos 2>/dev/null
  return 0
}

say "$(sw_vers -productName) $(sw_vers -productVersion) $ARCH, $(date)"
xcodebuild -version || {
  echo "Xcode is not installed or not selected (sudo xcode-select -s /Applications/Xcode_15.4.app)."
  exit 1; }

# ---- the machine: display, permissions -----------------------------------------------------------------------------
say "display"
run_to 60 system_profiler SPDisplaysDataType > "$OUT/display.txt" 2>&1
grep -iE "resolution|display type|main display|retina" "$OUT/display.txt" | head -8
run_to 20 screencapture -x "$OUT/screen-at-start.png" 2>&1
[ -s "$OUT/screen-at-start.png" ] && say "screencapture works" || say "WARNING: screencapture produced nothing; Screen Recording permission is probably missing (XCUIScreen screenshots would then be empty)"
say "developer mode and UI automation"
case "$(DevToolsSecurity -status 2>/dev/null)" in
  *enabled*) ;;
  *) say "developer mode is off; enabling"; sudo -n DevToolsSecurity -enable 2>&1 | head -3 ;;
esac
# Lets UI tests run without the authorisation dialog a human would click.
sudo -n automationmodetool enable-automationmode-without-authentication 2>&1 | head -3
automationmodetool 2>&1 | head -3
# Stop the screen sleeping or locking under the tour.
caffeinate -d -i -u -t 3000 >/dev/null 2>&1 &
# Best effort: pre-grant Accessibility and Screen Recording to the processes that need them. Fails quietly where SIP or
# a missing sudo forbids it; the pass logs then say whether it mattered ("not authorized", "automation mode").
grant_tcc() {
  local ts
  ts="$(date +%s)"
  local db
  for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
    [ -f "$db" ] || { echo "no $db"; continue; }
    local entry
    for entry in "kTCCServiceAccessibility|com.apple.dt.Xcode|0" "kTCCServiceAccessibility|local.macphotostour.uitests.xctrunner|0" \
                 "kTCCServiceAccessibility|/usr/bin/osascript|1" "kTCCServiceAccessibility|/bin/bash|1" \
                 "kTCCServiceScreenCapture|com.apple.dt.Xcode|0" "kTCCServiceScreenCapture|local.macphotostour.uitests.xctrunner|0" \
                 "kTCCServiceScreenCapture|/usr/bin/screencapture|1"; do
      local svc="${entry%%|*}"
      local rest="${entry#*|}"
      local client="${rest%%|*}"
      local ctype="${rest##*|}"
      local sql="INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags, last_modified) VALUES ('$svc','$client',$ctype,2,4,1,'UNUSED',0,$ts);"
      if sudo -n sqlite3 "$db" "$sql" 2>&1 || sqlite3 "$db" "$sql" 2>&1; then echo "granted $svc $client in $db"; fi
    done
  done
}
run_to 60 grant_tcc > "$OUT/tcc-grant.txt" 2>&1
say "TCC grant attempt: $(grep -c '^granted' "$OUT/tcc-grant.txt") rows written (see tcc-grant.txt)"

# ---- the photos ----------------------------------------------------------------------------------------------------
mkdir -p "$HERE/.tools"
if [ "${SKIP_SEED:-0}" != "1" ] || [ ! -d "$SEED" ]; then
  say "making the test photos in $SEED"
  rm -rf "$SEED"
  if xcrun swiftc -swift-version 5 -O -o "$HERE/.tools/seed" "$HERE/../seed.swift"; then
    "$HERE/.tools/seed" "$SEED" 30 || { echo "seed failed"; exit 4; }
  else
    swift -swift-version 5 "$HERE/../seed.swift" "$SEED" 30 || { echo "seed.swift failed"; exit 4; }
  fi
  if xcrun swiftc -swift-version 5 -O -o "$HERE/.tools/mkvideo" "$HERE/mkvideo.swift"; then
    run_to 120 "$HERE/.tools/mkvideo" "$SEED" 3 || echo "mkvideo failed or timed out; importing without videos"
  else
    echo "mkvideo.swift did not compile; importing without videos"
  fi
fi
EXPECTED_PHOTOS="$(ls "$SEED" 2>/dev/null | grep -ciE '\.(jpg|png)$')"
EXPECTED_VIDEOS="$(ls "$SEED" 2>/dev/null | grep -ciE '\.mp4$')"
say "$EXPECTED_PHOTOS images and $EXPECTED_VIDEOS videos to import"

# ---- the Xcode project ---------------------------------------------------------------------------------------------
XCODEGEN="$(command -v xcodegen || true)"
if [ -z "$XCODEGEN" ]; then
  XCODEGEN="$HERE/.tools/xcodegen/bin/xcodegen"
  if [ ! -x "$XCODEGEN" ]; then
    say "fetching XcodeGen"
    curl -fsSL -o "$HERE/.tools/xcodegen.zip" https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip &&
      unzip -oq "$HERE/.tools/xcodegen.zip" -d "$HERE/.tools" || { echo "Could not fetch XcodeGen"; exit 5; }
    [ -x "$XCODEGEN" ] || XCODEGEN="$(find "$HERE/.tools" -type f -name xcodegen -perm -u+x | head -1)"
  fi
fi
[ -n "$XCODEGEN" ] && [ -x "$XCODEGEN" ] || { echo "No xcodegen binary in $HERE/.tools"; exit 5; }
say "XcodeGen $("$XCODEGEN" --version 2>&1 | tail -1)"
(cd "$HERE" && "$XCODEGEN" generate) || { echo "XcodeGen failed"; exit 6; }

build_tests() {  # builds the host and the UI-test bundle once; the passes then run test-without-building
  local log="$OUT/xcodebuild-build-$SIGN.log"
  if [ "$SIGN" = "adhoc" ]; then
    run_to 600 xcodebuild build-for-testing -project "$HERE/MacPhotosTour.xcodeproj" -scheme MacTour \
      -destination "platform=macOS,arch=$ARCH" -derivedDataPath "$DERIVED" \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= > "$log" 2>&1
  else
    run_to 600 xcodebuild build-for-testing -project "$HERE/MacPhotosTour.xcodeproj" -scheme MacTour \
      -destination "platform=macOS,arch=$ARCH" -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO > "$log" 2>&1
  fi
  local rc=$?
  grep -E "error:|BUILD|TEST BUILD" "$log" | head -20
  return $rc
}
say "building the UI tests (unsigned)"
if ! build_tests; then
  say "unsigned build failed; retrying with an ad-hoc signature"
  SIGN="adhoc"
  build_tests || { echo "The UI tests did not build. See xcodebuild-build-*.log."; exit 7; }
fi

# ---- one UI-test pass ----------------------------------------------------------------------------------------------
HEARTBEAT=""
heartbeat_start() {  # a screenshot every 30 s, so a hang or an unexpected dialog can be seen afterwards
  ( n=0; while :; do n=$((n+1)); screencapture -x -t jpg "$OUT/heartbeat/$1-$(printf %03d $n).jpg" 2>/dev/null; sleep 30; done ) >/dev/null 2>&1 &
  HEARTBEAT=$!
}
heartbeat_stop() {
  [ -n "$HEARTBEAT" ] || return 0
  pkill -P "$HEARTBEAT" 2>/dev/null
  kill "$HEARTBEAT" 2>/dev/null
  wait "$HEARTBEAT" 2>/dev/null
  HEARTBEAT=""
}

xb_test() {  # $1 mode, $2 steps, $3 appearance, $4 seconds, $5 log
  rm -rf "$HERE/results-$1-$3.xcresult"
  run_to "$4" env TEST_RUNNER_MAC_TOUR_MODE="$1" TEST_RUNNER_MAC_TOUR_STEPS="$2" TEST_RUNNER_TOUR_APPEARANCE="$3" \
    TEST_RUNNER_TOUR_OUT="$OUT" TEST_RUNNER_MAC_SEED_DIR="$SEED" TEST_RUNNER_MAC_EXPECTED_PHOTOS="$EXPECTED_PHOTOS" \
    TEST_RUNNER_MAC_WIN_W="$WIN_W" TEST_RUNNER_MAC_WIN_H="$WIN_H" \
    xcodebuild test-without-building -project "$HERE/MacPhotosTour.xcodeproj" -scheme MacTour \
    -destination "platform=macOS,arch=$ARCH" -derivedDataPath "$DERIVED" -parallel-testing-enabled NO \
    -resultBundlePath "$HERE/results-$1-$3.xcresult" > "$5" 2>&1
}

run_pass() {  # $1 mode (import|wait|tour), $2 steps, $3 appearance, $4 max seconds, $5 log name
  local mode="$1" steps="$2" appearance="$3" tmo="$4" log="$OUT/$5"
  local left
  left="$(time_left)"
  if [ "$left" -lt 150 ]; then say "skipping the $mode pass: only ${left}s of the budget left"; return 1; fi
  [ "$tmo" -gt $(( left - 90 )) ] && tmo=$(( left - 90 ))
  say "pass $mode ($appearance): $steps, up to ${tmo}s, signing $SIGN"
  local stamp="$OUT/.started-$mode-$appearance"
  touch "$stamp"
  heartbeat_start "$mode-$appearance"
  log stream --style compact --predicate 'process == "Photos"' > "$OUT/photos-log-$mode-$appearance.txt" 2>&1 &
  local photoslog=$!
  xb_test "$mode" "$steps" "$appearance" "$tmo" "$log"
  local status=$?
  local tourlog
  tourlog="$(find "$OUT" -name tour-log.txt -newer "$stamp" 2>/dev/null | head -1)"
  if [ -z "$tourlog" ] && [ "$SIGN" = "none" ]; then
    say "the tour never started with the unsigned runner; rebuilding with an ad-hoc signature and retrying"
    mv "$log" "$log.unsigned" 2>/dev/null
    SIGN="adhoc"
    build_tests && {
      touch "$stamp"
      xb_test "$mode" "$steps" "$appearance" "$tmo" "$log"
      status=$?
      tourlog="$(find "$OUT" -name tour-log.txt -newer "$stamp" 2>/dev/null | head -1)"
    }
  fi
  heartbeat_stop
  kill "$photoslog" 2>/dev/null
  wait "$photoslog" 2>/dev/null
  pkill -f "MacTourUITests-Runner" 2>/dev/null
  say "xcodebuild exit status $status (124/143 = timed out or killed; 65 is normal: XCUITest records a failure for each control it could not use)"
  grep -E "error:|\*\* TEST|Testing failed|Test session results" "$log" | head -15
  if grep -qiE "automation mode|not authorized|Failed to initialize for UI testing|accessibility|Timed out while loading Accessibility" "$log"; then
    say "HINT: the log mentions automation or accessibility; the runner may lack Accessibility permission. Lines:"
    grep -iE "automation mode|not authorized|Failed to initialize|accessibility" "$log" | head -6
  fi
  if [ -n "$tourlog" ]; then
    say "tour log $tourlog"
    grep -E "== step|NOT FOUND|APPEARANCE|import|menu:|viewer open|window is|after dragging|snapshot failed|LOCKED|sidebar rows|no sheet|tour finished" "$tourlog" | head -150
    return 0
  fi
  say "the tour did not start; the end of $log:"
  tail -40 "$log"
  return 1
}

import_value() {  # $1 key, $2 folder (import or wait); reads <folder>/import-result.txt
  sed -n "s/^$1=//p" "$OUT/${2:-import}/import-result.txt" 2>/dev/null | tail -1
}

set_appearance() {  # $1 light|dark: the global default Photos reads at launch (System Events would need an Automation prompt)
  if [ "$1" = "dark" ]; then
    defaults write -g AppleInterfaceStyle Dark
  else
    defaults delete -g AppleInterfaceStyle 2>/dev/null
  fi
  defaults write -g AppleInterfaceStyleSwitchesAutomatically -bool false
  # Mac run 2: the default alone left Photos light. Post the change as System Settings does, and also ask System
  # Events (an Automation prompt cannot hang it: run_to stops it after 15 s).
  if [ -x "$HERE/.tools/theme-notify" ] || xcrun swiftc -swift-version 5 -O -o "$HERE/.tools/theme-notify" "$HERE/theme-notify.swift"; then
    "$HERE/.tools/theme-notify" && say "posted AppleInterfaceThemeChangedNotification"
  fi
  local dark=false
  [ "$1" = "dark" ] && dark=true
  run_to 15 osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $dark" \
    > "$OUT/appearance-osascript-$1.txt" 2>&1
  say "System Events dark mode $dark: exit $? ($(head -c 120 "$OUT/appearance-osascript-$1.txt"))"
  say "appearance $1: AppleInterfaceStyle is '$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo unset)' (unset means light)"
}

# The album lock: iOS keeps it in ContentPrivacyEnabled; the macOS domain is not documented, so it is written to the
# likely ones and the domain dumps before and after tell us which key Photos really reads.
probe_defaults() {  # $1 label
  defaults read com.apple.Photos > "$OUT/defaults-com.apple.Photos-$1.txt" 2>&1
  defaults read com.apple.photolibraryd > "$OUT/defaults-com.apple.photolibraryd-$1.txt" 2>&1
  defaults read com.apple.photos.shareddefaults > "$OUT/defaults-com.apple.photos.shareddefaults-$1.txt" 2>&1
  defaults domains | tr ',' '\n' | grep -i -E "photo" > "$OUT/defaults-domains-$1.txt" 2>&1
  grep -ril "ContentPrivacy" "$HOME/Library/Preferences" "$HOME/Library/Containers/com.apple.Photos" > "$OUT/privacy-files-$1.txt" 2>/dev/null
  say "defaults ($1): $(wc -l < "$OUT/defaults-com.apple.Photos-$1.txt" | tr -d ' ') lines in com.apple.Photos; ContentPrivacy files: $(wc -l < "$OUT/privacy-files-$1.txt" | tr -d ' ')"
}
probe_defaults before
for domain in com.apple.Photos com.apple.photolibraryd com.apple.photos.shareddefaults; do
  defaults write "$domain" ContentPrivacyEnabled -bool NO
done

# ---- import --------------------------------------------------------------------------------------------------------
set_appearance light
kill_photos
say "import strategy a: open -a Photos with the files"
FILES_LIST="$OUT/seed-files.txt"
find "$SEED" -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.mp4' \) | sort > "$FILES_LIST"
# xargs keeps the argument list inside the system limit however many files there are.
cat "$FILES_LIST" | tr '\n' '\0' | xargs -0 open -a Photos > "$OUT/open-a-photos.txt" 2>&1
say "open exit: $? ($(head -c 200 "$OUT/open-a-photos.txt"))"
sleep 8
run_pass import all light 780 xcodebuild-import.log
COUNT="$(import_value count)"
say "import result: method '$(import_value method)', clicked '$(import_value clicked)', count '${COUNT:-?}' of $EXPECTED_PHOTOS"
case "${COUNT:-}" in ''|*[!0-9]*) COUNT=0 ;; esac
if [ "$COUNT" -lt $(( EXPECTED_PHOTOS / 2 )) ] && [ "$(time_left)" -gt 600 ]; then
  say "import strategy c: AppleScript import (60 s limit; a permission prompt cannot hang it)"
  # run_to is a shell function, which xargs cannot run, so the pipeline goes inside a small sh.
  run_to 90 sh -c 'tr "\n" "\0" < "$1" | xargs -0 osascript "$2"' sh "$FILES_LIST" "$HERE/import.applescript" > "$OUT/applescript-import.txt" 2>&1
  say "osascript: $(head -c 300 "$OUT/applescript-import.txt")"
  run_pass wait all light 240 xcodebuild-import-wait.log
  COUNT="$(import_value count wait)"
  say "after strategy c: count '${COUNT:-?}' of $EXPECTED_PHOTOS"
fi

# ---- the tours -----------------------------------------------------------------------------------------------------
tour_pass() {  # $1 light|dark, $2 steps ("none" skips the pass), $3 seconds
  [ "$2" = "none" ] && return 0
  set_appearance "$1"
  kill_photos
  for domain in com.apple.Photos com.apple.photolibraryd com.apple.photos.shareddefaults; do
    defaults write "$domain" ContentPrivacyEnabled -bool NO
  done
  run_pass tour "$2" "$1" "$3" "xcodebuild-$1.log"
  local meta
  meta="$(find "$OUT" -path "*-$1/meta.json" 2>/dev/null | head -1)"
  [ -n "$meta" ] && say "recorded in $meta: $(grep -E 'sampledAppearance|windowPointsW|windowPointsH|screenPointsW|screenPointsH|backingScaleFactor' "$meta" | tr -d ' \n')"
  run_to 20 screencapture -x "$OUT/screen-after-$1.png" 2>&1
}
tour_pass light "${STEPS_LIGHT:-all}" 840
probe_defaults after-light
tour_pass dark "${STEPS_DARK:-library,sidebar,viewer,albums,search,deleted}" 600
probe_defaults after-dark

# Leave the machine as found, and keep the output small enough to upload.
defaults delete -g AppleInterfaceStyle 2>/dev/null
kill_photos
rm -f "$OUT"/.started-*
(cd "$HOME" && rm -f mac-photos-tour-out.zip && zip -qr mac-photos-tour-out.zip mac-photos-tour-out)
say "done: $(find "$OUT" -name '*.png' | wc -l | tr -d ' ') screenshots in $OUT, zipped to $HOME/mac-photos-tour-out.zip"
sleep 1
