import HerdrKit
import SwiftUI

/// The sidebar's measures, one for each role, shared by both views. Rows are composed on three
/// edges: the icon, the text and the end of the row; children step in from there.
enum SidebarMetrics {
    static let iconSize: CGFloat = 32
    static let iconRadius: CGFloat = 8
    static let childIconSize: CGFloat = 24
    static let childIconRadius: CGFloat = 6
    /// Between the icon, the text and what's at the end of a row.
    static let columnGap: CGFloat = 12
    static let childColumnGap: CGFloat = 8
    static let lineGap: CGFloat = 2
    /// Above and below a row's text: two lines come to about 60 points.
    static let rowInset: CGFloat = 9
    static let childRowInset: CGFloat = 6
    /// A section's header, in both views: its plus keeps a full target and both keep one rhythm.
    static let headerHeight: CGFloat = 44
    static let sectionSpacing: CGFloat = 8
    static let touchTarget: CGFloat = 44
    /// Between the edge the rows scroll under and the controls floating below it.
    static let barTopGap: CGFloat = 12
    /// The time's place on a title's line, and how far its target reaches past the text's edge.
    static let timeColumn: CGFloat = 32
    static let timeOverflow: CGFloat = 12
    /// The children's count and chevron on that line, at least, with the gap to the time.
    static let familyColumn: CGFloat = 26
    static let familyGap: CGFloat = 6
    /// A selected row's corners, whatever its height, tab, depth or appearance.
    static let selectionRadius: CGFloat = 12
    /// A selected row's distance from the edges of its column, next to the detail.
    static let selectionMargin: CGFloat = 8
    /// From a selected row's edge to its content there: icons start 20 points into the column.
    static let selectionPadding: CGFloat = 12
    /// How far the status mark reaches past the icon's corner.
    static let statusMarkOverhang: CGFloat = 3
    /// The gap the mark cuts out around itself, through which the row shows.
    static let statusMarkGap: CGFloat = 2
    /// How much further a child's text sits than its parent's.
    static let familyStep: CGFloat = 16
    static let maxFamilyDepth = 3
    /// How far a family's line reaches past its row, over the list's own margins, to meet the next.
    static let railOverreach: CGFloat = 16
}

/// Selected rows have this shape, and only they: controls keep their capsules and cards their own.
struct SidebarSelectionShape: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius, style: .continuous).path(in: rect)
    }
}

/// Behind a row next to the detail: replaces the system's fill, whose corners follow the row's
/// height. The list's selection (keyboard, focus, state) stays; only its drawing changes.
struct SidebarRowBackground: View {
    let selected: Bool

    var body: some View {
        if selected {
            SidebarSelectionShape().fill(Color.sidebarSelection)
        } else {
            Color.clear
        }
    }
}

extension EnvironmentValues {
    /// The list is a column next to the detail: a row's title may take a second line.
    @Entry var sidebarBesideDetail = false
}

extension Color {
    /// A terminal waits for you, as text: the time it has waited, a count.
    static let needsYou = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xe9 / 255, green: 0xa2 / 255, blue: 0x6b / 255, alpha: 1)
            : UIColor(red: 0xa8 / 255, green: 0x54 / 255, blue: 0x00 / 255, alpha: 1)
    })
    /// A terminal waits for you, as a mark: small, and never the fill of a surface.
    static let needsYouMark = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xff / 255, green: 0x9f / 255, blue: 0x0a / 255, alpha: 1)
            : UIColor(red: 0xd9 / 255, green: 0x6a / 255, blue: 0x00 / 255, alpha: 1)
    })
    /// Behind the sidebar next to the detail column: app chrome, whatever the terminal's theme.
    static let sidebarBackground = Color(uiColor: .secondarySystemBackground)
    /// The fill of a selected sidebar row. Rows set their text colors below themselves, so that
    /// the system's white labels for a selected row don't have to work on every fill.
    static let sidebarSelection = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x4a / 255, green: 0x4f / 255, blue: 0x55 / 255, alpha: 1)
            : UIColor(red: 0xc9 / 255, green: 0xcd / 255, blue: 0xd2 / 255, alpha: 1)
    })
    /// The app's accent where a surrounding tint means something else, or for a primary action.
    /// By name: `Color.accentColor` follows the surrounding tint.
    static let appControl = Color("AccentColor")
    /// Text in a sidebar row, the same selected or not.
    static let rowPrimary = Color(uiColor: .label)
    static let rowSecondary = Color(uiColor: UIColor.label.withAlphaComponent(0.65))
    /// Behind icons.
    static let rowFill = Color(uiColor: UIColor.label.withAlphaComponent(0.1))
    /// A family's rail. Opaque, so that lines meeting don't add up.
    static let rowRule = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x7a / 255, green: 0x7e / 255, blue: 0x84 / 255, alpha: 1)
            : UIColor(red: 0x8f / 255, green: 0x92 / 255, blue: 0x97 / 255, alpha: 1)
    })
}

extension Text {
    /// A status or space name: quiet structure above the rows. What asks for you stands out.
    func sidebarSectionTitle(emphasized: Bool = false) -> Text {
        font(.subheadline.weight(.semibold)).foregroundStyle(emphasized ? Color.rowPrimary : Color.rowSecondary)
    }

    /// Facts under a row's title, and anything of the same weight next to it.
    func sidebarDetail() -> Text {
        font(.footnote).foregroundStyle(Color.rowSecondary)
    }
}

/// How many rows a section has, right after its name.
struct SidebarCount: View {
    let count: Int
    var emphasized = false

    var body: some View {
        Text("\(count)")
            .font(.footnote.monospacedDigit())
            .foregroundStyle(emphasized ? Color.needsYou : Color.rowSecondary)
    }
}

/// How many terminals wait for you: the hand and a number, the form says it as well as the color.
struct NeedsYouBadge: View {
    let count: Int

    static func text(_ count: Int) -> String { "\(count) \(count == 1 ? "needs" : "need") you" }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(Color.needsYouMark)
            Text("\(count)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.needsYou)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.text(count))
    }
}

/// The one place a row says its state: a mark at the corner of its icon, sized by its rank: routine
/// states small, an error larger, the hand the largest. Waiting for you and not known yet (an open
/// ring) read without color too.
struct StatusMark: View {
    /// herdr's word for it; nil when it hasn't reported a recognized one.
    let state: String?
    var label: String?
    /// On a child's smaller icon.
    var compact = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    /// As the agents view shows it: done only while unread.
    init(agent: AgentState) {
        state = agent.statusWord
        label = agent.title
    }

    init(state: String?, label: String?) {
        self.state = state
        self.label = label
    }

    func compact(_ compact: Bool) -> StatusMark {
        var mark = self
        mark.compact = compact
        return mark
    }

    var diameter: CGFloat {
        switch state {
        case "blocked": compact ? 12 : 15
        case "error": compact ? 10 : 12
        default: compact ? 8 : 10
        }
    }

    var body: some View {
        Group {
            if state == "blocked" {
                Image(systemName: "hand.raised.fill")
                    .resizable().scaledToFit()
                    .foregroundStyle(Color.needsYouMark)
            } else if withoutColor, let symbol = StatusDot.symbol(for: state) {
                Image(systemName: symbol)
                    .resizable().scaledToFit()
                    .fontWeight(.bold)
                    .foregroundStyle(StatusDot.color(for: state))
            } else if state == nil {
                Circle().strokeBorder(Color.rowSecondary, lineWidth: 1.5)
            } else {
                Circle().fill(StatusDot.color(for: state))
            }
        }
        .frame(width: diameter, height: diameter)
        // On its own when the icon is switched off; on an icon, the icon says it together with who.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "No status")
    }
}

/// Where a row sits in its family: which lines pass through it, so that a parent and its children
/// read as one thing while each stays its own row.
struct FamilyRails: Equatable {
    var depth = 0
    /// The levels, from 1, whose line goes on below this row to a later sibling.
    var continuing: Set<Int> = []
    /// Its children come right after it.
    var opensDown = false

    var inFamily: Bool { depth > 0 || opensDown }
    /// The list's lines between the members of a family, not those around it.
    var hiddenSeparators: VerticalEdge.Set {
        var edges: VerticalEdge.Set = []
        if depth > 0 { edges.insert(.top) }
        if opensDown || !continuing.isEmpty { edges.insert(.bottom) }
        return edges
    }
    /// Where a row's icon starts: its text is then a family step further than its parent's.
    var indent: CGFloat { Self.indent(depth) }
    var iconSize: CGFloat { depth > 0 ? SidebarMetrics.childIconSize : SidebarMetrics.iconSize }
    var columnGap: CGFloat { depth > 0 ? SidebarMetrics.childColumnGap : SidebarMetrics.columnGap }
    var rowInset: CGFloat { depth > 0 ? SidebarMetrics.childRowInset : SidebarMetrics.rowInset }

    static func indent(_ depth: Int) -> CGFloat {
        guard depth > 0 else { return 0 }
        let parentText = SidebarMetrics.iconSize + SidebarMetrics.columnGap
        return parentText + CGFloat(depth) * SidebarMetrics.familyStep
            - SidebarMetrics.childIconSize - SidebarMetrics.childColumnGap
    }

    /// A level's line runs under the middle of the icon of the row it starts from.
    static func railX(_ level: Int) -> CGFloat {
        level > 1 ? indent(level - 1) + SidebarMetrics.childIconSize / 2 : SidebarMetrics.iconSize / 2
    }

    /// For rows in display order, from how deep each one is.
    static func layout(depths: [Int]) -> [FamilyRails] {
        let depths = depths.map { min($0, SidebarMetrics.maxFamilyDepth) }
        return depths.indices.map { index in
            let depth = depths[index]
            let after = depths[(index + 1)...]
            let continuing = depth < 1 ? [] : (1...depth).filter { level in
                // The next row no deeper than this level: its sibling, or the end of the branch.
                after.first { $0 <= level } == level
            }
            return FamilyRails(depth: depth, continuing: Set(continuing), opensDown: (after.first ?? 0) > depth)
        }
    }
}

extension VerticalAlignment {
    private struct RowAnchor: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    /// The icon's middle: the middle of a row's first two lines, whatever follows them.
    static let rowAnchor = VerticalAlignment(RowAnchor.self)
}

private struct IconBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// One row's layout in both of the sidebar's views: icon, text, and what's at its end.
struct SidebarRow<Icon: View, Content: View, Trailing: View>: View {
    var rails = FamilyRails()
    /// Off in the settings: then the separator starts where the text does.
    var hasIconColumn = true
    @ViewBuilder var icon: Icon
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .rowAnchor, spacing: rails.columnGap) {
            icon
                .anchorPreference(key: IconBounds.self, value: .bounds) { $0 }
                .overlay {
                    if rails.depth > 0 {
                        Color.clear.accessibilityElement().accessibilityLabel("Started by its parent")
                    }
                }
            content.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.leading, rails.indent)
        .backgroundPreferenceValue(IconBounds.self) { anchor in
            if rails.inFamily, let anchor {
                GeometryReader { proxy in FamilyRailsView(rails: rails, icon: proxy[anchor]) }
            }
        }
        // At the text of the family's parent, for a row inside a family as well.
        .alignmentGuide(.listRowSeparatorLeading) { _ in
            hasIconColumn ? SidebarMetrics.iconSize + SidebarMetrics.columnGap : 0
        }
    }
}

private struct FamilyRailsView: View {
    let rails: FamilyRails
    /// In the row's coordinates.
    let icon: CGRect

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let reach = SidebarMetrics.railOverreach
            for level in rails.continuing {
                path.move(to: CGPoint(x: FamilyRails.railX(level), y: 0))
                path.addLine(to: CGPoint(x: FamilyRails.railX(level), y: size.height))
            }
            if rails.depth > 0 {
                let x = FamilyRails.railX(rails.depth)
                let middle = icon.midY + reach
                let corner: CGFloat = 6
                if rails.continuing.contains(rails.depth) {
                    path.move(to: CGPoint(x: x, y: middle))
                } else {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: middle - corner))
                    path.addQuadCurve(to: CGPoint(x: x + corner, y: middle), control: CGPoint(x: x, y: middle))
                }
                path.addLine(to: CGPoint(x: icon.minX - 3, y: middle))
            }
            if rails.opensDown {
                path.move(to: CGPoint(x: icon.midX, y: icon.maxY + reach + 3))
                path.addLine(to: CGPoint(x: icon.midX, y: size.height))
            }
            context.stroke(path, with: .color(.rowRule), lineWidth: 1.5)
        }
        // The list keeps margins between rows that a row can't remove; the lines have to cross them.
        .padding(.vertical, -SidebarMetrics.railOverreach)
        // Hidden, or the row counts as reaching over its neighbours, for VoiceOver and hit tests.
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
