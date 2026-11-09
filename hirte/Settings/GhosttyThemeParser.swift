import Foundation
import HerdrKit

/// The colors of a theme someone imports, and how bright it is (from its background, as in Ghostty).
struct ThemeColors: Equatable {
    /// The 16 ANSI colors.
    var ansi: [RGB]
    var background: RGB
    var foreground: RGB
    var cursor: RGB
    var selection: RGB
    /// How many of the 16 ANSI colors the theme set itself.
    var ansiSet: Int

    var dark: Bool { !ThemeColorParser.isLight(background) }

    func theme(id: String, name: String) -> TerminalTheme {
        TerminalTheme(
            id: id, name: name, dark: dark, ansi: ansi.map(\.hex), background: background.hex,
            foreground: foreground.hex, cursor: cursor.hex, selection: selection.hex)
    }
}

/// What came of reading a theme: the colors if nothing stands in the way, and what to tell the user.
struct ThemeParseResult: Equatable {
    var colors: ThemeColors?
    /// Why it can't be imported.
    var errors: [String] = []
    /// What it can be imported without.
    var notes: [String] = []
}

/// Reads the colors out of Ghostty theme text, and nothing else.
///
/// A Ghostty theme is a config file and may set any option, so everything but the color keys is only
/// counted: `theme` and `config-file` are never followed, and commands, keybinds, URLs and paths are
/// never looked at. Line syntax as in Ghostty's `src/cli/args.zig`, color values from its parser.
enum GhosttyThemeParser {
    static let maxBytes = 64 * 1024
    static let maxLines = 2000
    static let maxLineBytes = 4096

    static let notText = "This file isn't text."
    static let tooLarge = "This file is too large to be a theme."
    /// Ghostty's defaults for an unset cursor or selection; not colors Hirte can use.
    private static let cellColors: Set<String> = ["cell-foreground", "cell-background"]
    private static let colorKeys: Set<String> = [
        "background", "foreground", "palette", "cursor-color", "cursor-text", "selection-background",
        "selection-foreground",
    ]
    /// Further problems are only counted: the first ones are enough to go on.
    private static let maxListedErrors = 5
    private static let maxListedKeys = 5
    private static let maxQuoted = 40

    /// The text of a file, or why it isn't one we'd read.
    static func text(from data: Data) -> Result<String, ThemeFileError> {
        guard data.count <= maxBytes else { return .failure(ThemeFileError(message: tooLarge)) }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return .failure(ThemeFileError(message: notText))
        }
        return .success(text)
    }

    static func parse(_ text: String) -> ThemeParseResult {
        guard text.utf8.count <= maxBytes else { return ThemeParseResult(errors: [tooLarge]) }
        guard !text.unicodeScalars.contains("\0") else { return ThemeParseResult(errors: [notText]) }
        // A byte order mark would otherwise become part of the first key.
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count <= maxLines else { return ThemeParseResult(errors: [tooLarge]) }

        var ansi = [RGB?](repeating: nil, count: 16)
        var background: RGB?
        var foreground: RGB?
        var cursor: RGB?
        var selection: RGB?
        var errors: [String] = []
        var ignoredKeys: [String] = []
        var ignoredCount = 0
        var themeReference: String?
        var followsFile = false
        var extendedPalette: Set<Int> = []
        var sawColorKey = false
        var sawHerdrSection = false
        var usesCellColors = false
        var setsUndrawnText = false
        var setsSelection = false

        for (offset, rawLine) in lines.enumerated() {
            let number = offset + 1
            guard rawLine.utf8.count <= maxLineBytes else {
                errors.append("Line \(number) is too long.")
                continue
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[theme") { sawHerdrSection = true }

            let (key, value) = keyAndValue(line)
            guard colorKeys.contains(key) else {
                ignoredCount += 1
                if isPrintableKey(key), !ignoredKeys.contains(key) { ignoredKeys.append(key) }
                if key == "theme", !value.isEmpty { themeReference = value }
                if key == "config-file" { followsFile = true }
                continue
            }
            sawColorKey = true

            // As in Ghostty: an empty value goes back to the default.
            if value.isEmpty {
                switch key {
                case "background": background = nil
                case "foreground": foreground = nil
                case "cursor-color": cursor = nil
                case "selection-background": selection = nil
                case "palette":
                    ansi = [RGB?](repeating: nil, count: 16)
                    extendedPalette = []
                default: break
                }
                continue
            }

            if key == "palette" {
                if let entry = ThemeColorParser.paletteEntry(value) {
                    if entry.index < 16 { ansi[entry.index] = entry.color } else { extendedPalette.insert(entry.index) }
                } else {
                    errors.append("Line \(number): \(paletteProblem(value))")
                }
                continue
            }

            if cellColors.contains(value), key != "background", key != "foreground" {
                usesCellColors = true
                if key == "cursor-color" { cursor = nil }
                if key == "selection-background" { selection = nil }
                continue
            }
            guard let color = ThemeColorParser.color(value) else {
                errors.append("Line \(number): “\(quoted(value))” isn't a color.")
                continue
            }
            switch key {
            case "background": background = color
            case "foreground": foreground = color
            case "cursor-color": cursor = color
            case "selection-background":
                selection = color
                setsSelection = true
            default: setsUndrawnText = true
            }
        }

        var notes: [String] = []
        if ignoredCount > 0 {
            var note = "Imported colors only. \(ignoredCount) other \(ignoredCount == 1 ? "setting was" : "settings were") ignored"
            if !ignoredKeys.isEmpty {
                let listed = ignoredKeys.prefix(maxListedKeys).joined(separator: ", ")
                note += ": \(listed)\(ignoredKeys.count > maxListedKeys ? ", …" : "")"
            }
            notes.append(note + ".")
        }
        if followsFile { notes.append("Other files this config points to weren't read.") }
        if !extendedPalette.isEmpty {
            notes.append("Palette colors 16–255 aren't used: Hirte keeps the standard 256-color palette.")
        }
        if setsSelection { notes.append("Hirte marks selections in the app's accent color, not this theme's selection color.") }
        if setsUndrawnText { notes.append("Hirte doesn't draw separate selection text and cursor text colors, so they aren't kept.") }
        if usesCellColors { notes.append("“cell-foreground” and “cell-background” aren't supported: the default colors are used instead.") }

        if background == nil || foreground == nil {
            // Without colors, what it is matters more than what's missing.
            if !sawColorKey, sawHerdrSection {
                errors.insert("This looks like a herdr config. herdr themes color herdr's own interface, not the terminal.", at: 0)
            } else if let themeReference, background == nil, foreground == nil {
                errors.insert("This config points to the theme “\(quoted(themeReference))” but doesn't contain its colors. Import that theme file instead.", at: 0)
            } else if !sawColorKey {
                errors.insert("No theme colors found. A Ghostty theme sets background, foreground and palette colors.", at: 0)
            } else {
                // After what's wrong with a line: that's often why it's missing.
                if background == nil { errors.append("Missing background.") }
                if foreground == nil { errors.append("Missing foreground.") }
            }
        }
        if errors.count > maxListedErrors {
            let more = errors.count - maxListedErrors
            errors = Array(errors.prefix(maxListedErrors)) + ["And \(more) more."]
        }
        guard errors.isEmpty, let background, let foreground else {
            return ThemeParseResult(errors: errors, notes: notes)
        }

        let defaults = ThemeColorParser.defaultPalette
        let filled = ansi.enumerated().map { $1 ?? defaults[$0] }
        let colors = ThemeColors(
            ansi: filled, background: background, foreground: foreground,
            cursor: cursor ?? foreground, selection: selection ?? filled[8],
            ansiSet: ansi.compactMap { $0 }.count)
        if colors.ansiSet < 16 {
            notes.append("\(16 - colors.ansiSet) of 16 ANSI colors aren't set and use Ghostty's defaults.")
        }
        notes += contrastNotes(colors)
        return ThemeParseResult(colors: colors, notes: notes)
    }

    /// The first `=` splits a line; without one, the whole line is the key. One pair of quotes comes off.
    private static func keyAndValue(_ line: String) -> (key: String, value: String) {
        guard let equals = line.firstIndex(of: "=") else { return (line, "") }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    /// Only names that look like options are repeated to the user.
    private static func isPrintableKey(_ key: String) -> Bool {
        key.count <= maxQuoted && !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func quoted(_ value: String) -> String {
        value.count > maxQuoted ? value.prefix(maxQuoted) + "…" : value
    }

    /// Ghostty only says a palette entry is invalid; this finds out which side of it is.
    private static func paletteProblem(_ value: String) -> String {
        guard let equals = value.firstIndex(of: "=") else {
            return "“\(quoted(value))” isn't a palette entry (index=color)."
        }
        let index = value[..<equals].trimmingCharacters(in: .whitespaces)
        let color = value[value.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard ThemeColorParser.color(color) != nil else { return "“\(quoted(color))” isn't a color." }
        return "palette index \(quoted(index)) is out of range (0–255)."
    }

    /// Warnings, not errors: it's the user's theme, and the preview shows what this means.
    /// Thresholds from Ghostty's advice on `minimum-contrast`. Black, white and their bright versions
    /// often match a background on purpose, so only the six colors that carry meaning count.
    private static func contrastNotes(_ colors: ThemeColors) -> [String] {
        var notes: [String] = []
        if ThemeColorParser.contrast(colors.foreground, colors.background) < 3 {
            notes.append("The text has low contrast with the background, which can be hard to read.")
        }
        let invisible = (Array(1...6) + Array(9...14)).filter {
            ThemeColorParser.contrast(colors.ansi[$0], colors.background) < 1.1
        }
        if !invisible.isEmpty {
            let list = invisible.map(String.init).joined(separator: ", ")
            notes.append("ANSI \(invisible.count == 1 ? "color" : "colors") \(list) can't be told from the background.")
        }
        return notes
    }
}

/// Why a file wasn't read; the message is for the user.
struct ThemeFileError: Error, Equatable {
    let message: String
}
