import UIKit
import XCTest

/// Walks through the demo machine. Set HIRTE_SHOTS (TEST_RUNNER_HIRTE_SHOTS for xcodebuild)
/// to a folder to also save screenshots there, e.g. for the App Store.
final class DemoTourTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoTour() throws {
        let app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        if environment["HIRTE_SHOTS"] != nil {
            // Screenshots: English, and a terminal font that fills the screen without wrapping.
            let fontSize = environment["HIRTE_SHOT_FONT"] ?? "17"
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-terminal.fontSize", fontSize]
        }
        app.launch()

        startDemo(app)

        XCTAssertTrue(blockedRow(app).waitForExistence(timeout: 10), "demo spaces appear")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "t3").firstMatch.exists)
        sleep(1)
        shot(app, "1-terminals")

        open(app, "t1")
        sleep(2)
        shot(app, "2-agent")
        backIfStacked(app)

        open(app, "t3")
        sleep(2)
        shot(app, "3-needs-you")
        backIfStacked(app)

        // A shell with the keyboard and key bar up.
        open(app, "t5")
        sleep(1)
        let keyboard = app.terminalAction("Show Keyboard")
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        keyboard.tap()
        sleep(1)
        // iOS explains slide-to-type the first time a keyboard appears.
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        app.typeText("git status\n")
        sleep(1)
        shot(app, "4-shell")
        app.buttons["Hide keyboard"].firstMatch.tap()
        backIfStacked(app)

        open(app, "t2")
        sleep(4)
        shot(app, "5-tests")
    }

    /// The README video, recorded by `scripts/video.sh`: the demo at a pace people can follow.
    /// Only runs with HIRTE_VIDEO set to a folder; it writes `start` and `end` (Unix times) there,
    /// so the script can cut the recording to the app.
    @MainActor
    func testVideoTour() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let marks = environment["HIRTE_VIDEO"] else { throw XCTSkip("HIRTE_VIDEO is not set") }
        let app = XCUIApplication()
        let fontSize = environment["HIRTE_SHOT_FONT"] ?? "15"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-terminal.fontSize", fontSize]
        app.launch()
        let tryDemo = app.buttons["Try the Demo"]
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 10), "a fresh install offers the demo")
        mark(marks, "start")
        pause(1.5)
        tryDemo.tap()

        // Everything at a glance; the blocked agent sits on top.
        XCTAssertTrue(blockedRow(app).waitForExistence(timeout: 10))
        pause(3)

        // An agent at work.
        open(app, "t1")
        pause(3)
        back(app)
        pause(1)

        // The blocked one: answer in a tap and watch it go.
        open(app, "t3")
        pause(2.5)
        let yes = app.buttons["Yes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5), "the needs-you bar shows")
        yes.tap()
        pause(5)
        back(app)
        pause(2)

        // A real terminal: type, then pinch to zoom.
        open(app, "t5")
        pause(1)
        app.terminalAction("Show Keyboard").tap()
        pause(1)
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        for character in "git log" {
            app.typeText(String(character))
            pause(0.08)
        }
        app.typeText("\n")
        pause(1.5)
        app.buttons["Hide keyboard"].firstMatch.tap()
        pause(0.5)
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        screen.pinch(withScale: 2.2, velocity: 1.5)
        pause(2)
        screen.pinch(withScale: 0.45, velocity: -1.5)
        pause(1.5)
        back(app)
        // Back on the list: the migration went through.
        pause(2.5)
        mark(marks, "end")
    }

    /// The video on a real device (`scripts/video-device.sh`), made for the unfolded iPhone Duo: the
    /// app records itself (ReplayKit, Debug builds) and stops when the test sends it home. Opens the
    /// demo machine without touching the other machines. Only runs with HIRTE_DEVICE_VIDEO set.
    @MainActor
    func testDeviceVideoTour() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["HIRTE_DEVICE_VIDEO"] else { throw XCTSkip("HIRTE_DEVICE_VIDEO is not set") }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-hirte.demo", "YES", "-hirte.record", name]
        if let fontSize = environment["HIRTE_SHOT_FONT"] { app.launchArguments += ["-terminal.fontSize", fontSize] }
        app.launch()
        allowScreenRecording(app)
        XCTAssertTrue(blockedRow(app).waitForExistence(timeout: 10), "the demo's terminals show")
        pause(2.5)

        // An agent at work.
        open(app, "t1")
        pause(3)
        backIfStacked(app)

        // The blocked one: answer in a tap and watch it go.
        open(app, "t3")
        pause(2.5)
        let yes = app.buttons["Yes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5), "the needs-you bar shows")
        yes.tap()
        pause(5)
        backIfStacked(app)

        // A real terminal: type, then pinch to zoom.
        open(app, "t5")
        pause(1)
        app.terminalAction("Show Keyboard").tap()
        pause(1)
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        app.typeText("git log")
        pause(0.5)
        app.typeText("\n")
        pause(2)
        app.buttons["Hide keyboard"].firstMatch.tap()
        pause(0.5)
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        screen.pinch(withScale: 2.2, velocity: 1.5)
        pause(2)
        screen.pinch(withScale: 0.45, velocity: -1.5)
        pause(1.5)
        backIfStacked(app)

        // Tests streaming in.
        open(app, "t2")
        pause(4)

        // Home: the app stops recording and writes the file.
        XCUIDevice.shared.press(.home)
        pause(4)
    }

    /// iOS asks before an app records its screen (again after some minutes). Taps the button that
    /// allows it, in any language: the one that isn't "Don't Allow" / "Nicht erlauben".
    @MainActor
    private func allowScreenRecording(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            for alert in [springboard.alerts.firstMatch, app.alerts.firstMatch] where alert.exists {
                let refuse = NSPredicate(format: "label CONTAINS[c] 'don' OR label CONTAINS[c] 'nicht' OR label CONTAINS[c] 'not'")
                let accept = alert.buttons.allElementsBoundByIndex.first { !refuse.evaluate(with: $0) }
                accept?.tap()
                return
            }
            pause(0.2)
        }
    }

    /// Two columns (unfolded Duo) keep the list next to the terminal; a stack needs going back.
    @MainActor
    private func backIfStacked(_ app: XCUIApplication) {
        let list = blockedRow(app)
        if !(list.exists && list.isHittable) { back(app) }
        pause(1)
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func mark(_ folder: String, _ name: String) {
        let now = String(Date().timeIntervalSince1970)
        try? now.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// The same terminal stays usable as its available area and keyboard change.
    @MainActor
    func testAdaptiveTerminalLayout() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments += ["-hirte.demo", "YES", "-appearance", "system", "-terminal.watch", "NO"]
        app.launch()
        XCTAssertTrue(blockedRow(app).waitForExistence(timeout: 10))
        open(app, "t5")
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        sleep(1)
        shot(app, "adaptive-portrait")

        screen.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        app.typeText("echo adaptive-window\n")
        shot(app, "adaptive-keyboard")
        // The accessory stays visible when the navigation toolbar moves into its overflow menu.
        app.buttons["Hide keyboard"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        let portraitSize = screen.frame.size
        let windowSize = app.windows.firstMatch.frame.size
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        sleep(1)
        // A floating iPad window may keep its size when the device rotates.
        if app.windows.firstMatch.frame.size != windowSize {
            XCTAssertNotEqual(screen.frame.size, portraitSize, "the terminal follows the available area")
        }
        shot(app, "adaptive-landscape")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .portraitUpsideDown
            XCTAssertTrue(screen.waitForExistence(timeout: 5))
            sleep(1)
            shot(app, "adaptive-upside-down")
        }
    }

    /// Pinch to zoom: the font changes once per gesture and the screen comes back crisp.
    @MainActor
    func testPinchZoom() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        open(app, "t5")
        // These checks start as a viewer even if an earlier run remembered Watch Only.
        let initiallyWatching = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Watching'")).firstMatch
        if initiallyWatching.waitForExistence(timeout: 1) { app.terminalAction("Take Over").tap() }
        sleep(2)
        shot(app, "zoom-0-start")
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        screen.pinch(withScale: 1.6, velocity: 1)
        sleep(1)
        shot(app, "zoom-1-in")
        screen.pinch(withScale: 0.6, velocity: -1)
        sleep(1)
        shot(app, "zoom-2-out")
    }

    /// Watch Only: the terminal opens as an observer; tapping it takes over (and the choice is
    /// remembered for the next terminal until it's switched off).
    @MainActor
    func testWatchOnly() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        open(app, "t5")
        // These checks start as a viewer even if an earlier run remembered Watch Only.
        let initiallyWatching = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Watching'")).firstMatch
        if initiallyWatching.waitForExistence(timeout: 1) { app.terminalAction("Take Over").tap() }
        let watch = app.buttons["Watch Only"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5))
        watch.tap()
        // The subtitle says so (the size the other viewer set).
        let banner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Watching'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "watching shows in the title")
        shot(app, "watch-0-watching")
        // Typing takes over: the keyboard comes up and the banner goes.
        app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch.tap()
        let hint = app.buttons["Continue"]
        if hint.waitForExistence(timeout: 2) { hint.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "tapping brings up the keyboard")
        app.assertTerminalAction("Hide Keyboard", "and offers to hide it")
        XCTAssertFalse(banner.exists, "and takes over")
        sleep(1)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Another viewer'")).firstMatch.exists,
                       "taking over sets the size, also with the keyboard up")
        XCTAssertTrue(app.buttons["Watch Only"].exists)
        shot(app, "watch-1-taken-over")
        // Watching again puts the keyboard away.
        app.buttons["Watch Only"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "watching hides the keyboard")
        app.assertTerminalAction("Show Keyboard", "and offers it again")
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        back(app)
        // Remembered: the next terminal opens watching. Switch it off again for the other tests.
        open(app, "t1")
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "the next terminal opens watching")
        app.buttons["Take Over"].tap()
        XCTAssertTrue(app.buttons["Watch Only"].waitForExistence(timeout: 5))
        XCTAssertFalse(banner.exists)
    }

    /// Long-pressing a live row shows its screen above the menu, watched (no attach, no resize).
    @MainActor
    func testRowPreview() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        app.buttons["Terminals"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "t5").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Copy Address"].waitForExistence(timeout: 5), "the menu opens")
        let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5), "with the terminal's screen above it")
        sleep(1)
        shot(app, "preview-0-menu")
        // Closing the menu leaves the list as it was.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: screen)
        wait(for: [gone], timeout: 5)

        // "Watch" opens it watching, without changing what the eye button remembers.
        row.press(forDuration: 1.2)
        let watch = app.buttons["Watch"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5))
        watch.tap()
        let watching = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Watching'")).firstMatch
        XCTAssertTrue(watching.waitForExistence(timeout: 5), "the terminal opens watching")
        shot(app, "preview-1-watch")
        backIfStacked(app)
        // Next to the lists it's still selected, and selecting it again wouldn't open it anew.
        if app.buttons["Hide Sidebar"].exists { open(app, "t4") }
        open(app, "t5")
        XCTAssertTrue(app.buttons["Watch Only"].waitForExistence(timeout: 5), "opening it normally doesn't watch")
        XCTAssertFalse(watching.exists)
    }

    /// Agents lists only agents, with their status; Terminals lists every terminal by space.
    @MainActor
    func testAgentsAndTerminals() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        // Not a launch argument: those win over what the app saves, so switching wouldn't stick.
        app.buttons["Agents"].tap()
        let shell = app.descendants(matching: .any).matching(identifier: "t5").firstMatch
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "t3").firstMatch.exists, "the blocked agent")
        XCTAssertFalse(shell.exists, "the shell is not an agent")
        shot(app, "view-agents")
        app.buttons["Terminals"].tap()
        XCTAssertTrue(shell.waitForExistence(timeout: 5), "the terminals view lists the shell")
        shot(app, "view-terminals")
        // Finished terminals are in a section of their own at the bottom, collapsed at first
        // (the simulator may remember it open from an earlier run).
        let backup = app.descendants(matching: .any).matching(identifier: "t7").firstMatch
        let finished = app.staticTexts["Finished"]
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 where !(finished.exists && finished.isHittable) { list.swipeUp() }
        XCTAssertTrue(finished.isHittable, "the Finished section is listed")
        if !backup.exists { finished.tap() }
        XCTAssertTrue(backup.waitForExistence(timeout: 5), "opening it shows the finished backup")
        shot(app, "view-terminals-finished")
        finished.tap()
        sleep(1)
        XCTAssertFalse(backup.exists, "collapsing it hides the finished backup")
        app.buttons["Agents"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "t3").firstMatch.waitForExistence(timeout: 5))
    }

    /// Agents are grouped by status, "Needs you" first; done means unread (herdr's shared
    /// `herdr.seen`): looking at one makes it idle, and Mark as Unread brings it back.
    @MainActor
    func testAgentsByStatus() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        app.buttons["Agents"].tap()
        func section(_ state: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "section-\(state)").firstMatch
        }
        for state in ["needsYou", "done", "working"] {
            XCTAssertTrue(section(state).waitForExistence(timeout: 5), "a \(state) section")
        }
        let upgrade = app.descendants(matching: .any).matching(identifier: "t6").firstMatch
        XCTAssertTrue(upgrade.exists, "the unread upgrade is under Done")
        XCTAssertLessThan(blockedRow(app).frame.minY, upgrade.frame.minY, "what needs you comes first")
        shot(app, "status-0-agents")

        // The time explains the state.
        let time = app.buttons["Needs you"].firstMatch
        XCTAssertTrue(time.exists, "the time is the state's button")
        XCTAssertGreaterThanOrEqual(time.frame.height, 44 - 1e-6)
        XCTAssertEqual(time.value as? String, "12m", "shown short in the row")
        time.tap()
        XCTAssertTrue(app.staticTexts["Needs you: waiting for your answer."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Since' AND label CONTAINS '12 minutes'")).firstMatch.exists,
                      "with how long it has waited")
        shot(app, "status-1-legend")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()

        // Looking at it reads it: it moves to Idle, which starts collapsed.
        open(app, "t6")
        sleep(2)
        backIfStacked(app)
        // Next to the lists it stays open, and held under Done, until another one is opened.
        if app.buttons["Hide Sidebar"].exists { open(app, "t3") }
        let idle = section("idle")
        XCTAssertTrue(idle.waitForExistence(timeout: 5), "an Idle section once it's read")
        if !upgrade.waitForExistence(timeout: 2) { idle.tap() }
        XCTAssertTrue(upgrade.waitForExistence(timeout: 5))
        XCTAssertLessThan(idle.frame.minY, upgrade.frame.minY, "it's under Idle now")
        shot(app, "status-2-read")

        // Swipe from the left: Mark as Unread puts it back under Done.
        upgrade.swipeRight()
        let unread = app.buttons["Mark as Unread"]
        XCTAssertTrue(unread.waitForExistence(timeout: 5))
        unread.tap()
        XCTAssertTrue(section("done").waitForExistence(timeout: 5), "back under Done")
        sleep(1)
        XCTAssertLessThan(upgrade.frame.minY, idle.exists ? idle.frame.minY : .infinity, "above Idle again")
        shot(app, "status-3-unread")
    }

    /// "Clear" in the open Finished section removes all finished terminals, after asking.
    @MainActor
    func testClearFinished() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        app.buttons["Terminals"].tap()
        let backup = app.descendants(matching: .any).matching(identifier: "t7").firstMatch
        let finished = app.staticTexts["Finished"]
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 where !(finished.exists && finished.isHittable) { list.swipeUp() }
        XCTAssertTrue(finished.isHittable, "the Finished section is listed")
        if !backup.exists { finished.tap() }
        XCTAssertTrue(backup.waitForExistence(timeout: 5), "opening it shows the finished backup")
        let clear = app.buttons["Clear"]
        XCTAssertTrue(clear.isHittable, "the open section offers Clear")
        shot(app, "finished-clear")
        clear.tap()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "Clear asks first")
        shot(app, "finished-clear-confirm")
        remove.tap()
        XCTAssertTrue(finished.waitForNonExistence(timeout: 5), "the section goes once it's empty")
        XCTAssertFalse(backup.exists)
    }

    /// Each view keeps its scroll position when switching away and back. Large text makes the
    /// demo list longer than the screen.
    @MainActor
    func testViewsKeepScrollPosition() throws {
        let app = XCUIApplication()
        // No sections folded away by an earlier test: the last terminal is what it scrolls to.
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
                                "-terminals.collapsed", ""]
        app.launch()
        startDemo(app)
        app.buttons["Terminals"].tap()
        let infra = app.descendants(matching: .any).matching(identifier: "t6").firstMatch
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 where !(infra.exists && infra.isHittable) { list.swipeUp() }
        XCTAssertTrue(infra.isHittable, "scrolled down to the last terminal")
        shot(app, "scroll-0-terminals-bottom")
        app.buttons["Agents"].tap()
        sleep(1)
        app.buttons["Terminals"].tap()
        sleep(1)
        shot(app, "scroll-1-terminals-back")
        XCTAssertTrue(infra.waitForExistence(timeout: 3) && infra.isHittable, "still scrolled down after switching back")
    }

    /// One sidebar: the machine is picked from the list's title.
    @MainActor
    func testMachineSwitcher() throws {
        let app = XCUIApplication()
        app.launch()
        startDemo(app)
        XCTAssertTrue(blockedRow(app).waitForExistence(timeout: 10), "the demo's terminals show")
        shot(app, "switcher-0-list")
        // The title is a menu button: "Demo machine ⌄".
        app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo machine'")).firstMatch.tap()
        let manage = app.buttons["Manage Machines…"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5), "the title opens the switcher")
        shot(app, "switcher-1-menu")
        manage.tap()
        XCTAssertTrue(app.navigationBars["Machines"].waitForExistence(timeout: 5))
        shot(app, "switcher-2-manage")
    }

    /// Settings: the font preview, the demo button and About.
    @MainActor
    func testSettings() throws {
        let app = XCUIApplication()
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.staticTexts["Terminal"].waitForExistence(timeout: 5))
        shot(app, "settings")
        // A row's label is its title and value: "Dark Theme, Hirte Dark".
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dark Theme'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Dracula"].waitForExistence(timeout: 5))
        shot(app, "settings-dark-themes")
        back(app)

        // Licenses: the list, then one license's text.
        app.swipeUp()
        let licenses = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open-Source Licenses'")).firstMatch
        XCTAssertTrue(licenses.waitForExistence(timeout: 5))
        licenses.tap()
        let ghostty = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ghostty'")).firstMatch
        XCTAssertTrue(ghostty.waitForExistence(timeout: 5), "the licenses list shows")
        shot(app, "settings-licenses")
        ghostty.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'MIT License'")).firstMatch
            .waitForExistence(timeout: 5), "a license's text shows")
        shot(app, "settings-license-ghostty")
    }

    /// Keys: create an Ed25519 key, import a passphrase-protected one, look at both.
    @MainActor
    func testKeys() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        startDemo(app)
        app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo machine'")).firstMatch.tap()
        app.buttons["Manage Machines…"].tap()
        let keysButton = app.buttons["Keys"]
        XCTAssertTrue(keysButton.waitForExistence(timeout: 5))
        keysButton.tap()

        // Create
        let newKey = app.buttons["new-key"]
        XCTAssertTrue(newKey.waitForExistence(timeout: 5))
        // Leftovers from an earlier run that failed halfway.
        for label in ["ui test ed25519", "laptop"] {
            while app.staticTexts[label].firstMatch.exists { deleteKey(app, label) }
        }
        shot(app, "keys-empty")
        newKey.tap()
        app.buttons["menu-create-key"].tap()
        XCTAssertTrue(app.staticTexts["Security Key (FIDO2)"].waitForExistence(timeout: 5))
        shot(app, "keys-new")
        app.staticTexts["Security Key (FIDO2)"].tap()
        shot(app, "keys-new-security-key")
        app.staticTexts["Ed25519"].tap()
        let name = app.textFields["Name"]
        name.tap()
        name.press(forDuration: 1)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        name.typeText("ui test ed25519")
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["ui test ed25519"].waitForExistence(timeout: 5), "the new key is listed")

        // Import
        newKey.tap()
        app.buttons["menu-import-key"].tap()
        let text = app.textViews["import-key-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        shot(app, "keys-import-empty")
        UIPasteboard.general.string = Self.fixtureKey
        app.buttons["Paste"].firstMatch.tap()
        shot(app, "keys-import-pasted")
        let passphrase = app.secureTextFields["import-key-passphrase"]
        XCTAssertTrue(passphrase.waitForExistence(timeout: 5), "asks for the passphrase")
        XCTAssertFalse(app.buttons["Import"].firstMatch.isEnabled, "Import waits for the passphrase")
        passphrase.tap()
        passphrase.typeText("wrong\n")
        XCTAssertTrue(app.staticTexts["The passphrase is wrong."].waitForExistence(timeout: 10))
        shot(app, "keys-import-wrong-passphrase")
        passphrase.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["Only used to decrypt the key now. Hirte keeps the key itself, without the passphrase."].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "tapping outside closes the keyboard")
        passphrase.tap()
        // Return imports (the Import button can be off screen behind the keyboard on the Duo).
        passphrase.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "hirte\n")
        let imported = app.staticTexts["laptop"]
        XCTAssertTrue(imported.waitForExistence(timeout: 10), "the imported key is listed under its comment")
        shot(app, "keys-list")
        imported.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'aqST3fqABUeUXNjo2Gqk' OR value CONTAINS 'aqST3fqABUeUXNjo2Gqk'")).firstMatch
            .waitForExistence(timeout: 5), "the public key matches ssh-keygen's")
        shot(app, "keys-detail-imported")

        // Clean up: delete both keys.
        back(app)
        deleteKey(app, "laptop")
        deleteKey(app, "ui test ed25519")
        XCTAssertFalse(app.staticTexts["laptop"].exists)
    }

    @MainActor
    private func deleteKey(_ app: XCUIApplication, _ label: String) {
        let row = app.staticTexts[label].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let delete = app.buttons["Delete Key"]
        for _ in 0..<4 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        sleep(1)
    }

    /// A throwaway RSA key (passphrase "hirte", comment "laptop"): long enough to scroll.
    private static let fixtureKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        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
        V1dqBw==
        -----END OPENSSH PRIVATE KEY-----
        """

    /// The appearance setting reaches sheets too, and switching it applies at once (also back to System).
    @MainActor
    func testAppearanceInSettings() throws {
        let app = XCUIApplication()
        app.launch()
        openSettings(app)
        XCTAssertTrue(app.staticTexts["Terminal"].waitForExistence(timeout: 5))
        app.buttons["Dark"].tap()
        sleep(1)
        shot(app, "appearance-dark")
        app.buttons["Light"].tap()
        sleep(1)
        shot(app, "appearance-light")
        app.buttons["System"].tap()
        sleep(1)
        shot(app, "appearance-system")
    }

    /// A light terminal theme: the screen, its title bar and the keyboard follow it.
    @MainActor
    func testLightTheme() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-appearance", "light", "-theme.light", "catppuccin-latte", "-terminal.fontSize", "15"]
        app.launch()
        startDemo(app)
        open(app, "t1")
        sleep(2)
        shot(app, "theme-light-agent")
        back(app)
        open(app, "t3")
        sleep(2)
        shot(app, "theme-light-needs-you")
    }

    /// A fresh install offers the demo in its empty state; later launches open on the last machine.
    /// The demo's blocked agent: listed in both views, so the list is on screen when it is.
    private func blockedRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "t3").firstMatch
    }

    @MainActor
    private func startDemo(_ app: XCUIApplication) {
        let tryDemo = app.buttons["Try the Demo"]
        if tryDemo.waitForExistence(timeout: 5) { tryDemo.tap() }
        XCTAssertTrue(blockedRow(app).waitForExistence(timeout: 10), "the demo's terminals show")
    }

    /// Settings is in the title menu, below the machines.
    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        startDemo(app)
        app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo machine'")).firstMatch.tap()
        let settings = app.buttons["Settings…"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the title menu offers Settings")
        settings.tap()
    }

    @MainActor
    private func open(_ app: XCUIApplication, _ address: String) {
        // Rows carry their terminal's address as identifier (the address itself isn't shown).
        // The agents view lists only agents; anything else is in the terminals view.
        let row = app.descendants(matching: .any).matching(identifier: address).firstMatch
        if !row.waitForExistence(timeout: 3) { app.buttons["Terminals"].tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(address) is listed")
        row.tap()
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        // The back button sits in a side rail on wide screens, in the navigation bar otherwise.
        for candidate in [app.buttons["BackButton"], app.buttons["Demo machine"], app.buttons["Back"]] where candidate.exists {
            candidate.tap()
            return
        }
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        // Include the display context for floating iPad windows and rotated scenes.
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
