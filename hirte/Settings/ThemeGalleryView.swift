import SwiftUI

/// A few lines in a theme and font, with the glyphs prompts and status lines rely on, so what's missing
/// shows here too. The lines are generic; colors and font are the real ones.
struct ThemeTerminalPreview: View {
    let size: Double
    let family: TerminalFont
    let theme: TerminalTheme

    var body: some View {
        let fonts = Fonts(size: size, family: family)
        VStack(alignment: .leading, spacing: 0) {
            ThemeText.line([("~/projects/shop-api ", theme.ansiColor(4)), ("❯ ", theme.ansiColor(5)), ("git log --oneline", nil)])
            ThemeText.line([("a41c9e2 ", theme.ansiColor(3)), ("Add order totals endpoint", nil)])
            ThemeText.line([("7d03b1f ", theme.ansiColor(3)), ("Cache product images", nil)])
            resultLine
            statusLine
            ThemeText.line([("┌─┐ ▁▃▅█ ", theme.ansiColor(6)), ("\u{F07C} \u{E725}", theme.ansiColor(5))])
        }
        .font(Font(fonts.regular))
        .foregroundStyle(theme.color(theme.foreground))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.color(theme.background))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of \(theme.name) in \(family.title)")
    }

    /// Ends in the cursor, at its color.
    private var resultLine: Text {
        var cursor = AttributedString(" ")
        cursor.backgroundColor = theme.color(theme.cursor)
        return Text(ThemeText.attributed([
            ("✓ ", theme.ansiColor(2)), ("48 passed ", nil), ("✗ ", theme.ansiColor(1)), ("0 failed ", nil),
        ]) + cursor)
    }

    /// A Powerline segment: the triangle has to meet the segment's background without a gap.
    private var statusLine: Text {
        var segment = AttributedString(" \u{E0A0} main ")
        segment.foregroundColor = theme.color(theme.background)
        segment.backgroundColor = theme.ansiColor(4)
        var arrow = AttributedString("\u{E0B0}")
        arrow.foregroundColor = theme.ansiColor(4)
        return Text(segment + arrow)
    }
}

/// Text in the colors of a theme.
enum ThemeText {
    /// One line from colored pieces (nil: the theme's foreground).
    static func line(_ pieces: [(String, Color?)]) -> Text { Text(attributed(pieces)) }

    static func attributed(_ pieces: [(String, Color?)]) -> AttributedString {
        var text = AttributedString()
        for (string, color) in pieces {
            var piece = AttributedString(string)
            if let color { piece.foregroundColor = color }
            text += piece
        }
        return text
    }
}

/// A theme at a glance: a small terminal, and its colors.
struct ThemeThumbnail: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                ThemeText.line([("❯ ", theme.ansiColor(5)), ("git status", nil)])
                ThemeText.line([("modified: ", theme.ansiColor(2)), ("app.py", nil)])
                ThemeText.line([("deleted: ", theme.ansiColor(1)), ("old.py", nil)])
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(theme.color(theme.foreground))
            .lineLimit(1)
            VStack(spacing: 3) {
                strip(0..<8)
                strip(8..<16)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color(theme.background), in: shape)
        .overlay(shape.strokeBorder(.quaternary))
        .accessibilityHidden(true)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    private func strip(_ range: Range<Int>) -> some View {
        HStack(spacing: 3) {
            ForEach(range, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2).fill(theme.ansiColor(index)).frame(height: 6)
            }
        }
    }
}

/// All themes for one slot, built-in and imported, to choose from. Importing starts here too.
struct ThemeGalleryView: View {
    let dark: Bool

    private let store = ThemeStore.shared
    @AppStorage private var selection: String
    @State private var importing = false
    @State private var removing: TerminalTheme?
    @State private var removeFailed = false
    @State private var removeProblem: ThemeStoreError?

    init(dark: Bool) {
        self.dark = dark
        _selection = AppStorage(
            wrappedValue: dark ? TerminalTheme.defaultDark : TerminalTheme.defaultLight,
            dark ? TerminalTheme.darkKey : TerminalTheme.lightKey)
    }

    private var title: String { dark ? "Dark Theme" : "Light Theme" }
    private var defaultId: String { dark ? TerminalTheme.defaultDark : TerminalTheme.defaultLight }
    private var imported: [TerminalTheme] { store.imported.filter { $0.dark == dark } }
    private var builtIn: [TerminalTheme] { dark ? TerminalTheme.darkThemes : TerminalTheme.lightThemes }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 12)], alignment: .leading, spacing: 12) {
                if !imported.isEmpty {
                    Section {
                        ForEach(imported, content: card)
                    } header: {
                        header("Imported")
                    } footer: {
                        Text("Touch and hold an imported theme to remove it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Section {
                    ForEach(builtIn, content: card)
                } header: {
                    header("Built-in")
                }
            }
            .padding(16)
            if TerminalTheme.find(selection, dark: dark).id != defaultId {
                Button("Reset to \(TerminalTheme.find(defaultId, dark: dark).name)") {
                    selection = defaultId
                }
                .padding(.bottom, 16)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Import Theme…", systemImage: "plus") { importing = true }
            }
        }
        .sheet(isPresented: $importing) {
            ThemeImportView()
        }
        .confirmationDialog(
            removing.map { "Remove “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { theme in
            Button("Remove", role: .destructive) { remove(theme) }
        } message: { theme in
            if theme.id == selection {
                Text("It's the \(title.lowercased()) in use. Terminals switch to \(TerminalTheme.find(defaultId, dark: dark).name).")
            }
        }
        .alert("Couldn't remove the theme. Nothing was changed.", isPresented: $removeFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            if let removeProblem { Text(removeProblem.localizedDescription) }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ theme: TerminalTheme) -> some View {
        let selected = TerminalTheme.find(selection, dark: dark).id == theme.id
        return Button {
            selection = theme.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ThemeThumbnail(theme: theme)
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.tint, lineWidth: 2)
                        }
                    }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(theme.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityValue(theme.isImported ? "Imported" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if theme.isImported {
                Button("Remove Theme", systemImage: "trash", role: .destructive) { removing = theme }
            }
        }
        .accessibilityActions {
            if theme.isImported {
                Button("Remove Theme") { removing = theme }
            }
        }
    }

    private func remove(_ theme: TerminalTheme) {
        do {
            try store.remove(theme)
        } catch {
            removeProblem = error as? ThemeStoreError
            removeFailed = true
        }
    }
}
