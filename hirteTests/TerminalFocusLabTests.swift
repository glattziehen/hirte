import XCTest
import UIKit
import HerdrKit
@testable import hirte

@MainActor
final class TerminalFocusLabTests: XCTestCase {
    private func canvas(mouse: Bool) throws -> (TerminalCanvasView, TerminalScreenModel, VirtualTerminal, UIWindow) {
        let terminal = try VirtualTerminal(cols: 40, rows: 10)
        terminal.write(Data("sample prompt> ".utf8))
        if mouse { terminal.write(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8)) }
        let model = TerminalScreenModel(
            theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: terminal)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: window)
        host.rootViewController = UIViewController()
        host.makeKeyAndVisible()
        let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        canvas.model = model
        canvas.screen = model.frame
        host.rootViewController?.view.addSubview(canvas)
        return (canvas, model, terminal, host)
    }

    func testShellAndMouseReportingTapAcquireTextFocus() throws {
        for mouse in [false, true] {
            let (canvas, model, _, window) = try canvas(mouse: mouse)
            defer { model.stop(); window.isHidden = true }
            canvas.handleTap(at: CGPoint(x: 30, y: 18))
            XCTAssertTrue(canvas.isFirstResponder, "mouse=\(mouse)")
            XCTAssertTrue(model.wantsKeyboard)
            XCTAssertFalse(model.watching)
            XCTAssertTrue(canvas.resignFirstResponder())
        }
    }

    func testObserverTapTakesOverAndFocusesIncludingMousePrograms() throws {
        for mouse in [false, true] {
            let (canvas, model, _, window) = try canvas(mouse: mouse)
            defer { model.stop(); window.isHidden = true }
            model.setWatching(true)
            canvas.handleTap(at: CGPoint(x: 30, y: 18))
            XCTAssertTrue(canvas.isFirstResponder)
            XCTAssertTrue(model.wantsKeyboard)
            XCTAssertFalse(model.watching)
            let expected = Data("\u{1b}[<0;3;1M\u{1b}[<0;3;1m".utf8)
            XCTAssertEqual(model.queuedInputForTesting, mouse ? [expected] : [],
                           "Mouse press/release stays queued in order for the viewer reattach")
            XCTAssertTrue(canvas.resignFirstResponder())
            model.setWatching(true)
            // The explicit keyboard action remains a deliberate takeover as well.
            XCTAssertTrue(canvas.becomeFirstResponder())
            XCTAssertFalse(model.watching)
            XCTAssertTrue(canvas.resignFirstResponder())
        }
    }

    func testTerminalHoldIsGoneButSpaceBarTrackpadSendsArrows() throws {
        let (canvas, model, _, window) = try canvas(mouse: false)
        defer { model.stop(); window.isHidden = true }
        // Only the canvas's own recognizer: UIScrollView and the edit menu's secondary click bring theirs.
        XCTAssertFalse((canvas.gestureRecognizers ?? []).contains { type(of: $0) == UILongPressGestureRecognizer.self },
                       "Holding the terminal has no action of its own")
        var input: [Data] = []
        model.sentInputForTesting = { input.append($0) }
        canvas.beginFloatingCursor(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(canvas.subviews.contains { $0 is ArrowPadView })
        canvas.updateFloatingCursor(at: CGPoint(x: 140, y: 100))
        canvas.endFloatingCursor()
        XCTAssertEqual(input, [Data("\u{1b}[C".utf8)])
        XCTAssertFalse(canvas.subviews.contains { $0 is ArrowPadView })
    }

    func testLinkTapRemainsALinkActionWhileWatching() throws {
        let terminal = try VirtualTerminal(cols: 40, rows: 10)
        terminal.write(Data("https://example.com".utf8))
        let model = TerminalScreenModel(
            theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: terminal)
        model.setWatching(true)
        guard case .link(let url) = model.tap(at: (3, 0)) else { return XCTFail("Link action must survive") }
        XCTAssertEqual(url.absoluteString, "https://example.com")
        XCTAssertTrue(model.watching)
        XCTAssertFalse(model.wantsKeyboard)
    }

    func testWatchingScrollsOnlyLocalHistory() async throws {
        for alternate in [false, true] {
            let terminal = try VirtualTerminal(cols: 40, rows: 10)
            for row in 0..<100 { terminal.write(Data("sample \(row)\r\n".utf8)) }
            terminal.write(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
            if alternate { terminal.write(Data("\u{1b}[?1049h".utf8)) }
            let model = TerminalScreenModel(
                theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: terminal)
            defer { model.stop() }
            model.setWatching(true)
            model.scroll(lines: -3, column: 2, row: 2)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(model.watching)
            XCTAssertFalse(model.wantsKeyboard)
            XCTAssertEqual(model.scrolledBack, !alternate)
        }
    }
}
