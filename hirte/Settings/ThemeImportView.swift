import SwiftUI
import UniformTypeIdentifiers

/// Imports a Ghostty theme, pasted or from a file. It's previewed first; only its colors are kept.
struct ThemeImportView: View {
    private let store = ThemeStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TerminalFont.sizeKey) private var fontSize = TerminalFont.defaultSize
    @AppStorage(TerminalFont.storageKey) private var fontFamily = TerminalFont.jetBrainsMono
    @State private var text = ""
    @State private var name = ""
    @State private var result = ThemeParseResult()
    @State private var useNow = true
    @State private var choosingFile = false
    @State private var fileProblem: String?
    @State private var confirmingReplace: TerminalTheme?
    @State private var saveFailed = false
    @State private var saveProblem: ThemeStoreError?

    private static let maxNameLength = 60

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var effectiveName: String { trimmedName.isEmpty ? "Imported Theme" : String(trimmedName.prefix(Self.maxNameLength)) }

    var body: some View {
        NavigationStack {
            Form {
                source
                if let colors = result.colors { review(colors) }
                messages
            }
            .navigationTitle("Import Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let colors = result.colors {
                        if case .sameColors(let existing) = store.duplicate(of: colors, named: effectiveName) {
                            Button("Use “\(existing.name)”") { finish(with: existing) }
                        } else {
                            Button("Add Theme") { add(colors) }
                        }
                    }
                }
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.plainText, .data]) { outcome in
                choseFile(outcome)
            }
            .onChange(of: text) { _, text in
                fileProblem = nil
                result = text.isEmpty ? ThemeParseResult() : GhosttyThemeParser.parse(text)
            }
            .confirmationDialog(
                "A theme named “\(confirmingReplace?.name ?? "")” already exists.",
                isPresented: Binding(get: { confirmingReplace != nil }, set: { if !$0 { confirmingReplace = nil } }),
                titleVisibility: .visible,
                presenting: confirmingReplace
            ) { existing in
                Button("Replace", role: .destructive) { save(replacing: existing) }
                Button("Keep Both") { save(replacing: nil) }
            }
            .alert("Couldn't save the theme. Nothing was changed.", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                if let saveProblem { Text(saveProblem.localizedDescription) }
            }
        }
        .interactiveDismissDisabled(!text.isEmpty)
    }

    private var source: some View {
        Section {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: 140)
                .accessibilityLabel("Theme text")
                .accessibilityIdentifier("theme-import-text")
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    // SwiftUI doesn't promise the main thread here.
                    Task { @MainActor in
                        if let string = strings.first { text = string }
                    }
                }
                .labelStyle(.titleAndIcon)
                Spacer()
                Button("Choose File…", systemImage: "doc") { choosingFile = true }
                    .buttonStyle(.borderless)
            }
            // Right under the text it's about, where the keyboard leaves it in view.
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Ghostty Theme")
        } footer: {
            Text("Paste the text of a Ghostty theme or config file, or choose one. Only its colors are used: nothing in it runs, and no other files or links are opened.")
        }
    }

    private func review(_ colors: ThemeColors) -> some View {
        let theme = colors.theme(id: "", name: effectiveName)
        let slot = colors.dark ? "Dark Theme" : "Light Theme"
        let builtInName = isBuiltInName(effectiveName)
        return Section {
            ThemeTerminalPreview(size: fontSize, family: fontFamily, theme: theme)
                .listRowInsets(EdgeInsets())
            TextField("Name", text: $name, prompt: Text("Imported Theme"))
                .accessibilityIdentifier("theme-import-name")
            LabeledContent("Brightness", value: "\(colors.dark ? "Dark" : "Light"), used as \(slot)")
            LabeledContent("ANSI colors", value: "\(colors.ansiSet) of 16")
            colorRow(theme)
            Toggle("Use as \(slot) now", isOn: $useNow)
        } header: {
            Text("Preview")
        } footer: {
            if builtInName {
                Text("A built-in theme has this name, so it's saved as “\(store.uniqueName(effectiveName))”.")
            }
        }
    }

    private func colorRow(_ theme: TerminalTheme) -> some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach([0..<8, 8..<16], id: \.lowerBound) { range in
                GridRow {
                    ForEach(range, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(theme.ansiColor(index))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.quaternary))
                            .frame(height: 18)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var problems: [String] { (fileProblem.map { [$0] } ?? []) + result.errors }

    @ViewBuilder private var messages: some View {
        if !result.notes.isEmpty {
            Section("Notes") {
                ForEach(result.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                }
            }
        }
        if let colors = result.colors,
           case .sameColors(let existing) = store.duplicate(of: colors, named: effectiveName) {
            Section {
                Label(
                    existing.isImported
                        ? "Already imported as “\(existing.name)”."
                        : "This has the same colors as the built-in theme “\(existing.name)”.",
                    systemImage: "doc.on.doc")
            }
        }
    }

    private func isBuiltInName(_ name: String) -> Bool {
        TerminalTheme.all.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func choseFile(_ outcome: Result<URL, Error>) {
        guard case .success(let url) = outcome else {
            if case .failure(let error as NSError) = outcome, error.code != NSUserCancelledError {
                fileProblem = "Couldn't read this file."
            }
            return
        }
        switch ThemeFile.read(url) {
        case .success(let contents):
            text = contents
            name = url.deletingPathExtension().lastPathComponent
        case .failure(let error):
            fileProblem = error.message
        }
    }

    private func add(_ colors: ThemeColors) {
        if case .sameName(let existing) = store.duplicate(of: colors, named: effectiveName) {
            confirmingReplace = existing
        } else {
            save(replacing: nil)
        }
    }

    private func save(replacing existing: TerminalTheme?) {
        guard let colors = result.colors else { return }
        do {
            finish(with: try store.add(colors, name: effectiveName, replacing: existing))
        } catch {
            saveProblem = error as? ThemeStoreError
            saveFailed = true
        }
    }

    private func finish(with theme: TerminalTheme) {
        if useNow { store.select(theme) }
        dismiss()
    }
}

/// Reading the one file the user chose, without taking in more than a theme can be.
enum ThemeFile {
    static func read(_ url: URL) -> Result<String, ThemeFileError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: GhosttyThemeParser.maxBytes + 1) ?? Data()
            return GhosttyThemeParser.text(from: data)
        } catch {
            return .failure(ThemeFileError(message: "Couldn't read this file."))
        }
    }
}

#Preview {
    ThemeImportView()
}
