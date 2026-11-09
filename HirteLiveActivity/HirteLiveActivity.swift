import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HirteActivityBundle: WidgetBundle {
    var body: some Widget { AgentLiveActivity() }
}

struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            ActivitySummary(state: context.state, stale: context.isStale)
                .padding(14)
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.headline ?? "Hirte · Agent").font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label(context.state.phase.label, systemImage: context.state.phase.symbol)
                        .foregroundStyle(phaseColor(context.state, stale: context.isStale))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityDetails(state: context.state, stale: context.isStale)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbol)
                    .foregroundStyle(phaseColor(context.state, stale: context.isStale))
            } compactTrailing: {
                if context.isStale || context.state.isLastKnown {
                    Image(systemName: "clock.badge.exclamationmark")
                } else if let progress = context.state.progress {
                    Text("\(progress)%").monospacedDigit()
                } else {
                    Image(systemName: context.state.phase.symbol)
                }
            } minimal: {
                Image(systemName: context.isStale || context.state.isLastKnown ? "clock" : context.state.phase.symbol)
                    .foregroundStyle(phaseColor(context.state, stale: context.isStale))
            }
            .widgetURL(context.attributes.url)
        }
    }
}

private func phaseColor(_ state: AgentActivityAttributes.ContentState, stale: Bool) -> Color {
    if stale || state.isLastKnown { return .secondary }
    switch state.phase {
    case .working: return .blue
    case .needsYou: return Color(red: 0.95, green: 0.70, blue: 0.24)
    case .done: return .green
    case .error: return .red
    case .ended: return .secondary
    }
}

struct ActivitySummary: View {
    let state: AgentActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.headline ?? "Hirte · Agent").font(.headline).lineLimit(1)
                Spacer()
                Label(state.phase.label, systemImage: state.phase.symbol)
                    .foregroundStyle(phaseColor(state, stale: stale))
            }
            ActivityDetails(state: state, stale: stale)
        }
    }
}

private struct ActivityDetails: View {
    let state: AgentActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = state.progress {
                HStack {
                    ProgressView(value: Double(progress), total: 100).tint(phaseColor(state, stale: stale))
                    Text("\(progress)%").monospacedDigit()
                }
            }
            if stale || state.isLastKnown {
                HStack(spacing: 4) {
                    Text("As of")
                    Text(state.asOf, style: .time)
                    Text("· Open Hirte to refresh")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else if state.phase == .needsYou {
                Text("Waiting for your answer in Hirte").font(.caption)
            } else {
                HStack(spacing: 4) {
                    Text("Since")
                    Text(state.since, style: .time)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
