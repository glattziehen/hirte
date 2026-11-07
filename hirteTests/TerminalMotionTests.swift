import XCTest
import UIKit
import HerdrKit
@testable import hirte

@MainActor
final class TerminalMotionTests: XCTestCase {
    private func fixture(mouse: Bool = false, alternate: Bool = false) throws -> (VirtualTerminal, TerminalScreenModel, TerminalCanvasView) {
        let vt = try VirtualTerminal(cols: 40, rows: 20)
        for row in 0..<300 { vt.write(Data("sample \(row) ready 漢 e\u{301}\r\n".utf8)) }
        if alternate { vt.write(Data("\u{1b}[?1049h".utf8)) }
        if mouse { vt.write(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8)) }
        let model = TerminalScreenModel(theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: vt)
        let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 380))
        canvas.contentScaleFactor = 2
        canvas.model = model
        canvas.screen = model.frame
        canvas.layoutIfNeeded()
        return (vt, model, canvas)
    }

    private func move(_ canvas: TerminalCanvasView, to offset: CGFloat) {
        canvas.scrollView.contentOffset.y = offset
    }

    private func visibleOffset(_ canvas: TerminalCanvasView) -> CGFloat {
        CGFloat(canvas.screen.scrollbar!.offset) * Fonts(size: 13).cellHeight + canvas.scrollFraction
    }

    func testContinuousPositionAndReversalAt60And120SamplesPerSecond() throws {
        for hz in [60, 120] {
            let (_, model, canvas) = try fixture()
            defer { model.stop() }
            let start = canvas.scrollView.contentOffset.y
            canvas.scrollViewWillBeginDragging(canvas.scrollView)
            for sample in 1...hz {
                let target = start - CGFloat(sample) * 213.5 / CGFloat(hz)
                move(canvas, to: target)
                let native = canvas.scrollView.contentOffset.y
                XCTAssertEqual(visibleOffset(canvas), (native * canvas.contentScaleFactor).rounded() / canvas.contentScaleFactor,
                               accuracy: 0.001, "Draw the native offset aligned to canvas pixels")
                XCTAssertEqual(native, target, accuracy: 1 / canvas.traitCollection.displayScale,
                               "UIKit may align the requested offset to its screen's pixels")
                // SwiftUI echo must not reset native subpixel position or cancel its gesture.
                let nativeOffset = canvas.scrollView.contentOffset.y
                canvas.screen = model.frame
                XCTAssertEqual(canvas.scrollView.contentOffset.y, nativeOffset, accuracy: 0.001)
            }
            let stopped = visibleOffset(canvas)
            move(canvas, to: start - 213.5 + 1.5)
            XCTAssertEqual(visibleOffset(canvas), stopped + 1.5, accuracy: 0.001,
                           "A reversal follows immediately, without a whole-row dead zone")
            canvas.scrollViewDidEndDragging(canvas.scrollView, willDecelerate: true)
            // UIKit supplies these offsets from native time-based physics, at either cadence.
            for sample in 1...hz {
                move(canvas, to: start - 212 - 100 * (1 - exp(-5 * CGFloat(sample) / CGFloat(hz))))
            }
            XCTAssertEqual(visibleOffset(canvas), ((start - 212 - 100 * (1 - exp(-5))) * 2).rounded() / 2, accuracy: 0.001)
            canvas.scrollViewDidEndDecelerating(canvas.scrollView)
        }
    }

    func testBoundariesAndCancellationCannotContinueAViewportOrInput() throws {
        let (_, model, canvas) = try fixture()
        defer { model.stop() }
        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        move(canvas, to: -100)
        XCTAssertEqual(visibleOffset(canvas), 0)
        move(canvas, to: 1_000_000)
        XCTAssertTrue(canvas.screen.scrollbar!.atBottom)
        XCTAssertEqual(canvas.scrollFraction, 0)

        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        move(canvas, to: 80.5)
        canvas.cancelScrolling(resetFraction: false)
        move(canvas, to: 60)
        XCTAssertEqual(visibleOffset(canvas), 80.5)
        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        model.stop()
        move(canvas, to: 20)
        XCTAssertEqual(model.frame.scrollbar?.offset, canvas.screen.scrollbar?.offset)
        XCTAssertEqual(model.scrollRoute, .disabled)
    }

    func testRemoteWheelOrderNoInterpolationAndNoInputAfterCancellationOrReplacement() throws {
        for mouse in [false, true] {
            let (_, model, canvas) = try fixture(mouse: mouse, alternate: true)
            defer { model.stop() }
            var input: [Data] = []
            model.sentInputForTesting = { input.append($0) }
            let initial = canvas.screen.text
            let start = canvas.scrollView.contentOffset.y
            canvas.scrollViewWillBeginDragging(canvas.scrollView)
            move(canvas, to: start - 36)
            move(canvas, to: start - 18)
            let up = mouse ? "\u{1b}[<64;1;1M" : "\u{1b}[A"
            let down = mouse ? "\u{1b}[<65;1;1M" : "\u{1b}[B"
            XCTAssertEqual(input, [Data((up + up).utf8), Data(down.utf8)])
            XCTAssertEqual(canvas.screen.text, initial)
            XCTAssertEqual(canvas.scrollFraction, 0)
            canvas.cancelScrolling()
            move(canvas, to: start - 54)
            XCTAssertEqual(input.count, 2)
            canvas.scrollViewWillBeginDragging(canvas.scrollView)
            let (_, replacement, _) = try fixture()
            defer { replacement.stop() }
            canvas.model = replacement
            canvas.screen = replacement.frame
            move(canvas, to: start - 72)
            XCTAssertEqual(input.count, 2, "No delayed gesture targets the old terminal")
        }
    }

    func testWatchingHistoryIsLocalAndAlternateScreenSendsNothing() throws {
        for alternate in [false, true] {
            let (_, model, canvas) = try fixture(mouse: true, alternate: alternate)
            defer { model.stop() }
            var input: [Data] = []
            model.sentInputForTesting = { input.append($0) }
            model.setWatching(true)
            canvas.screen = model.frame
            let old = model.frame.scrollbar!.offset
            let start = canvas.scrollView.contentOffset.y
            canvas.scrollViewWillBeginDragging(canvas.scrollView)
            move(canvas, to: start - 36.5)
            XCTAssertEqual(input, [])
            XCTAssertTrue(model.watching)
            XCTAssertFalse(model.wantsKeyboard)
            XCTAssertEqual(model.frame.scrollbar!.offset, alternate ? old : old - 3)
            XCTAssertEqual(canvas.scrollView.isScrollEnabled, !alternate)
        }
    }

    func testFractionalBottomRowLinksSelectionAndCursor() throws {
        let (vt, model, canvas) = try fixture()
        defer { model.stop() }
        vt.write(Data("\u{1b}[?25l\r\nhttps://example.com plain\r\n\u{1b}]8;;https://example.org\u{1b}\\linked word\u{1b}]8;;\u{1b}\\\r\nlast".utf8))
        // Both kinds of link and selection resolve the partially visible row itself.
        for (distance, expected) in [(3, "https://example.com"), (2, "https://example.org")] {
            vt.scroll(by: nil)
            let target = vt.scrollbar!.offset - distance
            let frame = model.scrollHistory(by: target - vt.scrollbar!.offset)
            XCTAssertEqual(vt.link(at: (3, frame.rows), in: frame)?.absoluteString, expected)
            vt.selectWord(at: (3, frame.rows))
            XCTAssertTrue(vt.selectedText()?.contains(distance == 3 ? "https" : "linked") == true)
            _ = model.scrollHistory(by: target - 1 - vt.scrollbar!.offset)
            let selected = model.scrollHistory(by: target - vt.scrollbar!.offset)
            XCTAssertNotNil(selected.selectionBelow)
            canvas.screen = selected
            canvas.scrollViewWillBeginDragging(canvas.scrollView)
            move(canvas, to: CGFloat(selected.scrollbar!.offset) * 18 + 9)
            canvas.scrollViewDidEndDragging(canvas.scrollView, willDecelerate: false)
            let cell = canvas.cell(at: CGPoint(x: 35, y: 10 + 20 * 18 - 4))
            XCTAssertEqual(cell.y, 20)
            XCTAssertEqual(vt.link(at: cell, in: canvas.screen)?.absoluteString, expected)
            vt.clearSelection()
        }
    }

    func testOverscanDoesNotChangeViewportAndRetainsSelection() throws {
        let vt = try VirtualTerminal(cols: 20, rows: 4)
        for row in 0..<12 { vt.write(Data("line \(row)\r\n".utf8)) }
        XCTAssertNil(vt.frame().lineBelow)
        vt.scroll(by: -3)
        let offset = vt.scrollbar!.offset
        let first = vt.frame()
        XCTAssertEqual(first.lines.count, 4)
        XCTAssertEqual(vt.scrollbar!.offset, offset)
        vt.select(from: (0, 3), to: (5, 4))
        let selected = vt.frame()
        XCTAssertEqual(selected.selectionBelow, 0...5)
        vt.scroll(by: 1)
        let next = vt.frame()
        XCTAssertEqual(first.lineBelow, next.lines.last)
        XCTAssertEqual(next.lines.count, 4)
        vt.write(Data("\u{1b}[?2026h\u{1b}[Hchanged".utf8))
        XCTAssertEqual(vt.frame().lines, next.lines, "Overscan must not bypass synchronized output")
        vt.write(Data("\u{1b}[?2026l".utf8))
        vt.scroll(by: nil)
        XCTAssertNil(vt.frame().lineBelow)
    }

    func testStoppingTouchDoesNotClickOrTakeOver() throws {
        let (_, model, canvas) = try fixture(mouse: true)
        defer { model.stop() }
        model.setWatching(true)
        canvas.screen = model.frame
        var input: [Data] = []
        model.sentInputForTesting = { input.append($0) }
        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        move(canvas, to: canvas.scrollView.contentOffset.y - 40.5)
        canvas.scrollViewDidEndDragging(canvas.scrollView, willDecelerate: true)
        let stopped = visibleOffset(canvas)
        canvas.prepareForTouch()
        canvas.handleTap(at: CGPoint(x: 30, y: 30))
        move(canvas, to: canvas.scrollView.contentOffset.y - 20)
        XCTAssertEqual(visibleOffset(canvas), stopped)
        XCTAssertTrue(model.watching)
        XCTAssertFalse(model.wantsKeyboard)
        XCTAssertEqual(input, [])
        canvas.prepareForTouch()
        canvas.handleTap(at: CGPoint(x: 30, y: 30))
        XCTAssertFalse(model.watching, "The next ordinary tap intentionally takes over")
        XCTAssertEqual(input.count, 1)
    }

    func testGeometryAndSessionChangesCancelRemoteMotion() throws {
        for change in 0..<6 {
            let (_, model, canvas) = try fixture(mouse: true, alternate: true)
            defer { model.stop() }
            var inputs = 0
            model.sentInputForTesting = { _ in inputs += 1 }
            canvas.scrollViewWillBeginDragging(canvas.scrollView)
            move(canvas, to: canvas.scrollView.contentOffset.y - 18)
            XCTAssertEqual(inputs, 1)
            switch change {
            case 0: canvas.fontSize = 16
            case 1: canvas.fontFamily = .menlo
            case 2:
                canvas.frame.size.height -= 40
                canvas.layoutIfNeeded()
            case 3: model.remoteSizeChanged(cols: 30, rows: 18)
            case 4: canvas.didMoveToWindow() // A detached canvas has no window.
            default: TerminalCanvas.dismantleUIView(canvas, coordinator: ())
            }
            move(canvas, to: canvas.scrollView.contentOffset.y - 36)
            XCTAssertEqual(inputs, 1, "No late wheel after lifecycle change \(change)")
        }
    }

    func testCursorInThePartialBottomRowUsesItsRealPosition() throws {
        let (vt, model, canvas) = try fixture()
        defer { model.stop() }
        let target = vt.scrollbar!.offset - 1
        canvas.screen = model.scrollHistory(by: target - vt.scrollbar!.offset)
        XCTAssertEqual(canvas.screen.cursor?.y, 20)
        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        move(canvas, to: CGFloat(target) * 18 + 9)
        XCTAssertEqual(canvas.screen.cursor?.y, 20)
        XCTAssertEqual(canvas.scrollFraction, 9)
        XCTAssertNil(canvas.screen.cursorRow, "An off-viewport cursor must not shift historical geometry")
    }

    func testPendingPruneKeepsNativeCoastingCoordinateAndAppliesOnlyGestureDelta() throws {
        let vt = try VirtualTerminal(cols: 40, rows: 20, scrollbackLines: 3000)
        for row in 0..<4000 { vt.write(Data("sample \(row) ready\r\n".utf8)) }
        let model = TerminalScreenModel(theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: vt)
        defer { model.stop() }
        let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 380))
        canvas.contentScaleFactor = 2
        canvas.model = model
        canvas.screen = model.frame
        canvas.layoutIfNeeded()
        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        move(canvas, to: canvas.scrollView.contentOffset.y - 4 * 18 - 7.5)
        canvas.scrollViewDidEndDragging(canvas.scrollView, willDecelerate: true)
        let published = model.frame.scrollbar!.offset
        // Output can prune the VT before its scheduled snapshot reaches Observation.
        for batch in 0..<200 {
            model.receiveOutputForTesting(Data((0..<8).map { "sample \(4000 + batch * 8 + $0)\r\n" }.joined().utf8))
            if vt.scrollbar!.offset < published { break }
        }
        let anchor = vt.scrollbar!.offset
        XCTAssertLessThan(anchor, published, "Exercise a real pending prune")
        let native = canvas.scrollView.contentOffset.y - 18
        move(canvas, to: native)
        XCTAssertEqual(model.frame.scrollbar!.offset, anchor - 1,
                       "The one-row native step applies to the retained anchor, not the stale absolute index")
        canvas.screen = model.frame
        XCTAssertEqual(canvas.scrollView.contentOffset.y, native, accuracy: 0.001,
                       "Neither a contentSize clamp nor an explicit offset sync may rewrite native motion")
        move(canvas, to: native - 3)
        XCTAssertEqual(canvas.scrollView.contentOffset.y, native - 3, accuracy: 0.001)
        let raw = canvas.scrollView.contentOffset.y
        let remainder = raw - floor(raw / 18) * 18
        let canonical = CGFloat(canvas.screen.scrollbar!.offset) * 18 + remainder
        canvas.scrollViewDidEndDecelerating(canvas.scrollView)
        XCTAssertEqual(canvas.scrollView.contentOffset.y, canonical, accuracy: 0.001,
                       "Restore canonical coordinates with UIKit's raw remainder after motion ends")
    }

    func testRebasedRawFractionSurvivesEndOrStopTouchAndNextGesture() throws {
        for scale: CGFloat in [2, 3] {
            for stopTouch in [false, true] {
                for fraction: CGFloat in [17.5, 17.833333333] {
                    let vt = try VirtualTerminal(cols: 40, rows: 20, scrollbackLines: 3000)
                    for row in 0..<4000 { vt.write(Data("sample \(row) ready\r\n".utf8)) }
                    let model = TerminalScreenModel(theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: vt)
                    defer { model.stop() }
                    let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 380))
                    canvas.contentScaleFactor = scale
                    canvas.scrollView.contentScaleFactor = 3
                    canvas.model = model
                    canvas.screen = model.frame
                    canvas.layoutIfNeeded()
                    canvas.scrollViewWillBeginDragging(canvas.scrollView)
                    move(canvas, to: CGFloat(vt.scrollbar!.offset - 10) * 18 + fraction)
                    canvas.scrollViewDidEndDragging(canvas.scrollView, willDecelerate: true)
                    let published = model.frame.scrollbar!.offset
                    let native = canvas.scrollView.contentOffset.y
                    let remainder = native - floor(native / 18) * 18
                    for batch in 0..<200 {
                        model.receiveOutputForTesting(Data((0..<8).map { "sample \(4000 + batch * 8 + $0)\r\n" }.joined().utf8))
                        if vt.scrollbar!.offset < published { break }
                    }
                    XCTAssertLessThan(vt.scrollbar!.offset, published)
                    move(canvas, to: native - 18)
                    canvas.screen = model.frame
                    XCTAssertNotEqual(canvas.scrollView.contentInset.top, 0, "Exercise a rebased native coordinate")
                    let row = canvas.screen.scrollbar!.offset
                    let text = canvas.screen.text
                    let expected = CGFloat(row) * 18 + remainder
                    if stopTouch { canvas.prepareForTouch() }
                    else { canvas.scrollViewDidEndDecelerating(canvas.scrollView) }
                    XCTAssertEqual(canvas.scrollView.contentInset.top, 0)
                    XCTAssertEqual(canvas.scrollView.contentOffset.y, expected, accuracy: 0.001,
                                   "Canonicalization preserves UIKit's accepted raw fraction, not the draw fraction")
                    XCTAssertEqual(Int(floor(canvas.scrollView.contentOffset.y / 18)), row)
                    XCTAssertEqual(canvas.screen.text, text)
                    canvas.scrollViewWillBeginDragging(canvas.scrollView)
                    move(canvas, to: canvas.scrollView.contentOffset.y - 18)
                    XCTAssertEqual(canvas.screen.scrollbar!.offset, row - 1, "No extra row at the next gesture")
                    print("COAST_RAW_FRACTION scale=\(scale) requested=\(fraction) accepted=\(remainder) stopTouch=\(stopTouch)")
                }
            }
        }
    }

    func testLiveOutputAndPruningRebaseHistoryWithoutFeedingBackMotion() async throws {
        let vt = try VirtualTerminal(cols: 40, rows: 20, scrollbackLines: 3000)
        for row in 0..<4000 { vt.write(Data("sample \(row)\r\n".utf8)) }
        let model = TerminalScreenModel(theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: vt)
        defer { model.stop() }
        let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 380))
        canvas.contentScaleFactor = 2
        canvas.model = model
        canvas.screen = model.frame
        canvas.layoutIfNeeded()
        var input = 0
        model.sentInputForTesting = { _ in input += 1 }
        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        move(canvas, to: canvas.scrollView.contentOffset.y - 4 * 18 - 7.5)
        let anchor = canvas.screen.text
        print("PRUNE_START total=\(canvas.screen.scrollbar!.total) offset=\(canvas.screen.scrollbar!.offset) top=\(anchor.split(separator: "\n").first ?? "")")
        let fraction = canvas.scrollFraction
        var offset = canvas.screen.scrollbar!.offset
        let nativeAnchor = canvas.scrollView.contentOffset.y
        var pruned = false
        for batch in 0..<200 {
            let frames = model.renderedFrames
            model.receiveOutputForTesting(Data((0..<8).map { "sample \(4000 + batch * 8 + $0)\r\n" }.joined().utf8))
            let deadline = CACurrentMediaTime() + 1
            while model.renderedFrames == frames, CACurrentMediaTime() < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertGreaterThan(model.renderedFrames, frames)
            canvas.screen = model.frame // The ordinary output/Observation path.
            if canvas.screen.text != anchor {
                print("PRUNE_CHANGE batch=\(batch) total=\(canvas.screen.scrollbar!.total) offset=\(canvas.screen.scrollbar!.offset) old_offset=\(offset) top=\(canvas.screen.text.split(separator: "\n").first ?? "")")
            }
            XCTAssertEqual(canvas.screen.text, anchor, "Appending must retain the historical anchor")
            XCTAssertEqual(canvas.scrollFraction, fraction)
            XCTAssertEqual(canvas.scrollView.contentOffset.y, nativeAnchor, accuracy: 0.001,
                           "Output must not rewrite the coordinate driving native motion")
            let next = canvas.screen.scrollbar!.offset
            if next < offset {
                print("PRUNE_REBASE total=\(canvas.screen.scrollbar!.total) old_offset=\(offset) new_offset=\(next) fraction=\(fraction) anchor_preserved=\(canvas.screen.text == anchor)")
                pruned = true
                break
            }
            offset = next
        }
        XCTAssertTrue(pruned, "Exercise actual bounded-history pruning, not merely append")
        XCTAssertEqual(input, 0)
        let rebased = visibleOffset(canvas)
        move(canvas, to: canvas.scrollView.contentOffset.y - 2)
        XCTAssertEqual(visibleOffset(canvas), rebased - 2, accuracy: 0.001)
        canvas.scrollViewDidEndDragging(canvas.scrollView, willDecelerate: true)
        move(canvas, to: canvas.scrollView.contentOffset.y - 3)
        XCTAssertEqual(visibleOffset(canvas), rebased - 5, accuracy: 0.001)
        canvas.cancelScrolling()
        model.scroll(toBottom: true)
        canvas.screen = model.frame
        let frames = model.renderedFrames
        model.receiveOutputForTesting(Data("new live line\r\n".utf8))
        let deadline = CACurrentMediaTime() + 1
        while model.renderedFrames == frames, CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        canvas.screen = model.frame
        XCTAssertTrue(canvas.screen.scrollbar!.atBottom)
        XCTAssertTrue(canvas.screen.text.contains("new live line"))
        XCTAssertEqual(canvas.scrollFraction, 0)
    }

    func testFractionalPixelsMatchRealRowsIncludingBottomEdgeAndSelection() throws {
        let (vt, model, canvas) = try fixture()
        defer { model.stop() }
        let target = vt.scrollbar!.offset - 30
        _ = model.scrollHistory(by: target - vt.scrollbar!.offset)
        vt.select(from: (0, 19), to: (10, 20))
        // Refresh after selection through the real local snapshot path.
        _ = model.scrollHistory(by: target - 1 - vt.scrollbar!.offset)
        canvas.screen = model.scrollHistory(by: target - vt.scrollbar!.offset)
        var extended = canvas.screen
        extended.lines.append(try XCTUnwrap(extended.lineBelow))
        extended.selection.append(extended.selectionBelow)
        extended.rows += 1
        extended.cursor = nil
        let reference = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        reference.contentScaleFactor = 2
        reference.screen = extended
        func bitmap(_ view: TerminalCanvasView) -> CGImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in view.draw(view.bounds) }.cgImage!
        }
        let full = bitmap(reference)
        for fraction: CGFloat in [0.5, 9, 17.5] {
            canvas.scrollViewWillBeginDragging(canvas.scrollView)
            move(canvas, to: CGFloat(target) * 18 + fraction)
            let actual = bitmap(canvas)
            let crop = CGRect(x: 24, y: 22, width: 640, height: 716)
            let expectedCrop = try XCTUnwrap(full.cropping(to: crop.offsetBy(dx: 0, dy: fraction * 2)))
            let actualCrop = try XCTUnwrap(actual.cropping(to: crop))
            func rgba(_ image: CGImage) -> Data {
                var data = Data(count: image.width * image.height * 4)
                data.withUnsafeMutableBytes { bytes in
                    let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                return data
            }
            XCTAssertEqual(rgba(actualCrop), rgba(expectedCrop), "Real neighboring rows at fractional offset \(fraction)")
            XCTAssertLessThanOrEqual(canvas.textRowBytes, 32 * 1024 * 1024)
        }
    }

    func testPromptRemoteResponsePreservesSplitSynchronizedFramesAndOutputBatching() async throws {
        let (_, model, canvas) = try fixture(mouse: true, alternate: true)
        defer { model.stop() }
        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        move(canvas, to: canvas.scrollView.contentOffset.y - 18)
        try await Task.sleep(for: .milliseconds(25))
        let before = model.frame.text
        model.receiveOutputForTesting(Data("\u{1b}[?2026h\u{1b}[Hpartial".utf8))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.frame.text, before)
        model.receiveOutputForTesting(Data("\u{1b}[Hcomplete\u{1b}[?2026l".utf8))
        for _ in 0..<100 where !model.frame.text.hasPrefix("complete") { await Task.yield() }
        XCTAssertTrue(model.frame.text.hasPrefix("complete"), "The completed response uses the same main-actor turn")

        // The fast response is consumed once. Sustained unrelated output still batches
        // at the display cadence while the finger/physics remain active.
        var counts: [Int] = []
        for active in [false, true] {
            model.setScrollActive(active)
            let frames = model.renderedFrames
            let start = CACurrentMediaTime()
            for sample in 0..<120 {
                model.receiveOutputForTesting(Data("\u{1b}[Hsample \(sample)\u{1b}[K".utf8))
                try await Task.sleep(for: .milliseconds(1))
            }
            try await Task.sleep(for: .milliseconds(25))
            counts.append(model.renderedFrames - frames)
            print("SCROLL_OUTPUT_BATCH active=\(active) chunks=120 frames=\(counts.last!) elapsed_ms=\((CACurrentMediaTime() - start) * 1000)")
        }
        XCTAssertLessThanOrEqual(counts[1], counts[0] + 2)
        XCTAssertLessThan(counts[1], 30, "An active scroll must not unthrottle unrelated output")
        canvas.cancelScrolling()
    }
}
