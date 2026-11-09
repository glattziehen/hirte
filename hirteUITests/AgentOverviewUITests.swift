import XCTest

final class AgentOverviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testStatusModesAndRowCustomization() throws {
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "dark"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-appearance", appearance]
        app.launch()
        if app.buttons["Try the Demo"].waitForExistence(timeout: 3) { app.buttons["Try the Demo"].tap() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "t3").firstMatch.waitForExistence(timeout: 10))
        if app.buttons["Agents"].exists { app.buttons["Agents"].tap() }
        openMenu(app)
        app.buttons["Customize Rows…"].tap()
        let done = app.buttons["agent-overview-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable)
        let form = app.collectionViews["agent-overview-settings"]
        let initialReset = app.buttons["Reset to Defaults"]
        for _ in 0..<5 where !initialReset.isHittable { form.swipeUp() }
        XCTAssertTrue(initialReset.isHittable)
        XCTAssertTrue(done.isHittable)
        shot("overview-customize-scrolled-" + appearance)
        if initialReset.isEnabled { initialReset.tap() }
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        shot("overview-individual-" + appearance)

        openMenu(app)
        shot("overview-menu-" + appearance)
        XCTAssertTrue(app.buttons["Nested"].waitForExistence(timeout: 5))
        app.buttons["Nested"].tap()
        XCTAssertTrue(app.buttons["children-t1"].waitForExistence(timeout: 5))
        shot("overview-nested-" + appearance)
        app.buttons["children-t1"].tap()
        app.buttons["children-t1"].tap()

        openMenu(app)
        app.buttons["Customize Rows…"].tap()
        XCTAssertTrue(app.navigationBars["Agent Overview"].waitForExistence(timeout: 5))
        shot("overview-customize-" + appearance)
        let branch = app.switches["Branch"]
        // Hittable isn't enough: on a wide sheet the row can rest half outside its lower edge.
        for _ in 0..<4 where !branch.isHittable || branch.frame.maxY > form.frame.maxY { form.swipeUp() }
        XCTAssertTrue(branch.isHittable)
        XCTAssertLessThanOrEqual(branch.frame.maxY, form.frame.maxY, "the whole row is in the sheet")
        XCTAssertEqual(branch.value as? String, "1")
        branch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: branch)], timeout: 3), .completed)
        let reset = app.buttons["Reset to Defaults"]
        for _ in 0..<4 where !reset.isHittable { form.swipeUp() }
        XCTAssertTrue(reset.isHittable)
        reset.tap()
        for _ in 0..<4 where !branch.isHittable { form.swipeDown() }
        XCTAssertEqual(branch.value as? String, "1")
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        shot("overview-reset-" + appearance)
    }

    @MainActor
    func testSelectedSidebarRows() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "dark"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-appearance", appearance, "-hirte.demo", "YES"]
        app.launch()
        let agents = app.buttons["Agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 10))
        // Rotation is asynchronous: while the window resizes, taps can miss a row or an open menu.
        // (Its size alone says nothing about the rotation: iPadOS may show the app in a free window.)
        XCTAssertEqual(XCUIDevice.shared.orientation, .landscapeLeft)
        let window = app.windows.firstMatch
        var size = window.frame.size
        var steady = 0
        for _ in 0..<40 where steady < 3 {
            Thread.sleep(forTimeInterval: 0.25)
            steady = window.frame.size == size ? steady + 1 : 0
            size = window.frame.size
        }
        XCTAssertEqual(steady, 3, "the window has settled")
        agents.tap()
        // The view is remembered across launches: choose it, so each shot shows what its name says.
        choose("Individual", app)
        let agent = app.descendants(matching: .any).matching(identifier: "t1").firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        // Its visible title, inside the cell: first that the row gets selected, then that it attaches.
        agent.staticTexts.firstMatch.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"), object: agent)], timeout: 5), .completed, "the row is selected")
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "the selected terminal attaches")
        XCTAssertTrue(agent.isHittable, "The selected row remains visible beside the terminal")
        shot("selected-agent-" + appearance)
        choose("Nested", app)
        let children = app.buttons["children-t1"]
        XCTAssertTrue(children.waitForExistence(timeout: 5))
        XCTAssertTrue(children.isHittable)
        shot("selected-nested-agent-" + appearance)
        children.tap()
        shot("selected-nested-closed-agent-" + appearance)
        children.tap()
        app.buttons["Terminals"].tap()
        let terminal = app.descendants(matching: .any).matching(identifier: "t5").firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        XCTAssertTrue(terminal.isHittable)
        shot("selected-terminal-" + appearance)
    }

    /// Picks an agent view from the menu and waits until the list shows it.
    @MainActor
    private func choose(_ mode: String, _ app: XCUIApplication) {
        openMenu(app)
        let item = app.buttons[mode]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5), "the menu closes")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", ": \(mode),"),
            object: app.buttons["agent-overview-menu"])], timeout: 5), .completed, "the list shows \(mode)")
    }

    @MainActor
    private func openMenu(_ app: XCUIApplication) {
        let menu = app.buttons["agent-overview-menu"]
        if !menu.exists {
            let more = app.buttons["TopOverflowBarButtonItem"].firstMatch
            if more.exists { more.tap() }
        }
        if menu.waitForExistence(timeout: 2) {
            menu.tap()
        } else {
            let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View and Sort'")).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            item.tap()
        }
    }

    @MainActor
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
