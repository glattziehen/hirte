import XCTest

/// Real continuous XCTest touches in the production sidebar and terminal. Generic demo only.
final class TerminalScrollUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCoasting() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-appearance", env["HIRTE_UI_APPEARANCE"] ?? "light",
                               "-hirte.demo", "YES", "-hirte.demo.dense", "YES",
                               "-terminal.watch", "NO", "-terminal.fontSize", "13"]
        app.launchEnvironment["HIRTE_SCROLL_TRACE"] = "1"
        for key in ["HIRTE_COAST_REFERENCE", "HIRTE_SCROLL_TUI_MS", "HIRTE_COAST_OUTPUT"] {
            if let value = env[key], !value.isEmpty { app.launchEnvironment[key] = value }
        }
        app.launch()
        let first = app.descendants(matching: .any).matching(identifier: "t1").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        let screen = app.descendants(matching: .any).matching(identifier:
            env["HIRTE_COAST_REFERENCE"] == "1" ? "coast-reference" : "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        func drag(_ element: XCUIElement, distance: CGFloat, velocity: CGFloat, hold: TimeInterval) {
            print("COAST_GESTURE time=\(ProcessInfo.processInfo.systemUptime) velocity=\(velocity) distance=\(distance) hold=\(hold)")
            let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: distance > 0 ? 0.3 : 0.7))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                        withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: hold)
        }
        if env["HIRTE_COAST_OUTPUT"] == "1" {
            // Start near the live end with enough retained history on both sides of a
            // page prune. The stream continues through the actual native deceleration.
            Thread.sleep(forTimeInterval: 1.5)
            drag(screen, distance: 180, velocity: 600, hold: 0)
            let live = app.buttons["Scrolled back. Tap to return to the live screen."]
            XCTAssertTrue(live.waitForExistence(timeout: 3))
            live.tap()
            Thread.sleep(forTimeInterval: 1.5)
            drag(screen, distance: 180, velocity: 1200, hold: 0)
        } else {
            let sidebar = app.collectionViews.firstMatch
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
            drag(sidebar, distance: -180, velocity: 600, hold: 0)
            for velocity: CGFloat in [240, 600, 1200] {
                drag(screen, distance: 180, velocity: velocity, hold: 0)
            }
            drag(screen, distance: -240, velocity: 160, hold: 0.4)
        }
        // Let the opt-in bounded trace flush only after all native motion ended.
        Thread.sleep(forTimeInterval: 2)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "coasting-final"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testContinuousDragAndRelease() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "light"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-appearance", appearance, "-hirte.demo", "YES", "-hirte.demo.dense", "YES",
                               "-terminal.watch", "NO", "-terminal.fontSize", "13"]
        app.launchEnvironment["HIRTE_SCROLL_TRACE"] = "1"
        if let delay = ProcessInfo.processInfo.environment["HIRTE_SCROLL_TUI_MS"] {
            app.launchEnvironment["HIRTE_SCROLL_TUI_MS"] = delay
        }
        app.launch()
        let first = app.descendants(matching: .any).matching(identifier: "t1").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        let sidebar = app.collectionViews.firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        func drag(_ element: XCUIElement, down: Bool, velocity: CGFloat, hold: TimeInterval) {
            let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: down ? 0.3 : 0.7))
            let end = start.withOffset(CGVector(dx: 0, dy: down ? 240 : -240))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: hold)
        }
        drag(sidebar, down: false, velocity: 160, hold: 0.4)
        drag(sidebar, down: true, velocity: 600, hold: 0)
        drag(screen, down: true, velocity: 160, hold: 0.4)
        drag(screen, down: true, velocity: 600, hold: 0)
        drag(screen, down: false, velocity: 160, hold: 0.4)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "scroll-" + appearance
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
            try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("scroll-" + appearance + ".png"))
        }
    }

    @MainActor
    func testWatchPinchKeyboardAndEdgeDrag() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "light"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-appearance", appearance, "-hirte.demo", "YES", "-hirte.demo.dense", "YES",
                               "-terminal.watch", "NO", "-terminal.fontSize", "13"]
        app.launchEnvironment["HIRTE_SCROLL_TRACE"] = "1"
        app.launch()
        let first = app.descendants(matching: .any).matching(identifier: "t1").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        // A vertical drag in the edge zone must still scroll; a horizontal drag hides the list.
        let edge = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 0, dy: 130)),
                   withVelocity: XCUIGestureVelocity(rawValue: 160), thenHoldForDuration: 0.3)
        XCTAssertTrue(app.staticTexts["Scrolled back. Tap to return to the live screen."].exists)
        screen.pinch(withScale: 1.25, velocity: 1)
        app.terminalAction("Watch Only").tap()
        XCTAssertTrue(app.terminalAction("Take Over").waitForExistence(timeout: 5))
        let start = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 160)),
                    withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0)
        XCTAssertTrue(app.terminalAction("Take Over").exists, "History scrolling never takes over")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "watch-scroll-" + appearance
        attachment.lifetime = .keepAlways
        add(attachment)
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 1) { hint.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Ordinary tap still focuses and takes over")
        XCTAssertTrue(app.terminalAction("Watch Only").exists)
        app.terminalAction("Hide Keyboard").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let hide = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        hide.press(forDuration: 0.05, thenDragTo: hide.withOffset(CGVector(dx: -150, dy: 0)),
                   withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0)
        XCTAssertFalse(app.buttons["Agents"].isHittable, "The horizontal edge swipe still hides the sidebar")
    }
}
