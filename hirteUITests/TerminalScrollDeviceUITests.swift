import XCTest

/// Continuous gestures through the compact terminal, using generic local history only.
final class TerminalScrollDeviceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testHistoryDragReleaseAndWatching() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "light"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-appearance", appearance, "-hirte.demo", "YES", "-hirte.demo.dense", "YES",
                               "-terminal.watch", "NO", "-terminal.fontSize", "13"]
        app.launchEnvironment["HIRTE_SCROLL_TRACE"] = "1"
        app.launch()
        let agents = app.buttons["Agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 10))
        agents.tap()
        let first = app.descendants(matching: .any).matching(identifier: "t1").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            if first.frame.maxY < agents.frame.minY - 12 { break }
            let start = app.collectionViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)),
                        withVelocity: XCUIGestureVelocity(rawValue: 160), thenHoldForDuration: 0.3)
        }
        XCTAssertLessThan(first.frame.maxY, agents.frame.minY - 12, "Reveal the row above the navigation bar")
        XCTAssertTrue(first.isHittable)
        first.tap()
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        func drag(velocity: CGFloat, hold: TimeInterval) {
            let start = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 150)),
                        withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: hold)
        }
        drag(velocity: 160, hold: 0.4)
        XCTAssertTrue(app.staticTexts["Scrolled back. Tap to return to the live screen."].exists)
        save("history-drag")
        drag(velocity: 700, hold: 0)
        save("history-release")
        app.terminalAction("Watch Only").tap()
        XCTAssertTrue(app.terminalAction("Take Over").waitForExistence(timeout: 5))
        drag(velocity: 160, hold: 0.4)
        XCTAssertTrue(app.terminalAction("Take Over").exists, "Scrolling keeps observer mode")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        save("watching-history")
        app.terminate()

        func save(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name + "-" + appearance
            attachment.lifetime = .keepAlways
            add(attachment)
            if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
                try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder)
                    .appendingPathComponent(name + "-" + appearance + ".png"))
            }
        }
    }
}
