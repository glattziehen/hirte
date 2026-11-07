import HerdrKit
import SwiftUI
import UIKit

/// Embedded by the settings owner. Everything is off until the person opts in.
struct LiveActivitySettingsView: View {
    @Bindable private var follow = FollowController.shared

    var body: some View {
        Section {
            Toggle("Follow on Lock Screen (Beta)", isOn: $follow.enabled)
            if follow.enabled {
                Toggle("Show task title", isOn: $follow.showTitle)
                Text("Task titles may contain private information and can also appear on your other Apple devices.")
                    .font(.footnote).foregroundStyle(.secondary)
                if follow.selection != nil {
                    Button("Stop Following", role: .destructive) { follow.stop() }
                }
            }
            if !follow.isAvailable {
                Text("Live Activities are off for Hirte. They have their own switch in iOS Settings, separate from notifications.")
                if let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open iOS Settings", destination: settings)
                }
            }
        } header: {
            Text("Live Activity")
        } footer: {
            Text("Choose one working agent from its terminal. The activity refreshes while Hirte is open and connected. When you leave Hirte or lose the connection, it shows the last known state. Open Hirte to refresh. If the task changed while you were away, choose it again. The first time, iOS may ask on the Lock Screen whether to allow it.")
        }
    }
}

struct LiveActivityFollowMenu: View {
    let session: HostSession
    let terminal: HerdrKit.Terminal?
    @Binding var showingSettings: Bool
    @Bindable private var follow = FollowController.shared

    var body: some View {
        let following = follow.follows(hostID: session.host.id, address: terminal?.address ?? "")
        Menu("Lock Screen", systemImage: following ? "lock.rectangle.fill" : "lock.rectangle") {
            LiveActivityFollowActions(session: session, terminal: terminal, showingSettings: $showingSettings)
        }
        .accessibilityValue(following ? "Following" : "")
    }
}

/// What the Lock Screen offers for a terminal: for a menu of their own, or a section of another menu.
/// (As a submenu of one, a status update arriving while it's open could lose the tap that opens it.)
struct LiveActivityFollowActions: View {
    let session: HostSession
    let terminal: HerdrKit.Terminal?
    /// Held outside: inside a menu, this view's own sheet could not present.
    @Binding var showingSettings: Bool
    @Bindable private var follow = FollowController.shared

    var body: some View {
        if follow.follows(hostID: session.host.id, address: terminal?.address ?? "") {
            Button("Stop Following", role: .destructive) { follow.stop() }
        } else if let block = follow.followBlock(session: session, terminal: terminal) {
            // Offered but dimmed, with the reason: an absent row explains nothing.
            Button {} label: {
                Text("Follow on Lock Screen")
                Text(block)
            }
            .disabled(true)
        } else if let terminal {
            Button("Follow on Lock Screen") { follow.start(session: session, terminal: terminal) }
        }
        Button("Live Activity Settings…") { showingSettings = true }
    }
}

private struct LiveActivityFollowPresentation: ViewModifier {
    @Binding var showingSettings: Bool
    @Bindable private var follow = FollowController.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    Form { LiveActivitySettingsView() }
                        .navigationTitle("Live Activity")
                        .toolbar { Button("Done") { showingSettings = false } }
                }
            }
            .alert("Live Activity", isPresented: Binding(
                get: { follow.errorMessage != nil }, set: { if !$0 { follow.dismissError() } })) {
                    Button("OK") { follow.dismissError() }
            } message: { Text(follow.errorMessage ?? "") }
            // The activity shows on the Lock Screen, not here: without this, a tap looks like nothing.
            .overlay(alignment: .top) {
                if follow.unconfirmedStart != nil {
                    Label("Following on the Lock Screen", systemImage: "lock.rectangle.fill")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.top, 8)
                        .transition(.opacity)
                        .accessibilityIdentifier("live-activity-started")
                }
            }
            .animation(.default, value: follow.unconfirmedStart)
            .sensoryFeedback(.success, trigger: follow.unconfirmedStart) { _, new in new != nil }
            .task(id: follow.unconfirmedStart) {
                guard let started = follow.unconfirmedStart else { return }
                AccessibilityNotification.Announcement("Following on the Lock Screen").post()
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled, follow.unconfirmedStart == started { follow.startConfirmed() }
            }
    }
}

extension View {
    /// What `LiveActivityFollowMenu` opens.
    func liveActivityFollowPresentation(showingSettings: Binding<Bool>) -> some View {
        modifier(LiveActivityFollowPresentation(showingSettings: showingSettings))
    }
}
