import SwiftUI

/// App-wide settings, and what Hirte is.
struct SettingsView: View {
    @Environment(HostStore.self) private var hosts
    @AppStorage(TerminalFont.sizeKey) private var fontSize = TerminalFont.defaultSize
    @AppStorage(TerminalFont.storageKey) private var fontFamily = TerminalFont.jetBrainsMono
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(TerminalTheme.lightKey) private var lightTheme = TerminalTheme.defaultLight
    @AppStorage(TerminalTheme.darkKey) private var darkTheme = TerminalTheme.defaultDark
    @Environment(\.colorScheme) private var colorScheme
    /// Adds the demo machine and shows it.
    var addDemo: () -> Void = {}

    private static let website = URL(string: "https://hirte.dev")!
    private static let sourceCode = URL(string: "https://github.com/glattziehen/hirte")!

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                ThemeTerminalPreview(
                    size: fontSize, family: fontFamily,
                    theme: TerminalTheme.current(colorScheme, light: lightTheme, dark: darkTheme))
                    .listRowInsets(EdgeInsets())
                NavigationLink {
                    ThemeGalleryView(dark: false)
                } label: {
                    LabeledContent("Light Theme", value: TerminalTheme.find(lightTheme, dark: false).name)
                }
                NavigationLink {
                    ThemeGalleryView(dark: true)
                } label: {
                    LabeledContent("Dark Theme", value: TerminalTheme.find(darkTheme, dark: true).name)
                }
                Picker("Font", selection: $fontFamily) {
                    ForEach(TerminalFont.allCases) { Text($0.title).tag($0) }
                }
                Stepper(value: $fontSize, in: 7...28, step: 1) {
                    LabeledContent("Size", value: "\(fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt")
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("The terminal uses the light or dark theme to match the appearance. Pinch a terminal to change the size there too.")
            }

            Section {
                Button(hosts.hasDemo ? "Show Demo Machine" : "Add Demo Machine", systemImage: "play.rectangle") {
                    addDemo()
                }
            } footer: {
                Text("A machine built into Hirte, with agents and terminals to try everything without a server.")
            }

            LiveActivitySettingsView()

            Section("Agents") {
                NavigationLink("Agent Overview") { AgentOverviewSettingsView() }
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                Link(destination: Self.website) {
                    Label("Website", systemImage: "globe")
                }
                Link(destination: Self.website.appending(path: "support/")) {
                    Label("Support", systemImage: "questionmark.circle")
                }
                Link(destination: Self.website.appending(path: "privacy/")) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: Self.sourceCode) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                NavigationLink {
                    LicensesView()
                } label: {
                    Label("Open-Source Licenses", systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(HostStore())
}
