import XCTest

/// Walks Apple's Photos app (com.apple.mobileslideshow) through every screen we need to recreate. For each
/// screen it saves a screenshot, the element tree as text, and every element's type, label and frame (in
/// points) as JSON, into <TOUR_OUT or $SIMULATOR_HOST_HOME/photos-tour-out>/<device>-iOS<version>-<appearance>/.
///
/// Nothing is asserted. A control the tour cannot find is logged ("NOT FOUND") and the tour moves on, so one
/// wrong label never costs the rest of the run. Environment (set through TEST_RUNNER_ prefixed variables):
///   TOUR_APPEARANCE  light or dark (only names the output folder; tour.sh switches the simulator)
///   TOUR_STEPS       comma list of steps, or "all"
///   TOUR_OUT         output root on the Mac (tour.sh passes ~/photos-tour-out)
///
/// Language mode: Swift 5 (project.yml). Xcode 16+ marks XCUIApplication and XCUIElement @MainActor; as
/// imported Objective-C they are @preconcurrency, so Swift 5 mode accepts the calls below. Swift 6 mode would not.
final class PhotosTour: XCTestCase {
    let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
    var outDir = URL(fileURLWithPath: NSTemporaryDirectory())
    var log: [String] = []
    var started = Date()

    override func setUpWithError() throws {
        continueAfterFailure = true
        started = Date()
        let env = ProcessInfo.processInfo.environment
        let appearance = env["TOUR_APPEARANCE"] ?? "light"
        let model = env["SIMULATOR_MODEL_IDENTIFIER"] ?? "device"
        let version = env["SIMULATOR_RUNTIME_VERSION"] ?? "unknown"
        // tour.sh names the folder itself; SIMULATOR_HOST_HOME (the Mac user's home, set by CoreSimulator for
        // every simulator process) is the fallback, and the runner's own temporary folder the last resort.
        let root: URL
        if let given = env["TOUR_OUT"], !given.isEmpty {
            root = URL(fileURLWithPath: given)
        } else {
            root = URL(fileURLWithPath: env["SIMULATOR_HOST_HOME"] ?? NSTemporaryDirectory())
                .appendingPathComponent("photos-tour-out")
        }
        outDir = root.appendingPathComponent("\(model)-iOS\(version)-\(appearance)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        note("output folder \(outDir.path)")
    }

    // MARK: the tour

    func testTour() {
        let wanted = Set((ProcessInfo.processInfo.environment["TOUR_STEPS"] ?? "all")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })

        func step(_ name: String, _ body: () -> Void) {
            guard wanted.contains("all") || wanted.contains(name) else { return }
            note("== step \(name)")
            // A crash, or a step that left another app in front, must not cost the remaining steps.
            if photos.state != .runningForeground {
                note("Photos not in front (state \(photos.state.rawValue)); activating it")
                photos.activate()
                pause(3)
            }
            XCTContext.runActivity(named: name) { _ in body() }
        }

        launchFresh()
        writeMeta()
        step("library") { stepLibrary() }
        step("views") { stepDaysMonthsYears() }
        step("viewer") { stepViewer() }
        step("context") { stepContextMenus() }
        step("foryou") { stepForYou() }
        step("albums") { stepAlbums() }
        step("search") { stepSearch() }
        step("delete") { stepDelete() }
        step("deleted") { stepRecentlyDeleted() }
        note("== tour finished")
    }

    // MARK: steps

    func stepLibrary() {
        tap(["Library"])
        tap(["All Photos"])
        capture("01-allphotos-default")
        if openMore() {
            capture("02-allphotos-more-menu")
            dismissMenu()
        }
        // Down to the smallest thumbnails, then up to the largest, one screenshot per level; then back.
        var out = 0
        while out < 8, openMoreAndTap(["Zoom Out"]) {
            out += 1
            capture(String(format: "03-allphotos-zoomout-%ld", out))
        }
        var into = 0
        while into < 10, openMoreAndTap(["Zoom In"]) {
            into += 1
            capture(String(format: "04-allphotos-zoomin-%ld", into))
        }
        for _ in 0..<max(0, into - out) { _ = openMoreAndTap(["Zoom Out"]) }
        note("zoom levels: \(out) out from default, \(into) in from the smallest; default is level \(out) of \(into)")

        // The same levels by pinching the grid, to check pinch and menu agree. iOS 14+ Photos draws the grid
        // itself, so it may be a scroll view rather than a collection view; failing both, pinch mid-screen.
        // Velocity must have the sign of the change: negative to pinch in (scale < 1), positive to spread.
        let grid = [photos.collectionViews.firstMatch, photos.scrollViews.firstMatch].first(where: { $0.exists })
            ?? (photos as XCUIElement)
        grid.pinch(withScale: 0.5, velocity: -1.0)
        capture("05-allphotos-pinched-out")
        grid.pinch(withScale: 2.0, velocity: 1.0)
        capture("05-allphotos-pinched-back")

        if openMoreAndTap(["Aspect Ratio Grid"]) {
            capture("06-allphotos-aspect-ratio-grid")
            _ = openMoreAndTap(["Square Photo Grid", "Square Grid", "Aspect Ratio Grid"])
        }
        if openMoreAndTap(["Filter"]) {
            capture("07-allphotos-filter")
            tap(["Done", "Cancel", "Close"], timeout: 2)
            dismissMenu()
        }

        // Older photos sit above: scroll up into the past to see the floating date header.
        photos.swipeDown()
        photos.swipeDown()
        capture("08-allphotos-scrolled-back")
        for _ in 0..<4 { photos.swipeUp() }

        if tap(["Select"]) {
            capture("09-select-mode")
            for cell in visibleCells().suffix(6).prefix(3) { cell.tap() }
            capture("10-select-three")
            tap(["Cancel"])
        }
    }

    func stepDaysMonthsYears() {
        tap(["Library"])
        for (number, view) in [(11, "Days"), (12, "Months"), (13, "Years")] {
            guard tap([view]) else { continue }
            capture("\(number)-\(view.lowercased())")
            photos.swipeDown()
            capture("\(number)-\(view.lowercased())-scrolled")
            photos.swipeUp()
        }
        // Years -> a year card -> Months -> a month card -> Days: the drill-down path.
        if tap(["Years"]), let year = visibleCells().last {
            year.tap()
            capture("14-year-tapped")
            if let month = visibleCells().last {
                month.tap()
                capture("15-month-tapped")
            }
        }
        // Days: tap a day's photo.
        if tap(["Days"]), let day = visibleCells().last {
            day.tap()
            capture("16-day-photo-tapped")
            closeViewer()
        }
        tap(["All Photos"])
    }

    func stepViewer() {
        tap(["Library"])
        tap(["All Photos"])
        guard openSomePhoto() else { return }
        capture("20-viewer")
        center().tap()
        capture("21-viewer-chrome-hidden")
        center().tap()
        photos.swipeUp()
        capture("22-viewer-info-swiped")
        photos.swipeDown()
        if tap(["Info", "Show Info", "info"]) {
            capture("23-viewer-info-button")
            photos.swipeDown()
        }
        // Favourite three photos, so the Favorites album has something in it.
        for n in 1...3 {
            if tap(["Favorite", "Favourite", "Add to Favorites"]) && n == 1 { capture("24-viewer-favourited") }
            photos.swipeLeft()
        }
        capture("25-viewer-after-swipes")
        if tap(["Share"]) {
            pause(2)
            capture("26-share-sheet")
            // Swipe the sheet away only when it has no Close button: with no sheet up, a swipe down closes the viewer.
            if !tap(["Close", "Cancel"], timeout: 2) { photos.swipeDown() }
        }
        center().press(forDuration: 1.2)
        capture("27-viewer-long-press")
        dismissMenu()
        closeViewer()
        capture("28-back-in-grid")
    }

    func stepContextMenus() {
        tap(["Library"])
        tap(["All Photos"])
        if let cell = visibleCells().dropLast(3).last {
            cell.press(forDuration: 1.2)
            capture("29-photo-context-menu")
            dismissMenu()
        }
    }

    func stepForYou() {
        guard tap(["For You"]) else { return }
        pause(2)
        capture("30-for-you")
        photos.swipeUp()
        capture("31-for-you-scrolled")
        photos.swipeDown()
        if let card = visibleCells().first {
            card.tap()
            pause(3)
            capture("32-memory-opened")
            tap(["Close", "Done"], timeout: 2)
            photos.swipeDown()
        }
    }

    func stepAlbums() {
        guard tap(["Albums"]) else { return }
        capture("40-albums-top")
        for n in 1...4 {
            photos.swipeUp()
            capture("4\(n)-albums-scroll-\(n)")
        }
        for _ in 0..<6 { photos.swipeDown() }
        if tap(["See All"]) { capture("45-albums-see-all"); goBack() }
        if tap(["Recents"]) { capture("46-album-recents"); goBack() }
        if tap(["Favorites", "Favourites"]) { capture("47-album-favorites"); goBack() }
        if tap(["People & Pets", "People"]) { capture("48-people-and-pets"); goBack() }
        for _ in 0..<2 { photos.swipeUp() }
        if tap(["Videos"]) {
            capture("49-media-type-videos")
            if openSomePhoto() {
                capture("50-video-viewer")
                tap(["Play"], timeout: 2)
                pause(1.5)
                capture("51-video-playing")
                closeViewer()
            }
            goBack()
        }
        if tap(["Screenshots"]) { capture("52-media-type-screenshots"); goBack() }
        for _ in 0..<6 { photos.swipeDown() }
        if tap(["+", "Add", "New Album"]) {
            capture("53-albums-add-menu")
            dismissMenu()
        }
    }

    func stepSearch() {
        guard tap(["Search"]) else { return }
        pause(2)
        capture("60-search")
        let field = photos.searchFields.firstMatch
        guard field.waitForExistence(timeout: 3) else { note("NOT FOUND search field"); return }
        field.tap()
        capture("61-search-focused")
        field.typeText("Oxford")
        pause(2)
        capture("62-search-typed")
        // Return submits. The keyboard's "search" key is absent while a hardware keyboard is attached, and a
        // "Search" label would match the tab bar.
        field.typeText("\n")
        pause(2)
        capture("63-search-results")
        tap(["Cancel"], timeout: 2)
    }

    func stepDelete() {
        tap(["Library"])
        tap(["All Photos"])
        guard openSomePhoto() else { return }
        if tap(["Delete", "Trash"]) {
            capture("70-delete-confirm")
            tap(["Delete Photo", "Delete"])
        }
        closeViewer()
    }

    func stepRecentlyDeleted() {
        guard tap(["Albums"]) else { return }
        for _ in 0..<6 { photos.swipeUp() }
        if tap(["Recently Deleted"]) {
            tap(["View Album"], timeout: 2)
            pause(2)
            capture("71-recently-deleted")
            if tap(["Select"]) {
                capture("72-recently-deleted-select")
                tap(["Cancel"])
            }
            goBack()
        }
    }

    // MARK: helpers

    func launchFresh() {
        photos.terminate()
        photos.launch()
        pause(4)
        tap(["Continue", "Not Now", "OK", "Allow"], timeout: 2)
    }

    /// Logs a line with the seconds since setUp. The file is rewritten on every line, so a crash or a killed run
    /// still leaves tour-log.txt up to that point.
    func note(_ line: String) {
        log.append(String(format: "%7.1fs  ", Date().timeIntervalSince(started)) + line)
        print("TOUR: \(line)")
        try? (log.joined(separator: "\n") + "\n")
            .write(to: outDir.appendingPathComponent("tour-log.txt"), atomically: true, encoding: .utf8)
    }

    func pause(_ seconds: Double = 0.8) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func center() -> XCUICoordinate {
        photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// Taps the first hittable element whose label or identifier is one of `labels` (exact, then
    /// "contains" for buttons and cells), retrying until `timeout`. Logs and returns false if none appears.
    /// Each pass first takes one snapshot of Photos and skips labels that appear nowhere in it, so a missing
    /// label costs one round trip per pass rather than eight queries per label (each query is a round trip,
    /// and a pass always runs once even when it outlasts `timeout`).
    @discardableResult
    func tap(_ labels: [String], timeout: Double = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let onScreen = screenLabels()
            for label in labels {
                if let onScreen = onScreen, !onScreen.contains(where: { $0.localizedCaseInsensitiveContains(label) }) {
                    continue
                }
                let exact = NSPredicate(format: "label == %@ OR identifier == %@", label, label)
                let queries = [photos.tabBars.buttons, photos.buttons, photos.segmentedControls.buttons,
                               photos.menuItems, photos.cells, photos.staticTexts, photos.otherElements]
                for query in queries {
                    if let element = firstHittable(query.matching(exact)) {
                        element.tap()
                        pause()
                        note("tapped \(label)")
                        return true
                    }
                }
                // "Contains" only for labels long enough not to hit unrelated controls ("ok" is inside "Look Up").
                // Cells too: album tiles may read "Recents, 312".
                guard label.count >= 3 else { continue }
                let loose = NSPredicate(format: "label CONTAINS[c] %@", label)
                for query in [photos.buttons, photos.cells] {
                    if let element = firstHittable(query.matching(loose)) {
                        let found = element.label
                        element.tap()
                        pause()
                        note("tapped ~\(label) (\(found))")
                        return true
                    }
                }
            }
            pause(0.4)
        } while Date() < deadline
        note("NOT FOUND \(labels)")
        return false
    }

    /// Every label and identifier in one snapshot of Photos; nil if the snapshot fails (every query is then tried).
    func screenLabels() -> [String]? {
        guard let root = try? photos.snapshot() else { return nil }
        var found: [String] = []
        var stack: [XCUIElementSnapshot] = [root]
        while let s = stack.popLast() {
            if !s.label.isEmpty { found.append(s.label) }
            if !s.identifier.isEmpty { found.append(s.identifier) }
            stack.append(contentsOf: s.children)
        }
        return found
    }

    func firstHittable(_ query: XCUIElementQuery) -> XCUIElement? {
        let count = query.count
        guard count > 0 else { return nil }
        for index in 0..<min(count, 8) {
            let element = query.element(boundBy: index)
            if element.exists && element.isHittable { return element }
        }
        return nil
    }

    /// The "..." button at the top of All Photos (its label is a guess; the log shows which one matched).
    @discardableResult
    func openMore() -> Bool {
        tap(["More", "More Options", "Show More", "ellipsis", "More actions", "ellipsis.circle"], timeout: 3)
    }

    /// Opens the "..." menu and taps one of `items` if it is there and enabled; otherwise closes the menu.
    func openMoreAndTap(_ items: [String]) -> Bool {
        guard openMore() else { return false }
        pause(0.6)
        for item in items {
            let predicate = NSPredicate(format: "label == %@", item)
            for query in [photos.buttons, photos.menuItems, photos.cells, photos.staticTexts] {
                let matches = query.matching(predicate)
                if matches.count > 0 {
                    let element = matches.element(boundBy: 0)
                    if element.isEnabled && element.isHittable {
                        element.tap()
                        pause(1.2)
                        note("menu: \(item)")
                        return true
                    }
                    note("menu: \(item) is there but not enabled")
                    dismissMenu()
                    return false
                }
            }
        }
        note("menu: none of \(items)")
        dismissMenu()
        return false
    }

    /// Closes a menu, sheet or context menu by tapping near the top of the screen, just below the status bar.
    /// (A tap on the status bar itself, as at dy 0.03, scrolls the grid to its top when nothing is open.)
    func dismissMenu() {
        photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.075)).tap()
        pause()
    }

    func goBack() {
        let back = photos.navigationBars.buttons.element(boundBy: 0)
        if back.exists && back.isHittable {
            back.tap()
        } else {
            photos.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: photos.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        pause()
    }

    func closeViewer() {
        if !tap(["All Photos", "Back", "Days", "Close"], timeout: 1.5) {
            center().press(forDuration: 0.05, thenDragTo: photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        pause()
    }

    /// Photo, card and album items on screen, as tap points ordered top to bottom, left to right (so `.last` is
    /// the newest photo in a grid). Since iOS 14 Photos draws its grids itself, so an item may be an image
    /// (labelled like "Photo, 8 January 2022") in a scroll view rather than a collection-view cell; one snapshot
    /// finds either kind, and is far faster than asking every cell whether it is hittable. Items whose centre
    /// is under the top or bottom bars are left out. The log says which kind was used.
    func visibleCells() -> [XCUICoordinate] {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let root = try? photos.snapshot() {
                let screen = root.frame
                var cells: [CGRect] = [], scrollerImages: [CGRect] = [], images: [CGRect] = []
                collectItems(root, inScroller: false, cells: &cells, scrollerImages: &scrollerImages, images: &images)
                let large = images.filter { $0.width >= 60 && $0.height >= 60 }
                for (kind, frames) in [("cells", cells), ("images in a scroll view", scrollerImages), ("large images", large)] {
                    let picked = frames.filter { isItem($0, on: screen) }
                        .sorted { $0.midY != $1.midY ? $0.midY < $1.midY : $0.midX < $1.midX }
                    guard !picked.isEmpty else { continue }
                    note("grid items: \(picked.count) \(kind)")
                    let origin = photos.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                    return picked.map { origin.withOffset(CGVector(dx: $0.midX - screen.minX, dy: $0.midY - screen.minY)) }
                }
            }
            pause(0.5)
        } while Date() < deadline
        note("NOT FOUND any grid item (no cell or image on screen)")
        return []
    }

    func collectItems(_ s: XCUIElementSnapshot, inScroller: Bool,
                      cells: inout [CGRect], scrollerImages: inout [CGRect], images: inout [CGRect]) {
        if s.elementType == .cell { cells.append(s.frame); return }
        if s.elementType == .image {
            images.append(s.frame)
            if inScroller { scrollerImages.append(s.frame) }
        }
        let scroller = inScroller || s.elementType == .scrollView || s.elementType == .collectionView
            || s.elementType == .table
        for child in s.children {
            collectItems(child, inScroller: scroller, cells: &cells, scrollerImages: &scrollerImages, images: &images)
        }
    }

    /// At least 30 points square, with its centre on screen and clear of the top bar (13 %) and the tab bar
    /// plus the Years/Months/Days/All Photos switcher (18 %).
    func isItem(_ r: CGRect, on screen: CGRect) -> Bool {
        guard r.width >= 30, r.height >= 30, r.midX.isFinite, r.midY.isFinite else { return false }
        let top = screen.minY + screen.height * 0.13
        let bottom = screen.maxY - screen.height * 0.18
        return r.midX > screen.minX && r.midX < screen.maxX && r.midY > top && r.midY < bottom
    }

    func openSomePhoto() -> Bool {
        let cells = visibleCells()
        guard !cells.isEmpty else { note("NOT FOUND any photo to open"); return false }
        cells[cells.count / 2].tap()
        pause(1.5)
        return true
    }

    // MARK: capture

    func capture(_ name: String) {
        pause(1.0)
        // Names joined as strings: URL.appendingPathExtension may refuse a two-part extension such as "tree.txt"
        // and hand back the bare URL, and then the PNG, tree and JSON would overwrite one another.
        let base = outDir.path + "/" + name
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: base + ".png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? photos.debugDescription.write(toFile: base + ".tree.txt", atomically: true, encoding: .utf8)
        if let snapshot = try? photos.snapshot() {
            var rows: [[String: Any]] = []
            walk(snapshot, depth: 0, into: &rows)
            // JSONSerialization raises an Objective-C exception (killing the runner) on anything invalid, so check first.
            if JSONSerialization.isValidJSONObject(rows),
               let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: base + ".elements.json"))
            } else {
                note("elements.json skipped for \(name): not valid JSON")
            }
        }
        note("captured \(name)")
    }

    func walk(_ s: XCUIElementSnapshot, depth: Int, into rows: inout [[String: Any]]) {
        let f = s.frame
        // An off-screen or empty frame can be CGRect.null, whose origin is infinite: write -1 instead.
        func num(_ v: CGFloat) -> Double { v.isFinite ? Double(v) : -1 }
        rows.append(["depth": depth, "type": typeName(s.elementType), "identifier": s.identifier,
                     "label": s.label, "title": s.title, "value": String(describing: s.value ?? ""),
                     "x": num(f.origin.x), "y": num(f.origin.y),
                     "w": num(f.size.width), "h": num(f.size.height),
                     "selected": s.isSelected, "enabled": s.isEnabled])
        for child in s.children { walk(child, depth: depth + 1, into: &rows) }
    }

    func writeMeta() {
        let frame = photos.frame
        let shot = XCUIScreen.main.screenshot().image
        let meta: [String: Any] = [
            "windowPointsW": Double(frame.size.width), "windowPointsH": Double(frame.size.height),
            "screenshotPixelsW": Double(shot.size.width * shot.scale), "screenshotPixelsH": Double(shot.size.height * shot.scale),
            "scale": Double(shot.scale),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "",
            "deviceName": ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""]
        if JSONSerialization.isValidJSONObject(meta),
           let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outDir.appendingPathComponent("meta.json"))
        }
    }

    func typeName(_ t: XCUIElement.ElementType) -> String {
        switch t {
        case .application: return "application"
        case .window: return "window"
        case .other: return "other"
        case .group: return "group"
        case .button: return "button"
        case .staticText: return "staticText"
        case .image: return "image"
        case .cell: return "cell"
        case .collectionView: return "collectionView"
        case .scrollView: return "scrollView"
        case .table: return "table"
        case .tabBar: return "tabBar"
        case .tab: return "tab"
        case .navigationBar: return "navigationBar"
        case .toolbar: return "toolbar"
        case .segmentedControl: return "segmentedControl"
        case .searchField: return "searchField"
        case .textField: return "textField"
        case .menu: return "menu"
        case .menuItem: return "menuItem"
        case .sheet: return "sheet"
        case .alert: return "alert"
        case .switch: return "switch"
        case .slider: return "slider"
        case .map: return "map"
        case .keyboard: return "keyboard"
        case .key: return "key"
        case .link: return "link"
        case .pageIndicator: return "pageIndicator"
        case .progressIndicator: return "progressIndicator"
        case .activityIndicator: return "activityIndicator"
        case .picker: return "picker"
        case .popover: return "popover"
        case .webView: return "webView"
        case .icon: return "icon"
        default: return "type\(t.rawValue)"
        }
    }
}
