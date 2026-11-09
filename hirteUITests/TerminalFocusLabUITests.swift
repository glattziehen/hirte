import XCTest

/// Only the built-in demo; no host keys, real terminals or device keyboard events.
final class TerminalFocusLabUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testTapToTypeAndWatchOnlyInBothAppearances() throws {
        XCUIDevice.shared.orientation = .portrait
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                   "-appearance", appearance, "-hirte.demo", "YES",
                                   "-terminal.watch", "NO"]
            app.launch()
            let terminals = app.buttons["Terminals"]
            XCTAssertTrue(terminals.waitForExistence(timeout: 10))
            terminals.tap()
            let shell = app.descendants(matching: .any).matching(identifier: "t5").firstMatch
            XCTAssertTrue(shell.waitForExistence(timeout: 5))
            shell.tap()
            let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
            XCTAssertTrue(screen.waitForExistence(timeout: 5))
            screen.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)).tap()
            let hint = app.buttons["Continue"]
            if hint.waitForExistence(timeout: 1) { hint.tap() }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Tap must focus without the toolbar")
            app.typeText("pwd\n")
            shot(app, "tap-to-type-" + appearance)

            app.terminalAction("Watch Only").tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.terminalAction("Take Over").exists)
            shot(app, "watch-only-" + appearance)
            screen.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Watching tap takes over and focuses")
            XCTAssertTrue(app.terminalAction("Watch Only").exists)
            app.typeText("echo watch-tap\n")
            shot(app, "watch-tap-takeover-" + appearance)

            app.terminate()
        }
    }

    /// Keep keyboard/takeover transitions separate from the typing tour: simulator
    /// animation quiescence after text entry can otherwise delay every later action.
    @MainActor
    func testKeyboardAndTakeOverActionsWhileWatching() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-appearance", "light", "-hirte.demo", "YES", "-terminal.watch", "NO"]
        app.launch()
        let terminals = app.buttons["Terminals"]
        XCTAssertTrue(terminals.waitForExistence(timeout: 10))
        terminals.tap()
        let shell = app.descendants(matching: .any).matching(identifier: "t5").firstMatch
        XCTAssertTrue(shell.waitForExistence(timeout: 5))
        shell.tap()
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        app.terminalAction("Watch Only").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let showKeyboard = app.terminalAction("Show Keyboard")
        showKeyboard.tap()
        XCTAssertTrue(showKeyboard.waitForNonExistence(timeout: 5), "The menu action must actually apply")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.terminalAction("Watch Only").exists)

        app.terminalAction("Watch Only").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.terminalAction("Take Over").tap()
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("git status\n")
        shot(app, "explicit-take-over-type")
        app.terminate()
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
