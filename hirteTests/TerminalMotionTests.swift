import XCTest
import UIKit
import HerdrKit
@testable import hirte

@MainActor
final class TerminalMotionTests: XCTestCase {
    private func fixture(mouse: Bool = false, alternate: Bool = false, rows: Int = 20) throws -> (VirtualTerminal, TerminalScreenModel, TerminalCanvasView) {
        let vt = try VirtualTerminal(cols: 40, rows: rows)
        for row in 0..<300 { vt.write(Data("sample \(row) ready 漢 e\u{301}\r\n".utf8)) }
        if alternate { vt.write(Data("\u{1b}[?1049h".utf8)) }
        if mouse { vt.write(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8)) }
        let model = TerminalScreenModel(theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: vt)
        let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: CGFloat(rows) * 18 + 20))
        canvas.contentScaleFactor = 2
        canvas.model = model
        canvas.screen = model.frame
        canvas.layoutIfNeeded()
        return (vt, model, canvas)
    }

    private func remotePaint(_ vt: VirtualTerminal, offset: Int, chrome: Bool = true) -> ScreenFrame {
        var output = "\u{1b}[?25l\u{1b}[?2026h"
        for y in 0..<vt.rows {
            let text: String
            if chrome && y == 0 { text = "header" }
            else if chrome && y >= vt.rows - 2 { text = "fixed footer \(y)" }
            else { text = "item \(y + offset) ready 漢 e\u{301}" }
            output += "\u{1b}[\(y + 1);1H" + text + "\u{1b}[K"
        }
        vt.write(Data((output + "\u{1b}[?2026l").utf8))
        return vt.frame()
    }

    private func remoteWheel(_ canvas: TerminalCanvasView, rows: Int) {
        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        move(canvas, to: canvas.scrollView.contentOffset.y + CGFloat(rows) * 18)
    }

    private func remoteImage(_ canvas: TerminalCanvasView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = canvas.contentScaleFactor
        return UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image {
            canvas.renderForTesting(in: $0.cgContext, repaint: false)
        }
    }

    func testRemoteArrivalAndDrainPixelsUseTransformsAndKeepFooterFixed() throws {
        for k in [1, -1, 3, -3, 9, -9] {
            let (vt, model, canvas) = try fixture(mouse: true, alternate: true, rows: 30)
            defer { model.stop(); canvas.cancelScrolling() }
            canvas.screen = remotePaint(vt, offset: 0)
            let before = remoteImage(canvas)
            remoteWheel(canvas, rows: k)
            canvas.screen = remotePaint(vt, offset: k)
            XCTAssertEqual(canvas.remoteOffset, CGFloat(k) * 18)
            XCTAssertEqual(remoteImage(canvas).pngData(), before.pngData(), "Arrival retains the complete previous image")
            let draws = canvas.contentDraws
            let rasters = canvas.textRowRasterizations
            let footer = CGRect(x: 0, y: 514 * 2, width: 500 * 2, height: 46 * 2)
            let footerBefore = try XCTUnwrap(before.cgImage?.cropping(to: footer))
            let footerData = UIImage(cgImage: footerBefore).pngData()
            var previous = abs(canvas.remoteOffset)
            for _ in 0..<80 {
                canvas.advanceRemoteShift(by: 1.0 / 120)
                XCTAssertLessThanOrEqual(abs(canvas.remoteOffset), previous)
                previous = abs(canvas.remoteOffset)
                let image = remoteImage(canvas)
                let crop = try XCTUnwrap(image.cgImage?.cropping(to: footer))
                XCTAssertEqual(UIImage(cgImage: crop).pngData(), footerData)
            }
            XCTAssertEqual(canvas.remoteOffset, 0)
            XCTAssertEqual(canvas.contentDraws, draws, "Draining never repaints the authoritative canvas")
            XCTAssertEqual(canvas.textRowRasterizations, rasters)
            let fresh = TerminalCanvasView(frame: canvas.bounds)
            fresh.contentScaleFactor = 2
            fresh.screen = canvas.screen
            XCTAssertEqual(remoteImage(canvas).pngData(), remoteImage(fresh).pngData())
        }
    }

    func testRemoteAccumulationAndOutsideStatusUpdatePreservePresentedImage() throws {
        for k in [1, -1] {
            let (vt, model, canvas) = try fixture(mouse: true, alternate: true)
            defer { model.stop(); canvas.cancelScrolling() }
            canvas.screen = remotePaint(vt, offset: 0)
            remoteWheel(canvas, rows: k)
            canvas.screen = remotePaint(vt, offset: k)
            canvas.advanceRemoteShift(by: 0.02)
            let image = remoteImage(canvas).pngData()
            let offset = canvas.remoteOffset
            remoteWheel(canvas, rows: k)
            canvas.screen = remotePaint(vt, offset: k * 2)
            XCTAssertEqual(canvas.remoteOffset, offset + CGFloat(k) * 18, accuracy: 0.001)
            XCTAssertEqual(remoteImage(canvas).pngData(), image, "A response mid-drain preserves the presented strip")
            var status = canvas.screen
            status.lines[19][0].text = "changed status"
            canvas.screen = status
            XCTAssertEqual(canvas.remoteOffset, offset + CGFloat(k) * 18, accuracy: 0.001)
        }
    }

    func testRemoteFallbacksSnapToTheAuthoritativeFrame() throws {
        for action in 0..<10 {
            let (vt, model, canvas) = try fixture(mouse: true, alternate: true)
            defer { model.stop(); canvas.cancelScrolling() }
            canvas.screen = remotePaint(vt, offset: 0)
            remoteWheel(canvas, rows: 1)
            canvas.screen = remotePaint(vt, offset: 1)
            XCTAssertNotEqual(canvas.remoteOffset, 0)
            switch action {
            case 0:
                var changed = canvas.screen
                changed.lines[8][0].text = "non-shift update"
                canvas.screen = changed
            case 1:
                remoteWheel(canvas, rows: -1)
                canvas.screen = remotePaint(vt, offset: 0)
            case 2: canvas.cancelScrolling()
            case 3:
                let (_, replacement, _) = try fixture()
                canvas.model = replacement
                replacement.stop()
            case 4:
                canvas.frame.size.width -= 20
                canvas.layoutIfNeeded()
            case 5: canvas.fontSize = 14
            case 6:
                // A visible cursor entering the moving band must cancel it too.
                vt.write(Data("\u{1b}[9;1H\u{1b}[?25h".utf8))
                canvas.screen = vt.frame()
            case 7:
                remoteWheel(canvas, rows: 9)
                canvas.screen = remotePaint(vt, offset: 10)
            case 8:
                var changedRegion = remotePaint(vt, offset: 2)
                for y in 1..<12 { changedRegion.lines[y] = canvas.screen.lines[y] }
                canvas.screen = changedRegion
            default:
                canvas.watching = true
                canvas.layoutIfNeeded()
            }
            let expected: CGFloat = action == 1 ? -18 : (action == 8 ? 18 : 0)
            XCTAssertEqual(canvas.remoteOffset, expected, "Snap/restart action \(action)")
        }
    }

    private func shifted(_ old: ScreenFrame, rows: Int, band: Range<Int>, serial: Int) -> ScreenFrame {
        var frame = old
        for y in band {
            if band.contains(y + rows) { frame.lines[y] = old.lines[y + rows] }
            else { frame.lines[y][0].text = "arrival \(serial) row \(y)" }
        }
        if band.lowerBound == 1 { frame.lines[0][0].text = "header \(serial)" }
        return frame
    }

    private func assertRemoteDrainMatchesFreshCanvas(_ canvas: TerminalCanvasView, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<100 { canvas.advanceRemoteShift(by: 1.0 / 120) }
        XCTAssertEqual(canvas.remoteOffset, 0, file: file, line: line)
        let fresh = TerminalCanvasView(frame: canvas.bounds)
        fresh.contentScaleFactor = canvas.contentScaleFactor
        fresh.screen = canvas.screen
        XCTAssertEqual(remoteImage(canvas).pngData(), remoteImage(fresh).pngData(),
                       "Including the exact authoritative header pixels", file: file, line: line)
    }

    func testRemoteBandReanchorsWhenHeaderJoinsAndLeavesInBothDirections() throws {
        for k in [1, -1] {
            for initialLower in [0, 1] {
                let (vt, model, canvas) = try fixture(mouse: true, alternate: true, rows: 26)
                defer { model.stop(); canvas.cancelScrolling() }
                canvas.screen = remotePaint(vt, offset: 0)
                for serial in 1...4 {
                    let lower = serial.isMultiple(of: 2) ? 1 - initialLower : initialLower
                    let band = lower..<24
                    let previous = canvas.remoteOffset
                    remoteWheel(canvas, rows: k)
                    canvas.screen = shifted(canvas.screen, rows: k, band: band, serial: serial)
                    XCTAssertEqual(canvas.remoteRegion, band)
                    XCTAssertEqual(canvas.remoteOffset, previous + CGFloat(k) * 18, accuracy: 0.001)
                    canvas.advanceRemoteShift(by: 0.012)
                }
                assertRemoteDrainMatchesFreshCanvas(canvas)
            }
        }
    }

    /// Codex's sticky header joins and leaves the scrolling band mid-glide. The strip must stay
    /// one continuous transcript column (no header copy spliced in, no missing row) and hold
    /// enough leaving rows to cover the residual offset at every step.
    func testRemoteStripStaysOneContinuousColumnWhileTheStickyHeaderJoinsAndLeaves() throws {
        func text(_ line: [ScreenCell]) -> String { line.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
        for k in [1, -1] {
            let (vt, model, canvas) = try fixture(mouse: true, alternate: true, rows: 26)
            defer { model.stop(); canvas.cancelScrolling() }
            let template = remotePaint(vt, offset: 0)
            func row(_ value: String) -> [ScreenCell] {
                var line = template.lines[1]
                for i in line.indices { line[i].text = "" }
                for (i, character) in value.enumerated() where i < line.count { line[i].text = String(character) }
                return line
            }
            func frame(scroll: Int, sticky: Bool) -> ScreenFrame {
                var frame = template
                for y in 0..<24 { frame.lines[y] = row("T\(100 + scroll + y)") }
                if sticky { frame.lines[0] = row("HEADER") }
                return frame
            }
            canvas.screen = frame(scroll: 0, sticky: true)
            var scroll = 0
            for (step, sticky) in [true, true, true, false, false, true, true, false, true, false].enumerated() {
                scroll += k
                remoteWheel(canvas, rows: k)
                canvas.screen = frame(scroll: scroll, sticky: sticky)
                let region = try XCTUnwrap(canvas.remoteRegion, "Glide at scroll \(scroll)")
                var texts = canvas.remoteStrip.map(text)
                // Scrolling back, a reappearing sticky header is indistinguishable from a row
                // entering at the top; it may only ever be that first entering row.
                if k < 0, texts.first == "HEADER" { texts.removeFirst() }
                XCTAssertFalse(texts.contains("HEADER"), "No fixed header copy in the strip: \(texts)")
                let numbers = texts.compactMap { Int($0.dropFirst()) }
                XCTAssertEqual(numbers.count, texts.count, "\(texts)")
                XCTAssertEqual(numbers, Array((numbers.first ?? 0)..<((numbers.first ?? 0) + numbers.count)),
                               "One continuous column at scroll \(scroll)")
                // Once rows have scrolled out, the strip covers the residual except for at most
                // the one row the header always hid (shown as background, never the frame below).
                if step >= 3 {
                    let leaving = canvas.remoteStrip.count - region.count
                    XCTAssertGreaterThanOrEqual(CGFloat(leaving + 1) * 18, abs(canvas.remoteOffset) - 0.001,
                                                "Leaving rows cover the residual at scroll \(scroll)")
                }
                canvas.advanceRemoteShift(by: 0.008)
            }
            assertRemoteDrainMatchesFreshCanvas(canvas)
        }
    }

    func testRemoteDrainNeverSlowsBelowNativeSpeedAboveItsGoal() {
        for gain: CGFloat in [0.25, 0.5, 1] {
            let slowed = RemoteScrollDrain.remaining(offset: 100, cellHeight: 18, velocity: 3000,
                                                     velocityAge: 0.008, gain: gain, dt: 1.0 / 120)
            let native = RemoteScrollDrain.remaining(offset: 100, cellHeight: 18, velocity: 3000,
                                                     velocityAge: 0.008, gain: 1, dt: 1.0 / 120)
            XCTAssertEqual(slowed, native, accuracy: 0.0001, "gain \(gain)")
        }
        // Below the goal a low gain still keeps the band behind a program that ignores reports.
        let behind = RemoteScrollDrain.remaining(offset: 9, cellHeight: 18, velocity: 400,
                                                 velocityAge: 0.008, gain: 0.25, dt: 1.0 / 120)
        let matched = RemoteScrollDrain.remaining(offset: 9, cellHeight: 18, velocity: 400,
                                                  velocityAge: 0.008, gain: 1, dt: 1.0 / 120)
        XCTAssertGreaterThan(behind, matched)
    }

    func testRemoteHeaderOnlyRepaintTrimsChangedEdgesWithoutDroppingResidual() throws {
        for k in [1, -1] {
            for changedRows in [[0], [0, 1], [23], [22, 23], [0, 23], [0, 1, 2]] {
                let (vt, model, canvas) = try fixture(mouse: true, alternate: true, rows: 26)
                defer { model.stop(); canvas.cancelScrolling() }
                canvas.screen = remotePaint(vt, offset: 0)
                remoteWheel(canvas, rows: k)
                canvas.screen = shifted(canvas.screen, rows: k, band: 0..<24, serial: 1)
                canvas.advanceRemoteShift(by: 0.012)
                let offset = canvas.remoteOffset
                var repaint = canvas.screen
                for y in changedRows { repaint.lines[y][0].text = "new edge \(y)" }
                canvas.screen = repaint
                if changedRows.count <= 2 {
                    XCTAssertEqual(canvas.remoteOffset, offset)
                    let band = try XCTUnwrap(canvas.remoteRegion)
                    XCTAssertGreaterThanOrEqual(band.count, 8)
                    XCTAssertTrue(changedRows.allSatisfy { !band.contains($0) })
                } else {
                    XCTAssertEqual(canvas.remoteOffset, 0, "A change wider than two rows still snaps")
                }
                assertRemoteDrainMatchesFreshCanvas(canvas)
            }
        }
    }

    func testRemoteInvisibleBlankRepaintKeepsGlidingButVisibleInkSnaps() throws {
        let (vt, model, canvas) = try fixture(mouse: true, alternate: true)
        defer { model.stop(); canvas.cancelScrolling() }
        canvas.screen = remotePaint(vt, offset: 0)
        remoteWheel(canvas, rows: 1)
        canvas.screen = remotePaint(vt, offset: 1)
        let offset = canvas.remoteOffset
        var repaint = canvas.screen
        let column = repaint.lines[8].count - 1
        XCTAssertTrue(repaint.lines[8][column].text.isEmpty)
        repaint.lines[8][column].text = " "
        repaint.lines[8][column].style.foreground = RGB(r: 255, g: 0, b: 0)
        repaint.lines[8][column].style.faint = true
        canvas.screen = repaint
        XCTAssertEqual(canvas.remoteOffset, offset)
        repaint.lines[8][column].style.underline = true
        canvas.screen = repaint
        XCTAssertEqual(canvas.remoteOffset, 0)
        assertRemoteDrainMatchesFreshCanvas(canvas)
    }

    func testRemoteEdgeTrimRequiresAtLeastEightVerifiedRows() throws {
        for count in [9, 10] {
            let (vt, model, canvas) = try fixture(mouse: true, alternate: true, rows: 26)
            defer { model.stop(); canvas.cancelScrolling() }
            canvas.screen = remotePaint(vt, offset: 0)
            remoteWheel(canvas, rows: 1)
            canvas.screen = shifted(canvas.screen, rows: 1, band: 0..<count, serial: 1)
            XCTAssertEqual(canvas.remoteRegion, 0..<count)
            let offset = canvas.remoteOffset
            var edge = canvas.screen
            edge.lines[0][0].text = "new header"
            edge.lines[1][0].text = "new subheader"
            canvas.screen = edge
            XCTAssertEqual(canvas.remoteOffset, count == 10 ? offset : 0)
            if count == 10 { XCTAssertEqual(canvas.remoteRegion, 2..<10) }
            assertRemoteDrainMatchesFreshCanvas(canvas)
        }
    }

    func testRemoteRepliesInFlightUseTheRecentWheelSignOnceAfterReversal() async throws {
        for expired in [false, true] {
            let (vt, model, canvas) = try fixture(mouse: true, alternate: true)
            defer { model.stop(); canvas.cancelScrolling() }
            canvas.screen = remotePaint(vt, offset: 0)
            remoteWheel(canvas, rows: 1)
            canvas.screen = remotePaint(vt, offset: 1)
            if expired { try await Task.sleep(for: .milliseconds(320)) }
            let residual = canvas.remoteOffset
            remoteWheel(canvas, rows: -1)
            // The reply belongs to the preceding positive wheel, not the latest input.
            canvas.screen = remotePaint(vt, offset: 2)
            XCTAssertEqual(canvas.remoteOffset, expired ? 0 : residual + 18, accuracy: 0.001)
        }
    }

    func testRemoteDrainMatchesSteadyNativeMotionAndBoundsBacklog() {
        let dt = 1.0 / 120
        for speed: CGFloat in [72, 400, 3000] {
            var offset: CGFloat = 0
            var periodSteps: [Int: CGFloat] = [:]
            var ratios: [CGFloat] = []
            for tick in 1...720 {
                let time = Double(tick) * dt
                let before = Double(tick - 1) * dt
                let arrived = Int(floor(time * speed / 18 + 1e-8)) - Int(floor(before * speed / 18 + 1e-8))
                offset += CGFloat(arrived) * 18
                let remaining = RemoteScrollDrain.remaining(offset: offset, cellHeight: 18,
                    velocity: speed, velocityAge: 0, dt: dt)
                let step = offset - remaining
                offset = remaining
                XCTAssertGreaterThanOrEqual(offset, 0)
                XCTAssertLessThanOrEqual(offset, 36)
                if time > 1 {
                    ratios.append(step / (speed * dt))
                    if speed != 72 { XCTAssertEqual(step, speed * dt, accuracy: 0.25 * speed * dt) }
                }
                // At 72 pt/s the period is 250 ms, equal to the correction time constant:
                // test the period mean, not an incompatible pointwise ±25% requirement.
                if speed == 72 { periodSteps[(tick - 1) / 30, default: 0] += step }
            }
            if speed == 72 {
                for period in 1..<24 { XCTAssertEqual(periodSteps[period]!, 18, accuracy: 18 * 0.25) }
            }
            print("REMOTE_DRAIN_STEADY speed=\(speed) tick_ratio_min=\(ratios.min()!) max=\(ratios.max()!) backlog_pt=\(offset)")
        }
    }

    func testRemoteDrainSettlesExactlyLikeOldFollowerWithoutForwardNativeMotion() {
        for sign: CGFloat in [1, -1] {
            for (velocity, age): (CGFloat, Double) in [(0, 0), (24, 0), (400, 0.05), (400, 1), (-400, 0)] {
                var offset = sign * 108
                for _ in 0..<60 {
                    let previous = offset
                    offset = RemoteScrollDrain.remaining(offset: offset, cellHeight: 18,
                        velocity: sign * velocity, velocityAge: age, dt: 1.0 / 120)
                    XCTAssertEqual(offset, previous * exp(-1.0 / 120 / 0.04), accuracy: 1e-10)
                    XCTAssertGreaterThanOrEqual(offset * sign, 0)
                    XCTAssertLessThan(abs(offset), abs(previous))
                }
            }
            for velocity: CGFloat in [25, 72, 400, 3000, 100_000] {
                for dt in [0.0, 1.0 / 120, 0.1, 2] {
                    let offset = RemoteScrollDrain.remaining(offset: sign * 18, cellHeight: 18,
                        velocity: sign * velocity, velocityAge: 0, gain: 4, dt: dt)
                    XCTAssertGreaterThanOrEqual(offset * sign, 0)
                    XCTAssertLessThanOrEqual(abs(offset), 18)
                }
            }
        }
    }

    func testRemoteDrainSixRowBurstHasNoExtraSpikeAtRestOrModerateSpeed() {
        for dt in [1.0 / 120, 1.0 / 60] {
            let oldStep = 108 * (1 - exp(-dt / 0.04))
            for speed: CGFloat in [0, 72, 400, 800] {
                for age in [0.0, 0.05] {
                    let remaining = RemoteScrollDrain.remaining(offset: 108, cellHeight: 18,
                        velocity: speed, velocityAge: age, dt: dt)
                    let step = 108 - remaining
                    if speed == 0 || age >= 0.05 { XCTAssertEqual(step, oldStep, accuracy: 1e-10) }
                    else { XCTAssertLessThanOrEqual(step, max(oldStep, 1.25 * speed * dt)) }
                }
            }
        }
    }

    func testRemoteDrainFiltersNativeVelocityAndUsesOnlyRecentDistanceForGain() {
        var drain = RemoteScrollDrain()
        drain.begin(at: 0, time: 0)
        drain.moved(to: 12, time: 0.03)
        XCTAssertEqual(drain.velocity, 400 * (1 - exp(-1)), accuracy: 1e-8)
        drain.arrived(rows: 2, cellHeight: 18, time: 0.03)
        XCTAssertEqual(drain.gain(cellHeight: 18), 1, "Need at least three received rows")
        drain.arrived(rows: 1, cellHeight: 18, time: 0.03)
        XCTAssertEqual(drain.gain(cellHeight: 18), 4, "Gain is clamped")
        drain.moved(to: 1012, time: 0.04)
        XCTAssertEqual(drain.gain(cellHeight: 18), 0.25)
        // Pruning on the drain's clock removes both numerator and denominator.
        _ = drain.remaining(offset: 18, cellHeight: 18, time: 0.6, dt: 0)
        XCTAssertEqual(drain.gain(cellHeight: 18), 1)
        drain.begin(at: 0, time: 1)
        drain.moved(to: 108, time: 1.1)
        drain.arrived(rows: 3, cellHeight: 18, time: 1.1)
        XCTAssertEqual(drain.gain(cellHeight: 18), 0.5)
        drain.stop()
        XCTAssertEqual(drain.velocity, 0)
        XCTAssertEqual(drain.remaining(offset: 18, cellHeight: 18, time: 1.1, dt: 0.01),
                       18 * exp(-0.01 / 0.04), accuracy: 1e-10)
    }

    func testRemoteNativeEndCallbacksReturnTheFollowerToExponentialSettle() throws {
        for decelerating in [false, true] {
            let (vt, model, canvas) = try fixture(mouse: true, alternate: true)
            defer { model.stop(); canvas.cancelScrolling() }
            canvas.screen = remotePaint(vt, offset: 0)
            remoteWheel(canvas, rows: 3)
            canvas.screen = remotePaint(vt, offset: 3)
            canvas.scrollViewDidEndDragging(canvas.scrollView, willDecelerate: decelerating)
            if decelerating { canvas.scrollViewDidEndDecelerating(canvas.scrollView) }
            let offset = canvas.remoteOffset
            canvas.advanceRemoteShift(by: 0.01)
            XCTAssertEqual(canvas.remoteOffset, offset * exp(-0.01 / 0.04), accuracy: 1e-8)
            assertRemoteDrainMatchesFreshCanvas(canvas)
        }
    }

    func testRemoteRetainedRowTapIsConsumedAndCurrentRowsUseInverseMapping() throws {
        for retained in [false, true] {
            let (vt, model, canvas) = try fixture(mouse: true, alternate: true)
            defer { model.stop() }
            var input: [Data] = []
            model.sentInputForTesting = { input.append($0) }
            canvas.screen = remotePaint(vt, offset: 0)
            remoteWheel(canvas, rows: 3)
            canvas.screen = remotePaint(vt, offset: 3)
            let count = input.count
            canvas.handleTap(at: CGPoint(x: 20, y: retained ? 37 : 190))
            XCTAssertEqual(canvas.remoteOffset, 0)
            if retained { XCTAssertEqual(input.count, count, "No remote click targets a retained row") }
            else {
                XCTAssertGreaterThan(input.count, count)
                XCTAssertTrue(String(decoding: input[count], as: UTF8.self).hasPrefix("\u{1b}[<0;2;8M"))
            }
        }
    }

    /// A band that reaches the grid's edge must not inverse-map taps in the padding beyond it.
    func testRemotePaddingTapKeepsThePhysicalRow() throws {
        let (vt, model, canvas) = try fixture(mouse: true, alternate: true)
        defer { model.stop() }
        var input: [Data] = []
        model.sentInputForTesting = { input.append($0) }
        canvas.screen = remotePaint(vt, offset: 20, chrome: false)
        remoteWheel(canvas, rows: -3)
        canvas.screen = remotePaint(vt, offset: 17, chrome: false)
        XCTAssertLessThan(canvas.remoteOffset, 0, "The band glides")
        let count = input.count
        canvas.handleTap(at: CGPoint(x: 20, y: 5))
        XCTAssertGreaterThan(input.count, count)
        XCTAssertTrue(String(decoding: input[count], as: UTF8.self).hasPrefix("\u{1b}[<0;2;1M"))
    }

    func testRemoteBandVisualsAtPhoneAndDuoSizes() throws {
        for dark in [false, true] {
            for (name, size) in [("phone", CGSize(width: 320, height: 640)),
                                 ("duo", CGSize(width: 669, height: 951))] {
                let (vt, model, canvas) = try fixture(mouse: true, alternate: true, rows: 30)
                defer { model.stop(); canvas.cancelScrolling() }
                canvas.frame.size = size
                canvas.contentScaleFactor = 3
                canvas.overrideUserInterfaceStyle = dark ? .dark : .light
                let colors = dark ? "ffffff;101010" : "161616;eeeeee"
                let pair = colors.split(separator: ";")
                vt.write(Data("\u{1b}]10;#\(pair[0])\u{07}\u{1b}]11;#\(pair[1])\u{07}".utf8))
                canvas.screen = remotePaint(vt, offset: 0)
                canvas.layoutIfNeeded()
                let before = remoteImage(canvas)
                remoteWheel(canvas, rows: 3)
                canvas.screen = remotePaint(vt, offset: 3)
                let arrival = remoteImage(canvas)
                if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
                    let base = URL(fileURLWithPath: folder).appendingPathComponent("remote-\(name)-\(dark ? "dark" : "light")")
                    try before.pngData()?.write(to: base.appendingPathExtension("before.png"))
                    try arrival.pngData()?.write(to: base.appendingPathExtension("arrival.png"))
                }
                XCTAssertEqual(arrival.pngData(), before.pngData())
                canvas.advanceRemoteShift(by: 0.025)
                let during = remoteImage(canvas)
                if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
                    try during.pngData()?.write(to: URL(fileURLWithPath: folder)
                        .appendingPathComponent("remote-\(name)-\(dark ? "dark" : "light").png"))
                }
                canvas.cancelScrolling()
            }
        }
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

    /// The painted rows move with UIKit's native offset; only a row change repaints them.
    /// Draws and movements are counted separately, so "no draw" can't hide a frozen screen.
    func testFractionOnlyMotionMovesPaintedRowsWithoutCPUDraws() throws {
        let (vt, model, canvas) = try fixture()
        defer { model.stop() }
        let content = canvas.contentView
        let clip = try XCTUnwrap(content.superview)
        func displayedTop() -> CGFloat { content.convert(CGPoint.zero, to: canvas).y }
        content.layer.displayIfNeeded()
        XCTAssertFalse(clip.clipsToBounds, "The live screen is not clipped")
        XCTAssertEqual(displayedTop(), 0)
        XCTAssertTrue(canvas.hitTest(CGPoint(x: 100, y: 100), with: nil) === canvas.scrollView,
                      "The painted rows never take touches")
        XCTAssertFalse(content.isUserInteractionEnabled || clip.isUserInteractionEnabled)

        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        let base = (floor(canvas.scrollView.contentOffset.y / 18) - 6) * 18
        move(canvas, to: base + 1)
        XCTAssertTrue(content.layer.needsDisplay(), "Entering rows repaint")
        content.layer.displayIfNeeded()
        let draws = canvas.contentDraws
        let moves = canvas.contentMoves
        XCTAssertTrue(clip.clipsToBounds)
        XCTAssertEqual(clip.frame, CGRect(x: 0, y: 10, width: 500, height: 20 * 18),
                       "The clip is exactly the original grid: nothing above or below it is masked")
        for (step, fraction) in [CGFloat(1.5), 4.25, 9.5, 17.5, 3].enumerated() {
            canvas.layoutIfNeeded()
            move(canvas, to: base + fraction)
            XCTAssertFalse(canvas.layer.needsLayout(), "A fraction alone must not lay out the canvas again")
            XCTAssertFalse(content.layer.needsDisplay(), "A fraction alone must not repaint")
            canvas.layoutIfNeeded()
            content.layer.displayIfNeeded()
            XCTAssertEqual(canvas.contentDraws, draws)
            XCTAssertEqual(canvas.contentMoves, moves + step + 1, "Every native offset moves the rows")
            let aligned = (fraction * 2).rounded() / 2
            XCTAssertEqual(canvas.scrollFraction, aligned)
            XCTAssertEqual(displayedTop(), -aligned, "Displayed geometry follows the native offset")
            XCTAssertEqual(visibleOffset(canvas), (canvas.scrollView.contentOffset.y * 2).rounded() / 2, accuracy: 0.001)
            XCTAssertEqual(canvas.cell(at: CGPoint(x: 20, y: 10 + 18 - aligned + 0.25)).y, 1,
                           "Hit testing uses the same displayed geometry")
        }
        // Updates arriving inside an animation block (keyboard, SwiftUI) don't animate the rows.
        UIView.animate(withDuration: 1) { self.move(canvas, to: base + 6) }
        XCTAssertNil(clip.layer.animationKeys())
        XCTAssertNil(content.layer.animationKeys())
        XCTAssertEqual(displayedTop(), -6)
        move(canvas, to: base + 18 + 2)
        XCTAssertTrue(content.layer.needsDisplay(), "A whole row repaints the changed rows")

        canvas.cancelScrolling()
        XCTAssertEqual(canvas.scrollFraction, 0)
        XCTAssertEqual(displayedTop(), 0, "A fraction reset moves the painted rows back")
        canvas.layoutIfNeeded()
        content.layer.displayIfNeeded()
        let settled = canvas.contentDraws
        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        move(canvas, to: canvas.scrollView.contentOffset.y - 18 + 7)
        let native = canvas.scrollView.contentOffset.y
        let remainder = ((native - floor(native / 18) * 18) * 2).rounded() / 2
        XCTAssertGreaterThan(remainder, 0)
        XCTAssertEqual(displayedTop(), -remainder)
        canvas.layoutIfNeeded()
        content.layer.displayIfNeeded()
        XCTAssertEqual(canvas.contentDraws, settled + 1, "One repaint for the row change; layout passes add none")
        move(canvas, to: native + 0.5)
        canvas.layoutIfNeeded()
        content.layer.displayIfNeeded()
        XCTAssertEqual(canvas.contentDraws, settled + 1)
        // A route switch (a full-screen program) cancels the gesture and drops the fraction.
        vt.write(Data("\u{1b}[?1049h".utf8))
        canvas.screen = vt.frame()
        XCTAssertEqual(model.scrollRoute, .remote)
        XCTAssertEqual(canvas.scrollFraction, 0)
        XCTAssertEqual(displayedTop(), 0)
        XCTAssertFalse(clip.clipsToBounds)
        XCTAssertTrue(content.layer.needsDisplay())
    }

    /// Crossing rows repaints only invalidated lines and moves the rest. What shows after each
    /// native step (down and back up, across several rows) equals a fresh canvas placed there.
    func testRowCrossingPixelsMatchAFreshCanvasAtTheSameOffset() throws {
        let (_, model, canvas) = try fixture()
        defer { model.stop() }
        func image(_ view: TerminalCanvasView) -> Data {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image {
                view.renderForTesting(in: $0.cgContext, repaint: false)
            }.pngData()!
        }
        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        let base = (floor(canvas.scrollView.contentOffset.y / 18) - 10) * 18
        var crossed = 0
        var previousRow = canvas.screen.scrollbar!.offset
        for offset in [base + 9, base + 17.5, base + 18.5, base + 30, base + 41.5, base + 23, base + 12.5, base + 3] {
            move(canvas, to: offset)
            if canvas.screen.scrollbar!.offset != previousRow { crossed += 1 }
            previousRow = canvas.screen.scrollbar!.offset
            let (_, freshModel, fresh) = try fixture()
            defer { freshModel.stop() }
            fresh.scrollViewWillBeginDragging(fresh.scrollView)
            fresh.scrollView.contentOffset.y = offset
            XCTAssertEqual(fresh.screen.scrollbar!.offset, canvas.screen.scrollbar!.offset)
            XCTAssertEqual(fresh.scrollFraction, canvas.scrollFraction)
            XCTAssertEqual(image(canvas), image(fresh), "Shown pixels at native offset \(offset)")
        }
        XCTAssertGreaterThanOrEqual(crossed, 5, "Exercise real row crossings both ways")
    }

    func testPaintedRowsUseTheWindowScreenScale() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        window.addSubview(canvas)
        window.makeKeyAndVisible()
        canvas.layoutIfNeeded()
        XCTAssertEqual(canvas.contentView.contentScaleFactor, window.screen.scale)
        XCTAssertEqual(canvas.contentScaleFactor, window.screen.scale,
                       "Fractions and cached rows round to the screen's pixels, not the non-drawing canvas's")
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

    func testRemoteWheelOrderNoPredictionAndNoInputAfterCancellationOrReplacement() throws {
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
            return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image {
                view.renderForTesting(in: $0.cgContext, repaint: false)
            }.cgImage!
        }
        let full = bitmap(reference)
        canvas.scrollViewWillBeginDragging(canvas.scrollView)
        move(canvas, to: CGFloat(target) * 18 + 0.5)
        _ = bitmap(canvas)
        let draws = canvas.contentDraws
        for fraction: CGFloat in [0.5, 9, 17.5] {
            move(canvas, to: CGFloat(target) * 18 + fraction)
            let actual = bitmap(canvas)
            XCTAssertEqual(canvas.contentDraws, draws, "Within a row the displayed pixels move without a CPU repaint")
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
        let framesBeforeWheel = model.renderedFrames
        // A second wheel in the split DEC 2026 frame must not publish its partial rows.
        move(canvas, to: canvas.scrollView.contentOffset.y - 18)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.frame.text, before)
        XCTAssertEqual(model.renderedFrames, framesBeforeWheel)
        model.receiveOutputForTesting(Data("\u{1b}[Hcomplete\u{1b}[?2026l".utf8))
        for _ in 0..<100 where !model.frame.text.hasPrefix("complete") { await Task.yield() }
        XCTAssertTrue(model.frame.text.hasPrefix("complete"), "The completed response uses the same main-actor turn")
        XCTAssertEqual(model.renderedFrames, framesBeforeWheel + 1)

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

    func testAgedRemoteWheelHoldPublishesTheEscapeFrame() async throws {
        for mouse in [false, true] {
            let (_, model, canvas) = try fixture(mouse: mouse, alternate: true)
            defer { model.stop(); canvas.cancelScrolling() }
            remoteWheel(canvas, rows: 1)
            model.receiveOutputForTesting(Data("\u{1b}[?2026h\u{1b}[Hparked".utf8))
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertFalse(model.frame.text.hasPrefix("parked"))
            let before = model.renderedFrames
            move(canvas, to: canvas.scrollView.contentOffset.y + 18)
            for _ in 0..<100 where !model.frame.text.hasPrefix("parked") { await Task.yield() }
            XCTAssertTrue(model.frame.text.hasPrefix("parked"))
            XCTAssertEqual(model.renderedFrames, before + 1)
        }
    }
}
