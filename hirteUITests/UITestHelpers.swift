import XCTest

extension XCUIApplication {
    /// One of a terminal's actions: in the toolbar next to the lists, under More on a phone, whose
    /// bar keeps room for the title. Opens More if it has to.
    @MainActor
    func terminalAction(_ name: String) -> XCUIElement {
        let action = buttons[name]
        if !action.exists, buttons["More"].waitForExistence(timeout: 2) { openMore() }
        return action
    }

    /// A menu's rows take no tap while it's still opening: one right away is lost (measured on a
    /// phone: a submenu row tapped at once never opened, one second later it always did).
    @MainActor
    func openMore() {
        buttons["More"].tap()
        Thread.sleep(forTimeInterval: 1)
    }

    /// That the action is offered, then leaves things as they were: an open More is closed again.
    @MainActor
    func assertTerminalAction(_ name: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let opened = !buttons[name].exists && buttons["More"].waitForExistence(timeout: 2)
        let action = terminalAction(name)
        XCTAssertTrue(action.waitForExistence(timeout: 5), message, file: file, line: line)
        if opened {
            // Outside the menu: this tap only closes it.
            coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            XCTAssertTrue(action.waitForNonExistence(timeout: 5), "More closes", file: file, line: line)
        }
    }

    /// The bottom of the list's title: nothing of the list starts above it.
    @MainActor
    var sidebarTitleBottom: CGFloat {
        navigationBars["Demo machine"].frame.maxY
    }

    /// The top of the bar over the list's end, its gap above the controls included: what's below
    /// this is under the scroll edge, not in view.
    @MainActor
    var modeBarTop: CGFloat {
        // Its controls inherit the identifier: the bar itself is the one reaching furthest up.
        let parts = descendants(matching: .any).matching(identifier: "mode-bar").allElementsBoundByIndex
        XCTAssertFalse(parts.isEmpty, "the bar over the list")
        return parts.map(\.frame.minY).min() ?? 0
    }
}
