import XCTest

/// Captures for judging the sidebar's composition: both views, default and every field, standard and
/// dense data, a selected row at two heights. Saves into `TEST_RUNNER_HIRTE_SHOTS`, named by device
/// width and appearance (`TEST_RUNNER_HIRTE_UI_APPEARANCE`). What the app remembers comes from launch
/// arguments, checked in the app itself, so every shot shows what its name says.
final class DesignPassUITests: XCTestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "dark" }
    private static let defaultFields = ["account", "agent", "branch", "directory", "icon", "progress", "project", "time"]
    private static let everyField = defaultFields + ["message", "name", "space"]

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCaptureStandard() throws {
        XCUIDevice.shared.orientation = .portrait
        var app = launch(fields: Self.defaultFields, mode: "individual", view: "agents")
        shot("agents")
        app.buttons["Terminals"].tap()
        XCTAssertTrue(row("t5", app).waitForExistence(timeout: 5))
        shot("terminals")
        app.terminate()

        app = launch(fields: Self.defaultFields, mode: "nested", view: "agents")
        XCTAssertTrue(row("t2", app).waitForExistence(timeout: 5))
        shot("family")
        app.terminate()

        app = launch(fields: Self.everyField, mode: "nested", view: "agents")
        XCTAssertTrue(row("t2", app).waitForExistence(timeout: 5))
        shot("family-every-field")
        app.terminate()
    }

    @MainActor
    func testCaptureDense() throws {
        XCUIDevice.shared.orientation = .portrait
        var app = launch(fields: Self.defaultFields, mode: "individual", view: "agents", dense: true)
        shot("dense-agents")
        app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 0.6)
        shot("dense-agents-scrolled")
        app.terminate()

        app = launch(fields: Self.defaultFields, mode: "nested", view: "agents", dense: true)
        shot("dense-nested")
        app.terminate()

        app = launch(fields: Self.defaultFields, mode: "individual", view: "terminals", dense: true)
        shot("dense-terminals")
        reveal(row("t18", app), app)
        shot("dense-terminals-scrolled")
        app.terminate()

        app = launch(fields: Self.everyField, mode: "nested", view: "agents", dense: true)
        shot("dense-nested-every-field")
        app.terminate()
    }

    /// A selected row: the same corners at about 44 points as at over 100. Only next to the detail.
    @MainActor
    func testCaptureSelection() throws {
        XCUIDevice.shared.orientation = .portrait
        var app = launch(fields: Self.defaultFields, mode: "individual", view: "terminals")
        try XCTSkipUnless(app.buttons["Hide Sidebar"].waitForExistence(timeout: 5), "only next to the detail")
        select("t5", app)
        shot("selected-low")
        // A key takes focus from the list to the terminal: the row looks the same.
        app.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(row("t5", app).isSelected, "it stays selected")
        shot("selected-low-inactive")
        select("t3", app)
        shot("selected-two-lines")
        // The same cells selected again, with one between them.
        select("t5", app)
        select("t3", app)
        shot("selected-two-lines-again")
        app.terminate()

        app = launch(fields: Self.defaultFields, mode: "nested", view: "agents")
        select("t2", app)
        shot("selected-child")
        app.terminate()

        app = launch(fields: Self.everyField, mode: "nested", view: "agents", dense: true)
        select("t8", app)
        let parent = row("t8", app)
        XCTAssertTrue(parent.isSelected, "the list's own selection")
        XCTAssertGreaterThan(parent.frame.height, 80, "a tall row")
        print("DESIGN-ROW t8 height \(parent.frame.height)")
        shot("selected-tall")
        app.terminate()
    }

    /// The floating controls keep their sizes and a gap below the edge the rows scroll under.
    @MainActor
    func testModeBarGeometry() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(fields: Self.defaultFields, mode: "individual", view: "agents", dense: true)
        let controls = [app.buttons["Agents"], app.buttons["Terminals"], app.buttons["New Terminal"]]
        for control in controls {
            XCTAssertGreaterThanOrEqual(control.frame.height, 44 - 1e-6, control.label)
            XCTAssertGreaterThanOrEqual(control.frame.minY - app.modeBarTop, 12 - 1e-6, control.label)
        }
        shot("mode-bar")
        XCTAssertEqual(app.buttons["New Terminal"].frame.height, 48, accuracy: 0.5)
        print("DESIGN-BAR top=\(app.modeBarTop) plus=\(app.buttons["New Terminal"].frame) agents=\(app.buttons["Agents"].frame)")
    }

    /// With the icon and the time off, a child's mark is all that says its state: it has to say it.
    @MainActor
    func testStatusIsSpokenWithoutIconAndTime() throws {
        XCUIDevice.shared.orientation = .portrait
        let fields = Self.defaultFields.filter { $0 != "icon" && $0 != "time" }
        let app = launch(fields: fields, mode: "nested", view: "agents")
        let child = row("t2", app)
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        XCTAssertTrue(child.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Working' OR label == 'Done'")).firstMatch.waitForExistence(timeout: 5),
                      "the state of a child without icon and time")
        shot("no-icon-no-time")
    }

    /// Selecting a row moves nothing: titles close to wrapping keep their lines, in both views.
    @MainActor
    func testSelectionKeepsRowHeights() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(fields: Self.defaultFields, mode: "individual", view: "agents", dense: true)
        try XCTSkipUnless(app.buttons["Hide Sidebar"].waitForExistence(timeout: 5), "only next to the detail")
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        func check(_ addresses: [String]) {
            var heights: [String: CGFloat] = [:]
            for address in addresses {
                reveal(row(address, app), app)
                heights[address] = row(address, app).frame.height
            }
            for address in addresses {
                reveal(row(address, app), app)
                row(address, app).tap()
                XCTAssertTrue(screen.waitForExistence(timeout: 10), "\(address) attaches")
                Thread.sleep(forTimeInterval: 0.5)
                XCTAssertTrue(row(address, app).isSelected, "\(address) is selected")
                for other in addresses where row(other, app).exists {
                    XCTAssertEqual(row(other, app).frame.height, heights[other] ?? 0, accuracy: 1,
                                   "\(other) keeps its height with \(address) selected")
                }
                print("DESIGN-HEIGHT \(address) \(heights[address] ?? 0) -> \(row(address, app).frame.height)")
            }
        }
        // Working or waiting: they stay in their sections when looked at, done ones move on.
        check(["t2", "t13", "t1", "t8", "t6", "t10", "t7"])
        shot("heights-agents")
        app.buttons["Terminals"].tap()
        Thread.sleep(forTimeInterval: 1)
        check(["t1", "t11", "t10", "t18", "t13"])
        shot("heights-terminals")
    }

    /// A selected row under a finger: what the list draws for a swipe and for a long press.
    @MainActor
    func testCaptureRowInteractions() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(fields: Self.defaultFields, mode: "individual", view: "terminals")
        try XCTSkipUnless(app.buttons["Hide Sidebar"].waitForExistence(timeout: 5), "only next to the detail")
        select("t3", app)
        let selected = row("t3", app)
        let start = selected.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        // Held, with a screenshot taken meanwhile: the press's own look.
        let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"]
        let width = Int(XCUIScreen.main.screenshot().image.size.width)
        let appearance = appearance
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
            let data = XCUIScreen.main.screenshot().pngRepresentation
            if let folder {
                try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(width)-\(appearance)-row-pressed.png"))
            }
        }
        row("t5", app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.3, thenDragTo: row("t5", app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        Thread.sleep(forTimeInterval: 0.8)
        select("t3", app)
        start.press(forDuration: 0.05, thenDragTo: selected.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        XCTAssertTrue(app.buttons["Kill"].waitForExistence(timeout: 5), "the swipe's action")
        Thread.sleep(forTimeInterval: 0.4)
        shot("row-swiped-selected")
        app.collectionViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        Thread.sleep(forTimeInterval: 0.6)
        selected.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Copy Address"].waitForExistence(timeout: 5), "the menu opens")
        Thread.sleep(forTimeInterval: 0.6)
        shot("row-context-menu-selected")
    }

    /// A key reaches the list: from no selection it selects a row and opens that terminal, and the
    /// terminal then takes the keys. Arrow keys between rows while a terminal is open aren't covered:
    /// those go to the terminal. XCTest's keys don't always reach the app's focus system (the same
    /// key selected a row in one run and nothing in another): then it's reported as not verified.
    @MainActor
    func testKeyboardSelection() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(fields: Self.defaultFields, mode: "individual", view: "agents")
        try XCTSkipUnless(app.buttons["Hide Sidebar"].waitForExistence(timeout: 5), "only next to the detail")
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        shot("keyboard-0-start")
        XCTAssertFalse(screen.exists, "nothing is open yet")
        XCTAssertFalse(row("t3", app).isSelected)
        app.typeKey(.downArrow, modifierFlags: [])
        try XCTSkipUnless(screen.waitForExistence(timeout: 3), "the key didn't reach the list: keyboard selection not verified in this run")
        shot("keyboard-1-down")
        XCTAssertTrue(row("t3", app).isSelected, "the first row is the list's selection")
        XCTAssertTrue(app.staticTexts["Run the database migration?"].exists, "and its terminal opened")
    }

    /// A phone's terminal screen: the title, its context and the shortened toolbar.
    @MainActor
    func testCaptureTerminalScreen() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(fields: Self.defaultFields, mode: "individual", view: "agents", dense: true)
        select("t1", app)
        Thread.sleep(forTimeInterval: 1)
        // What a row says while it's being answered: its task and where it works.
        XCTAssertTrue(app.staticTexts["Rework the checkout flow"].exists, "the title shows")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'feature/checkout-rework'")).firstMatch.exists,
                      "and its context")
        shot("terminal-agent")
        if app.buttons["More"].exists {
            app.openMore()
            for action in ["Show Keyboard", "Live Activity Settings…", "Info"] {
                XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), action)
            }
            shot("terminal-more")
        }
    }

    @MainActor
    private func select(_ address: String, _ app: XCUIApplication) {
        let target = row(address, app)
        reveal(target, app)
        target.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
            .waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.5)
        // The shot is named for this row: it has to be the one selected, and stay so. On a phone the
        // terminal has been pushed over the list by now, and its title says which one opened.
        if app.buttons["Hide Sidebar"].exists {
            XCTAssertTrue(target.isSelected, "\(address) is the selected row")
        }
    }

    /// Scrolls until the whole element is above the floating bar. A list only makes the rows on
    /// screen: a row further down isn't there to query yet, which says nothing about the row.
    @MainActor
    @discardableResult
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) -> Int {
        func inView() -> Bool { element.exists && element.isHittable && element.frame.maxY <= app.modeBarTop }
        // Twice in a row: a list that has just been swapped in still moves its rows.
        func settledInView() -> Bool {
            guard inView() else { return false }
            Thread.sleep(forTimeInterval: 0.4)
            return inView()
        }
        var swipes = 0
        // Down the list first, then back up: a view returns to where it was left.
        while swipes < 12, !settledInView() {
            if swipes < 5 {
                app.collectionViews.firstMatch.swipeUp(velocity: .slow)
            } else {
                app.collectionViews.firstMatch.swipeDown(velocity: .slow)
            }
            Thread.sleep(forTimeInterval: 0.3)
            swipes += 1
        }
        XCTAssertTrue(swipes < 12, "\(element) after \(swipes) swipes: exists \(element.exists), window \(app.windows.firstMatch.frame)")
        return swipes
    }

    @MainActor
    private func row(_ address: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: address).firstMatch
    }

    @MainActor
    private func launch(fields: [String], mode: String, view: String, dense: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        let list = fields.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"{"fields":[\#(list)],"mode":["\#(mode)"],"sort":["lastStateChange"]}"#
        // An argument is read as an old-style property list: bare JSON would be dropped silently,
        // and the app would show what it has saved instead.
        let preferences = "\"" + json.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearance", appearance,
                                "-hirte.demo", "YES", "-hirte.demo.dense", dense ? "YES" : "NO",
                                "-agents.overview", preferences, "-terminals.collapsed", ""]
        app.launch()
        // Not a launch argument: those win over what the app saves, so switching wouldn't stick.
        let agents = app.buttons["Agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 15))
        agents.tap()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch.exists,
                       "nothing has opened a terminal: no shot of a list that something else has changed")
        verifyConfiguration(app, fields: fields, mode: mode, dense: dense)
        if view == "terminals" { app.buttons["Terminals"].tap() }
        Thread.sleep(forTimeInterval: 1)
        return app
    }

    /// The app really runs with what the shot's name will claim: the view from its menu, the fields
    /// from a message that only shows with its field on, and the data from a dense scene's row.
    @MainActor
    private func verifyConfiguration(_ app: XCUIApplication, fields: [String], mode: String, dense: Bool) {
        let menu = app.buttons["agent-overview-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        let title = mode == "nested" ? "Nested" : "Individual"
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", ": \(title),"), object: menu)], timeout: 5), .completed,
                       "runs as \(title): \(menu.label)")
        let waiting = row(dense ? "t10" : "t3", app)
        XCTAssertTrue(waiting.waitForExistence(timeout: 10))
        let swipes = min(reveal(waiting, app), 5)
        XCTAssertEqual(waiting.staticTexts["npm run migrate"].exists, fields.contains("message"),
                       "the status message follows its field")
        XCTAssertEqual(row("t10", app).exists, dense, "dense data only when asked for")
        for _ in 0..<(swipes * 2) { app.collectionViews.firstMatch.swipeDown(velocity: .fast) }
    }

    @MainActor
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
            let size = Int(screenshot.image.size.width)
            try? screenshot.pngRepresentation.write(
                to: URL(fileURLWithPath: folder).appendingPathComponent("\(size)-\(appearance)-\(name).png"))
        }
    }
}
