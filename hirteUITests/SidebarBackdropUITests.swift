import UIKit
import XCTest

/// The sidebar is app chrome: its background doesn't follow what the detail column shows. Compares
/// actual pixels, since the system's sidebar material samples what's behind it.
final class SidebarBackdropUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSidebarKeepsItsColorWhateverTheDetailShows() throws {
        XCUIDevice.shared.orientation = .portrait
        // A theme's brightness is tied to its slot, so these are the extremes within each.
        let setups = [("light", "github-light", "tokyo-night-day"), ("dark", "github-dark", "nord")]
        var varying: [String] = []
        for (appearance, first, second) in setups {
            var sidebar: Set<[UInt8]> = []
            var liveDetail: Set<[UInt8]> = []
            for theme in [first, second] {
                let app = XCUIApplication()
                app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearance", appearance,
                                        "-hirte.demo", "YES", "-theme.light", theme, "-theme.dark", theme]
                app.launch()
                let terminals = app.buttons["Terminals"]
                XCTAssertTrue(terminals.waitForExistence(timeout: 15))
                try XCTSkipUnless(app.buttons["Hide Sidebar"].waitForExistence(timeout: 5),
                                  "a sidebar next to the detail only")
                terminals.tap()
                let live = row("t1", app)
                XCTAssertTrue(live.waitForExistence(timeout: 5))
                let screen = app.descendants(matching: .any).matching(identifier: "terminal-screen").firstMatch
                let window = app.windows.firstMatch.frame
                // Above the bar that floats over the list's end, below the last row.
                let blank = CGPoint(x: window.minX + 60, y: terminals.frame.minY - 40)
                let detail = CGPoint(x: window.maxX - 60, y: window.maxY - 60)
                // In the column's margin, beside the rows and whatever fills them.
                let margin = CGPoint(x: window.minX + 4, y: window.midY)

                func read(_ step: String) -> ([UInt8], [UInt8]) {
                    Thread.sleep(forTimeInterval: 1)
                    let shot = XCUIScreen.main.screenshot()
                    let values = (color(at: blank, in: shot.image), color(at: detail, in: shot.image))
                    let marginColor = color(at: margin, in: shot.image)
                    print("SIDEBAR-PIXEL \(appearance) \(theme) \(step) sidebar=\(values.0) margin=\(marginColor) detail=\(values.1)")
                    XCTAssertEqual(marginColor, values.0, "the column has one background, top to bottom")
                    save(shot, "backdrop-\(appearance)-\(theme)-\(step)")
                    return values
                }

                live.tap()
                XCTAssertTrue(screen.waitForExistence(timeout: 10))
                let first = read("1-live")
                let finishedHeader = app.staticTexts["Finished"]
                XCTAssertTrue(finishedHeader.waitForExistence(timeout: 5))
                let finished = row("t7", app)
                if !finished.exists { finishedHeader.tap() }
                XCTAssertTrue(finished.waitForExistence(timeout: 5))
                finished.tap()
                XCTAssertTrue(screen.waitForNonExistence(timeout: 10), "a finished terminal shows its facts")
                let second = read("2-finished")
                live.tap()
                XCTAssertTrue(screen.waitForExistence(timeout: 10))
                let third = read("3-live")

                sidebar.formUnion([first.0, second.0, third.0])
                liveDetail.insert(first.1)
                XCTAssertNotEqual(first.1, second.1, "the detail really changed under it")
                app.terminate()
            }
            XCTAssertEqual(liveDetail.count, 2, "the two themes really differ")
            if sidebar.count != 1 { varying.append("\(appearance): \(sidebar)") }
        }
        XCTAssertEqual(varying, [], "the sidebar has one color per appearance")
    }

    /// Without machines the sidebar is the machines list, on the same backdrop. An empty list in
    /// the launch arguments stands in for a fresh install, and leaves the stored machines alone.
    @MainActor
    func testNoMachinesSidebarCapture() throws {
        XCUIDevice.shared.orientation = .portrait
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearance", appearance,
                                    "-hirte.hosts", "<5b5d>"]
            app.launch()
            XCTAssertTrue(app.buttons["Try the Demo"].waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 1)
            save(XCUIScreen.main.screenshot(), "backdrop-no-machines-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    private func row(_ address: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: address).firstMatch
    }

    private func color(at point: CGPoint, in image: UIImage) -> [UInt8] {
        guard let cgImage = image.cgImage else { return [] }
        var pixel = [UInt8](repeating: 0, count: 4)
        let x = point.x * image.scale, y = point.y * image.scale
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: -x, y: y + 1 - height, width: width, height: height))
        }
        return Array(pixel[0..<3])
    }

    @MainActor
    private func save(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
