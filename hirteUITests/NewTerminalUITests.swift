import XCTest

/// Starting a template on the demo machine: success, a first message that didn't go in, and
/// waiting stopped here. Generic demo only (`HIRTE_DEMO_FIRST_MESSAGE`); no real host or agent.
final class NewTerminalUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch(_ outcome: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-hirte.demo", "YES",
                                "-appearance", ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "light"]
        if let outcome { app.launchEnvironment["HIRTE_DEMO_FIRST_MESSAGE"] = outcome }
        app.launch()
        XCTAssertTrue(row(app, "t1").waitForExistence(timeout: 10))
        app.buttons["Terminals"].tap()
        return app
    }

    private func row(_ app: XCUIApplication, _ address: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: address).firstMatch
    }

    @MainActor
    private func startAgent(_ app: XCUIApplication, shot name: String) {
        app.buttons["New Terminal"].tap()
        let agent = app.buttons["Agent"]
        XCTAssertTrue(agent.waitForExistence(timeout: 5), "the demo lists templates")
        agent.tap()
        XCTAssertTrue(app.staticTexts["Start options"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["start-option-model"].exists)
        shot(name)
        app.buttons["Start"].tap()
    }

    @MainActor
    func testTemplateStartOpensTheNewAgent() throws {
        let app = launch(nil)
        startAgent(app, shot: "new-agent-form")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
            .waitForExistence(timeout: 5), "a sent first message opens the new terminal")
        XCTAssertFalse(app.buttons["Start"].exists, "the sheet closed")
        assertOneNewTerminal(app)
    }

    @MainActor
    func testUnsentFirstMessageOffersTheCreatedTerminalOnce() throws {
        let app = launch("unsent")
        startAgent(app, shot: "new-agent-form-unsent")
        let notice = app.staticTexts["t8 started, but its first message didn't go in."]
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "not shown as an ordinary success")
        XCTAssertTrue(app.staticTexts["the agent was not ready in time"].exists, "the core's reason")
        XCTAssertFalse(app.buttons["Start"].exists, "no second start from this sheet")
        shot("new-agent-unsent")
        app.buttons["Open t8"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
            .waitForExistence(timeout: 5))
        assertOneNewTerminal(app)
    }

    @MainActor
    func testStopWaitingLeavesTheRunAloneAndIgnoresTheLateReply() throws {
        let app = launch("slow")
        startAgent(app, shot: "new-agent-form-slow")
        let stop = app.buttons["Stop Waiting"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "waiting can be stopped")
        shot("new-agent-waiting")
        stop.tap()
        XCTAssertTrue(app.staticTexts["Stopped waiting."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Nothing was stopped on the machine. If the terminal starts, it shows in the list."].exists)
        shot("new-agent-stopped-waiting")
        app.buttons["Close"].tap()
        assertOneNewTerminal(app, "the core created it anyway")
        // The demo replies after 8 s; a late reply must not open anything or start again.
        sleep(10)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch.exists)
        assertOneNewTerminal(app)
        shot("new-agent-after-late-reply")
    }

    /// Exactly one terminal was created (t8, after the demo's seven), whatever the screen size.
    /// Compact (no list beside the terminal): go back with the navigation back button or the edge
    /// gesture. Regular width: the list stays; scroll it to the row. Never the title menu.
    @MainActor
    private func assertOneNewTerminal(_ app: XCUIApplication, _ message: String = "") {
        let newTerminal = app.buttons["New Terminal"]
        if !(newTerminal.exists && newTerminal.isHittable) {
            let back = app.navigationBars.buttons["BackButton"]
            if back.exists && back.isHittable {
                back.tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(
                    forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
            }
            XCTAssertTrue(newTerminal.waitForExistence(timeout: 5) && newTerminal.isHittable, "back at the list")
        }
        let created = row(app, "t8")
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 where !(created.exists && created.isHittable) { list.swipeUp() }
        XCTAssertTrue(created.exists && created.isHittable, "t8 is listed. \(message)")
        XCTAssertFalse(row(app, "t9").exists, "nothing started twice")
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
