import HerdrKit
import SwiftUI

/// The detail column: the live terminal screen, with its facts one tap away.
struct TerminalScreenView: View {
    let session: HostSession
    let address: String
    @Binding var expanded: Bool
    @State private var model: TerminalScreenModel
    @State private var showingInfo = false
    @State private var showingFollowSettings = false
    @AppStorage(TerminalFont.sizeKey) private var fontSize = TerminalFont.defaultSize
    @AppStorage(TerminalFont.storageKey) private var fontFamily = TerminalFont.jetBrainsMono
    /// Open terminals watching (observe) instead of taking them over; remembered.
    @AppStorage("terminal.watch") private var watchByDefault = false
    @AppStorage(TerminalTheme.lightKey) private var lightTheme = TerminalTheme.defaultLight
    @AppStorage(TerminalTheme.darkKey) private var darkTheme = TerminalTheme.defaultDark
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var theme: TerminalTheme { TerminalTheme.current(colorScheme, light: lightTheme, dark: darkTheme) }

    init(session: HostSession, address: String, expanded: Binding<Bool>) {
        self.session = session
        self.address = address
        _expanded = expanded
        // The theme from the start, so the screen never shows other colors while it attaches.
        // (The color scheme isn't known yet here; onChange below corrects it before the first frame.)
        let defaults = UserDefaults.standard
        let style = UITraitCollection.current.userInterfaceStyle
        let theme = TerminalTheme.current(
            style == .dark ? .dark : .light,
            light: defaults.string(forKey: TerminalTheme.lightKey) ?? TerminalTheme.defaultLight,
            dark: defaults.string(forKey: TerminalTheme.darkKey) ?? TerminalTheme.defaultDark)
        _model = State(initialValue: TerminalScreenModel(theme: theme))
    }

    var body: some View {
        let terminal = session.terminal(address)
        ZStack(alignment: .top) {
            // Before the first frame, the theme's background (the frame's afterwards: programs may change it).
            Color(uiColor: UIColor(model.frame.cols == 0 ? theme.backgroundRGB : model.frame.background)).ignoresSafeArea()
            if terminal?.isLive ?? false || model.phase == .live {
                TerminalCanvas(
                    model: model, fontSize: $fontSize, fontFamily: fontFamily, dark: theme.dark,
                    // Unfolded, from the terminal's left part: swiping right brings back the lists,
                    // swiping left pushes them away. (Folded, the edge is the stack's back swipe.)
                    onEdgeSwipe: sizeClass == .regular ? { toRight in
                        if toRight == expanded { withAnimation { expanded = !toRight } }
                    } : nil
                ) { cols, rows in
                    if case .attaching = model.phase {
                        let watch = watchByDefault || session.watchNext == address
                        if session.watchNext == address { session.watchNext = nil }
                        model.start(session: session, address: address, cols: cols, rows: rows, watch: watch)
                    } else {
                        model.viewSizeChanged(cols: cols, rows: rows)
                    }
                }
                // The canvas keeps its full size and makes room for the keyboard itself.
                .ignoresSafeArea(.keyboard)
            }
            overlay(terminal)
            if let terminal, terminal.isLive, terminal.status?.state == "blocked", model.phase == .live {
                NeedsYouBar(status: terminal.status, model: model, dark: theme.dark)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        // Its task, as in the lists, else its name: on a phone the list isn't there to tell.
        .navigationTitle(terminal?.headline(inSpace: true) ?? address)
        // Watching, the size being watched instead.
        .navigationSubtitle(model.watching && terminal != nil
            ? "Watching · \(terminal!.cols)×\(terminal!.rows)" : terminal.map(contextLine) ?? "")
        .navigationBarTitleDisplayMode(.inline)
        // The title bar sits on the terminal's background: match its brightness, not the app's.
        .toolbarColorScheme(theme.dark ? .dark : .light, for: .navigationBar)
        .onChange(of: theme, initial: true) { _, theme in model.theme = theme }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.phase == .live { watchButton }
                if sizeClass == .compact {
                    // A phone's bar keeps room for the title: the rest is one tap further.
                    Menu("More", systemImage: "ellipsis") {
                        if model.phase == .live { keyboardButton }
                        Section("Lock Screen") {
                            LiveActivityFollowActions(session: session, terminal: terminal,
                                                      showingSettings: $showingFollowSettings)
                        }
                        infoButton
                    }
                } else {
                    if model.phase == .live { keyboardButton }
                    followMenu(terminal)
                    // Hiding and showing the lists is the split view's own sidebar button.
                    infoButton
                }
            }
        }
        .liveActivityFollowPresentation(showingSettings: $showingFollowSettings)
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                TerminalDetailView(session: session, address: address)
                    .toolbar {
                        Button("Done") { showingInfo = false }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: terminal.map { [$0.cols, $0.rows] }) { _, size in
            if let size { model.remoteSizeChanged(cols: size[0], rows: size[1]) }
        }
        .onChange(of: session.state) { _, state in
            // The line dropped and came back: attach again.
            if state == .connected, case .failed = model.phase {
                model.stop()
                // With the current theme: onChange(of: theme) won't fire again for the new model.
                model = TerminalScreenModel(theme: theme)
            }
        }
        // "Watch" from the list while this terminal is already open.
        .onChange(of: session.watchNext) { _, next in
            guard next == address, model.phase == .live else { return }
            session.watchNext = nil
            model.setWatching(true)
        }
        // On screen: its agent counts as read (herdr's shared `herdr.seen`).
        .onAppear {
            session.startLooking(at: address)
        }
        .onDisappear {
            model.stop()
            session.stopLooking(at: address)
        }
    }

    /// Watching is remembered for the next terminal; typing ends it only here.
    private var watchButton: some View {
        Button(model.watching ? "Take Over" : "Watch Only",
               systemImage: model.watching ? "eye.fill" : "eye")
        {
            watchByDefault = !model.watching
            model.setWatching(!model.watching)
        }
    }

    private var keyboardButton: some View {
        Button(model.wantsKeyboard ? "Hide Keyboard" : "Show Keyboard",
               systemImage: model.wantsKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
        {
            model.wantsKeyboard.toggle()
        }
    }

    private func followMenu(_ terminal: Terminal?) -> some View {
        LiveActivityFollowMenu(session: session, terminal: terminal, showingSettings: $showingFollowSettings)
    }

    private var infoButton: some View {
        Button("Info", systemImage: "info.circle") { showingInfo = true }
    }

    /// Where it works and whose account, as its row says it: what it's about while you answer it.
    private func contextLine(_ terminal: Terminal) -> String {
        let context = TerminalContext(terminal: terminal)
        var parts: [String] = []
        for case let part? in [spaceName(terminal), context.branch, context.account] where !parts.contains(part) {
            parts.append(part)
        }
        return parts.joined(separator: " · ")
    }

    /// The space (or machine) the terminal belongs to, as the list shows it.
    private func spaceName(_ terminal: Terminal) -> String? {
        TerminalGrouping.bySpace(session.terminals, layout: session.layout)
            .first { $0.rows.contains { $0.terminal.address == terminal.address } }?.title
    }

    @ViewBuilder
    private func overlay(_ terminal: Terminal?) -> some View {
        switch model.phase {
        case .attaching:
            if terminal?.isLive == false {
                TerminalDetailView(session: session, address: address)
            } else {
                let foreground = theme.color(theme.foreground)
                ProgressView("Attaching…").padding(.top, 40).tint(foreground).foregroundStyle(foreground)
            }
        case .live:
            // Watching needs no banner: the subtitle says so, with the size.
            if model.sizeOwnedElsewhere && !model.watching {
                Banner(text: "Another viewer sets the size. Tap the screen and type to take over.",
                       systemImage: "rectangle.on.rectangle", dark: theme.dark)
            } else if model.scrolledBack {
                Button {
                    model.scroll(toBottom: true)
                } label: {
                    Banner(text: "Scrolled back. Tap to return to the live screen.", systemImage: "arrow.down.to.line", dark: theme.dark)
                }
                .buttonStyle(.plain)
            }
        case .ended(let reason):
            Banner(text: reason, systemImage: "stop.circle", dark: theme.dark)
        case .failed(let message):
            Banner(text: message, systemImage: "exclamationmark.triangle", dark: theme.dark)
        }
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String
    var dark = true

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            // Over the terminal, like the bar below: its brightness, not the app's.
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// A blocked agent waits for an answer: the usual replies as buttons, so there's no need to type.
private struct NeedsYouBar: View {
    let status: TerminalStatus?
    let model: TerminalScreenModel
    var dark = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(status?.title ?? "Waiting for you").lineLimit(2)
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(Color.needsYouMark)
            }
            .font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Button { model.type("y") } label: {
                    Label("Yes", systemImage: "checkmark").fixedSize().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appControl)
                .foregroundStyle(Color(uiColor: .systemBackground))
                Button { model.type("n") } label: {
                    Label("No", systemImage: "xmark").fixedSize().frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { model.press(.enter) } label: { Image(systemName: "return").fixedSize() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Return")
                Button { model.press(.escape) } label: { Text("esc").font(.callout.monospaced()).fixedSize() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Escape")
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
        }
        .padding(16)
        .background(.regularMaterial, in: ConcentricRectangle(corners: .concentric(minimum: 24), isUniform: true))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}
