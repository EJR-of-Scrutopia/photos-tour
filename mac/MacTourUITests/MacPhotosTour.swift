import AppKit
import XCTest

/// Walks Apple's Photos app on macOS 14 (com.apple.Photos) through every screen we need to recreate. For each
/// screen it saves a full-screen screenshot, the Photos window cropped out of it, the element tree as text, and
/// every element's type, label and frame (points, global screen coordinates, plus window-relative wx/wy) as JSON,
/// into <TOUR_OUT>/<macOS14-light|macOS14-dark|import|wait>/.
///
/// Nothing is asserted. A control the tour cannot find is logged ("NOT FOUND") and the tour moves on, so one wrong
/// label never costs the rest of the run. Environment (TEST_RUNNER_ prefixed variables set by mac-tour.sh):
///   MAC_TOUR_MODE     import (click Photos' import UI, then wait), wait (only wait for an import), tour
///   MAC_TOUR_STEPS    comma list of steps, or "all"
///   TOUR_APPEARANCE   light or dark (names the output folder; mac-tour.sh switches the system appearance)
///   TOUR_OUT          output root
///   MAC_SEED_DIR, MAC_EXPECTED_PHOTOS   the folder of test photos and how many images it holds
///   MAC_WIN_W, MAC_WIN_H                wanted window size in points (default 1440 x 900, clamped to the screen)
///
/// Design: unlike the iOS tour, controls are found in ONE snapshot of the whole app (flattened into `Node`s) and
/// clicked by coordinate. Photos' macOS accessibility types are guesses (sidebar rows may be outline rows, cells
/// or plain texts), and a type-agnostic search by label avoids guessing them. The log says which type matched.
///
/// Language mode: Swift 5 (project.yml), so Xcode's @MainActor annotations on XCUI types are not errors.
final class MacPhotosTour: XCTestCase {
    let photos = XCUIApplication(bundleIdentifier: "com.apple.Photos")
    var outDir = URL(fileURLWithPath: NSTemporaryDirectory())
    var log: [String] = []
    var started = Date()
    var mode = "tour"
    var appearance = "light"
    var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// One accessibility element, flattened out of the snapshot tree.
    struct Node {
        var type: XCUIElement.ElementType
        var label: String
        var title: String
        var identifier: String
        var value: String
        var frame: CGRect
        var enabled: Bool
        var selected: Bool
        var depth: Int
        var inSelected: Bool   // this node or an ancestor reports isSelected (a sidebar row's text sits inside its row)
        var inDialog: Bool     // below a sheet, dialog, alert or popover
    }

    enum Region { case any, toolbar, sidebar, content, dialog }

    override func setUpWithError() throws {
        continueAfterFailure = true
        started = Date()
        mode = environment["MAC_TOUR_MODE"] ?? "tour"
        appearance = environment["TOUR_APPEARANCE"] ?? "light"
        let root: URL
        if let given = environment["TOUR_OUT"], !given.isEmpty {
            root = URL(fileURLWithPath: given)
        } else {
            root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("mac-photos-tour-out")
        }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let name = mode == "tour" ? "macOS\(major)-\(appearance)" : mode
        outDir = root.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            // Never end the tour over a folder: fall back to the runner's temporary folder (it is still logged).
            outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            note("could not create \(root.path)/\(name): \(error); using \(outDir.path)")
        }
        note("output folder \(outDir.path)")
    }

    // MARK: the tour

    func testRun() {
        note("mode \(mode), appearance \(appearance), \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if mode == "import" || mode == "wait" {
            runImport(waitOnly: mode == "wait")
        } else {
            runTour()
        }
        note("== tour finished")
    }

    func runTour() {
        let wanted = Set((environment["MAC_TOUR_STEPS"] ?? "all")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })

        func step(_ name: String, _ body: () -> Void) {
            guard wanted.contains("all") || wanted.contains(name) else { return }
            note("== step \(name)")
            ensureRunning()
            leaveViewerAndMenus()
            XCTContext.runActivity(named: name) { _ in body() }
        }

        // A fresh launch, so the pass reads the appearance and lock preferences mac-tour.sh just wrote.
        if photos.state != .notRunning { photos.terminate(); pause(2) }
        photos.launch()
        _ = photos.windows.firstMatch.waitForExistence(timeout: 40)
        pause(3)
        dismissOnboarding()
        setWindowSize()
        writeMeta()
        step("library") { stepLibrary() }
        step("sidebar") { stepSidebar() }
        step("viewer") { stepViewer() }
        step("select") { stepSelect() }
        step("albums") { stepAlbums() }
        step("search") { stepSearch() }
        step("delete") { stepDelete() }
        step("deleted") { stepDeleted() }
        step("settings") { stepSettings() }
    }

    // MARK: import

    /// Imports the seeded photos and waits until the Library shows them. mac-tour.sh has already run
    /// `open -a Photos <files>` (strategy a); this pass clicks the import UI that opens, else tries File > Import
    /// (strategy b). Strategy c (AppleScript) runs from the script, followed by a "wait" pass.
    func runImport(waitOnly: Bool) {
        let t0 = Date()
        let expected = Int(environment["MAC_EXPECTED_PHOTOS"] ?? "") ?? 0
        if photos.state == .notRunning { photos.launch() } else { photos.activate() }
        note("Photos state \(photos.state.rawValue) (1 not running, 4 foreground)")
        _ = photos.windows.firstMatch.waitForExistence(timeout: 40)
        pause(3)
        dismissOnboarding()
        setWindowSize()
        writeMeta()
        capture("00-after-launch")
        var method = "none"
        var clicked: [String] = []
        if !waitOnly {
            clicked = pressImportButtons(firstWait: 30)
            if !clicked.isEmpty {
                method = "a-open"
            } else {
                note("(a) no import button appeared after `open -a Photos`; trying (b) File > Import")
                clicked = importViaFileMenu()
                if !clicked.isEmpty { method = "b-menu" }
            }
            capture("01-after-import-click")
        }
        let count = waitForImport(expected: expected, maxSeconds: waitOnly ? 150 : 540)
        capture("02-import-done")
        let result = "method=\(method)\nclicked=\(clicked.joined(separator: ";"))\ncount=\(count.map(String.init) ?? "unknown")\n"
            + "expected=\(expected)\nseconds=\(Int(Date().timeIntervalSince(t0)))\n"
        try? result.write(to: outDir.appendingPathComponent("import-result.txt"), atomically: true, encoding: .utf8)
        note("import result: method \(method), count \(count.map(String.init) ?? "unknown") of \(expected)")
    }

    /// Clicks "Review for Import" and/or "Import All" (any of the button names Sonoma uses) until an Import button
    /// has been pressed. Returns the labels clicked.
    func pressImportButtons(firstWait: Double) -> [String] {
        var clicked: [String] = []
        var wait = firstWait
        for _ in 0..<6 {
            guard let button = waitForImportButton(seconds: wait) else { break }
            let name = button.label.isEmpty ? button.title : button.label
            capture("01-import-before-click-\(clicked.count + 1)")
            clickAt(button.frame)
            clicked.append(name)
            note("import: clicked '\(name)'")
            pause(3)
            wait = 8
            // "Review for Import" leads on to an Import All; an Import button is the last click.
            if !norm(name).hasPrefix("review") { break }
        }
        return clicked
    }

    func waitForImportButton(seconds: Double) -> Node? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            let nodes = snapshotNodes()
            let win = mainRect(nodes)
            let side = sidebarWidth(nodes, win)
            for n in nodes where [.button, .popUpButton, .menuButton].contains(n.type) && n.enabled && !n.frame.isNull
                && !n.frame.isInfinite && n.frame.width > 0 && !inRegion(n, .sidebar, win, side) {
                let s = norm(n.label.isEmpty ? n.title : n.label)
                let numbered = s.hasPrefix("import ") && (s.dropFirst(7).first?.isNumber ?? false)
                if s.hasPrefix("import all") || s.hasPrefix("review for import") || numbered { return n }
            }
            pause(1)
        } while Date() < deadline
        return nil
    }

    func importViaFileMenu() -> [String] {
        guard chooseMenu("File", ["Import…", "Import"]) else { return [] }
        pause(2.5)
        capture("02-open-panel")
        let dir = environment["MAC_SEED_DIR"] ?? ""
        photos.typeKey("g", modifierFlags: [.command, .shift])
        pause(1.2)
        photos.typeText(dir)
        pause(0.8)
        photos.typeKey(.return, modifierFlags: [])
        pause(1.5)
        capture("03-open-panel-folder")
        photos.typeKey("a", modifierFlags: .command)
        pause(0.8)
        return pressImportButtons(firstWait: 12)
    }

    /// Polls until the import has finished: no "Importing" text, and the Library footer ("300 Photos") reports
    /// nearly the expected number, or has stopped growing for a minute. Returns the last count read.
    func waitForImport(expected: Int, maxSeconds: Double) -> Int? {
        let end = Date().addingTimeInterval(maxSeconds)
        var last: Int? = nil
        var lastChange = Date()
        var idle = 0
        while Date() < end {
            let nodes = snapshotNodes()
            let busy = nodes.contains { n in
                let s = norm(n.label) + " " + norm(n.value)
                return s.contains("importing") || s.contains("preparing to import")
            }
            if busy {
                idle = 0
                pause(5)
                continue
            }
            idle += 1
            if idle >= 2 {
                goSidebar(["Library"])
                clickView("All Photos")
                photos.typeKey(.end, modifierFlags: [])   // the footer count shows at the end of the grid
                pause(2)
                let count = photoCount(snapshotNodes())
                note("library shows \(count.map(String.init) ?? "no count") photos (expect \(expected))")
                if let c = count {
                    if c != last { last = c; lastChange = Date() }
                    if expected > 0 && Double(c) >= Double(expected) * 0.95 { return c }
                    if Date().timeIntervalSince(lastChange) > 60 && c > 0 { return c }
                } else if idle >= 6 {
                    return nil
                }
            }
            pause(5)
        }
        return last
    }

    /// The largest "N Photos" figure on screen (the Library footer reads like "300 Photos, 3 Videos").
    func photoCount(_ nodes: [Node]) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "([0-9][0-9,.]*) photos?\\b") else { return nil }
        var best: Int? = nil
        for n in nodes {
            for raw in [n.label, n.value, n.title] {
                let s = norm(raw)
                guard s.contains("photo") else { continue }
                let range = NSRange(location: 0, length: (s as NSString).length)
                for m in regex.matches(in: s, range: range) where m.numberOfRanges > 1 {
                    let digits = (s as NSString).substring(with: m.range(at: 1)).filter { $0.isNumber }
                    if let v = Int(digits), v > (best ?? 0) { best = v }
                }
            }
        }
        return best
    }

    // MARK: steps

    func stepLibrary() {
        goSidebar(["Library"])
        capture("01-library-default")
        // Years, Months, Days (Days only if present), All Photos.
        for (n, view) in [(2, "Years"), (3, "Months"), (4, "Days"), (5, "All Photos")] {
            if clickView(view) {
                pause(1.5)
                capture(String(format: "%02ld-library-%@", n, view.lowercased().replacingOccurrences(of: " ", with: "")))
            }
        }
        clickView("All Photos")
        pause(1)
        // Zoom levels: the toolbar slider if there is one (clicked at five points along its track), else Cmd+- / Cmd+=.
        let slider = snapshotNodes().first(where: { $0.type == .slider })
        if let slider = slider {
            note("zoom slider \(rectString(slider.frame)) value '\(slider.value)'")
            for (i, fraction) in [0.02, 0.25, 0.5, 0.75, 0.98].enumerated() {
                clickAt(CGRect(x: slider.frame.minX + slider.frame.width * CGFloat(fraction), y: slider.frame.midY,
                               width: 0, height: 0))
                pause(1.5)
                let now = snapshotNodes().first(where: { $0.type == .slider })
                note("zoom slider at \(fraction): value '\(now?.value ?? "?")'")
                capture(String(format: "06-allphotos-zoom-%ld", i + 1))
            }
            clickAt(CGRect(x: slider.frame.midX, y: slider.frame.midY, width: 0, height: 0))
            pause(1)
        } else {
            note("NOT FOUND zoom slider; using Zoom Out / Zoom In")
            var out = 0
            while out < 5 {
                if !chooseMenu("View", ["Zoom Out"]) { photos.typeKey("-", modifierFlags: .command) }
                pause(1.2)
                out += 1
                capture(String(format: "06-allphotos-zoomout-%ld", out))
            }
            for n in 1...out {
                if !chooseMenu("View", ["Zoom In"]) { photos.typeKey("=", modifierFlags: .command) }
                pause(1.2)
                if n >= out - 1 { capture(String(format: "07-allphotos-zoomin-%ld", n)) }
            }
        }
        // The View menu itself, and the aspect-ratio / square thumbnails toggle if the menu has one.
        if let items = openMenu("View") {
            note("View menu: \(items.joined(separator: " | "))")
            capture("08-view-menu")
            esc()
        }
        let toggles = ["Aspect Ratio", "Square", "Show Photos in Square", "Crop Square"]
        if chooseMenu("View", toggles, loose: true) {
            pause(1.2)
            capture("09-allphotos-thumbnail-shape-toggled")
            _ = chooseMenu("View", toggles, loose: true)   // the same item flips back
            pause(1)
        } else {
            note("NOT FOUND an aspect-ratio / square thumbnail item in the View menu")
        }
        // Scrolled into the past, so the floating date header shows. Scroll deltas: positive is taken to reveal
        // older photos (the grid starts at its newest end); the log has the screenshot to judge by.
        scrollContent(1500)
        pause(1)
        capture("10-allphotos-scrolled-back")
        scrollContent(-1500)
    }

    func stepSidebar() {
        ensureSidebar()
        goSidebar(["Library"])
        expandSidebarSections()
        let nodes = snapshotNodes()
        let win = mainRect(nodes)
        let side = sidebarWidth(nodes, win)
        let rows = nodes.filter { $0.type == .staticText && inRegion($0, .sidebar, win, side) && !$0.label.isEmpty }
            .sorted { $0.frame.minY < $1.frame.minY }.map { $0.label }
        note("sidebar rows (\(rows.count)): \(rows.joined(separator: " | "))")
        let expectedRows: [[String]] = [["Library"], ["Memories"], ["Shared with You"], ["People & Pets", "People"], ["Places"],
                                        ["Favorites", "Favourites"], ["Recents"], ["Imports"], ["Duplicates"], ["Hidden"],
                                        ["Recently Deleted"], ["Albums", "My Albums"], ["Projects"]]
        for names in expectedRows where !rows.contains(where: { r in names.contains(where: { norm(r) == norm($0) }) }) {
            note("NOT FOUND sidebar row \(names)")
        }
        capture("20-sidebar-expanded")
        // The sidebar may be taller than the window: scroll it down and capture the rest, then back.
        scrollSidebar(-900)
        pause(1)
        capture("21-sidebar-scrolled-down")
        scrollSidebar(900)
        pause(1)
        // Hover state, and the selected state of another row.
        if let recents = locate(["Recents"], region: .sidebar) {
            clickAt(recents.frame, hoverOnly: true)
            pause(1)
            capture("22-sidebar-hover-recents")
        }
        goSidebar(["Recents"])
        capture("23-sidebar-selected-recents")
        goSidebar(["Library"])
    }

    func stepViewer() {
        goSidebar(["Library"])
        clickView("All Photos")
        pause(1)
        let rects = gridRects(snapshotNodes())
        guard rects.count >= 3 else { note("NOT FOUND any photo to open"); return }
        let target = rects[rects.count / 2]
        clickAt(target, double: true)
        pause(2)
        if !inViewer(snapshotNodes()) {
            note("double-click did not open the viewer; selecting then pressing Space")
            clickAt(target)
            photos.typeKey(.space, modifierFlags: [])
            pause(2)
        }
        note("viewer open: \(inViewer(snapshotNodes()))")
        capture("30-viewer")
        photos.typeKey("i", modifierFlags: .command)
        pause(1.5)
        capture("31-viewer-info")
        photos.typeKey("i", modifierFlags: .command)
        pause(1)
        // Favourite three photos, so the Favourites album has something in it.
        for n in 1...3 {
            if !click(["Favorite", "Favourite", "Add to Favorites"], region: .toolbar, timeout: 2) {
                photos.typeKey(".", modifierFlags: .command)   // Image > Favorite
                pause(0.8)
            }
            if n == 1 { capture("32-viewer-favourited") }
            photos.typeKey(.rightArrow, modifierFlags: [])
            pause(1)
        }
        // Full screen, if the shortcut works; checked by the window growing to the screen, then undone.
        let before = mainRect(snapshotNodes())
        photos.typeKey("f", modifierFlags: [.command, .control])
        pause(3)
        let full = mainRect(snapshotNodes())
        note("full screen: window \(rectString(before)) -> \(rectString(full))")
        capture("33-viewer-fullscreen")
        photos.typeKey("f", modifierFlags: [.command, .control])
        pause(3)
        note("after leaving full screen: \(rectString(mainRect(snapshotNodes())))")
        // Back to the grid: Escape, and only if the viewer is still up, the toolbar's back button.
        esc()
        pause(1.5)
        if inViewer(snapshotNodes()) {
            note("still in the viewer after Escape")
            _ = click(["Back", "Library", "All Photos"], region: .toolbar, timeout: 2)
        }
        capture("34-back-in-grid")
    }

    func stepSelect() {
        goSidebar(["Library"])
        clickView("All Photos")
        pause(1)
        var nodes = snapshotNodes()
        let rects = gridRects(nodes)
        guard rects.count >= 6 else { note("NOT FOUND enough photos to select (\(rects.count))"); return }
        let picks = [rects[rects.count / 2 - 1], rects[rects.count / 2], rects[rects.count / 2 + 1]]
        clickAt(picks[0])
        pause(0.8)
        // Cmd-click adds to the selection.
        clickAt(picks[1], command: true)
        pause(0.8)
        clickAt(picks[2], command: true)
        pause(1.2)
        nodes = snapshotNodes()
        let ticked = gridNodes(nodes).filter { $0.inSelected }.count
        let text = nodes.map { $0.label }.filter { norm($0).contains("selected") }
        note("selection: \(ticked) grid items report selected; texts: \(text)")
        capture("40-select-three")
        clickAt(picks[2], right: true)
        pause(1.2)
        capture("41-select-context-menu")
        esc()
        pause(0.8)
        if let items = openMenu("Image") {
            note("Image menu: \(items.joined(separator: " | "))")
            capture("42-image-menu")
            esc()
        }
        photos.typeKey("a", modifierFlags: [.command, .shift])   // Deselect All
        pause(1)
    }

    func stepAlbums() {
        ensureSidebar()
        expandSidebarSections()
        let wanted: [([String], String, Double)] = [
            (["Favorites", "Favourites"], "50-album-favourites", 1.5), (["Recents"], "51-album-recents", 1.5),
            (["Videos"], "52-media-videos", 1.5), (["Screenshots"], "53-media-screenshots", 1.5),
            (["People & Pets", "People"], "54-people-and-pets", 3), (["Places"], "55-places-map", 7),
            (["Memories"], "56-memories", 4), (["My Albums", "Albums"], "57-my-albums", 1.5)]
        for (names, file, wait) in wanted {
            goSidebar(names)
            pause(wait)
            capture(file)
        }
        // The new-album flow up to its sheet, then cancel it.
        goSidebar(["Library"])
        if chooseMenu("File", ["New Album…", "New Album"]) || chooseMenu("File", ["New Album"], loose: true) {
            pause(1.5)
            capture("58-new-album")
            let nodes = snapshotNodes()
            if nodes.contains(where: { $0.inDialog && $0.type == .button }) {
                if !click(["Cancel"], region: .dialog, timeout: 2) { esc() }
            } else {
                note("no sheet for the new album (inline name field?); pressing Escape")
                esc()
            }
            pause(1)
            capture("59-new-album-cancelled")
        } else {
            note("NOT FOUND File > New Album")
        }
        goSidebar(["Library"])
    }

    func stepSearch() {
        goSidebar(["Library"])
        let field = snapshotNodes().first(where: { $0.type == .searchField })
        if let field = field {
            clickAt(field.frame)
        } else {
            note("NOT FOUND search field node; using Cmd+F")
            photos.typeKey("f", modifierFlags: .command)
        }
        pause(1.2)
        capture("60-search-focused")
        photos.typeText("2025")
        pause(3)
        capture("61-search-typed-2025")
        photos.typeKey(.return, modifierFlags: [])
        pause(4)
        let none = snapshotNodes().contains { norm($0.label).contains("no results") }
        note("search '2025': \(none ? "no results" : "results")")
        capture("62-search-results-2025")
        // A place as well (the iOS simulator indexed years but not places).
        photos.typeKey("a", modifierFlags: .command)
        photos.typeKey(.delete, modifierFlags: [])
        photos.typeText("Oxford")
        pause(3)
        capture("63-search-typed-oxford")
        photos.typeKey(.return, modifierFlags: [])
        pause(3)
        note("search 'Oxford': \(snapshotNodes().contains { norm($0.label).contains("no results") } ? "no results" : "results")")
        capture("64-search-results-oxford")
        photos.typeKey("a", modifierFlags: .command)
        photos.typeKey(.delete, modifierFlags: [])
        esc()
        pause(1)
    }

    func stepDelete() {
        goSidebar(["Library"])
        clickView("All Photos")
        pause(1)
        // Three photos, so Recently Deleted has a grid with days-remaining labels rather than one item.
        for n in 1...3 {
            let rects = gridRects(snapshotNodes())
            guard rects.count >= 6 else { note("NOT FOUND enough photos to delete (\(rects.count))"); return }
            clickAt(rects[rects.count / 2])
            pause(0.8)
            photos.typeKey(.delete, modifierFlags: .command)
            pause(1.5)
            let nodes = snapshotNodes()
            let dialog = nodes.contains { $0.inDialog && $0.type == .button }
            if n == 1 { capture(dialog ? "70-delete-confirm" : "70-delete-no-confirm") }
            if dialog {
                if !click(["Delete"], region: .dialog, loose: true, only: [.button], timeout: 2) {
                    note("confirmation up but no Delete button found; pressing Return")
                    photos.typeKey(.return, modifierFlags: [])
                }
            } else {
                note("delete \(n): no confirmation sheet (Photos may have deleted at once)")
            }
            pause(2.5)
            note("deleted photo \(n)")
        }
        capture("71-after-deleting-three")
    }

    func stepDeleted() {
        goSidebar(["Recently Deleted"])
        pause(2)
        var nodes = snapshotNodes()
        // The lock (Sonoma): the album asks for Touch ID or the account password before it shows anything.
        let locked = nodes.contains { n in
            let s = norm(n.label) + " " + norm(n.value)
            return s.contains("is locked") || s.contains("view album") || s.contains("touch id") || s.contains("password")
        }
        capture(locked ? "80-recently-deleted-locked" : "80-recently-deleted")
        if locked {
            note("Recently Deleted is LOCKED (ContentPrivacyEnabled did not unlock it); capturing the locked view")
            if click(["View Album", "Unlock"], timeout: 2) {
                pause(3)
                capture("81-recently-deleted-unlock-prompt")
                esc()
                pause(1)
            }
            nodes = snapshotNodes()
        }
        // Its toolbar buttons (Recover / Delete All), then one item selected.
        let toolbarButtons = nodes.filter { $0.type == .button && inRegion($0, .toolbar, mainRect(nodes), 0) }.map { $0.label }
        note("Recently Deleted toolbar buttons: \(toolbarButtons)")
        for name in ["Recover", "Delete All"] where locate([name], region: .toolbar, loose: true) == nil {
            note("NOT FOUND toolbar button \(name)")
        }
        let rects = gridRects(nodes)
        if let first = rects.first {
            clickAt(first)
            pause(1.2)
            capture("82-recently-deleted-one-selected")
        } else {
            note("NOT FOUND any item in Recently Deleted")
        }
    }

    func stepSettings() {
        photos.typeKey(",", modifierFlags: .command)
        pause(2.5)
        capture("90-settings-general")
        let panes = ["General", "iCloud"]
        for (n, pane) in panes.enumerated() {
            if click([pane], only: [.button, .radioButton, .tab, .checkBox], timeout: 3) {
                pause(1.5)
                capture(String(format: "9%ld-settings-%@", n + 1, pane.lowercased()))
            }
        }
        let windows = photos.windows.count
        photos.typeKey("w", modifierFlags: .command)
        pause(1)
        note("windows before closing Settings: \(windows), after: \(photos.windows.count)")
    }

    // MARK: finding and clicking

    func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func stringValue(_ v: Any?) -> String {
        guard let v = v else { return "" }
        return String(describing: v)
    }

    func flatten(_ s: XCUIElementSnapshot, depth: Int, selectedAbove: Bool, dialogAbove: Bool, into nodes: inout [Node]) {
        let type = s.elementType
        let dialog = dialogAbove || type == .sheet || type == .dialog || type == .alert || type == .popover
        let selected = selectedAbove || s.isSelected
        nodes.append(Node(type: type, label: s.label, title: s.title, identifier: s.identifier, value: stringValue(s.value),
                          frame: s.frame, enabled: s.isEnabled, selected: s.isSelected, depth: depth,
                          inSelected: selected, inDialog: dialog))
        for child in s.children {
            flatten(child, depth: depth + 1, selectedAbove: selected, dialogAbove: dialog, into: &nodes)
        }
    }

    /// Every element of Photos in one snapshot (one round trip). Empty if the snapshot fails.
    func snapshotNodes() -> [Node] {
        ensureRunning()
        guard let root = try? photos.snapshot() else {
            note("snapshot failed")
            return []
        }
        var out: [Node] = []
        flatten(root, depth: 0, selectedAbove: false, dialogAbove: false, into: &out)
        return out
    }

    /// The biggest window: Photos' main window (Settings, Info and sheets are smaller).
    func mainRect(_ nodes: [Node]) -> CGRect {
        var best = CGRect.zero
        for n in nodes where n.type == .window && !n.frame.isNull && !n.frame.isInfinite {
            if n.frame.width * n.frame.height > best.width * best.height { best = n.frame }
        }
        return best
    }

    func sidebarWidth(_ nodes: [Node], _ win: CGRect) -> CGFloat {
        for n in nodes where n.type == .outline && !n.frame.isNull && n.frame.minX < win.minX + 40
            && n.frame.width > 80 && n.frame.width < 500 {
            return n.frame.width
        }
        return 240
    }

    func inRegion(_ n: Node, _ region: Region, _ win: CGRect, _ side: CGFloat) -> Bool {
        switch region {
        case .any: return true
        case .toolbar: return n.frame.midY < win.minY + 90 && n.frame.midY >= win.minY - 5
        case .sidebar: return n.frame.midX < win.minX + side && n.frame.midY > win.minY + 40
        case .content: return n.frame.midX > win.minX + side && n.frame.midY > win.minY + 60
        case .dialog: return n.inDialog
        }
    }

    func clickable(_ t: XCUIElement.ElementType) -> Bool {
        switch t {
        case .window, .application, .scrollView, .outline, .table, .collectionView, .toolbar, .menuBar, .menu,
             .sheet, .dialog, .alert, .popover:
            return false
        default:
            return true
        }
    }

    func priority(_ t: XCUIElement.ElementType) -> Int {
        switch t {
        case .button, .radioButton, .popUpButton, .menuButton, .checkBox, .disclosureTriangle: return 0
        case .menuItem, .menuBarItem, .tab: return 1
        case .staticText: return 2
        case .cell, .outlineRow: return 3
        case .image: return 4
        case .other, .group: return 5
        default: return 9
        }
    }

    func nameMatches(_ n: Node, _ wanted: String, loose: Bool) -> Bool {
        let w = norm(wanted)
        var candidates = [n.label, n.title, n.identifier]
        if n.type == .staticText { candidates.append(n.value) }
        for raw in candidates {
            let s = norm(raw)
            if s.isEmpty { continue }
            if s == w { return true }
            // "Recents, 312" and "Import…" style labels.
            if loose && s.hasPrefix(w) { return true }
        }
        return false
    }

    /// The best node for the first of `labels` that exists: buttons before texts before cells, enabled before
    /// disabled, smaller before larger.
    func locate(_ labels: [String], region: Region = .any, loose: Bool = false,
                only: [XCUIElement.ElementType]? = nil, in given: [Node]? = nil) -> Node? {
        let all = given ?? snapshotNodes()
        if all.isEmpty { return nil }
        let win = mainRect(all)
        let side = sidebarWidth(all, win)
        for label in labels {
            let hits = all.filter { n in
                guard clickable(n.type), !n.frame.isNull, !n.frame.isInfinite, n.frame.width > 0, n.frame.height > 0 else {
                    return false
                }
                if let only = only, !only.contains(n.type) { return false }
                return inRegion(n, region, win, side) && nameMatches(n, label, loose: loose)
            }
            let sorted = hits.sorted { a, b in
                if a.enabled != b.enabled { return a.enabled }
                if priority(a.type) != priority(b.type) { return priority(a.type) < priority(b.type) }
                return a.frame.width * a.frame.height < b.frame.width * b.frame.height
            }
            if let first = sorted.first { return first }
        }
        return nil
    }

    func anchorWindow() -> XCUIElement? {
        var best: XCUIElement? = nil
        var area: CGFloat = 0
        for w in photos.windows.allElementsBoundByIndex where w.exists {
            let f = w.frame
            if f.width * f.height > area { area = f.width * f.height; best = w }
        }
        return best
    }

    /// A screen point (global points) as a coordinate, anchored on the main window's top-left corner.
    func coordinate(x: CGFloat, y: CGFloat) -> XCUICoordinate? {
        guard let win = anchorWindow() else { return nil }
        let f = win.frame
        return win.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: x - f.minX, dy: y - f.minY))
    }

    func clickAt(_ rect: CGRect, double: Bool = false, right: Bool = false, command: Bool = false, hoverOnly: Bool = false) {
        ensureRunning()
        guard let c = coordinate(x: rect.midX, y: rect.midY) else {
            note("no window to click in")
            return
        }
        if hoverOnly {
            c.hover()
        } else if command {
            XCUIElement.perform(withKeyModifiers: .command) { c.click() }
        } else if right {
            c.rightClick()
        } else if double {
            c.doubleClick()
        } else {
            c.click()
        }
    }

    /// Clicks the best node matching one of `labels`, retrying until `timeout`. Logs the type that matched, or NOT FOUND.
    @discardableResult
    func click(_ labels: [String], region: Region = .any, loose: Bool = false,
               only: [XCUIElement.ElementType]? = nil, timeout: Double = 4, double: Bool = false) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let n = locate(labels, region: region, loose: loose, only: only) {
                if !n.enabled {
                    note("'\(labels[0])' is there (\(typeName(n.type))) but disabled")
                    return false
                }
                clickAt(n.frame, double: double)
                pause(0.8)
                note("clicked '\(n.label.isEmpty ? n.title : n.label)' (\(typeName(n.type)) \(rectString(n.frame)))")
                return true
            }
            pause(0.5)
        } while Date() < deadline
        note("NOT FOUND \(labels) (\(region))")
        return false
    }

    func esc() {
        photos.typeKey(.escape, modifierFlags: [])
        pause(0.6)
    }

    // MARK: menus

    /// Opens a menu-bar menu and returns its item titles (the menu is left open), or nil if the menu is not there.
    func openMenu(_ menu: String) -> [String]? {
        ensureRunning()
        guard let bar = locate([menu], only: [.menuBarItem]) else {
            note("NOT FOUND menu bar item \(menu)")
            return nil
        }
        clickAt(bar.frame)
        pause(1)
        let items = snapshotNodes().filter { $0.type == .menuItem }
            .sorted { $0.frame.minY < $1.frame.minY }.map { $0.title.isEmpty ? $0.label : $0.title }
        return items
    }

    /// File > Import… style: opens the menu, clicks the first item whose title equals (then starts with, if `loose`)
    /// one of `items`. Closes the menu and returns false if none is there or it is disabled.
    @discardableResult
    func chooseMenu(_ menu: String, _ items: [String], loose: Bool = false) -> Bool {
        guard let titles = openMenu(menu) else { return false }
        let nodes = snapshotNodes()
        for prefixMatch in [false, true] where prefixMatch == false || loose {
            if let item = locate(items, loose: prefixMatch, only: [.menuItem], in: nodes) {
                if !item.enabled {
                    note("menu \(menu) > '\(item.title)' is disabled")
                    esc()
                    return false
                }
                clickAt(item.frame)
                pause(1.2)
                note("menu: \(menu) > \(item.title.isEmpty ? item.label : item.title)")
                return true
            }
        }
        note("NOT FOUND menu item \(items) in \(menu): \(titles.joined(separator: " | "))")
        esc()
        return false
    }

    // MARK: sidebar and view switcher

    /// Years / Months / Days / All Photos: the toolbar's switcher, else the View menu.
    @discardableResult
    func clickView(_ name: String) -> Bool {
        if click([name], region: .toolbar, timeout: 3) {
            let on = locate([name], region: .toolbar).map { $0.selected || $0.value == "1" } ?? false
            note("view '\(name)' now \(on ? "selected" : "not reported selected")")
            return true
        }
        return chooseMenu("View", [name, "as \(name)"])
    }

    func ensureSidebar() {
        let nodes = snapshotNodes()
        if !nodes.contains(where: { $0.type == .outline }) {
            note("no sidebar outline on screen; toggling it with Cmd+Option+S")
            photos.typeKey("s", modifierFlags: [.command, .option])
            pause(1.5)
        }
    }

    func sidebarSelected(_ names: [String]) -> Bool {
        let nodes = snapshotNodes()
        let win = mainRect(nodes)
        let side = sidebarWidth(nodes, win)
        for n in nodes where inRegion(n, .sidebar, win, side) && n.inSelected {
            if names.contains(where: { nameMatches(n, $0, loose: false) }) { return true }
        }
        // The toolbar title names the open view.
        return nodes.contains { n in
            n.type == .staticText && inRegion(n, .toolbar, win, side) && names.contains(where: { nameMatches(n, $0, loose: false) })
        }
    }

    /// Clicks a sidebar row and checks it took (a first click can be dead, as on iOS); the second try aims at the row.
    @discardableResult
    func goSidebar(_ names: [String], loose: Bool = false) -> Bool {
        ensureSidebar()
        for attempt in 1...2 {
            let rowTypes: [XCUIElement.ElementType]? = attempt == 1 ? nil : [.outlineRow, .cell]
            guard click(names, region: .sidebar, loose: loose, only: rowTypes, timeout: attempt == 1 ? 4 : 1.5) else {
                return false
            }
            pause(1)
            if sidebarSelected(names) {
                note("sidebar '\(names[0])' selected (verified)")
                return true
            }
            note("sidebar '\(names[0])' not verified after click \(attempt)")
        }
        return false
    }

    /// Opens collapsed sidebar sections (Utilities, Media Types, Shared Albums, My Albums): disclosure triangles that
    /// read 0, and the Show buttons Photos draws beside a header on hover.
    func expandSidebarSections() {
        for _ in 0..<8 {
            let nodes = snapshotNodes()
            let win = mainRect(nodes)
            let side = sidebarWidth(nodes, win)
            if let t = nodes.first(where: { $0.type == .disclosureTriangle && inRegion($0, .sidebar, win, side)
                                            && ($0.value == "0" || norm($0.label) == "show") && $0.frame.width > 0 }) {
                clickAt(t.frame)
                pause(0.8)
                continue
            }
            var opened = false
            for header in ["Utilities", "Media Types", "Shared Albums", "My Albums", "Projects"] {
                guard let h = nodes.first(where: { $0.type == .staticText && nameMatches($0, header, loose: false)
                                                    && inRegion($0, .sidebar, win, side) }) else { continue }
                clickAt(h.frame, hoverOnly: true)
                pause(0.5)
                let after = snapshotNodes()
                if let show = after.first(where: { $0.type == .button && norm($0.label) == "show"
                                                   && abs($0.frame.midY - h.frame.midY) < 14 && $0.frame.width > 0 }) {
                    clickAt(show.frame)
                    pause(0.8)
                    note("expanded sidebar section \(header)")
                    opened = true
                    break
                }
            }
            if !opened { break }
        }
    }

    // MARK: scrolling

    func scrollContent(_ dy: CGFloat) {
        var best: XCUIElement? = nil
        var area: CGFloat = 0
        for s in photos.scrollViews.allElementsBoundByIndex where s.exists {
            let f = s.frame
            if f.width * f.height > area { area = f.width * f.height; best = s }
        }
        guard let target = best ?? anchorWindow() else { note("nothing to scroll"); return }
        target.scroll(byDeltaX: 0, deltaY: dy)
        pause(0.8)
    }

    func scrollSidebar(_ dy: CGFloat) {
        let outline = photos.outlines.firstMatch
        guard let target = outline.exists ? outline : anchorWindow() else { return }
        target.scroll(byDeltaX: 0, deltaY: dy)
        pause(0.8)
    }

    // MARK: grid and viewer detection

    /// Photo, video and card items in the content area: cells, else images, else labelled groups. Sorted top to bottom,
    /// left to right; items whose centre is under the toolbar or past the window edge are left out.
    func gridNodes(_ nodes: [Node]) -> [Node] {
        let win = mainRect(nodes)
        let side = sidebarWidth(nodes, win)
        func ok(_ n: Node) -> Bool {
            let f = n.frame
            guard !f.isNull, !f.isInfinite, f.width >= 40, f.height >= 40, f.width < win.width * 0.6, !n.inDialog else { return false }
            return f.midX > win.minX + side && f.midX < win.maxX && f.midY > win.minY + 90 && f.midY < win.maxY - 20
        }
        let cells = nodes.filter { $0.type == .cell && ok($0) }
        var pool = cells
        if cells.count < 3 {
            let images = nodes.filter { $0.type == .image && ok($0) }
            if images.count >= 3 {
                pool = images
            } else {
                pool = nodes.filter { n in
                    (n.type == .other || n.type == .group) && ok(n) && (norm(n.label).hasPrefix("photo") || norm(n.label).hasPrefix("video"))
                }
            }
        }
        return pool.sorted { $0.frame.midY != $1.frame.midY ? $0.frame.midY < $1.frame.midY : $0.frame.midX < $1.frame.midX }
    }

    /// Frames of the grid items, or, when Photos exposes none, a synthesised 5 x 3 grid in the content area (logged).
    func gridRects(_ nodes: [Node]) -> [CGRect] {
        let found = gridNodes(nodes).map { $0.frame }
        if found.count >= 3 {
            note("grid items: \(found.count)")
            return found
        }
        let win = mainRect(nodes)
        let side = sidebarWidth(nodes, win)
        note("NOT FOUND grid items in the accessibility tree (\(found.count)); clicking a synthesised 5 x 3 grid")
        var rects: [CGRect] = []
        for row in 0..<3 {
            for col in 0..<5 {
                rects.append(CGRect(x: win.minX + side + 80 + CGFloat(col) * 150, y: win.minY + 170 + CGFloat(row) * 150,
                                    width: 140, height: 140))
            }
        }
        return rects
    }

    /// The single-photo viewer has Rotate / Crop / Info / Favorite style controls and no Years..All Photos switcher.
    func inViewer(_ nodes: [Node]) -> Bool {
        let win = mainRect(nodes)
        let bar = nodes.filter { $0.frame.midY < win.minY + 90 && $0.frame.midY > win.minY - 5 }
        let gridSwitch = bar.contains { n in
            ["all photos", "years", "months", "days"].contains(norm(n.label)) && (n.type == .button || n.type == .radioButton)
        }
        let markers = ["rotate", "crop", "enhance", "markup", "info", "favorite", "favourite", "edit", "adjust"]
        let marker = bar.contains { n in markers.contains(where: { norm(n.label).hasPrefix($0) || norm(n.title).hasPrefix($0) }) }
        return marker && !gridSwitch
    }

    /// Start of every step: close a menu, a stray sheet or the viewer left open by the step before.
    func leaveViewerAndMenus() {
        let nodes = snapshotNodes()
        if nodes.contains(where: { $0.type == .menuItem }) { esc() }
        if inViewer(nodes) {
            note("viewer left open; pressing Escape")
            esc()
        }
    }

    // MARK: launch, windows, onboarding

    func ensureRunning() {
        let state = photos.state
        if state == .notRunning {
            note("Photos is not running (crashed?); relaunching")
            photos.launch()
            _ = photos.windows.firstMatch.waitForExistence(timeout: 30)
            pause(4)
            dismissOnboarding(maxSeconds: 10)
        } else if state != .runningForeground {
            note("Photos not in front (state \(state.rawValue)); activating it")
            photos.activate()
            pause(1.5)
        }
    }

    /// First launch on a fresh account: "Welcome to Photos" (Continue / Get Started) and an iCloud question (Not Now).
    func dismissOnboarding(maxSeconds: Double = 40) {
        let labels = ["Get Started", "Continue", "Not Now", "Later", "Maybe Later", "Skip", "Don't Sign In",
                      "Use Without iCloud", "OK"]
        let deadline = Date().addingTimeInterval(maxSeconds)
        var quiet = 0
        var announced = false
        while Date() < deadline && quiet < 3 {
            let nodes = snapshotNodes()
            if !announced && nodes.contains(where: { norm($0.label).contains("welcome to photos") || norm($0.value).contains("welcome to photos") }) {
                note("welcome screen showing")
                capture("00-welcome")
                announced = true
            }
            if let b = locate(labels, only: [.button], in: nodes) {
                clickAt(b.frame)
                note("onboarding: clicked '\(b.label)'")
                quiet = 0
            } else {
                quiet += 1
            }
            pause(2)
        }
    }

    /// Drags the main window's bottom-right corner towards the wanted size (default 1440 x 900, never past the screen).
    /// Logged either way; meta.json records the size the window ended up with. AppleScript is a last resort, off by
    /// default (MAC_OSASCRIPT=1) because its Automation prompt could sit over the screenshots.
    func setWindowSize() {
        let wantW = CGFloat(Double(environment["MAC_WIN_W"] ?? "") ?? 1440)
        let wantH = CGFloat(Double(environment["MAC_WIN_H"] ?? "") ?? 900)
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: wantW, height: wantH)
        let w = min(wantW, screen.width), h = min(wantH, screen.height - 10)
        let rect = mainRect(snapshotNodes())
        guard rect.width > 0 else { note("NOT FOUND a window to resize"); return }
        note("window is \(rectString(rect)); wanted \(Int(w)) x \(Int(h)) (screen \(Int(screen.width)) x \(Int(screen.height)))")
        if abs(rect.width - w) > 20 || abs(rect.height - h) > 20 {
            if let from = coordinate(x: rect.maxX - 2, y: rect.maxY - 2),
               let to = coordinate(x: rect.minX + w - 2, y: rect.minY + h - 2) {
                from.click(forDuration: 0.2, thenDragTo: to)
                pause(1.5)
            }
            let now = mainRect(snapshotNodes())
            note("after dragging the corner: \(rectString(now))")
            if (abs(now.width - w) > 40 || abs(now.height - h) > 40) && environment["MAC_OSASCRIPT"] == "1" {
                resizeWithAppleScript(w: w, h: h)
                note("after AppleScript: \(rectString(mainRect(snapshotNodes())))")
            }
        }
    }

    func resizeWithAppleScript(w: CGFloat, h: CGFloat) {
        let script = "tell application \"System Events\" to tell process \"Photos\" to tell window 1 to "
            + "(set position to {20, 40}) & (set size to {\(Int(w)), \(Int(h))})"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do { try p.run() } catch { note("osascript could not run: \(error)"); return }
        let end = Date().addingTimeInterval(20)
        while p.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate(); note("osascript timed out (Automation prompt?)") }
    }

    // MARK: capture

    func note(_ line: String) {
        log.append(String(format: "%7.1fs  ", Date().timeIntervalSince(started)) + line)
        print("TOUR: \(line)")
        try? (log.joined(separator: "\n") + "\n")
            .write(to: outDir.appendingPathComponent("tour-log.txt"), atomically: true, encoding: .utf8)
    }

    func pause(_ seconds: Double = 0.8) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func rectString(_ r: CGRect) -> String {
        if r.isNull || r.isInfinite { return "(none)" }
        return String(format: "(%.0f,%.0f %.0fx%.0f)", Double(r.minX), Double(r.minY), Double(r.width), Double(r.height))
    }

    func num(_ v: CGFloat) -> Double { v.isFinite ? Double(v) : -1 }

    func writeJSON(_ object: Any, to path: String) {
        // JSONSerialization raises an Objective-C exception (killing the runner) on anything invalid, so check first.
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        } else {
            note("JSON skipped for \(path): not valid")
        }
    }

    func cgImage(_ shot: XCUIScreenshot) -> CGImage? {
        shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Screenshot (whole screen, and the Photos window cropped out), element tree, and elements.json for the screen.
    /// Names are joined as strings so "x.tree.txt" cannot lose its two-part extension.
    func capture(_ name: String) {
        ensureRunning()
        pause(1.0)
        let base = outDir.path + "/" + name
        var shot = XCUIScreen.main.screenshot()
        if shot.image.size.width < 1, let win = anchorWindow() {
            note("screen screenshot is empty (Screen Recording permission?); using the window's own")
            shot = win.screenshot()
        }
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: base + ".png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? photos.debugDescription.write(toFile: base + ".tree.txt", atomically: true, encoding: .utf8)
        let nodes = snapshotNodes()
        let win = mainRect(nodes)
        let screenSize = NSScreen.main?.frame.size ?? CGSize.zero
        var scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 1
        if let cg = cgImage(shot), screenSize.width > 0 {
            scale = CGFloat(cg.width) / screenSize.width   // pixels per point of this very screenshot
            let box = CGRect(x: win.minX * scale, y: win.minY * scale, width: win.width * scale, height: win.height * scale)
                .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            if win.width > 0, !box.isNull, box.width > 0, let crop = cg.cropping(to: box), let png = pngData(crop) {
                try? png.write(to: URL(fileURLWithPath: base + ".window.png"))
            }
        }
        var rows: [[String: Any]] = []
        for n in nodes {
            rows.append(["depth": n.depth, "type": typeName(n.type), "identifier": n.identifier, "label": n.label,
                         "title": n.title, "value": n.value,
                         "x": num(n.frame.origin.x), "y": num(n.frame.origin.y),
                         "w": num(n.frame.size.width), "h": num(n.frame.size.height),
                         "wx": num(n.frame.origin.x - win.minX), "wy": num(n.frame.origin.y - win.minY),
                         "selected": n.selected, "enabled": n.enabled, "inDialog": n.inDialog])
        }
        writeJSON(rows, to: base + ".elements.json")
        let windows = nodes.filter { $0.type == .window }.map { n -> [String: Any] in
            ["title": n.title, "x": num(n.frame.origin.x), "y": num(n.frame.origin.y),
             "w": num(n.frame.size.width), "h": num(n.frame.size.height)]
        }
        writeJSON(["mainWindow": ["x": num(win.origin.x), "y": num(win.origin.y), "w": num(win.width), "h": num(win.height)],
                   "screenPointsW": num(screenSize.width), "screenPointsH": num(screenSize.height),
                   "pixelsPerPoint": Double(scale), "windows": windows] as [String: Any], to: base + ".window.json")
        note("captured \(name)")
    }

    func luminance(_ cg: CGImage, x: Int, y: Int) -> Double? {
        guard x >= 0, y >= 0, x < cg.width, y < cg.height,
              let px = cg.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return (0.2126 * Double(data[0]) + 0.7152 * Double(data[1]) + 0.0722 * Double(data[2])) / 255.0
    }

    /// meta.json: screen size and scale, the window's size, the requested appearance, and the appearance actually
    /// sampled from three background pixels of the window (mean luminance below 0.5 is dark).
    func writeMeta() {
        let nodes = snapshotNodes()
        let win = mainRect(nodes)
        let screenSize = NSScreen.main?.frame.size ?? CGSize.zero
        let backing = NSScreen.main?.backingScaleFactor ?? 1
        var meta: [String: Any] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "requestedAppearance": appearance,
            "screenPointsW": Double(screenSize.width), "screenPointsH": Double(screenSize.height),
            "backingScaleFactor": Double(backing),
            "windowOriginX": num(win.origin.x), "windowOriginY": num(win.origin.y),
            "windowPointsW": num(win.width), "windowPointsH": num(win.height),
            "wantedWindowW": environment["MAC_WIN_W"] ?? "1440", "wantedWindowH": environment["MAC_WIN_H"] ?? "900"]
        let shot = XCUIScreen.main.screenshot()
        if let cg = cgImage(shot), screenSize.width > 0, win.width > 0 {
            let s = CGFloat(cg.width) / screenSize.width
            meta["screenshotPixelsW"] = cg.width
            meta["screenshotPixelsH"] = cg.height
            let spots: [(CGFloat, CGFloat)] = [(win.minX + 20, win.maxY - 40), (win.minX + win.width * 0.6, win.minY + 8),
                                               (win.maxX - 60, win.maxY - 12)]
            let lums = spots.compactMap { luminance(cg, x: Int($0.0 * s), y: Int($0.1 * s)) }
            if !lums.isEmpty {
                let mean = lums.reduce(0, +) / Double(lums.count)
                meta["sampledLuminance"] = lums
                meta["sampledAppearance"] = mean < 0.5 ? "dark" : "light"
                if mode == "tour" && (mean < 0.5 ? "dark" : "light") != appearance {
                    note("APPEARANCE MISMATCH: asked for \(appearance), sampled luminance \(String(format: "%.2f", mean))")
                } else {
                    note("appearance sample: luminance \(String(format: "%.2f", mean)) (\(mean < 0.5 ? "dark" : "light"))")
                }
            }
        }
        writeJSON(meta, to: outDir.appendingPathComponent("meta.json").path)
    }

    func typeName(_ t: XCUIElement.ElementType) -> String {
        switch t {
        case .application: return "application"
        case .window: return "window"
        case .other: return "other"
        case .group: return "group"
        case .button: return "button"
        case .radioButton: return "radioButton"
        case .popUpButton: return "popUpButton"
        case .menuButton: return "menuButton"
        case .checkBox: return "checkBox"
        case .disclosureTriangle: return "disclosureTriangle"
        case .staticText: return "staticText"
        case .image: return "image"
        case .cell: return "cell"
        case .outline: return "outline"
        case .outlineRow: return "outlineRow"
        case .collectionView: return "collectionView"
        case .scrollView: return "scrollView"
        case .table: return "table"
        case .tab: return "tab"
        case .toolbar: return "toolbar"
        case .searchField: return "searchField"
        case .textField: return "textField"
        case .menu: return "menu"
        case .menuItem: return "menuItem"
        case .menuBar: return "menuBar"
        case .menuBarItem: return "menuBarItem"
        case .sheet: return "sheet"
        case .dialog: return "dialog"
        case .alert: return "alert"
        case .popover: return "popover"
        case .slider: return "slider"
        case .progressIndicator: return "progressIndicator"
        case .map: return "map"
        default: return "type\(t.rawValue)"
        }
    }
}
