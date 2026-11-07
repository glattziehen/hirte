import XCTest

/// Comparable overview captures for the UI/UX pass, including the terminal-first workflow.
final class UXPassUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testTerminalOverviewInBothAppearances() throws {
        XCUIDevice.shared.orientation = .portrait
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                   "-appearance", appearance, "-hirte.demo", "YES"]
            app.launch()
            let terminals = app.buttons["Terminals"]
            XCTAssertTrue(terminals.waitForExistence(timeout: 10))
            terminals.tap()
            for address in ["t3", "t5"] {
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: address)
                    .firstMatch.waitForExistence(timeout: 5))
            }
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "terminal-overview-" + appearance
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }
}
