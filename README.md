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
