import XCTest

final class LiveActivityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testExplicitFollowAndStop() throws {
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "dark"
        // A real ongoing task: the standard scene completes t1 after 40 seconds.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearance", appearance,
                                "-hirte.demo", "YES", "-hirte.demo.dense", "YES", "-terminals.collapsed", ""]
        app.launch()
        app.buttons["Terminals"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "t1").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        openLockScreenMenu(app, timeout: 10)
        app.buttons["Live Activity Settings…"].tap()
        let enabled = app.switches["Follow on Lock Screen (Beta)"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        if enabled.value as? String == "1" { toggle(enabled) }
        shot("live-activity-off-" + appearance)
        // Off: the terminal's menu says so, instead of just not having the row.
        app.navigationBars["Live Activity"].buttons["Done"].tap()
        openLockScreenMenu(app)
        XCTAssertTrue(dimmedFollow(app).waitForExistence(timeout: 5))
        XCTAssertTrue(dimmedFollow(app).label.contains("Live Activity Settings"), dimmedFollow(app).label)
        XCTAssertFalse(dimmedFollow(app).isEnabled)
        shot("live-activity-menu-off-" + appearance)
        app.buttons["Live Activity Settings…"].tap()
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        toggle(enabled)
        XCTAssertEqual(enabled.value as? String, "1")
        let title = app.switches["Show task title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        if title.value as? String == "1" { toggle(title) }
        shot("live-activity-settings-" + appearance)
        app.navigationBars["Live Activity"].buttons["Done"].tap()
        openLockScreenMenu(app)
        let follow = app.buttons["Follow on Lock Screen"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        follow.tap()
        // A menu runs its action after closing. Leaving before that wouldn't start anything.
        Thread.sleep(forTimeInterval: 2)
        // What iOS itself shows of it: Dynamic Island on the home screen, then the Lock Screen.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        shot("live-activity-island-" + appearance)
        lockAndWake()
        shot("live-activity-lockscreen-" + appearance)
        unlock(app)
        openLockScreenMenu(app)
        let stop = app.buttons["Stop Following"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        shot("live-activity-following-" + appearance)
        stop.tap()
        openLockScreenMenu(app)
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        app.buttons["Live Activity Settings…"].tap()
        toggle(enabled)
        XCTAssertEqual(enabled.value as? String, "0")
        app.navigationBars["Live Activity"].buttons["Done"].tap()
    }

    /// Follow once: going back to the list, opening the terminal again, leaving the app and a whole
    /// new run of it all keep the same follow, until it's stopped. Uses the real ActivityKit.
    @MainActor
    func testFollowSurvivesReopening() throws {
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "dark"
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearance", appearance,
                                "-hirte.demo", "YES", "-hirte.demo.dense", "YES",
                                "-terminals.collapsed", "", "-liveActivity.enabled", "YES"]
        // The demo's terminals keep their identity across runs, as a real machine's do.
        app.launchEnvironment["HIRTE_DEMO_EPOCH_MS"] = String(UInt64(Date().timeIntervalSince1970 * 1000))
        app.launch()
        func openTerminal() {
            app.buttons["Terminals"].tap()
            let row = app.descendants(matching: .any).matching(identifier: "t1").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
        }
        func assertFollowing(_ message: String) {
            openLockScreenMenu(app, timeout: 10)
            XCTAssertTrue(app.buttons["Stop Following"].waitForExistence(timeout: 5), message)
            // Outside the menu: this tap only closes it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.8)).tap()
            XCTAssertTrue(app.buttons["Stop Following"].waitForNonExistence(timeout: 5))
        }
        openTerminal()
        openLockScreenMenu(app, timeout: 10)
        app.buttons["Follow on Lock Screen"].tap()
        // A menu runs its action after closing. Leaving before that wouldn't start anything.
        Thread.sleep(forTimeInterval: 2)
        assertFollowing("following after the tap")

        // Viewing the terminal is not Stop Following.
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        if back.exists {
            back.tap()
        } else {
            // Beside the sidebar there is no Back button: select another terminal first.
            let other = app.descendants(matching: .any).matching(identifier: "t3").firstMatch
            XCTAssertTrue(other.waitForExistence(timeout: 5))
            other.tap()
        }
        openTerminal()
        assertFollowing("still following after opening its terminal again")

        // The app in the background and back.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        shot("live-activity-reopen-island-" + appearance)
        app.activate()
        Thread.sleep(forTimeInterval: 1)
        assertFollowing("still following after coming back")

        // A new run of the app, with the activity still on the Lock Screen.
        app.terminate()
        lockAndWake()
        shot("live-activity-reopen-lockscreen-before-" + appearance)
        unlock(app)
        app.launch()
        openTerminal()
        assertFollowing("still following in a new run")
        lockAndWake()
        shot("live-activity-reopen-lockscreen-after-" + appearance)
        unlock(app)
        assertFollowing("still following after the Lock Screen")

        // Stopped is stopped, also for the next run.
        openLockScreenMenu(app)
        app.buttons["Stop Following"].tap()
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
        app.launch()
        openTerminal()
        openLockScreenMenu(app, timeout: 10)
        XCTAssertTrue(app.buttons["Follow on Lock Screen"].waitForExistence(timeout: 5), "a stopped follow stays stopped")
        XCTAssertFalse(app.buttons["Stop Following"].exists)
    }

    /// A terminal whose agent isn't running: the menu says why it can't be followed.
    @MainActor
    func testFinishedAgentSaysWhyItCannotBeFollowed() throws {
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "dark"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearance", appearance,
                                "-hirte.demo", "YES", "-liveActivity.enabled", "YES"]
        app.launch()
        let row = app.descendants(matching: .any).matching(identifier: "t6").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        openLockScreenMenu(app, timeout: 10)
        XCTAssertTrue(dimmedFollow(app).waitForExistence(timeout: 5))
        XCTAssertTrue(dimmedFollow(app).label.contains("working or waiting"), dimmedFollow(app).label)
        XCTAssertFalse(dimmedFollow(app).isEnabled)
        shot("live-activity-not-eligible-" + appearance)
    }

    /// iOS's own question on the Lock Screen, after an activity's start. A refusal stays until it's
    /// changed in iOS Settings, so only on request, in this order: fresh install + `deny`, then
    /// `restore`; or fresh install + `allow`. (`HIRTE_LIVE_PERMISSION`)
    @MainActor
    func testLockScreenPermission() throws {
        let stage = ProcessInfo.processInfo.environment["HIRTE_LIVE_PERMISSION"]
        try XCTSkipUnless(["deny", "restore", "allow"].contains(stage))
        let appearance = ProcessInfo.processInfo.environment["HIRTE_UI_APPEARANCE"] ?? "dark"
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearance", appearance,
                                "-hirte.demo", "YES", "-liveActivity.enabled", "YES"]
        app.launch()
        let row = app.descendants(matching: .any).matching(identifier: "t1").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        openLockScreenMenu(app, timeout: 10)

        if stage == "restore" {
            XCTAssertTrue(dimmedFollow(app).waitForExistence(timeout: 5))
            app.buttons["Live Activity Settings…"].tap()
            let open = openSettingsLink(app)
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            // The way back Hirte offers: this link opens Hirte's page in iOS Settings.
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            settings.terminate()
            open.tap()
            let toggle = settings.switches.matching(NSPredicate(
                format: "label IN %@", ["Live Activities", "Live-Aktivitäten"])).firstMatch
            // The simulator's Settings doesn't always go on to the app's own page.
            if !toggle.waitForExistence(timeout: 4) {
                let apps = settings.staticTexts.matching(NSPredicate(format: "label == 'Apps'")).firstMatch
                for _ in 0..<4 where !apps.exists { settings.swipeUp() }
                XCTAssertTrue(apps.waitForExistence(timeout: 5))
                Thread.sleep(forTimeInterval: 1)
                apps.tap()
                let hirte = settings.staticTexts["Hirte Dev"]
                XCTAssertTrue(hirte.waitForExistence(timeout: 5))
                for _ in 0..<8 where !hirte.isHittable { settings.swipeUp() }
                hirte.tap()
            }
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "iOS Settings shows the switch")
            shot("live-activity-ios-settings-" + appearance)
            setSwitch(toggle, on: true)
            // Back with the sheet still open: it follows without a relaunch.
            app.activate()
            XCTAssertTrue(open.waitForNonExistence(timeout: 5))
            shot("live-activity-permission-restored-" + appearance)
            app.navigationBars["Live Activity"].buttons["Done"].tap()
            openLockScreenMenu(app)
        }

        app.buttons["Follow on Lock Screen"].tap()
        // A menu runs its action after closing. Leaving before that wouldn't start anything.
        Thread.sleep(forTimeInterval: 2)
        lockAndWake()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func answer(_ labels: [String]) -> XCUIElement {
            springboard.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        }
        if stage == "restore" {
            shot("live-activity-lockscreen-allowed-" + appearance)
            unlock(app)
            return
        }
        let choice = stage == "deny" ? answer(["Nicht erlauben", "Don\u{2019}t Allow", "Don't Allow"])
                                     : answer(["Erlauben", "Allow"])
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "iOS asks on the Lock Screen")
        shot("live-activity-prompt-" + appearance)
        choice.tap()
        Thread.sleep(forTimeInterval: 2)
        shot("live-activity-prompt-answered-\(stage ?? "")-" + appearance)
        unlock(app)
        openLockScreenMenu(app)
        if stage == "allow" {
            XCTAssertTrue(app.buttons["Stop Following"].waitForExistence(timeout: 5))
            shot("live-activity-allowed-following-" + appearance)
            app.buttons["Stop Following"].tap()
            return
        }
        // Refused: not a silently missing row, and the way back is one tap away.
        XCTAssertTrue(dimmedFollow(app).waitForExistence(timeout: 5))
        XCTAssertTrue(dimmedFollow(app).label.contains("iOS Settings"), dimmedFollow(app).label)
        XCTAssertFalse(dimmedFollow(app).isEnabled)
        shot("live-activity-denied-menu-" + appearance)
        app.buttons["Live Activity Settings…"].tap()
        XCTAssertTrue(openSettingsLink(app).waitForExistence(timeout: 5))
        shot("live-activity-denied-settings-" + appearance)
    }

    /// A link in a form, whatever element type it reports.
    @MainActor
    private func openSettingsLink(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Open iOS Settings'")).firstMatch
    }

    @MainActor
    private func lockAndWake() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        Thread.sleep(forTimeInterval: 1)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
    }

    @MainActor
    private func unlock(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
    }

    @MainActor
    private func setSwitch(_ element: XCUIElement, on: Bool) {
        if (element.value as? String == "1") != on { toggle(element) }
        XCTAssertEqual(element.value as? String, on ? "1" : "0")
    }

    @MainActor
    private func dimmedFollow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Follow on Lock Screen,'")).firstMatch
    }

    /// A menu in the toolbar next to the lists, a section of More on a phone.
    @MainActor
    private func openLockScreenMenu(_ app: XCUIApplication, timeout: TimeInterval = 5) {
        let more = app.buttons["More"]
        let menu = app.buttons["Lock Screen"]
        XCTAssertTrue(menu.exists || more.waitForExistence(timeout: timeout), "the terminal's actions show")
        if more.exists { app.openMore() } else { menu.tap() }
        XCTAssertTrue(app.buttons["Live Activity Settings…"].waitForExistence(timeout: 5), "its actions show")
    }

    @MainActor
    private func toggle(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
