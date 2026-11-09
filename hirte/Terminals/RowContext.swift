import HerdrKit
import SwiftUI

/// What a row says under its title, as one sentence: where it works, then who runs it. Each fact
/// has its place in it, and none is said twice.
struct RowContext: Equatable {
    /// A space with another name than its project: first in the sentence.
    var space: String?
    /// With the project switched off, the folder takes its place, whole: `~/projects/` before it.
    var folder: String?
    var project: String?
    var branch: String?
    var who: [String] = []
    /// A folder that isn't the project's: a worktree, say. It gets a line of its own.
    var elsewhere: String?
    /// Every fact, also what the sentence leaves out because the icon says it or space is short.
    var label = ""

    var isEmpty: Bool { project == nil && branch == nil && who.isEmpty }

    /// The sentence in plain text, without what has its own line.
    var sentence: String {
        let place = [folderAndProject, branch].compactMap { $0 }.joined(separator: " ")
        return ([space].compactMap { $0 } + [place].filter { !$0.isEmpty } + who).joined(separator: Terminal.detailSeparator)
    }

    private var folderAndProject: String? { project.map { (folder ?? "") + $0 } }

    private static func unique(_ values: [String?]) -> [String] {
        var seen: [String] = []
        for case let value? in values where !seen.contains(value) { seen.append(value) }
        return seen
    }

    /// `~/projects/shop-api` as `~/projects/` and `shop-api`.
    private static func split(_ path: String) -> (folder: String?, leaf: String) {
        guard let slash = path.lastIndex(of: "/"), path.index(after: slash) != path.endIndex else { return (nil, path) }
        return (String(path[...slash]), String(path[path.index(after: slash)...]))
    }

    /// A row of the Agents view: only enabled fields, and nothing the parent right above already
    /// says. The provider's name is left to its icon, where there's one.
    static func agent(
        terminal: Terminal, state: AgentOverviewState, context: TerminalContext, fields: Set<AgentOverviewField>,
        space: String?, parent: TerminalContext?, message: String?, showsProvider: Bool
    ) -> RowContext {
        func enabled(_ field: AgentOverviewField, _ value: String?) -> String? {
            guard fields.contains(field),
                  let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
            else { return nil }
            return trimmed
        }
        let place = unique([
            enabled(.space, space == parent?.project ? nil : space),
            enabled(.project, context.project == parent?.project ? nil : context.project),
        ])
        let directory = context.directory == parent?.directory
            ? nil : enabled(.directory, context.directory.map { Terminal.abbreviate($0) })
        let branch = enabled(.branch, context.branch == parent?.branch ? nil : context.branch)
        let name = enabled(.name, terminal.status?.title?.isEmpty == false ? terminal.nameInSpace : nil)
        let agent = enabled(.agent, context.agent)
        let account = enabled(.account, context.account)

        var row = RowContext(branch: branch)
        row.project = place.last
        row.space = place.count > 1 ? place.first : nil
        if let directory {
            let (folder, leaf) = split(directory)
            if place.isEmpty {
                row.folder = folder
                row.project = leaf
            } else if place.last != leaf {
                row.elsewhere = directory
            }
            // Otherwise the project says it: each sentence starts with the project, and the
            // folder above it stays in the space's header, the info sheet and the label.
        }
        row.who = unique([name, showsProvider ? nil : agent, account])
        // The status remains readable even when every optional field is hidden.
        if row.isEmpty, row.elsewhere == nil, message == nil, parent == nil { row.who = [state.title] }
        row.label = unique(place + [branch, directory, name, agent, account]).joined(separator: ", ")
        if row.label.isEmpty { row.label = row.who.joined(separator: ", ") }
        return row
    }

    /// A row of the Terminals view, under its space: what the header says isn't repeated, nor what
    /// its parent right above says.
    static func terminal(_ terminal: Terminal, inSpace: Bool, sharedFolder: String?, parent: Terminal?) -> RowContext {
        let name = inSpace ? terminal.nameInSpace : terminal.displayName
        let context = TerminalContext(terminal: terminal)
        let inherited = parent.map { TerminalContext(terminal: $0) }
        var row = RowContext(branch: context.branch == inherited?.branch ? nil : context.branch)
        row.who = unique([
            terminal.headline(inSpace: inSpace) == name ? nil : name,
            terminal.foreground?.name == name ? nil : terminal.foreground?.name,
            context.account,
        ])
        if let directory = context.directory, directory != sharedFolder, directory != inherited?.directory {
            row.elsewhere = Terminal.abbreviate(directory)
        }
        row.label = unique([row.branch, row.elsewhere] + row.who.map(Optional.some)).joined(separator: ", ")
        return row
    }
}

/// The sentence on one line, as far as it goes: first the branch shortens in its middle, then who
/// runs it moves to a line of its own. A branch never wraps, and no line ends on a separator.
struct RowContextLine: View {
    let context: RowContext
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                wrapped
            } else {
                ViewThatFits(in: .horizontal) {
                    line(branchLimit: nil)
                    line(branchLimit: 112)
                    line(branchLimit: 84)
                    stacked
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(context.label)
        .accessibilityAddTraits(.isStaticText)
    }

    /// The shortest form on one line, for next to a child's title.
    static func inline(_ context: RowContext) -> some View {
        RowContextLine(context: context).line(branchLimit: nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(context.label)
            .accessibilityAddTraits(.isStaticText)
    }

    private var separator: Text { Text(Terminal.detailSeparator).sidebarDetail() }

    private var projectText: some View {
        Text("\(Text(context.folder ?? "").foregroundStyle(Color.rowSecondary))\(Text(context.project ?? "").fontWeight(.medium).foregroundStyle(Color.rowSecondary))")
            .font(.footnote)
            .lineLimit(1)
            // A folder keeps its end, which says which one it is.
            .truncationMode(context.folder == nil ? .tail : .head)
    }

    private var branchMark: Text {
        Text("\(Image(systemName: "arrow.triangle.branch"))").font(.caption2).foregroundStyle(Color.rowSecondary)
    }

    private func line(branchLimit: CGFloat?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let space = context.space {
                Text(space).sidebarDetail().fontWeight(.medium).lineLimit(1)
                separator
            }
            if context.project != nil { projectText }
            if let branch = context.branch {
                branchMark.padding(.leading, context.project != nil ? 6 : 0).padding(.trailing, 3)
                Text(branch).sidebarDetail().lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: branchLimit, alignment: .leading)
            }
            if !context.who.isEmpty {
                if context.project != nil || context.branch != nil { separator }
                Text(context.who.joined(separator: Terminal.detailSeparator)).sidebarDetail().lineLimit(1)
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
            if context.project != nil || context.branch != nil {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let space = context.space {
                        Text(space).sidebarDetail().fontWeight(.medium).lineLimit(1).layoutPriority(1)
                        separator.layoutPriority(1)
                    }
                    if context.project != nil {
                        // The project goes short last: the branch can shorten in its middle first.
                        projectText.layoutPriority(1)
                    }
                    if let branch = context.branch {
                        branchMark.padding(.leading, context.project != nil ? 6 : 0).padding(.trailing, 3)
                            .layoutPriority(1)
                        Text(branch).sidebarDetail().lineLimit(1).truncationMode(.middle)
                            .frame(minWidth: 56, alignment: .leading)
                    }
                }
            }
            if !context.who.isEmpty {
                Text(context.who.joined(separator: Terminal.detailSeparator)).sidebarDetail().lineLimit(1)
            }
        }
    }

    /// At accessibility sizes everything may wrap, at its separators where it can.
    private var wrapped: some View {
        VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
            if context.project != nil || context.branch != nil {
                Text("\(context.space.map { $0 + Terminal.detailSeparator } ?? "")\(context.folder ?? "")\(context.project ?? "") \(context.branch == nil ? Text("") : branchMark) \(context.branch ?? "")")
                    .sidebarDetail()
            }
            if !context.who.isEmpty {
                Text(context.who.joined(separator: Terminal.detailSeparator)).sidebarDetail()
            }
        }
    }
}

/// A row's first lines in both views: the title with what's at its end, and the sentence. A child
/// or a shell keeps it all on one line while it fits.
struct RowHead<Accessory: View>: View {
    let title: String
    var dimmed = false
    /// Waits for you: the weight says so even without color.
    var emphasized = false
    /// A child: a smaller title.
    var compact = false
    var inline = false
    let context: RowContext
    @ViewBuilder var accessory: Accessory
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.sidebarBesideDetail) private var besideDetail

    /// A question that waits for you isn't cut short, on any row.
    private var waitingLines: Int { 3 }

    private func titleText(limit: Int?) -> some View {
        Text(title)
            .font(compact ? .subheadline : .body)
            // Only what waits for you: selecting a row mustn't rewrap its title, or the list moves.
            .fontWeight(emphasized ? .semibold : .regular)
            .foregroundStyle(dimmed ? Color.rowSecondary : Color.rowPrimary)
            .lineLimit(limit)
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
                titleText(limit: nil)
                accessory
                if !context.isEmpty { RowContextLine(context: context) }
            }
            .alignmentGuide(.rowAnchor) { $0[.top] + SidebarMetrics.iconSize / 2 }
        } else if inline || compact {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        titleText(limit: 1)
                        if !context.isEmpty { RowContextLine.inline(context) }
                    }
                    VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
                        titleText(limit: emphasized ? waitingLines : 1)
                        if !context.isEmpty { RowContextLine(context: context) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
            .alignmentGuide(.rowAnchor) { $0[VerticalAlignment.center] }
        } else {
            VStack(alignment: .leading, spacing: SidebarMetrics.lineGap) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // Whole on a phone's width anyway, or else short; a narrow column has a second line.
                    titleText(limit: emphasized ? waitingLines : besideDetail ? 2 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    accessory
                }
                if !context.isEmpty { RowContextLine(context: context) }
            }
            .alignmentGuide(.rowAnchor) { $0[VerticalAlignment.center] }
        }
    }
}
