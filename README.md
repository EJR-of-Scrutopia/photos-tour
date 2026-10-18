# Photos tour

An automated walk through Apple's Photos app on an iOS 17 simulator, to measure the iOS 16/17 interface
precisely. For every screen it saves a screenshot, the accessibility tree, and each element's type, label and
frame in points (`*.elements.json`), so grid gaps, columns and bar sizes come out as numbers.

It runs on a GitHub-hosted macOS 14 runner (Xcode 15.4, iOS 17.x simulators): **Actions > Photos tour > Run
workflow**. The results are uploaded as the `photos-tour-out` artifact.

## Files

- `seed.swift`: about 300 dated, located test images (2022 to 2025, four places, near-duplicate bursts,
  screenshots), drawn with CoreGraphics; no real photos.
- `project.yml`: XcodeGen spec for a do-nothing host app and the UI-testing bundle. `tour.sh` fetches XcodeGen.
- `TourUITests/PhotosTour.swift`: the tour. Labels are guesses for iOS 17 English; `tour-log.txt` lists every
  `NOT FOUND`, so a wrong label is fixed and that step re-run (workflow inputs `steps_light`, `steps_dark`).
- `tour.sh`: creates and boots the simulator, adds the test media, generates the project, runs the tour in
  light then dark mode, and writes `~/photos-tour-out`. Also runs on any Mac with Xcode: `./tour.sh`.

Exit status 65 from `xcodebuild` is expected: XCUITest records a failure for each control the tour could not use.

## Mac tour

The same measurement for the macOS 14 Photos app (`com.apple.Photos`), driven by a macOS XCUITest bundle on a
GitHub-hosted `macos-14` runner. `mac/mac-tour.sh` makes the test photos (`seed.swift` plus three short clips), opens
Photos with them and imports them (three fallbacks: `open -a Photos` then the Import buttons, File > Import with the
open panel, an AppleScript import), then runs a light pass and a dark pass. Per screen it saves the full screenshot, the
Photos window cropped out, the element tree, and `*.elements.json` (type, label, identifier, value, frame in points
with window-relative `wx`/`wy`, selected, enabled). `meta.json` records the screen size, scale factor, window size and
the appearance actually sampled from the pixels. `tour-log.txt` lists every `NOT FOUND`.

Steps (`steps_light`, `steps_dark`): `library sidebar viewer select albums search delete deleted settings`.

Trigger it, then download the artifact:

```
gh workflow run mac-photos-tour.yml -R EJR-of-Scrutopia/photos-tour
gh run list -R EJR-of-Scrutopia/photos-tour -w "Mac Photos tour" -L 1
gh run download <id> -R EJR-of-Scrutopia/photos-tour -n mac-photos-tour-out -D <dir>
```

Files: `mac/project.yml` (XcodeGen spec), `mac/MacTourHost/` (empty host app), `mac/MacTourUITests/MacPhotosTour.swift`
(the tour), `mac/mac-tour.sh`, `mac/import.applescript`, `mac/mkvideo.swift`. The runner needs Accessibility and Screen
Recording permission for the test runner; the script tries to pre-grant them and logs `tcc-grant.txt`. Beside the
screens, the artifact holds `heartbeat/` (a screenshot every 30 s), `photos-log-*.txt`, `defaults-*` dumps (to learn which
preference holds the Hidden / Recently Deleted lock) and the xcodebuild logs.
