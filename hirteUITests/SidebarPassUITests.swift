import XCTest

/// The sidebar's two views as the UI/UX pass left them: what a terminal row says, stable bar and
/// header actions and readable controls. Screenshots go to `TEST_RUNNER_HIRTE_SHOTS`.
final class SidebarPassUITests: XCTestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "dark" }

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testTerminalRowsAndHeaderActions() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        let plus = app.buttons["New Terminal"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        XCTAssertTrue(plus.isHittable, "in the bar over the list in the Agents view")
        XCTAssertGreaterThanOrEqual(plus.frame.width, 44 - 1e-6)
        XCTAssertGreaterThanOrEqual(plus.frame.height, 44 - 1e-6)
        let agentsPlus = plus.frame

        app.buttons["Terminals"].tap()
        // A session says what it's working on; its own name stays next to it.
        XCTAssertTrue(app.staticTexts["Run the database migration?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["zsh"].exists, "a shell keeps its name")
        XCTAssertTrue(app.staticTexts["dev-server"].exists, "a named terminal keeps its name")
        XCTAssertEqual(plus.frame, agentsPlus, "the plus doesn't move between the views")
        shot("sidebar-terminals-\(appearance)")

        // Coming back to a list that was at its top leaves it there: the first header stays in view.
        app.buttons["Agents"].tap()
        XCTAssertTrue(app.buttons["agent-overview-menu"].waitForExistence(timeout: 5))
        app.buttons["Terminals"].tap()
        let firstHeader = app.staticTexts["website"]
        XCTAssertTrue(firstHeader.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertGreaterThanOrEqual(firstHeader.frame.minY, app.sidebarTitleBottom,
                                    "the first space's header isn't under the title")

        // A space offers a new terminal without its context menu.
        let add = app.buttons["New Terminal in website"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isHittable)
        XCTAssertGreaterThanOrEqual(add.frame.minY, app.sidebarTitleBottom,
                                    "the whole button is below the title, or a tap lands on the bar above")
        XCTAssertLessThanOrEqual(add.frame.maxY, app.modeBarTop, "and above the bar below")
        XCTAssertGreaterThanOrEqual(add.frame.width, 44 - 1e-6)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44 - 1e-6)
        add.tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))

        // Remembered across launches, like the other sections: it may be open already.
        let clear = app.buttons["Clear"]
        let finished = app.staticTexts["Finished"]
        reveal(finished, in: app)
        if !clear.exists { finished.tap() }
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        shot("sidebar-terminals-finished-\(appearance)")
    }

    @MainActor
    func testSelectedRowsAndFamilies() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        try XCTSkipUnless(app.buttons["Hide Sidebar"].waitForExistence(timeout: 5),
                          "a selected row stays in view only beside the terminal")
        // The view is remembered across launches: choose it, so each shot shows what its name says.
        let menu = app.buttons["agent-overview-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        choose("Individual", app)
        let agent = app.descendants(matching: .any).matching(identifier: "t1").firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 10))
        shot("sidebar-agents-\(appearance)")
        agent.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
            .waitForExistence(timeout: 5))
        shot("sidebar-agent-selected-\(appearance)")

        choose("Nested", app)
        let children = app.buttons["children-t1"]
        XCTAssertTrue(children.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(children.frame.height, 44 - 1e-6)
        XCTAssertGreaterThanOrEqual(children.frame.width, 44 - 1e-6)
        let status = app.buttons["Working"].firstMatch
        XCTAssertGreaterThanOrEqual(status.frame.height, 44, "the status explains itself on a full target")
        XCTAssertGreaterThanOrEqual(status.frame.width, 44 - 1e-6)
        shot("sidebar-family-open-selected-\(appearance)")
        children.tap()
        let child = app.descendants(matching: .any).matching(identifier: "t2").firstMatch
        XCTAssertTrue(child.waitForNonExistence(timeout: 5), "collapsing hides the child")
        shot("sidebar-family-closed-selected-\(appearance)")
        children.tap()
        XCTAssertTrue(child.waitForExistence(timeout: 5))

        app.buttons["Terminals"].tap()
        let shell = app.descendants(matching: .any).matching(identifier: "t5").firstMatch
        XCTAssertTrue(shell.waitForExistence(timeout: 5))
        shell.tap()
        XCTAssertTrue(shell.isHittable)
        shot("sidebar-terminal-selected-\(appearance)")
        let waiting = app.descendants(matching: .any).matching(identifier: "t3").firstMatch
        waiting.tap()
        shot("sidebar-terminal-agent-selected-\(appearance)")
    }

    /// Every field on: a family stays one thing, and no enabled field gets lost. Set up through the
    /// real menu and form, and reset through them at the end.
    @MainActor
    func testFamilyWithEveryField() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        let besideTerminal = app.buttons["Hide Sidebar"].waitForExistence(timeout: 5)
        let menu = app.buttons["agent-overview-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        setFields(app, ["Space", "Name", "Status message"], on: true)

        choose("Nested", app)
        let children = app.buttons["children-t1"]
        reveal(children, in: app)
        XCTAssertTrue(children.exists)
        let child = app.descendants(matching: .any).matching(identifier: "t2").firstMatch
        if !child.waitForExistence(timeout: 2) { children.tap() }
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'Work'")).firstMatch.exists,
                      "provider and account stay on a child")
        shot("sidebar-many-open-\(appearance)")
        if besideTerminal {
            app.descendants(matching: .any).matching(identifier: "t1").firstMatch.tap()
            shot("sidebar-many-open-selected-\(appearance)")
            children.tap()
            XCTAssertTrue(child.waitForNonExistence(timeout: 5))
            shot("sidebar-many-closed-selected-\(appearance)")
            children.tap()
            XCTAssertTrue(child.waitForExistence(timeout: 5))
            child.tap()
            shot("sidebar-many-child-selected-\(appearance)")
        }

        resetRows(app)
    }

    /// Every field at the largest text the sidebar has to carry: set up at normal size through the
    /// real settings, then a relaunch.
    @MainActor
    func testEveryFieldAtLargeText() throws {
        XCUIDevice.shared.orientation = .portrait
        var app = launch()
        XCTAssertTrue(app.buttons["agent-overview-menu"].waitForExistence(timeout: 5))
        setFields(app, ["Space", "Name", "Status message"], on: true)
        choose("Nested", app)
        app.terminate()

        app = launch(textSize: "UICTContentSizeCategoryAccessibilityXL")
        let besideTerminal = app.buttons["Hide Sidebar"].waitForExistence(timeout: 5)
        shot("sidebar-many-large-top-\(appearance)")
        let children = app.buttons["children-t1"]
        reveal(children, in: app)
        XCTAssertTrue(children.exists)
        XCTAssertGreaterThanOrEqual(children.frame.height, 44 - 1e-6)
        let child = app.descendants(matching: .any).matching(identifier: "t2").firstMatch
        if !child.waitForExistence(timeout: 2) { children.tap() }
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        shot("sidebar-many-large-parent-\(appearance)")
        // The line itself, not just some part of the child, has to come into view.
        let identity = child.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'Work'")).firstMatch
        reveal(identity, in: app)
        // Hittable can still mean under the bar: the shot has to show the whole line.
        for _ in 0..<4 where identity.frame.maxY > app.modeBarTop {
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(identity.isHittable, "provider and account stay on a child")
        XCTAssertLessThanOrEqual(identity.frame.maxY, app.modeBarTop, "the whole line is above the bar")
        XCTAssertTrue(app.buttons["New Terminal"].isHittable, "the bar stays usable at this size")
        shot("sidebar-many-large-child-\(appearance)")
        if besideTerminal {
            identity.tap()
            shot("sidebar-many-large-child-selected-\(appearance)")
        }
        app.buttons["Terminals"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "t1").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["~/projects/website"].exists, "a space's folder is whole, wrapped if need be")
        shot("sidebar-terminals-large-\(appearance)")
        app.terminate()

        app = launch()
        resetRows(app)
    }

    /// Picks an agent view from the menu and waits until the list shows it.
    @MainActor
    private func choose(_ mode: String, _ app: XCUIApplication) {
        let menu = app.buttons["agent-overview-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let item = app.buttons[mode]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5), "the menu closes")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", ": \(mode),"), object: menu)], timeout: 5), .completed,
                       "the list shows \(mode)")
    }

    @MainActor
    private func resetRows(_ app: XCUIApplication) {
        let menu = app.buttons["agent-overview-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        XCTAssertTrue(app.buttons["Customize Rows…"].waitForExistence(timeout: 5))
        app.buttons["Customize Rows…"].tap()
        let form = app.collectionViews["agent-overview-settings"]
        let reset = app.buttons["Reset to Defaults"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        for _ in 0..<8 where !reset.isHittable { form.swipeUp() }
        reset.tap()
        app.buttons["agent-overview-done"].tap()
    }

    @MainActor
    private func setFields(_ app: XCUIApplication, _ names: [String], on: Bool) {
        app.buttons["agent-overview-menu"].tap()
        XCTAssertTrue(app.buttons["Customize Rows…"].waitForExistence(timeout: 5))
        app.buttons["Customize Rows…"].tap()
        let form = app.collectionViews["agent-overview-settings"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        for name in names {
            let toggle = app.switches[name]
            for _ in 0..<10 where !toggle.exists || !toggle.isHittable || toggle.frame.maxY > form.frame.maxY {
                // Tall rows at large text can overshoot it.
                if toggle.exists, toggle.frame.minY < form.frame.minY + 60 { form.swipeDown(velocity: .slow) }
                else { form.swipeUp(velocity: .slow) }
            }
            XCTAssertTrue(toggle.isHittable, name)
            if (toggle.value as? String == "1") != on {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", on ? "1" : "0"), object: toggle)], timeout: 3), .completed, name)
        }
        app.buttons["agent-overview-done"].tap()
        XCTAssertTrue(app.buttons["agent-overview-done"].waitForNonExistence(timeout: 5))
    }

    /// Scrolls the sidebar until the element is there: tall rows can push it out of the list's range.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.waitForExistence(timeout: 2) || !element.isHittable {
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
    }

    @MainActor
    private func launch(textSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-appearance", appearance, "-hirte.demo", "YES"]
        if let textSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launch()
        let agents = app.buttons["Agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 15))
        // After a test that rotated, the window can still be resizing: taps then miss an open menu.
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
        return app
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
