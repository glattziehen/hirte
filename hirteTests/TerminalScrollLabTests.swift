import XCTest
import UIKit
import SwiftUI
import HerdrKit
@testable import hirte

/// Fixed, generic workloads. Timings are simulator CPU/wall time, never device FPS.
@MainActor
final class TerminalScrollLabTests: XCTestCase {
    func testSeparateScrollPathsBenchmark() throws {
        for remote in [false, true] {
            let vt = try VirtualTerminal(cols: 100, rows: 60)
            for row in 0..<1000 {
                vt.write(Data("\u{1b}[32mitem \(row)\u{1b}[0m ready 漢 e\u{301} sample\r\n".utf8))
            }
            if remote { vt.write(Data("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h".utf8)) }
            let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
            canvas.contentScaleFactor = 2
            canvas.screen = vt.frame()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: canvas.bounds.size, format: format)
            var input: [Double] = [], feed: [Double] = [], snapshot: [Double] = [], draw: [Double] = []
            var bytes = 0
            _ = renderer.image { _ in
                for sample in 0..<150 {
                    autoreleasepool {
                        let start = CACurrentMediaTime()
                        let wheel = vt.wheel(lines: sample % 40 < 20 ? -1 : 1, column: 20, row: 20)
                        let encoded = CACurrentMediaTime()
                        if case .send(let data) = wheel { bytes += data.count }
                        // Deterministic synthetic TUI response, including synchronized-output boundaries.
                        if remote {
                            vt.write(Data("\u{1b}[?2026h\u{1b}[H".utf8))
                            for row in 0..<60 {
                                vt.write(Data("\u{1b}[\(row + 1);1H\u{1b}[36mitem \(sample + row)\u{1b}[0m ready 漢 e\u{301}\u{1b}[K".utf8))
                            }
                            vt.write(Data("\u{1b}[?2026l".utf8))
                        }
                        let fed = CACurrentMediaTime()
                        canvas.screen = vt.frame()
                        let snapped = CACurrentMediaTime()
                        canvas.drawForTesting(canvas.bounds)
                        let end = CACurrentMediaTime()
                        if sample >= 30 {
                            input.append((encoded - start) * 1000)
                            feed.append((fed - encoded) * 1000)
                            snapshot.append((snapped - fed) * 1000)
                            draw.append((end - snapped) * 1000)
                        }
                    }
                }
            }
            print("SCROLL_LAB path=\(remote ? "remote-tui" : "local-history") samples=120 warmup=30 grid=100x60 bitmap=834x1194@2 input_ms \(stats(input)) feed_ms \(stats(feed)) snapshot_invalidate_ms \(stats(snapshot)) draw_ms \(stats(draw)) encoded_bytes=\(bytes)")
            XCTAssertEqual(bytes, remote ? 1800 : 0)
            XCTAssertLessThanOrEqual(canvas.textRowBytes, 32 * 1024 * 1024)
        }
    }

    func testVisibleIPadRowsCacheDiagnostic() throws {
        let vt = try VirtualTerminal(cols: 100, rows: 60)
        for row in 0..<1000 { vt.write(Data("item \(row) ready 漢 e\u{301}\r\n".utf8)) }
        let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 834, height: 1194))
        canvas.contentScaleFactor = 2
        canvas.screen = vt.frame()
        let renderer = UIGraphicsImageRenderer(size: canvas.bounds.size)
        _ = renderer.image { _ in
            canvas.drawForTesting(canvas.bounds)
            let initial = canvas.textRowRasterizations
            canvas.drawForTesting(canvas.bounds)
            let repeated = canvas.textRowRasterizations - initial
            XCTAssertEqual(repeated, 0, "A visible iPad viewport must fit without LRU thrashing")
            vt.scroll(by: -1)
            canvas.screen = vt.frame()
            canvas.drawForTesting(canvas.bounds)
            XCTAssertEqual(canvas.textRowRasterizations - initial - repeated, 1, "Only the entering row needs rasterization")
            print("CACHE_LAB grid=100x60 initial=\(initial) unchanged_misses=\(repeated) scroll_misses=\(canvas.textRowRasterizations - initial - repeated) bytes=\(canvas.textRowBytes)")
        }
    }

    func testScrollEventSchedulingBenchmark() async throws {
        let vt = try VirtualTerminal(cols: 100, rows: 60)
        for row in 0..<1000 { vt.write(Data("item \(row) ready\r\n".utf8)) }
        let model = TerminalScreenModel(
            theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: vt)
        defer { model.stop() }
        var callbacks: [Double] = [], publication: [Double] = []
        let framesBefore = model.renderedFrames
        for batch in 0..<40 {
            let offset = try XCTUnwrap(model.frame.scrollbar).offset
            let direction = batch % 2 == 0 ? -1 : 1
            let start = CACurrentMediaTime()
            for _ in 0..<8 { model.scroll(lines: direction, column: 20, row: 20) }
            let returned = CACurrentMediaTime()
            let deadline = returned + 1
            while model.frame.scrollbar?.offset != offset + direction * 8, CACurrentMediaTime() < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertEqual(model.frame.scrollbar?.offset, offset + direction * 8)
            callbacks.append((returned - start) * 1000)
            publication.append((CACurrentMediaTime() - start) * 1000)
        }
        print("SCHEDULING_LAB batches=40 events_per_batch=8 grid=100x60 callback_ms \(stats(callbacks)) event_to_publication_ms \(stats(publication)) frames=\(model.renderedFrames - framesBefore)")
    }

    /// Runs the production Observation → SwiftUI → UIView invalidation path in a real
    /// simulator window. Draw completion is observable; compositor/physical scanout is not.
    func testEventToUIKitDrawProbe() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for remote in [false, true] {
            let terminal = try VirtualTerminal(cols: 100, rows: 60)
            for row in 0..<1000 { terminal.write(Data("sample \(row) ready\r\n".utf8)) }
            if remote { terminal.write(Data("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h".utf8)) }
            let model = TerminalScreenModel(
                theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: terminal)
            let host = UIHostingController(rootView: TerminalCanvas(model: model, fontSize: .constant(13)) { _, _ in })
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            func findCanvas(_ view: UIView) -> TerminalCanvasView? {
                if let canvas = view as? TerminalCanvasView { return canvas }
                return view.subviews.lazy.compactMap(findCanvas).first
            }
            let canvas = try XCTUnwrap(findCanvas(host.view))
            try await Task.sleep(for: .milliseconds(100))
            if remote { canvas.scrollViewWillBeginDragging(canvas.scrollView) }
            var draws: [Double] = []
            var callback: [Double] = []
            // Sustain the real Observation → UIKit path for about four seconds at 60 Hz.
            // This is scripted scroll input, not a physical pan or compositor FPS probe.
            let sampleCount = 240
            let traceStart = CACurrentMediaTime()
            for sample in 0..<sampleCount {
                let old = model.frame.lines.first
                var drawnAt: CFTimeInterval?
                canvas.didDrawForTesting = {
                    if canvas.screen.lines.first != old { drawnAt = CACurrentMediaTime() }
                }
                let start = CACurrentMediaTime()
                for _ in 0..<8 { model.scroll(lines: sample % 2 == 0 ? -1 : 1, column: 20, row: 20) }
                if remote {
                    model.receiveOutputForTesting(Data("\u{1b}[?2026h\u{1b}[H".utf8))
                    for row in 0..<60 {
                        model.receiveOutputForTesting(Data("\u{1b}[\(row + 1);1Hsample \(sample + row) ready\u{1b}[K".utf8))
                    }
                    model.receiveOutputForTesting(Data("\u{1b}[?2026l".utf8))
                }
                callback.append((CACurrentMediaTime() - start) * 1000)
                let deadline = start + 1
                while drawnAt == nil, CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(1)) }
                draws.append(((try XCTUnwrap(drawnAt)) - start) * 1000)
                canvas.didDrawForTesting = nil
            }
            print("DRAW_PIPELINE_LAB path=\(remote ? "synthetic-tui" : "local-history") samples=\(sampleCount) duration_s=\(CACurrentMediaTime() - traceStart) grid=100x60 view=\(canvas.bounds.size) scale=\(canvas.contentScaleFactor) callback_feed_ms \(stats(callback)) event_to_uikit_draw_ms \(stats(draws))")
        }
    }

    func testInteractionRenderingCoalescesAndCancelsWithoutLosingScroll() async throws {
        let terminal = try VirtualTerminal(cols: 40, rows: 10)
        for row in 0..<100 { terminal.write(Data("sample \(row)\r\n".utf8)) }
        let model = TerminalScreenModel(
            theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: terminal)
        let offset = try XCTUnwrap(model.frame.scrollbar).offset
        for _ in 0..<8 { model.scroll(lines: -1, column: 1, row: 1) }
        XCTAssertEqual(model.renderedFrames, 0)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.renderedFrames, 1)
        XCTAssertEqual(model.frame.scrollbar?.offset, offset - 8)
        model.scroll(lines: -1, column: 1, row: 1)
        model.stop()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.renderedFrames, 1, "Detached views must cancel queued renders")
    }

    func testLargestIPadAndUnfoldedDuoViewportsFitCache() throws {
        // Native integrated-display dimensions from installed CoreSimulator capabilities.plist:
        // iPad Pro 13-inch (M5): 2064×2752 @2; iPhone Duo inner display: 2007×2853 @3.
        // Render full bounds without navigation/keyboard insets, in both orientations.
        let devices: [(String, CGSize, CGFloat)] = [
            ("ipad-13", CGSize(width: 1032, height: 1376), 2),
            ("duo-inner", CGSize(width: 669, height: 951), 3)
        ]
        for (name, portrait, scale) in devices {
            for size in [portrait, CGSize(width: portrait.height, height: portrait.width)] {
                for family in TerminalFont.allCases {
                    for fontSize: CGFloat in [7, 13] {
                        try autoreleasepool {
                            let fonts = Fonts(size: fontSize, family: family)
                            let cols = Int((size.width - 20) / fonts.cellWidth)
                            let rows = Int((size.height - 20) / fonts.cellHeight)
                            let terminal = try VirtualTerminal(cols: cols, rows: rows)
                            for row in 0..<(rows + 200) {
                                terminal.write(Data("sample \(row) ready 漢 e\u{301}\r\n".utf8))
                            }
                            let canvas = TerminalCanvasView(frame: CGRect(origin: .zero, size: size))
                            canvas.fontFamily = family
                            canvas.fontSize = fontSize
                            canvas.contentScaleFactor = scale
                            canvas.screen = terminal.frame()
                            let format = UIGraphicsImageRendererFormat()
                            format.scale = scale
                            let renderer = UIGraphicsImageRenderer(size: size, format: format)
                            var unchangedMisses = 0, scrollMisses = 0
                            _ = renderer.image { _ in
                                canvas.drawForTesting(canvas.bounds)
                                let initial = canvas.textRowRasterizations
                                canvas.drawForTesting(canvas.bounds)
                                unchangedMisses = canvas.textRowRasterizations - initial
                                XCTAssertEqual(unchangedMisses, 0, "Visible rows must all fit")
                                let repeated = canvas.textRowRasterizations
                                terminal.scroll(by: -1)
                                canvas.screen = terminal.frame()
                                canvas.drawForTesting(canvas.bounds)
                                scrollMisses = canvas.textRowRasterizations - repeated
                                XCTAssertEqual(scrollMisses, 1)
                                let model = TerminalScreenModel(
                                    theme: TerminalTheme.find(TerminalTheme.defaultDark, dark: true), terminal: terminal)
                                canvas.model = model
                                canvas.screen = model.frame
                                canvas.layoutIfNeeded()
                                canvas.scrollViewWillBeginDragging(canvas.scrollView)
                                canvas.scrollView.contentOffset.y -= 0.5
                                canvas.drawForTesting(canvas.bounds)
                                let fractional = canvas.textRowRasterizations
                                canvas.drawForTesting(canvas.bounds)
                                XCTAssertEqual(canvas.textRowRasterizations, fractional,
                                               "The fractional viewport including real overscan must fit too")
                                XCTAssertLessThanOrEqual(canvas.textRowBytes, 32 * 1024 * 1024)
                                model.stop()
                            }
                            print("VIEWPORT_CACHE_LAB device=\(name) size=\(size) scale=\(scale) font=\(family.rawValue)/\(fontSize) grid=\(cols)x\(rows) bytes=\(canvas.textRowBytes) unchanged_misses=\(unchangedMisses) scroll_misses=\(scrollMisses)")
                        }
                    }
                }
            }
        }
    }

    private func stats(_ values: [Double]) -> String {
        let sorted = values.sorted()
        return String(format: "median=%.3f p95=%.3f p99=%.3f max=%.3f over_16_7ms=%d over_33ms=%d",
                      sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)],
                      sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))], sorted.last!,
                      sorted.filter { $0 > 16.7 }.count, sorted.filter { $0 > 33 }.count)
    }
}
