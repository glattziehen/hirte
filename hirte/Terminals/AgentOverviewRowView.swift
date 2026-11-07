import HerdrKit
import SwiftUI

struct AgentOverviewRowView: View {
    let terminal: Terminal
    let state: AgentOverviewState
    let context: TerminalContext
    let preferences: AgentOverviewPreferences
    var space: String?
    var rails = FamilyRails()
    /// The agent it's shown under: what that row already says isn't repeated, except who runs it.
    var parent: TerminalContext?
    var reason: Terminal?
    var familyState: AgentOverviewState?
    var childCount = 0
    var expanded: Binding<Bool>?
    /// What's most urgent among the children folded away, when that's more than this row says.
    var foldedState: AgentOverviewState?
    @State private var explaining = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var timeBaseline: CGFloat = 4.5

    private var fields: Set<AgentOverviewField> { preferences.fields }
    private var mark: StatusMark { StatusMark(state: state.statusWord, label: state.title) }
    private var rowContext: RowContext {
        .agent(terminal: terminal, state: state, context: context, fields: fields, space: space, parent: parent,
               message: message,
               showsProvider: fields.contains(.icon) && AgentProviderIcon.hasAsset(terminal))
    }

    var body: some View {
        let row = rowContext
        SidebarRow(rails: rails, hasIconColumn: fields.contains(.icon) || rails.inFamily) {
            if fields.contains(.icon) {
                AgentProviderIcon(terminal: terminal, size: rails.iconSize, mark: mark)
            } else {
                // Without an icon the mark stays; the family's line needs its column.
                mark.compact(rails.depth > 0)
                    .frame(width: rails.inFamily ? rails.iconSize : mark.diameter)
            }
        } content: {
            VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
                RowHead(title: terminal.headline(inSpace: true), emphasized: state == .needsYou,
                        compact: rails.depth > 0, context: row) {
                    if large {
                        time
                    } else {
                        // Times keep one edge across rows; the context's line keeps its full width.
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            familyControl
                            time
                        }
                    }
                }
                if let message { detail(message) }
                if let elsewhere = row.elsewhere { detail(elsewhere).truncationMode(.head) }
                if let reason {
                    detail("Family: \(AgentOverview.title(reason)) — \((familyState ?? AgentOverviewState(terminal: reason)).title)")
                }
                if large {
                    progress
                    familyControl
                }
            }
            // Under the text, in the row's margin: reported progress doesn't make a row taller.
            .overlay(alignment: .bottom) {
                if !large { progress.offset(y: rails.rowInset - 3) }
            }
        } trailing: {
            EmptyView()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(terminal.address)
    }

    /// At accessibility sizes a column at the row's end would take the text's width: what's there
    /// moves under the title.
    private var large: Bool { typeSize.isAccessibilitySize }

    private func detail(_ text: String) -> some View {
        Text(text).sidebarDetail().lineLimit(large ? nil : 1)
    }

    /// How long it has been like this, which explains itself when tapped. In the row's line as
    /// wide as it needs, as a target past it.
    @ViewBuilder private var time: some View {
        if fields.contains(.time), let since = terminal.statusSince {
            Button { explaining = true } label: {
                TimelineView(.periodic(from: .now, by: 30)) { date in
                    Text(Terminal.shortAge(since, now: date.date))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(state == .needsYou ? Color.needsYou : Color.rowSecondary)
                }
                .frame(minWidth: large ? nil : SidebarMetrics.timeColumn, alignment: large ? .leading : .trailing)
                .padding(.trailing, large ? 0 : SidebarMetrics.timeOverflow)
                .frame(minWidth: SidebarMetrics.touchTarget, minHeight: SidebarMetrics.touchTarget,
                       alignment: large ? .leading : .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            // Only the text takes room on the line; the full target reaches past it.
            .padding(.trailing, large ? 0 : -SidebarMetrics.timeOverflow)
            .padding(.vertical, large ? 0 : -(SidebarMetrics.touchTarget - 20) / 2)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + timeBaseline }
            .accessibilityLabel(state.title)
            .accessibilityValue(Terminal.shortAge(since))
            .popover(isPresented: $explaining) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.explanation)
                    Text("Since \(since.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                }
                .font(.callout).padding().presentationCompactAdaptation(.popover)
            }
        }
    }

    @ViewBuilder private var progress: some View {
        if fields.contains(.progress), let progress = terminal.status?.progress, state == .working {
            ProgressView(value: Double(min(max(progress, 0), 100)), total: 100)
                .progressViewStyle(RowProgressStyle())
                .accessibilityLabel("Progress")
                .accessibilityValue(terminal.status?.msg ?? "\(min(max(progress, 0), 100)) percent")
        }
    }

    /// How many children, and whether they show, on the title's line next to the time: under it, on
    /// the context's line, two full targets without overlap would take a row of 88 points.
    @ViewBuilder private var familyControl: some View {
        if let expanded, childCount > 0 {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 3) {
                    if let foldedState {
                        Circle()
                            .fill(foldedState == .needsYou ? Color.needsYouMark : StatusDot.color(for: foldedState.statusWord))
                            .frame(width: 6, height: 6)
                    }
                    Text("\(childCount)").font(.footnote.monospacedDigit())
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        // Room for the wider of the two chevrons, whatever the text size.
                        .frame(minWidth: 10)
                }
                .fixedSize()
                .foregroundStyle(Color.rowSecondary)
                .frame(minWidth: large ? nil : SidebarMetrics.familyColumn, alignment: large ? .leading : .trailing)
                .padding(.trailing, large ? 0 : SidebarMetrics.familyGap)
                .padding(.leading, large ? 0 : familyReach)
                .frame(minWidth: SidebarMetrics.touchTarget, minHeight: SidebarMetrics.touchTarget,
                       alignment: large ? .leading : .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            // Ends where the time's target starts; reaches over the title's end, not onto the time.
            .padding(.leading, large ? 0 : -familyReach)
            .padding(.vertical, large ? 0 : -(SidebarMetrics.touchTarget - 20) / 2)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + timeBaseline }
            .accessibilityLabel("\(expanded.wrappedValue ? "Collapse" : "Expand") children of \(AgentOverview.title(terminal))")
            .accessibilityValue(childCount == 1 ? "1 child" : "\(childCount) children")
            .accessibilityIdentifier("children-\(terminal.address)")
        }
    }

    /// What the family's target needs beyond its column to be a full one.
    private var familyReach: CGFloat {
        SidebarMetrics.touchTarget - SidebarMetrics.familyColumn - SidebarMetrics.familyGap
    }

    private var message: String? {
        guard fields.contains(.message),
              let text = terminal.status?.msg?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }
}

/// A row's reported progress: a thin line from the text's edge to the row's end.
struct RowProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.rowFill)
                Capsule().fill(Color.blue)
                    .frame(width: proxy.size.width * (configuration.fractionCompleted ?? 0))
            }
        }
        .frame(height: 2)
    }
}

/// Only bundled original assets are used; anything else gets a neutral system symbol. All of them
/// share one tile, so the list keeps a calm column whichever programs are running. The state sits
/// on its corner, with a gap cut out around it through which the row shows, selected or not.
struct AgentProviderIcon: View {
    let terminal: Terminal
    var neutralSymbol = "sparkles"
    var size = SidebarMetrics.iconSize
    var mark: StatusMark?

    private static func provider(_ terminal: Terminal) -> String {
        let raw = TerminalContext(terminal: terminal).agent ?? terminal.foreground?.name ?? terminal.argv.first ?? ""
        return URL(fileURLWithPath: raw).lastPathComponent.lowercased()
    }

    private static func asset(_ provider: String) -> String? {
        switch provider {
        case "claude", "claude-code": "AgentIcon-Claude"
        case "codex": "AgentIcon-Codex"
        case "grok": "AgentIcon-Grok"
        case "gemini": "AgentIcon-Gemini"
        default: nil
        }
    }

    /// Whether the icon says who it is, so that the row needn't.
    static func hasAsset(_ terminal: Terminal) -> Bool { asset(provider(terminal)) != nil }

    private var compact: Bool { size < SidebarMetrics.iconSize }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: compact ? SidebarMetrics.childIconRadius : SidebarMetrics.iconRadius,
                         style: .continuous)
    }

    private var tile: some View {
        let asset = Self.asset(Self.provider(terminal))
        return ZStack {
            shape.fill(Color.rowFill)
            if let asset, let image = UIImage(named: asset) {
                Image(uiImage: image)
                    // Without colors of their own they take the text's, to read in both appearances.
                    .renderingMode(["AgentIcon-Grok", "AgentIcon-Gemini"].contains(asset) ? .template : .original)
                    .resizable().scaledToFit().foregroundStyle(Color.rowPrimary)
                    // Codex's original is a tile itself; the others are marks to place on one.
                    .padding(asset == "AgentIcon-Codex" ? 0 : size / 6.5)
            } else {
                // A fixed size like the tile's: at large text it would outgrow it.
                Image(systemName: neutralSymbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(Color.rowPrimary)
            }
            shape.strokeBorder(Color.rowFill, lineWidth: 1)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }

    var body: some View {
        let provider = Self.provider(terminal)
        let isNeutral = Self.asset(provider) == nil
        Group {
            if let mark {
                let sized = mark.compact(compact)
                let diameter = sized.diameter
                let overhang = SidebarMetrics.statusMarkOverhang
                let gap = SidebarMetrics.statusMarkGap
                tile
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .frame(width: diameter + 2 * gap, height: diameter + 2 * gap)
                            .offset(x: overhang + gap, y: overhang + gap)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .overlay(alignment: .bottomTrailing) {
                        sized.offset(x: overhang, y: overhang)
                    }
            } else {
                tile
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isNeutral && neutralSymbol == "terminal" ? "Terminal" : provider.isEmpty ? "Agent" : provider)
        .accessibilityValue(mark?.label ?? "")
    }
}

extension AgentOverviewState {
    var title: String { AgentState(rawValue: rawValue)?.title ?? "Unknown" }
    var explanation: String {
        AgentState(rawValue: rawValue)?.explanation ?? "Unknown: this agent has not reported a recognized status."
    }
    var statusWord: String? { AgentState(rawValue: rawValue)?.statusWord }
}

extension AgentOverviewMode {
    var title: String { self == .individual ? "Individual" : "Nested" }
}

extension AgentOverviewSort {
    var title: String {
        switch self {
        case .lastStateChange: "Last state change"
        case .longestWaiting: "Longest waiting"
        case .title: "Title"
        }
    }
}

extension AgentOverviewField {
    var title: String {
        switch self {
        case .icon: "Agent icon"
        case .space: "Space"
        case .name: "Name"
        case .message: "Status message"
        case .time: "Time"
        case .progress: "Progress"
        case .branch: "Branch"
        case .project: "Project"
        case .directory: "Directory"
        case .agent: "Agent / provider"
        case .account: "Account"
        }
    }
}
