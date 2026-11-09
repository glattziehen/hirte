import GhosttyVt

/// Ghostty's own color syntax and color math, for reading theme files.
public enum ThemeColorParser {
    /// `#rgb`, `#rrggbb` (the `#` is optional for both), 9 and 12 digits, `rgb:`, `rgbi:` and X11 names.
    public static func color(_ text: String) -> RGB? {
        var out = GhosttyColorRgb()
        let result = text.withCString { ghostty_color_parse($0, text.utf8.count, &out) }
        return result == GHOSTTY_SUCCESS ? RGB(out) : nil
    }

    /// `N=COLOR`, with N from 0 to 255, in decimal or with a `0x`, `0o` or `0b` prefix.
    public static func paletteEntry(_ text: String) -> (index: Int, color: RGB)? {
        var index: UInt8 = 0
        var out = GhosttyColorRgb()
        let result = text.withCString { ghostty_color_parse_palette_entry($0, text.utf8.count, &index, &out) }
        return result == GHOSTTY_SUCCESS ? (Int(index), RGB(out)) : nil
    }

    /// Ghostty treats a background as light above 0.5.
    public static func isLight(_ background: RGB) -> Bool {
        var c = GhosttyColorRgb(r: background.r, g: background.g, b: background.b)
        return ghostty_color_perceived_luminance(&c) > 0.5
    }

    /// The WCAG contrast ratio, from 1 (the same color) to 21 (black and white).
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        var first = GhosttyColorRgb(r: a.r, g: a.g, b: a.b)
        var second = GhosttyColorRgb(r: b.r, g: b.g, b: b.b)
        return ghostty_color_contrast(&first, &second)
    }

    /// Ghostty's default palette, whose first 16 colors stand in for those a theme leaves out.
    public static var defaultPalette: [RGB] {
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        palette.withUnsafeMutableBufferPointer { ghostty_color_palette_default($0.baseAddress) }
        return palette.map(RGB.init)
    }
}
