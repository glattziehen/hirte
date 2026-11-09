import XCTest

/// Importing a theme, from the gallery back to the gallery. Set HIRTE_SHOTS (TEST_RUNNER_HIRTE_SHOTS for
/// xcodebuild) to a folder to look at the screens, in both appearances with `-appearance`.
final class ThemeGalleryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let theme = """
        keybind = ctrl+a=text:hello
        background = #10141c
        foreground = #d8dee9
        palette = 1=#e06c75
        palette = 2=#98c379
        palette = 4=#61afef

        """

    @MainActor
    func testImportPreviewSelectAndRemove() throws {
        try run(appearance: "dark", slot: "Dark Theme", text: Self.theme, name: "UI Night", suffix: "dark")
    }

    @MainActor
    func testImportingALightThemeOffersTheLightSlot() throws {
        let text = "background = #f4f4f0\nforeground = #20242c\n"
        try run(appearance: "light", slot: "Light Theme", text: text, name: "UI Day", suffix: "light")
    }

    @MainActor
    private func run(appearance: String, slot: String, text: String, name: String, suffix: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearance", appearance]
        app.launch()

        let tryDemo = app.buttons["Try the Demo"]
        if tryDemo.waitForExistence(timeout: 5) { tryDemo.tap() }
        let title = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo machine'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the demo machine opens")
        title.tap()
        let settings = app.buttons["Settings…"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", slot)).firstMatch.tap()
        XCTAssertTrue(app.buttons["Import Theme…"].waitForExistence(timeout: 5))
        shot("theme-gallery-\(suffix)")

        // Nothing to add until the theme is readable, and a bad one says why.
        app.buttons["Import Theme…"].tap()
        let editor = app.textViews["theme-import-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add Theme"].exists)
        editor.tap()
        editor.typeText("background = #12345\n")
        XCTAssertTrue(app.staticTexts["Line 1: “#12345” isn't a color."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add Theme"].exists)
        shot("theme-import-error-\(suffix)")
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))

        // The preview comes first, then it can be added.
        editor.typeText(text)
        let nameField = app.textFields["theme-import-name"]
        if !nameField.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add Theme"].exists)
        nameField.tap()
        nameField.typeText(name)
        shot("theme-import-preview-\(suffix)")
        app.buttons["Add Theme"].tap()

        // It's in the gallery and in use.
        let card = app.buttons[name]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.isSelected)
        shot("theme-gallery-imported-\(suffix)")

        // Removing it goes back to the default.
        card.press(forDuration: 1)
        let remove = app.buttons["Remove Theme"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let confirm = app.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        let fallback = app.buttons[appearance == "dark" ? "Hirte Dark" : "Hirte Light"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 5))
        XCTAssertTrue(fallback.isSelected)
    }

    @MainActor
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
