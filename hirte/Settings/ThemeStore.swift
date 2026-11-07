import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// What's already there that an import would duplicate.
enum ThemeDuplicate: Equatable {
    /// A theme with the same colors, imported or built in: no need for another.
    case sameColors(TerminalTheme)
    /// An imported theme with the same name: replace it, or keep both.
    case sameName(TerminalTheme)
}

/// Why a change to the imported themes was refused.
enum ThemeStoreError: LocalizedError, Equatable {
    /// The file is there but can't be read yet: changing it now would lose the themes in it.
    case unreadable

    var errorDescription: String? {
        "Your imported themes can't be read right now. Unlock your device and try again."
    }
}

/// The user's imported themes, kept in a file of their parsed colors. The theme's text isn't kept.
/// Which theme is in use stays in the two slots of `TerminalTheme.lightKey` and `darkKey`.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    static let idPrefix = "custom-"

    private(set) var imported: [TerminalTheme]

    private let fileURL: URL
    private let defaults: UserDefaults
    private let read: (URL) throws -> Data
    /// The file couldn't be read, so `imported` says nothing about what's in it. A launch in the
    /// background before the first unlock gets here: the file is protected until then.
    @ObservationIgnored private var readFailed: Bool

    private struct Saved: Codable {
        var version: Int
        var themes: [TerminalTheme]
    }

    private static let version = 1

    private static var defaultFile: URL {
        URL.applicationSupportDirectory.appending(path: "Themes/custom-themes.json")
    }

    init(fileURL: URL? = nil, defaults: UserDefaults = .standard, read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        let fileURL = fileURL ?? Self.defaultFile
        self.fileURL = fileURL
        self.defaults = defaults
        self.read = read
        let loaded = Self.load(fileURL, read: read)
        imported = loaded ?? []
        readFailed = loaded == nil
        #if canImport(UIKit)
        // Becoming active means the device has been unlocked, whenever the store was first asked.
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfNeeded() }
        }
        #endif
    }

    /// Picks up the saved themes if they couldn't be read before.
    func reloadIfNeeded() {
        guard readFailed, let themes = Self.load(fileURL, read: read) else { return }
        imported = themes
        readFailed = false
    }

    /// Every change starts from what's in the file, or doesn't start.
    private func requireLoaded() throws {
        reloadIfNeeded()
        if readFailed { throw ThemeStoreError.unreadable }
    }

    /// The imported theme of this name, or the first with these colors.
    func duplicate(of colors: ThemeColors, named name: String) -> ThemeDuplicate? {
        let candidate = colors.theme(id: "", name: name)
        if let same = (imported + TerminalTheme.all).first(where: { $0.hasSameColors(as: candidate) }) {
            return .sameColors(same)
        }
        let name = Self.key(name)
        return imported.first { Self.key($0.name) == name }.map(ThemeDuplicate.sameName)
    }

    /// The name, numbered if another theme has it already: built-in themes can't be replaced.
    func uniqueName(_ name: String) -> String {
        let taken = Set((imported + TerminalTheme.all).map { Self.key($0.name) })
        guard taken.contains(Self.key(name)) else { return name }
        var number = 2
        while taken.contains(Self.key("\(name) \(number)")) { number += 1 }
        return "\(name) \(number)"
    }

    /// Saves a new theme under a free name, or in place of an imported one; nothing changes if that fails.
    @discardableResult
    func add(_ colors: ThemeColors, name: String, replacing old: TerminalTheme? = nil) throws -> TerminalTheme {
        try requireLoaded()
        var themes = imported
        let theme: TerminalTheme
        if let old, let index = themes.firstIndex(where: { $0.id == old.id }) {
            theme = colors.theme(id: old.id, name: name)
            themes[index] = theme
        } else {
            theme = colors.theme(id: Self.idPrefix + UUID().uuidString.lowercased(), name: uniqueName(name))
            themes.append(theme)
        }
        try save(themes)
        imported = themes
        // The other brightness doesn't fit the slot it was in.
        if let old, old.dark != theme.dark { clearSlot(of: old) }
        return theme
    }

    /// Removes an imported theme; a slot that used it goes back to the default.
    func remove(_ theme: TerminalTheme) throws {
        try requireLoaded()
        let themes = imported.filter { $0.id != theme.id }
        try save(themes)
        imported = themes
        clearSlot(of: theme)
    }

    /// Whether the theme is the one in use for its brightness.
    func isSelected(_ theme: TerminalTheme) -> Bool {
        defaults.string(forKey: Self.slot(dark: theme.dark)) == theme.id
    }

    func select(_ theme: TerminalTheme) {
        defaults.set(theme.id, forKey: Self.slot(dark: theme.dark))
    }

    private func clearSlot(of theme: TerminalTheme) {
        guard isSelected(theme) else { return }
        defaults.set(theme.dark ? TerminalTheme.defaultDark : TerminalTheme.defaultLight, forKey: Self.slot(dark: theme.dark))
    }

    private static func slot(dark: Bool) -> String {
        dark ? TerminalTheme.darkKey : TerminalTheme.lightKey
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func save(_ themes: [TerminalTheme]) throws {
        let data = try JSONEncoder().encode(Saved(version: Self.version, themes: themes))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// The themes in the file, none if there's no file, or nil if it can't be read (which may pass).
    /// A file we can't use isn't overwritten by the next save without a copy, in case it can be rescued.
    /// Themes that aren't what we write are left out, since drawing them assumes 16 valid colors.
    private static func load(_ url: URL, read: (URL) throws -> Data) -> [TerminalTheme]? {
        let data: Data
        do {
            data = try read(url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            return nil
        }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == version else {
            return keepCopy(of: url) ? [] : nil
        }
        let themes = saved.themes.filter { isValid($0) }
        if themes.count != saved.themes.count, !keepCopy(of: url) { return nil }
        return themes
    }

    private static func keepCopy(of url: URL) -> Bool {
        var copy = url.deletingLastPathComponent().appending(path: "custom-themes.unreadable.json")
        // Keep earlier recovery copies too. Never permit a save unless this original was preserved.
        if FileManager.default.fileExists(atPath: copy.path) {
            if let original = try? Data(contentsOf: url), let backup = try? Data(contentsOf: copy), original == backup {
                return true
            }
            copy = url.deletingLastPathComponent().appending(path: "custom-themes.unreadable-\(UUID().uuidString).json")
        }
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return true
        } catch {
            return false
        }
    }

    private static func isValid(_ theme: TerminalTheme) -> Bool {
        let colors = theme.ansi + [theme.background, theme.foreground, theme.cursor, theme.selection]
        return theme.isImported && !theme.name.isEmpty && theme.ansi.count == 16 && colors.allSatisfy { color in
            color.count == 7 && color.hasPrefix("#") && color.dropFirst().allSatisfy(\.isHexDigit)
        }
    }
}
