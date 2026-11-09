import XCTest
import UIKit
import HerdrKit
import CoreText
@testable import hirte

/// The same fixture is run before and after renderer changes. This measures CPU time in
/// the real VT snapshot and UIView CoreGraphics drawing, not display FPS or network latency.
@MainActor
final class TerminalRenderingTests: XCTestCase {
    private func fixture() throws -> VirtualTerminal {
        let vt = try VirtualTerminal(cols: 44, rows: 45)
        for row in 0..<1000 {
            vt.write(Data("\u{1B}[32mitem \(row)\u{1B}[0m build ready 漢 e\u{301} 👩‍💻\r\n".utf8))
        }
        return vt
    }

    func testFrameAndCanvasBenchmark() throws {
        let vt = try fixture()
        let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        canvas.fontSize = 13
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvas.bounds.size, format: format)
        for scenario in ["scroll", "output", "sparse"] {
            vt.scroll(by: nil)
            var snapshot: [Double] = [], drawing: [Double] = [], total: [Double] = []
            // One bitmap allocation; every sample executes the actual UIView draw path.
            _ = renderer.image { _ in
                for sample in 0..<150 {
                    autoreleasepool {
                        let start = CACurrentMediaTime()
                        switch scenario {
                        case "scroll": vt.scroll(by: sample % 40 < 20 ? -1 : 1)
                        case "output":
                            vt.write(Data("\u{1B}[36mjob \(sample)\u{1B}[0m ready 漢 e\u{301} 👩‍💻\r\n".utf8))
                        default:
                            vt.write(Data("\u{1B}[2;1Hstep \(sample)\u{1B}[K".utf8))
                        }
                        let frame = vt.frame()
                        let snapped = CACurrentMediaTime()
                        canvas.screen = frame
                        canvas.drawForTesting(canvas.bounds)
                        let end = CACurrentMediaTime()
                        if sample >= 30 {
                            snapshot.append((snapped - start) * 1000)
                            drawing.append((end - snapped) * 1000)
                            total.append((end - start) * 1000)
                        }
                    }
                }
            }
            func stats(_ values: [Double]) -> String {
                let sorted = values.sorted()
                return String(format: "median=%.3f p95=%.3f", sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)])
            }
            print("RENDER_BENCH scenario=\(scenario) samples=120 warmup=30 grid=44x45 bitmap=390x844@3 snapshot_ms \(stats(snapshot)) canvas_ms \(stats(drawing)) total_ms \(stats(total))")
            XCTAssertEqual(canvas.screen.cols, 44)
        }
    }

    func testGlyphContactSheet() throws {
        for family in TerminalFont.allCases {
            for size: CGFloat in [7, 13, 28] {
                let vt = try VirtualTerminal(cols: 36, rows: 10)
                let lines = ["\u{1B}[?25lA\u{E0A0}B \u{F07C}X \u{E725}Y \u{F0001}Z",
                    "\u{1B}[42;30m left \u{1B}[40;32m\u{E0B0}\u{1B}[0m right",
                    "\u{E0B0}\u{E0B1}\u{E0B2}\u{E0B3} ┌─┐ ▁▃▅█ ⣿",
                    "漢字 e\u{301} 👩‍💻 🙂 adjacent",
                    "\u{1B}[1mBold \u{F07C}X\u{1B}[0m \u{1B}[3mItalic \u{E725}Y\u{1B}[0m",
                    "\u{1B}[4munderline\u{1B}[0m \u{1B}[9mstrike\u{1B}[0m",
                    "unknown \u{EFFF} safe"]
                vt.write(Data(lines.joined(separator: "\r\n").utf8))
                let fonts = Fonts(size: size, family: family)
                let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0,
                    width: ceil(fonts.cellWidth * 36) + 20, height: fonts.cellHeight * 10 + 20))
                canvas.fontFamily = family
                canvas.fontSize = size
                canvas.screen = vt.frame()
                let format = UIGraphicsImageRendererFormat()
                format.scale = 3
                let image = UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image {
                    canvas.renderForTesting(in: $0.cgContext)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "glyphs-\(family.rawValue)-\(Int(size))"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertTrue(canvas.screen.text.contains("漢字 e\u{301} 👩‍💻"))
            }
        }
    }

    func testSymbolsAreBundledAndDoNotChangeGridMetrics() {
        for family in TerminalFont.allCases {
            for size: CGFloat in [7, 13, 28] {
                let fonts = Fonts(size: size, family: family)
                XCTAssertEqual(fonts.symbols.fontName, "SymbolsNFM")
                XCTAssertEqual(fonts.cellWidth, ("M" as NSString).size(withAttributes: [.font: fonts.regular]).width)
                for text in ["\u{E0A0}", "\u{F07C}", "\u{E725}", "\u{F0001}"] {
                    let characters = Array(text.utf16)
                    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                    XCTAssertTrue(CTFontGetGlyphsForCharacters(fonts.symbols as CTFont, characters, &glyphs, characters.count), text)
                }
            }
        }
    }

    private func pixels(_ canvas: TerminalCanvasView) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = canvas.contentScaleFactor
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image {
            canvas.renderForTesting(in: $0.cgContext)
        }
        return image.cgImage!.dataProvider!.data! as Data
    }

    func testCachedRowsMatchFreshCanvasAcrossChanges() throws {
        let vt = try fixture()
        let canvas = TerminalCanvasView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        // Keep the same cache through edits, scrolling, cursor, selection, colors, font,
        // Retina scale and resize. A new view renders the same state without previous entries.
        for step in 0..<28 {
            vt.write(Data("\u{1B}[2;2H\u{1B}[\(step % 2 == 0 ? 31 : 34)m\(step) 漢 e\u{301} \u{F07C}\u{1B}[0m".utf8))
            if step % 3 == 0 { vt.scroll(by: -2) } else { vt.scroll(by: nil) }
            if step % 4 == 0 { vt.select(from: (2, 2), to: (8, 3)) } else { vt.clearSelection() }
            if step % 5 == 0 { vt.resize(cols: 42, rows: 43) } else { vt.resize(cols: 44, rows: 45) }
            if step >= 8 {
                if step % 2 == 0 {
                    vt.setDefaultColors(foreground: RGB(r: 20, g: 30, b: 40), background: RGB(r: 245, g: 245, b: 240))
                } else {
                    vt.setDefaultColors(foreground: RGB(r: 220, g: 230, b: 240), background: RGB(r: 20, g: 20, b: 30))
                }
                canvas.fontFamily = TerminalFont.allCases[step % 4]
                canvas.fontSize = [7, 13, 28][step % 3]
                canvas.contentScaleFactor = step % 2 == 0 ? 2 : 3
                canvas.frame.size.width = step % 2 == 0 ? 390 : 600
            }
            canvas.screen = vt.frame()
            let cached = pixels(canvas)
            XCTAssertEqual(cached, pixels(canvas), "cache hit step \(step)")
            let fresh = TerminalCanvasView(frame: canvas.frame)
            fresh.fontFamily = canvas.fontFamily
            fresh.fontSize = canvas.fontSize
            fresh.contentScaleFactor = canvas.contentScaleFactor
            fresh.screen = canvas.screen
            XCTAssertEqual(cached, pixels(fresh), "fresh canvas step \(step)")
            XCTAssertLessThanOrEqual(canvas.textRowBytes, 32 * 1024 * 1024)
        }
        // Continuous new lines exceed the cache capacity without retaining unlimited history.
        for step in 0..<200 {
            vt.write(Data("\r\nrow \(step) \u{F07C} 漢".utf8))
            canvas.screen = vt.frame()
            _ = pixels(canvas)
            XCTAssertLessThanOrEqual(canvas.textRowBytes, 32 * 1024 * 1024)
        }
    }

    func testSynchronizedOutputCapturesBoundariesAndResize() throws {
        let vt = try VirtualTerminal(cols: 20, rows: 4)
        vt.write(Data("ready\u{1B}[?2026h\rpartial".utf8))
        XCTAssertTrue(vt.frame().text.hasPrefix("ready"))
        XCTAssertNotNil(vt.renderHoldRemaining)
        vt.write(Data("\u{1B}[?2026l\rcomplete\u{1B}[?2026h\rnext".utf8))
        XCTAssertTrue(vt.frame().text.hasPrefix("complete"))
        vt.write(Data("\u{1B}[?2026l".utf8))
        XCTAssertTrue(vt.frame().text.hasPrefix("next"))
        XCTAssertNil(vt.renderHoldRemaining)
        vt.write(Data("\u{1B}[?2026h\rresize".utf8))
        vt.resize(cols: 30, rows: 5)
        XCTAssertNil(vt.renderHoldRemaining)
        XCTAssertEqual(vt.frame().cols, 30)
        XCTAssertTrue(vt.frame().text.hasPrefix("resize"))
    }

    func testSynchronizedOutputTimesOut() async throws {
        let vt = try VirtualTerminal(cols: 20, rows: 4)
        vt.write(Data("old\u{1B}[?2026h\rnew".utf8))
        XCTAssertTrue(vt.frame().text.hasPrefix("old"))
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertTrue(vt.frame().text.hasPrefix("new"))
        XCTAssertNil(vt.renderHoldRemaining)
    }

    func testWheelReleasesOnlyAgedHoldWithoutWaitingForRemoteOutput() async throws {
        for mode in ["\u{1B}[?1000h\u{1B}[?1006h", "\u{1B}[?1049h"] {
            let vt = try VirtualTerminal(cols: 20, rows: 5)
            vt.write(Data((mode + "before").utf8))
            _ = vt.frame()
            vt.write(Data("\r\u{1B}[?2026hafter".utf8))
            XCTAssertNotNil(vt.renderHoldRemaining)
            XCTAssertTrue(vt.frame().lines[0].map(\.text).joined().hasPrefix("before"))
            guard case .send(let data) = vt.wheel(lines: -1, column: 1, row: 1) else {
                return XCTFail("Mouse and alternate-screen wheel input goes to the program")
            }
            XCTAssertFalse(data.isEmpty)
            XCTAssertNotNil(vt.renderHoldRemaining, "Fresh remote holds protect a partial frame")
            XCTAssertTrue(vt.frame().lines[0].map(\.text).joined().hasPrefix("before"))
            vt.write(Data("\rcomplete\u{1B}[?2026l".utf8))
            XCTAssertNil(vt.renderHoldRemaining)
            XCTAssertTrue(vt.frame().lines[0].map(\.text).joined().hasPrefix("complete"))
            vt.write(Data("\r\u{1B}[?2026hafter".utf8))
            try await Task.sleep(for: .milliseconds(120))
            _ = vt.wheel(lines: -1, column: 1, row: 1)
            XCTAssertNil(vt.renderHoldRemaining)
            XCTAssertTrue(vt.frame().lines[0].map(\.text).joined().hasPrefix("after"))
        }
    }

    func testInteractionReleasesSynchronizedOutput() throws {
        let vt = try fixture()
        vt.write(Data("\u{1B}[?2026h".utf8))
        vt.scroll(by: -1)
        XCTAssertNil(vt.renderHoldRemaining)
        XCTAssertFalse(vt.frame().scrollbar!.atBottom)
        vt.write(Data("\u{1B}[?2026h".utf8))
        vt.selectWord(at: (2, 2))
        XCTAssertNil(vt.renderHoldRemaining)
        XCTAssertNotNil(vt.frame().selection[2])
        vt.write(Data("\u{1B}[?2026h".utf8))
        vt.clearSelection()
        XCTAssertNil(vt.renderHoldRemaining)
        XCTAssertTrue(vt.frame().selection.allSatisfy { $0 == nil })
        vt.write(Data("\u{1B}[?2026h".utf8))
        vt.select(from: (1, 1), to: (4, 1))
        XCTAssertNil(vt.renderHoldRemaining)
        XCTAssertEqual(vt.frame().selection[1], 1...4)
    }
}
