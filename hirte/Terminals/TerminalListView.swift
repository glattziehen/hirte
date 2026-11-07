import HerdrKit
import SwiftUI

/// A machine's terminals, live from events, in two views like herdr-app's sidebar: the agents
/// (what each is doing, with its status) or all terminals by space and tab.
struct TerminalListView: View {
    @Environment(KeyLibrary.self) private var keys
    let session: HostSession
    @Binding var selection: String?
    /// A column next to the detail: its selected row stays, drawn in the sidebar's own shape.
    let besideDetail: Bool
    @AppStorage("terminals.view") private var mode = Mode.agents
    /// The rows each view had on screen, so switching back scrolls to where it was.
    @State private var visibleRows: [Mode: Set<String>] = [:]
    /// Set while a view is swapped in and scrolled back; rows coming and going then don't count.
    @State private var restoring: Mode?
    /// Hides a swapped-in list until it's scrolled back, so its top doesn't flash.
    @State private var concealed = false
    @State private var newTerminal: NewTerminalContext?
    @State private var confirmKill: Terminal?
    /// The finished terminals "Clear" would remove, as they were when it was tapped.
    @State private var confirmClear: [Terminal]?
    @State private var actionError: String?
    /// The open agent and how it showed when opened: a done one stays under Done while it's
    /// open (looking marks it read), instead of moving away under the selection.
    @State private var held: (address: String, state: AgentState)?
    /// Collapsed sections as "hostID|sectionID" lines, remembered across launches.
    @AppStorage("terminals.collapsed") private var collapsed = ""
    @AppStorage(AgentOverviewPreferences.storageKey) private var overviewStored = ""
    @State private var showingAgentSettings = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var overview: AgentOverviewPreferences { .init(rawValue: overviewStored) }

    enum Mode: String, CaseIterable, Identifiable {
        case agents, terminals
        var id: Self { self }
        var title: String { self == .agents ? "Agents" : "Terminals" }
    }

    var body: some View {
        content
            .navigationTitle(session.host.name)
            .toolbar {
                // One item at most: a second would fall into the overflow in the unfolded sidebar.
                if session.snapshot != nil, mode == .agents {
                    ToolbarItem(placement: .topBarTrailing) { overviewMenu }
                }
            }
            .onAppear { session.start(keys: keys) }
            .onChange(of: selection, initial: true) { _, address in
                held = session.terminal(address).flatMap { terminal in
                    terminal.agentState.map { (terminal.address, $0) }
                }
            }
            .sheet(item: $newTerminal) { context in
                NewTerminalView(session: session, context: context) { address in
                    selection = address
                }
            }
            .sheet(isPresented: $showingAgentSettings) {
                NavigationStack {
                    agentSettings
                        .accessibilityIdentifier("agent-overview-settings")
                        .toolbar {
                            Button("Done") { showingAgentSettings = false }
                                .accessibilityIdentifier("agent-overview-done")
                        }
                }
            }
            .confirmationDialog(
                "Kill \(confirmKill?.nameInSpace ?? "")?", isPresented: .constant(confirmKill != nil),
                titleVisibility: .visible, presenting: confirmKill
            ) { terminal in
                Button("Kill", role: .destructive) { perform { try await session.kill(terminal.address) } }
                Button("Cancel", role: .cancel) { confirmKill = nil }
            } message: { terminal in
                Text("\(terminal.address) gets a hangup, then is terminated. Agents it started end with it.")
            }
            .alert("Could not do that", isPresented: .constant(actionError != nil)) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            .alert(
                "Trust this machine?",
                isPresented: .constant(session.pendingHostKey != nil),
                presenting: session.pendingHostKey
            ) { _ in
                Button("Trust") { session.answerHostKey(trust: true) }
                Button("Cancel", role: .cancel) { session.answerHostKey(trust: false) }
            } message: { key in
                Text("First connection to \(key.host). Its host key fingerprint is\n\n\(key.fingerprint)\n\n"
                    + "Compare it with `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub` on the machine.")
            }
    }

    /// iOS 27 can minimize the navigation bar while the form scrolls. Keep Done reachable there;
    /// earlier releases use the standard navigation bar without that minimization behavior.
    @ViewBuilder
    private var agentSettings: some View {
        if #available(iOS 27.0, *) {
            AgentOverviewSettingsView()
                .toolbarMinimizationBehavior(.never, for: .navigationBar)
        } else {
            AgentOverviewSettingsView()
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.snapshot != nil {
            terminalList
        } else {
            switch session.state {
            case .failed(let message, let retrying):
                ConnectionProblem(message: message, retrying: retrying, session: session)
            default:
                VStack(spacing: 12) {
                    ProgressView()
                    if case .connecting(let step) = session.state {
                        Text(step).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// A visible "new terminal here", for real spaces: the same as the header's context menu.
    private func newTerminalAction(_ section: TerminalSection) -> (() -> Void)? {
        guard session.state == .connected, case .space(let id) = section.kind,
              let space = session.layout?.spaces.first(where: { $0.id == id }) else { return nil }
        return { newTerminal = NewTerminalContext(space: space, folder: spaceFolder(space, section)) }
    }

    /// Where a new terminal in this space starts.
    private func spaceFolder(_ space: HerdrAppLayout.Space, _ section: TerminalSection) -> String {
        section.workingFolder ?? space.folder
    }

    private func rowView(_ row: TerminalRow) -> some View {
        rowView(row, terminal: row.terminal, rails: row.rails)
    }

    private func rowView<Content: View>(_ row: Content, terminal: Terminal, rails: FamilyRails,
                                        showsProgress: Bool = false) -> some View {
        var add: ((Terminal) -> Void)?
        if canAddToHerdrApp(terminal) { add = { addToHerdrApp($0) } }
        let actions = TerminalActions(
            terminal: terminal, session: session, kill: { confirmKill = $0 }, remove: { remove($0) },
            addToHerdrApp: add, watch: { watch($0) }, mark: { mark($0, $1) })
        // Outside the actions' wrappers, or a list doesn't see it.
        var hidden = rails.hiddenSeparators
        // A progress line along the row's end is its separator: no second line right below it.
        if showsProgress { hidden.insert(.bottom) }
        let selected = besideDetail && selection == terminal.address
        return row
            .background { if besideDetail { RowFocusEffectRemover() } }
            .environment(\.sidebarBesideDetail, besideDetail)
            .tag(terminal.address)
            .modifier(actions)
            .listRowSeparator(hidden.isEmpty ? .automatic : .hidden, edges: hidden.isEmpty ? .all : hidden)
            .listRowInsets(.vertical, rails.rowInset)
            .listRowInsets(.horizontal, besideDetail ? SidebarMetrics.selectionPadding : nil)
            // Beside the detail only: on a phone there's no lasting selection, and this would
            // replace the fill of its card.
            .listRowBackground(besideDetail ? SidebarRowBackground(selected: selected) : nil)
    }

    /// Live, on this machine, in no herdr-app space or pane, and not an agent's child
    /// (children follow their parent).
    private func canAddToHerdrApp(_ terminal: Terminal) -> Bool {
        guard terminal.isLive, !terminal.address.contains("/"), terminal.parent == nil,
              (terminal.labels[HerdrAppLayout.spaceLabel] ?? "").isEmpty
        else { return false }
        return !(session.layout?.spaces.contains { $0.tabs.contains { $0.terminals.contains(terminal.address) } } ?? false)
    }

    /// Labels it with a fresh space id: a running herdr-app opens a new space for it.
    private func addToHerdrApp(_ terminal: Terminal) {
        perform { try await session.label(terminal.address, [HerdrAppLayout.spaceLabel: HerdrAppLayout.newSpaceID()]) }
    }

    /// Opens it watching, this once.
    private func watch(_ terminal: Terminal) {
        session.watchNext = terminal.address
        selection = terminal.address
    }

    /// Mark as read or unread: writes `herdr.seen`, shared with herdr-app.
    private func mark(_ terminal: Terminal, _ labels: [String: String]) {
        // Marked by hand: show it where it now belongs, even while open.
        if held?.address == terminal.address { held = nil }
        perform { try await session.label(terminal.address, labels) }
    }

    private func remove(_ terminal: Terminal) {
        if selection == terminal.address { selection = nil }
        perform { try await session.remove(terminal.address) }
    }

    private static func finishedCount(_ terminals: [Terminal]) -> String {
        terminals.count == 1 ? "1 finished terminal" : "\(terminals.count) finished terminals"
    }

    /// Removes them one by one, going on past failures: the core keeps a terminal until a
    /// waiting parent has its exit code.
    private func clear(_ terminals: [Terminal]) {
        confirmClear = nil
        if let selection, terminals.contains(where: { $0.address == selection }) { self.selection = nil }
        Task {
            var failed: [(String, Error)] = []
            for terminal in terminals {
                do { try await session.remove(terminal.address) } catch { failed.append((terminal.address, error)) }
            }
            guard let (address, error) = failed.first else { return }
            let removed = terminals.count - failed.count
            actionError = "Removed \(removed) of \(terminals.count). \(failed.count == 1 ? address : "\(failed.count), like \(address),")"
                + " could not be removed: \(error.localizedDescription)"
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        confirmKill = nil
        Task {
            do { try await action() } catch { actionError = error.localizedDescription }
        }
    }

    /// Whether a section is open; collapsing is remembered per machine. A section that starts
    /// collapsed is remembered when opened instead (its key gets an "open:" prefix).
    private func expanded(_ section: String, initially open: Bool = true) -> Binding<Bool> {
        let key = "\(session.host.id.uuidString)|\(open ? "" : "open:")\(section)"
        return Binding(
            get: { collapsed.split(separator: "\n").contains(Substring(key)) != open },
            set: { isOpen in
                var keys = collapsed.split(separator: "\n").map(String.init).filter { $0 != key }
                if isOpen != open { keys.append(key) }
                collapsed = keys.joined(separator: "\n")
            })
    }

    private var spaceSections: [TerminalSection] {
        TerminalGrouping.bySpace(session.terminals.filter(\.isLive), layout: session.layout)
    }

    /// Finished terminals, newest first, in one section of their own below the spaces.
    private var finished: [Terminal] {
        session.terminals.filter { !$0.isLive }.sorted { $0.createdMs > $1.createdMs }
    }

    private var agentGroups: [AgentOverviewGroup] {
        AgentOverview.groups(session.terminals, mode: overview.mode, sort: overview.sort,
                             held: held.map { [$0.address: $0.state] } ?? [:])
    }

    private var agentSpaces: [String: String] {
        var result: [String: String] = [:]
        for section in TerminalGrouping.bySpace(session.terminals.filter(\.isLive), layout: session.layout) {
            if case .other = section.kind { continue }
            for row in section.rows { result[row.terminal.address] = section.title }
        }
        return result
    }

    private func visibleAgentRows(_ group: AgentOverviewGroup) -> [AgentOverviewRow] {
        group.rows.filter { row in
            row.ancestors.allSatisfy { expanded("agent:\($0)").wrappedValue }
        }
    }

    /// What's most urgent among the children folded away, if that's more than the row itself says.
    private func foldedState(_ row: AgentOverviewRow, in group: AgentOverviewGroup) -> AgentOverviewState? {
        guard row.childCount > 0, !expanded("agent:\(row.id)").wrappedValue else { return nil }
        let states = group.rows.filter { $0.ancestors.contains(row.id) }.map(\.state)
        let order = AgentOverviewState.allCases
        guard let urgent = order.first(where: states.contains),
              order.firstIndex(of: urgent)! < order.firstIndex(of: row.state)! else { return nil }
        return urgent
    }

    private func overviewBinding<Value>(_ keyPath: WritableKeyPath<AgentOverviewPreferences, Value>) -> Binding<Value> {
        Binding(get: { overview[keyPath: keyPath] }, set: { value in
            var updated = overview
            updated[keyPath: keyPath] = value
            overviewStored = updated.rawValue
        })
    }

    private var overviewMenu: some View {
        Menu {
            Picker("Agent view", selection: overviewBinding(\.mode)) {
                ForEach(AgentOverviewMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Sort by", selection: overviewBinding(\.sort)) {
                ForEach(AgentOverviewSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Button("Customize Rows…", systemImage: "slider.horizontal.3") { showingAgentSettings = true }
        } label: {
            // Its title is what VoiceOver reads: a toolbar item has no value of its own to say this.
            Label("View and Sort: \(overview.mode.title), sorted by \(overview.sort.title)",
                  systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityIdentifier("agent-overview-menu")
    }

    /// One list per view (`.id`), swapped without animation: agents are rows in both, and
    /// diffing one into the other slid them across while the rest faded over them. Switching back
    /// scrolls to the row that was at the top. (Keeping both lists alive would keep the position
    /// for free, but a hidden List stays in the accessibility tree; and `ScrollPosition` doesn't
    /// move a List.)
    private var terminalList: some View {
        ScrollViewReader { proxy in
            list(mode)
                .id(mode)
                .opacity(concealed ? 0 : 1)
                .onChange(of: mode) { _, mode in
                    restoring = mode
                    let seen = visibleRows[mode] ?? []
                    let order = rowOrder(mode)
                    // At the top already: nothing to hide, nor to scroll, which would put the first
                    // row where its section's header belongs.
                    let top = order.first { seen.contains($0) }.flatMap { $0 == order.first ? nil : $0 }
                    concealed = top != nil
                    Task { @MainActor in
                        // The new list lays out its rows first.
                        try? await Task.sleep(for: .milliseconds(30))
                        if let top { proxy.scrollTo(top, anchor: .top) }
                        // Show it once the scroll has been drawn.
                        try? await Task.sleep(for: .milliseconds(20))
                        concealed = false
                        try? await Task.sleep(for: .milliseconds(180))
                        visibleRows[mode] = seen
                        if restoring == mode { restoring = nil }
                    }
                }
        }
            // Over the list, not a strip above it: the rows scroll on underneath.
            .safeAreaBar(edge: .bottom, spacing: 0) { modeBar }
    }

    /// One height and edge for every section's header, whichever view and whatever it holds.
    private func sectionHeader<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(minHeight: SidebarMetrics.headerHeight)
            .listRowInsets(.vertical, 0)
            // The header's own cell starts a little further in than a row's.
            .listRowInsets(.horizontal, besideDetail ? SidebarMetrics.selectionPadding - 4 : nil)
    }

    /// The views' switch and the one action both views share, at the thumb. Glass only here, where
    /// there's something to see through it.
    private var modeBar: some View {
        let large = typeSize.isAccessibilitySize
        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ModeSwitch(mode: $mode)
                    .frame(maxWidth: large ? .infinity : 240, alignment: .leading)
                Spacer(minLength: 0)
                Button {
                    newTerminal = NewTerminalContext(folder: nil)
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color.rowPrimary)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("New Terminal")
                .disabled(session.state != .connected)
            }
        }
        .padding(.horizontal, besideDetail ? SidebarMetrics.selectionMargin : 16)
        .padding(.top, SidebarMetrics.barTopGap)
        .padding(.bottom, besideDetail ? 16 : 4)
        // All of it, gap included: where the list's visible part ends.
        .contentShape(.accessibility, Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mode-bar")
    }

    /// The rows of a view, top to bottom.
    private func rowOrder(_ shown: Mode) -> [String] {
        if shown == .agents {
            return agentGroups.filter { expanded("status:\($0.state.rawValue)", initially: $0.state != .idle).wrappedValue }
                .flatMap { visibleAgentRows($0).map(\.terminal.address) }
        }
        let open = expanded("finished", initially: false).wrappedValue
        return spaceSections.flatMap { $0.rows.map(\.terminal.address) } + (open ? finished.map(\.address) : [])
    }

    private func tracking(_ address: String, in shown: Mode) -> RowVisibility {
        RowVisibility { isVisible in
            guard restoring == nil, mode == shown else { return }
            if isVisible { visibleRows[shown, default: []].insert(address) }
            else { visibleRows[shown]?.remove(address) }
        }
    }

    private func list(_ shown: Mode) -> some View {
        List(selection: $selection) {
            // Keep the last list visible while reconnecting, with a banner on top.
            if session.state != .connected {
                ConnectionBanner(state: session.state, session: session)
                    .tint(Color.appControl)
            }
            switch shown {
            case .agents:
                let groups = agentGroups
                let spaces = agentSpaces
                if groups.isEmpty {
                    ContentUnavailableView(
                        "No agents", systemImage: "sparkles",
                        description: Text("Agents that report their status to herdr show up here."))
                }
                ForEach(groups) { group in
                    let visible = visibleAgentRows(group)
                    Section(isExpanded: expanded("status:\(group.state.rawValue)", initially: group.state != .idle)) {
                        let rails = FamilyRails.layout(depths: visible.map(\.depth))
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                            rowView(AgentOverviewRowView(
                                terminal: row.terminal, state: row.state,
                                context: TerminalContext(terminal: row.terminal, project: spaces[row.id]),
                                preferences: overview, space: spaces[row.id], rails: rails[index],
                                parent: session.terminal(row.ancestors.last).map {
                                    TerminalContext(terminal: $0, project: spaces[$0.address])
                                },
                                // Only while the member it names is out of sight.
                                reason: visible.contains { $0.id == row.reason?.address } ? nil : row.reason,
                                familyState: group.state, childCount: row.childCount,
                                expanded: row.childCount > 0 ? expanded("agent:\(row.id)") : nil,
                                foldedState: foldedState(row, in: group)),
                                terminal: row.terminal, rails: rails[index],
                                showsProgress: overview.fields.contains(.progress) && row.state == .working
                                    && row.terminal.status?.progress != nil)
                                .modifier(tracking(row.terminal.address, in: shown))
                        }
                    } header: {
                        sectionHeader { AgentGroupHeader(group: group) }
                    }
                    .listSectionMargins(.horizontal, besideDetail ? SidebarMetrics.selectionMargin : nil)
                }
            case .terminals:
                if spaceSections.isEmpty {
                    ContentUnavailableView(
                        "No live terminals", systemImage: "terminal",
                        description: Text("Start one with `hc run --bg` on the machine."))
                }
                ForEach(spaceSections) { section in
                    Section(isExpanded: expanded(section.id)) {
                        let rails = FamilyRails.layout(depths: section.rows.map(\.depth))
                        ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                            rowView(TerminalRow(
                                terminal: row.terminal, rails: rails[index], tab: row.tab, inSpace: true,
                                sharedFolder: section.workingFolder,
                                parent: row.depth > 0 ? session.terminal(row.terminal.parent) : nil))
                                .modifier(tracking(row.terminal.address, in: shown))
                        }
                    } header: {
                        sectionHeader {
                            SpaceHeader(section: section, addTerminal: newTerminalAction(section),
                                        expanded: expanded(section.id).wrappedValue)
                                .contextMenu {
                                    if case .space(let id) = section.kind,
                                       let space = session.layout?.spaces.first(where: { $0.id == id })
                                    {
                                        Button("New Terminal Here", systemImage: "plus") {
                                            newTerminal = NewTerminalContext(space: space, folder: spaceFolder(space, section))
                                        }
                                    }
                                }
                        }
                    }
                    .listSectionMargins(.horizontal, besideDetail ? SidebarMetrics.selectionMargin : nil)
                }
                // Out of the way, but at hand to see how something ended or to remove it.
                if !finished.isEmpty {
                    Section(isExpanded: expanded("finished", initially: false)) {
                        ForEach(finished) { terminal in
                            rowView(TerminalRow(terminal: terminal))
                                .modifier(tracking(terminal.address, in: shown))
                        }
                    } header: {
                        sectionHeader { HStack(spacing: 6) {
                            Text("Finished").sidebarSectionTitle()
                            SidebarCount(count: finished.count)
                            Spacer()
                            // Only while open: next to the rows it removes, not in the way of
                            // the tap that opens the section.
                            if expanded("finished", initially: false).wrappedValue {
                                Button { confirmClear = finished } label: {
                                    // Set on the label: a borderless button draws in the tint.
                                    Text("Clear").font(.subheadline).foregroundStyle(Color.rowSecondary)
                                }
                                    .buttonStyle(.borderless)
                                    .tint(Color.appControl)
                                    .disabled(session.state != .connected)
                                    // On the button, so the popover points at it.
                                    .confirmationDialog(
                                        "Remove \(confirmClear.map(Self.finishedCount) ?? "")?",
                                        isPresented: .constant(confirmClear != nil),
                                        titleVisibility: .visible, presenting: confirmClear
                                    ) { terminals in
                                        Button("Remove", role: .destructive) { clear(terminals) }
                                        Button("Cancel", role: .cancel) { confirmClear = nil }
                                    } message: { terminals in
                                        Text(terminals.count == 1
                                            ? "Its screen and exit code are gone for good."
                                            : "Their screens and exit codes are gone for good.")
                                    }
                            }
                        } }
                    }
                    .listSectionMargins(.horizontal, besideDetail ? SidebarMetrics.selectionMargin : nil)
                }
            }
            if !session.machines.isEmpty {
                Section("Machines added on \(session.coreName ?? "this core")") {
                    ForEach(session.machines) { machine in
                        LabeledContent(machine.name, value: machine.state)
                    }
                }
            }
            if !session.host.isDemo, let name = session.coreName, let version = session.coreVersion {
                Text("\(name) · herdr-core \(version)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        // Rows going under the bar lose their text before they reach its glass.
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .listSectionSpacing(SidebarMetrics.sectionSpacing)
        .environment(\.defaultMinListRowHeight, SidebarMetrics.touchTarget)
        .tint(Color.sidebarSelection)
        .animation(.default, value: session.terminals.map(\.address))
    }
}

/// Removes the focus halo of the list's cell around this row: it has the cell's square corners, not
/// the row's, and `focusEffectDisabled` doesn't reach it (seen on iOS 27.2). The cell stays focusable
/// and selectable: the keyboard's focus moves the selection, whose fill then shows where it is.
private struct RowFocusEffectRemover: UIViewRepresentable {
    final class Marker: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            clear()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            clear()
        }

        func clear() {
            var view = superview
            while let candidate = view {
                if let cell = candidate as? UICollectionViewCell {
                    if cell.focusEffect != nil { cell.focusEffect = nil }
                    return
                }
                view = candidate.superview
            }
        }
    }

    func makeUIView(context: Context) -> Marker {
        let marker = Marker()
        marker.isUserInteractionEnabled = false
        marker.isAccessibilityElement = false
        return marker
    }

    /// Also on every update of the row: a list may configure its cell again.
    func updateUIView(_ uiView: Marker, context: Context) { uiView.clear() }
}

/// Agents or Terminals: one glass capsule with one quiet pill. (A segmented picker brings a track and
/// border of its own, which on glass reads as a capsule in a capsule.)
private struct ModeSwitch: View {
    @Binding var mode: TerminalListView.Mode
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TerminalListView.Mode.allCases) { option in
                let selected = option == mode
                Button { mode = option } label: {
                    Text(option.title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.rowPrimary : Color.rowSecondary)
                        .frame(maxWidth: .infinity, minHeight: SidebarMetrics.touchTarget)
                        .background {
                            if selected {
                                Capsule().fill(Color.rowFill).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: mode)
        .padding(2)
        .frame(minHeight: 48)
        .glassEffect(.regular, in: .capsule)
    }
}

struct ConnectionProblem: View {
    @Environment(KeyLibrary.self) private var keys
    let message: String
    let retrying: Bool
    let session: HostSession

    var body: some View {
        ContentUnavailableView {
            Label(retrying ? "Reconnecting…" : "Could not connect", systemImage: "bolt.horizontal.circle")
        } description: {
            Text(message)
        } actions: {
            Button(retrying ? "Retry Now" : "Retry") { session.retry(keys: keys) }
                .buttonStyle(.borderedProminent)
            if message.contains("host key") && message.contains("changed") {
                Button("Forget Stored Host Key", role: .destructive) { session.forgetHostKey() }
            }
        }
    }
}

struct ConnectionBanner: View {
    @Environment(KeyLibrary.self) private var keys
    let state: HostSession.State
    let session: HostSession

    var body: some View {
        HStack(spacing: 10) {
            switch state {
            case .connecting(let step):
                ProgressView().controlSize(.small)
                Text(step)
            case .failed(let message, let retrying):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(retrying ? "Reconnecting… \(message)" : message).lineLimit(2)
                Spacer()
                Button("Retry") { session.retry(keys: keys) }.buttonStyle(.bordered)
            default:
                Text("Not connected")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct TerminalRow: View {
    let terminal: Terminal
    var rails = FamilyRails()
    var tab: String?
    /// Inside a space section the space name is already the header.
    var inSpace = false
    /// The folder the header shows; only a terminal working elsewhere repeats a path.
    var sharedFolder: String?
    /// The terminal it's shown under, whose branch and folder it needn't repeat.
    var parent: Terminal?

    private var title: String { inSpace ? terminal.headline(inSpace: true) : terminal.displayName }
    /// It says what it's working on: an agent's row. Otherwise one line, with what it runs next to its name.
    private var hasTask: Bool { terminal.isLive && terminal.status?.title?.isEmpty == false }

    private var context: RowContext {
        if !terminal.isLive {
            var row = RowContext()
            row.who = [terminal.detail(inSpace: inSpace) ?? "finished"]
            row.label = row.who[0]
            return row
        }
        var row = RowContext.terminal(terminal, inSpace: inSpace, sharedFolder: sharedFolder, parent: parent)
        if !hasTask, let elsewhere = row.elsewhere {
            row.who.append(elsewhere)
            row.elsewhere = nil
        }
        return row
    }

    var body: some View {
        let row = context
        SidebarRow(rails: rails) {
            AgentProviderIcon(
                terminal: terminal, neutralSymbol: "terminal", size: rails.iconSize,
                mark: terminal.isLive ? terminal.agentState.map { StatusMark(agent: $0) } : nil)
        } content: {
            VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
                RowHead(title: title, dimmed: !terminal.isLive, emphasized: terminal.isLive && terminal.agentState == .needsYou,
                        compact: rails.depth > 0, inline: !hasTask, context: row) {
                    if let tab {
                        // Plain, at the row's end: which tab of its space it's in.
                        Text(tab).sidebarDetail().lineLimit(1).accessibilityLabel("Tab \(tab)")
                    }
                }
                if let elsewhere = row.elsewhere {
                    Text(elsewhere).sidebarDetail().lineLimit(1).truncationMode(.head)
                }
            }
        } trailing: {
            EmptyView()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(terminal.address)
    }
}

/// Reports when a row comes on screen or goes off it.
struct RowVisibility: ViewModifier {
    let changed: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { changed(true) }
            .onDisappear { changed(false) }
    }
}

/// Kill (live) or remove (finished) from a row's context menu or swipe. A live terminal's
/// menu shows its screen above, watched.
struct TerminalActions: ViewModifier {
    let terminal: Terminal
    let session: HostSession
    let kill: (Terminal) -> Void
    let remove: (Terminal) -> Void
    /// Set for live local terminals herdr-app doesn't show yet.
    var addToHerdrApp: ((Terminal) -> Void)?
    /// Opens a live terminal watching.
    var watch: ((Terminal) -> Void)?
    /// Writes labels: mark as read or unread.
    var mark: ((Terminal, [String: String]) -> Void)?
    /// The row's width: the preview may not be wider than the column it opens in, or the
    /// system crops it (seen on the unfolded Duo).
    @State private var rowWidth: CGFloat = 0

    func body(content: Content) -> some View {
        Group {
            if terminal.isLive {
                content
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
                    .contentShape(.contextMenuPreview, SidebarSelectionShape())
                    .contextMenu { menu } preview: {
                        TerminalPeek(session: session, terminal: terminal, maxWidth: rowWidth)
                    }
            } else {
                content
                    .contentShape(.contextMenuPreview, SidebarSelectionShape())
                    .contextMenu { menu }
            }
        }
        // Like Mail: read state from the leading edge.
        .swipeActions(edge: .leading) {
            if let mark, let (title, icon, labels) = readAction {
                Button(title, systemImage: icon) { mark(terminal, labels) }.tint(.blue)
            }
        }
        .swipeActions(edge: .trailing) {
            if terminal.isLive {
                Button("Kill", systemImage: "xmark.octagon") { kill(terminal) }.tint(.red)
            } else {
                Button("Remove", systemImage: "trash", role: .destructive) { remove(terminal) }
            }
        }
    }

    /// Mark as Read for an unread agent, Mark as Unread for a read one with a turn behind it.
    private var readAction: (String, String, [String: String])? {
        guard terminal.isLive else { return nil }
        if let labels = terminal.markRead { return ("Mark as Read", "envelope.open", labels) }
        if let labels = terminal.markUnread { return ("Mark as Unread", "envelope.badge", labels) }
        return nil
    }

    @ViewBuilder
    private var menu: some View {
        // What its mark means, also with the time, which explains it on a tap, switched off.
        if AgentOverview.isAgent(terminal) {
            Section(AgentOverviewState(terminal: terminal).explanation) {}
        }
        if terminal.isLive, let watch {
            Button("Watch", systemImage: "eye") { watch(terminal) }
        }
        if let mark, let (title, icon, labels) = readAction {
            Button(title, systemImage: icon) { mark(terminal, labels) }
        }
        Button("Copy Address", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = terminal.address
        }
        if let addToHerdrApp {
            Button("Add to herdr-app", systemImage: "square.stack.badge.plus") { addToHerdrApp(terminal) }
        }
        if terminal.isLive {
            Button("Kill", systemImage: "xmark.octagon", role: .destructive) { kill(terminal) }
        } else {
            Button("Remove", systemImage: "trash", role: .destructive) { remove(terminal) }
        }
    }
}

/// A section on one line: its name, the folder its terminals share if all of it fits, how many
/// need you, and how many there are while they're folded away. Spaces, by far the most common,
/// have no icon, like in herdr-app; only another machine's terminals get one.
struct SpaceHeader: View {
    let section: TerminalSection
    /// New terminal in this space; nil where there's no space to add to or no connection.
    var addTerminal: (() -> Void)?
    var expanded = true
    @Environment(\.dynamicTypeSize) private var typeSize

    private var name: some View {
        Text(section.title).sidebarSectionTitle(emphasized: section.needsYou > 0).lineLimit(large ? nil : 1)
    }

    private func folder(_ path: String) -> some View {
        Text(path).sidebarDetail().lineLimit(large ? nil : 1).truncationMode(.middle)
    }

    @ViewBuilder private var counts: some View {
        HStack(spacing: 8) {
            if section.needsYou > 0 { NeedsYouBadge(count: section.needsYou) }
            if !expanded { SidebarCount(count: section.rows.count) }
        }
    }

    var body: some View {
        let path = section.workingFolder.map { Terminal.abbreviate($0) }
        if large {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    machineIcon
                    name
                    Spacer(minLength: 4)
                    addButton
                }
                counts
                if let path { folder(path) }
            }
        } else {
            HStack(spacing: 6) {
                machineIcon
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        name
                        if let path { folder(path) }
                    }
                    name
                }
                Spacer(minLength: 4)
                counts
                addButton
            }
        }
    }

    @ViewBuilder private var machineIcon: some View {
        if case .machine = section.kind {
            Image(systemName: "server.rack")
                .foregroundStyle(Color.rowSecondary)
                .accessibilityLabel("Machine")
        }
    }

    @ViewBuilder private var addButton: some View {
        if let addTerminal {
            Button(action: addTerminal) {
                Image(systemName: "plus")
                    .font(.subheadline)
                    .foregroundStyle(Color.rowSecondary)
                    .frame(width: SidebarMetrics.touchTarget, height: SidebarMetrics.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("New Terminal in \(section.title)")
        }
    }

    private var large: Bool { typeSize.isAccessibilitySize }
}

extension Terminal {
    /// A live terminal whose program reports its status to herdr (an agent).
    var isAgent: Bool { isLive && status != nil }

    /// Its name inside a space: without herdr-app's "space / tab" label, which the header already says.
    var nameInSpace: String {
        if let name, !name.isEmpty { return name }
        if let title, !title.isEmpty { return title }
        if let foreground { return foreground.name }
        return address
    }

    /// The row's main line: what an agent is working on, else the terminal's name.
    func headline(inSpace: Bool) -> String {
        if isLive, let title = status?.title, !title.isEmpty { return title }
        return inSpace ? nameInSpace : displayName
    }

    /// What the row says next to its headline: where it works, who it is if the headline is its
    /// task. A folder the section's header already says isn't repeated, nor what its parent right
    /// above it says.
    func detail(inSpace: Bool, sharedFolder: String? = nil, parent: Terminal? = nil) -> String? {
        guard isLive else { return exitCode.map { "exited \($0)" } ?? reason ?? "finished" }
        let row = RowContext.terminal(self, inSpace: inSpace, sharedFolder: sharedFolder, parent: parent)
        let parts = [row.branch, row.elsewhere].compactMap { $0 } + row.who
        return parts.isEmpty ? nil : parts.joined(separator: Self.detailSeparator)
    }

    /// Stays at the end of a line when text wraps, so that no line starts with a dot.
    static let detailSeparator = "\u{00A0}· "

    /// What it is doing: the status message, else the foreground program and folder.
    var summary: String? {
        if let status, isLive {
            let message = [status.title, status.msg].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return message.isEmpty ? status.state : "\(status.state) · \(message)"
        }
        if let foreground {
            return "\(foreground.name) · \(Self.abbreviate(foreground.cwd))"
        }
        if !isLive {
            return exitCode.map { "exited \($0)" } ?? reason
        }
        return Self.abbreviate(cwd)
    }

    /// When its status word last changed, as herdr-core reports it.
    var statusSince: Date? {
        statusMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    /// "now", "47m", "3h", "2d": how long ago, as short as herdr-app's agents list shows it.
    /// A machine's clock running ahead reads as now.
    static func shortAge(_ date: Date, now: Date = .now) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
    }

    static func abbreviate(_ path: String) -> String {
        for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") { return "~" + rest[slash...] }
            return "~"
        }
        return path
    }
}

/// herdr's status colors: working, blocked (needs you), done, idle. In a row they're a `StatusMark`.
struct StatusDot: View {
    let state: String?
    var label: String?
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    /// As the agents view shows it: done only while unread.
    init(agent: AgentState) {
        state = agent.statusWord
        label = agent.title
    }

    init(state: String?) {
        self.state = state
    }

    var body: some View {
        Group {
            if withoutColor, let symbol = Self.symbol(for: state) {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Self.color(for: state))
            } else {
                Circle()
                    .fill(Self.color(for: state))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityLabel(label ?? state ?? "no status")
    }

    /// With Differentiate Without Color: the status as a shape too.
    static func symbol(for state: String?) -> String? {
        switch state {
        case "working": "arrow.triangle.2.circlepath"
        case "blocked": "hand.raised.fill"
        case "error": "exclamationmark.triangle.fill"
        case "done": "checkmark"
        case "idle": "moon.fill"
        default: nil
        }
    }

    static func color(for state: String?) -> Color {
        switch state {
        case "working": .blue
        case "blocked": .needsYouMark
        case "error": .red
        case "done": .green
        case "idle": .gray
        case "finished": .gray.opacity(0.4)
        default: .secondary.opacity(0.5)
        }
    }
}

/// The status's name and how many, on one line: what asks for you stands out, without a dot.
struct AgentGroupHeader: View {
    let group: AgentOverviewGroup

    private var emphasized: Bool { group.state == .needsYou || group.state == .error }

    var body: some View {
        HStack(spacing: 6) {
            Text(group.state.title).sidebarSectionTitle(emphasized: emphasized)
            SidebarCount(count: group.rows.count, emphasized: group.state == .needsYou)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("section-\(group.state.rawValue)")
    }
}

extension AgentState {
    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .error: "Error"
        case .done: "Done"
        case .working: "Working"
        case .idle: "Idle"
        }
    }

    /// What its mark means, when tapped.
    var explanation: String {
        switch self {
        case .needsYou: "Needs you: waiting for your answer."
        case .error: "Error: stopped on a problem."
        case .done: "Done: finished, and nobody has looked yet."
        case .working: "Working on it."
        case .idle: "Idle: nothing new since you looked."
        }
    }

    /// herdr's word for the color.
    var statusWord: String {
        switch self {
        case .needsYou: "blocked"
        case .error: "error"
        case .done: "done"
        case .working: "working"
        case .idle: "idle"
        }
    }
}
