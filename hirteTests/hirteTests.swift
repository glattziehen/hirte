import Foundation
import HerdrKit
import Testing
import UIKit
@testable import hirte

@MainActor
struct ThemeTests {
    @Test func bundledThemesLoad() {
        // More than the built-in fallback: themes.json is in the app and decodes.
        #expect(TerminalTheme.all.count > 1)
        #expect(!TerminalTheme.darkThemes.isEmpty)
        #expect(!TerminalTheme.lightThemes.isEmpty)
    }

    @Test func everyThemeHasSixteenColors() {
        for theme in TerminalTheme.all {
            #expect(theme.ansi.count == 16, "\(theme.id)")
        }
    }

    @Test func defaultsExistAndUnknownIdsFallBack() {
        #expect(TerminalTheme.find(TerminalTheme.defaultDark, dark: true).id == TerminalTheme.defaultDark)
        #expect(TerminalTheme.find(TerminalTheme.defaultLight, dark: false).id == TerminalTheme.defaultLight)
        #expect(TerminalTheme.find("no-such-theme", dark: true).id == TerminalTheme.defaultDark)
        // A dark theme's id asked for as light falls back to the light default.
        #expect(TerminalTheme.find(TerminalTheme.defaultDark, dark: false).id == TerminalTheme.defaultLight)
    }
}

@MainActor
struct HostTests {
    @Test func subtitleShowsPortOnlyWhenNotDefault() {
        var host = Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel"))
        #expect(host.subtitle == "pavel@mini.local")
        host.target.port = 2222
        #expect(host.subtitle == "pavel@mini.local:2222")
    }

    @Test func hostsSavedBeforeTheDemoExistedStillDecode() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Mini","target":{"host":"mini.local","port":22,"username":"pavel"}}]"#
        let hosts = try JSONDecoder().decode([Host].self, from: Data(json.utf8))
        #expect(hosts.first?.isDemo == false)
    }

    @Test func storePersistsAndAddsTheDemoOnce() throws {
        let suite = "hirteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = HostStore(defaults: defaults)
        store.save(Host(name: "Mini", target: SSHTarget(host: "mini.local", username: "pavel")))
        let demo = store.addDemo()
        #expect(store.addDemo().id == demo.id)

        let reloaded = HostStore(defaults: defaults)
        #expect(reloaded.hosts.map(\.name) == ["Mini", "Demo machine"])
        #expect(reloaded.hasDemo)
    }
}

struct AgeTests {
    @Test func shortAgesLikeHerdrApp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func age(_ seconds: TimeInterval) -> String { Terminal.shortAge(now.addingTimeInterval(-seconds), now: now) }
        #expect(age(59) == "now")
        #expect(age(-30) == "now")  // the machine's clock is ahead
        #expect(age(60) == "1m")
        #expect(age(47 * 60 + 59) == "47m")
        #expect(age(3 * 3600) == "3h")
        #expect(age(23 * 3600 + 3599) == "23h")
        #expect(age(2 * 86_400) == "2d")
    }
}

@MainActor
struct ScrollGlideTests {
    /// How far a glide goes, a frame at a time, until under half a point is left.
    private func coasted(_ start: ScrollGlide, framesPerSecond: Double) -> (travel: Double, seconds: Double) {
        var glide = start
        var travel = 0.0
        var frames = 0.0
        while abs(glide.travelLeft) >= 0.5 {
            travel += glide.advance(by: 1 / framesPerSecond)
            frames += 1
        }
        return (travel, frames / framesPerSecond)
    }

    @Test func decelerationIsUIKits() {
        #expect(abs(ScrollGlide.decelerationRate - Double(UIScrollView.DecelerationRate.normal.rawValue)) < 0.0001)
        #expect(abs(ScrollGlide.settlingRate - Double(UIScrollView.DecelerationRate.fast.rawValue)) < 0.0001)
    }

    @Test func aFlickCoastsForAboutHalfASecondOfItsSpeed() {
        let down = coasted(ScrollGlide(lift: 2000), framesPerSecond: 60).travel
        #expect(down > 990)
        #expect(down < 1000)
        #expect(abs(coasted(ScrollGlide(lift: -2000), framesPerSecond: 60).travel + down) < 0.001)
    }

    @Test func theFrameRateChangesNothing() {
        let slow = coasted(ScrollGlide(lift: 2000), framesPerSecond: 60).travel
        let fast = coasted(ScrollGlide(lift: 2000), framesPerSecond: 120).travel
        #expect(abs(slow - fast) < 1)
    }

    @Test func aboutASeventhOfTheSpeedIsLeftAfterASecond() {
        var glide = ScrollGlide(lift: 2000)
        _ = glide.advance(by: 1)
        #expect(abs(glide.velocity - 270) < 1)
    }

    @Test func aFlickAddsToTheGlideItsTouchStopped() {
        #expect(ScrollGlide(lift: 1000, interrupted: 800, heldFor: 0.1).velocity == 1800)
        #expect(ScrollGlide(lift: -1000, interrupted: -800, heldFor: 0.1).velocity == -1800)
    }

    @Test func turningAroundOrHoldingStillStartsAfresh() {
        #expect(ScrollGlide(lift: -1000, interrupted: 800, heldFor: 0.1).velocity == -1000)
        #expect(ScrollGlide(lift: 1000, interrupted: 800, heldFor: ScrollGlide.carryTime + 0.1).velocity == 1000)
    }

    /// A small move stays where it was left, also when its touch stopped a glide.
    @Test func aSlowLiftDoesNotGlide() {
        for lift in [0.0, 50, -100, 299, -299] {
            #expect(ScrollGlide(lift: lift).velocity == 0, "\(lift)")
            #expect(ScrollGlide(lift: lift, interrupted: lift < 0 ? -2000 : 2000, heldFor: 0.1).velocity == 0, "\(lift)")
        }
    }

    @Test func aFirmFlickGlidesInFull() {
        for lift in [ScrollGlide.fullGlideSpeed, -ScrollGlide.fullGlideSpeed, 2000, -5000] {
            #expect(ScrollGlide(lift: lift).velocity == lift, "\(lift)")
        }
    }

    /// In between, a little more speed never means suddenly many more lines.
    @Test func theGlideBuildsUpSmoothly() {
        #expect(ScrollGlide(lift: 550).velocity == 275)
        var last = 0.0
        for lift in stride(from: 300.0, through: 800, by: 5) {
            let velocity = ScrollGlide(lift: lift).velocity
            #expect(velocity >= last, "\(lift)")
            #expect(velocity - last <= 15, "\(lift)")
            last = velocity
        }
    }

    @Test func repeatedFlicksHaveALimit() {
        #expect(ScrollGlide(lift: 10_000, interrupted: 10_000).velocity == ScrollGlide.maxSpeed)
        #expect(ScrollGlide(lift: -10_000, interrupted: -10_000).velocity == -ScrollGlide.maxSpeed)
    }

    /// The text comes to rest on a line, whatever the speed and however far off one it starts.
    @Test func aGlideLandsOnALine() {
        for lift in [0.0, 50, -90, 700, 2000, -2000, 15_000] {
            for offset in [0.0, 5, -7, 17, -17] {
                var glide = ScrollGlide(lift: lift)
                glide.land(onMultiplesOf: 18, from: offset)
                let lines = (glide.travelLeft + offset) / 18
                #expect(abs(lines - lines.rounded()) < 0.000001, "\(lift) from \(offset)")
            }
        }
    }

    @Test func landingBarelyChangesWhereAFlickGoes() {
        let flick = ScrollGlide(lift: 2000)
        var landing = flick
        landing.land(onMultiplesOf: 18, from: 5)
        #expect(abs(landing.travelLeft - flick.travelLeft) <= 9 + 5)
        #expect(landing.velocity > 0)
    }

    /// After a slow lift the text finds its line quickly: a long slow crawl looks like lag.
    @Test func aSlowLiftSettlesOnTheNearestLineQuickly() {
        var back = ScrollGlide(lift: 0)
        back.land(onMultiplesOf: 18, from: 8)
        #expect(abs(back.travelLeft + 8) < 0.000001)
        #expect(coasted(back, framesPerSecond: 60).seconds < 0.5)

        var onward = ScrollGlide(lift: 0)
        onward.land(onMultiplesOf: 18, from: 10)
        #expect(abs(onward.travelLeft - 8) < 0.000001)
    }
}

@MainActor
struct ArrowStickTests {
    private func key(_ dx: CGFloat, _ dy: CGFloat, current: TerminalKey? = nil) -> TerminalKey? {
        ArrowStick.reading(dx: dx, dy: dy, current: current)?.key
    }

    @Test func deadZoneGivesNoKey() {
        #expect(ArrowStick.reading(dx: 0, dy: 0, current: nil) == nil)
        #expect(ArrowStick.reading(dx: 10, dy: -10, current: .right) == nil)
    }

    @Test func furthestAxisPicksTheKey() {
        #expect(key(30, 5) == .right)
        #expect(key(-30, 5) == .left)
        #expect(key(5, -30) == .up)
        #expect(key(5, 30) == .down)
    }

    @Test func diagonalsKeepTheCurrentAxis() {
        // Slightly more vertical, but going sideways already: stays sideways.
        #expect(key(30, 34, current: .right) == .right)
        #expect(key(30, 34) == .down)
        // Clearly vertical now: switches.
        #expect(key(20, 40, current: .right) == .down)
        // Crossing over to the other side switches direction on the same axis.
        #expect(key(-30, 0, current: .right) == .left)
    }

    @Test func distancePicksTheSpeed() {
        #expect(ArrowStick.reading(dx: 30, dy: 0, current: nil)?.speed == .slow)
        #expect(ArrowStick.reading(dx: ArrowStick.flowDistance, dy: 0, current: nil)?.speed == .flow)
        #expect(ArrowStick.reading(dx: 0, dy: -ArrowStick.fastDistance, current: nil)?.speed == .fast)
    }

    /// Renders the pad in each mode, over light and dark text, into HIRTE_SHOTS, to look at.
    @Test func arrowPadRenders() throws {
        guard let folder = ProcessInfo.processInfo.environment["HIRTE_SHOTS"] else { return }
        let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
        let window = try #require(windows.first)
        let modes: [(String, ArrowPadView.Mode)] = [
            ("idle", .idle), ("press-left", .press(.left)),
            ("slow-left-0", .repeating(.left, .slow, step: 0)), ("flow-up-1", .repeating(.up, .flow, step: 1)),
            ("fast-right", .repeating(.right, .fast, step: 0)),
        ]
        for dark in [true, false] {
            let backdrop = UILabel(frame: CGRect(x: 0, y: 0, width: 130, height: 130))
            backdrop.numberOfLines = 0
            backdrop.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            backdrop.text = String(repeating: "~/src $ git status -sb ", count: 12)
            backdrop.backgroundColor = dark ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.98, alpha: 1)
            backdrop.textColor = dark ? .white : .black
            let pad = ArrowPadView()
            pad.dark = dark
            pad.frame.origin = CGPoint(x: 23, y: 23)
            backdrop.addSubview(pad)
            window.addSubview(backdrop)
            defer { backdrop.removeFromSuperview() }
            for (name, mode) in modes {
                pad.mode = mode
                let image = UIGraphicsImageRenderer(bounds: backdrop.bounds).image { _ in
                    backdrop.drawHierarchy(in: backdrop.bounds, afterScreenUpdates: true)
                }
                let file = "arrow-pad-\(dark ? "dark" : "light")-\(name).png"
                try image.pngData()?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(file))
            }
        }
    }
}

@MainActor
struct TerminalTextInputTests {
    /// The keyboard stops repeating a held delete when it finds nothing before the cursor.
    @Test func thereIsAlwaysACharacterBeforeTheCursor() throws {
        let view = TerminalCanvasView()
        let cursor = try #require(view.selectedTextRange).start
        let before = try #require(view.position(from: cursor, offset: -1))
        let range = try #require(view.textRange(from: before, to: cursor))
        #expect(view.text(in: range)?.isEmpty == false)
    }
}
