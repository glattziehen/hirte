import HerdrKit
import SwiftUI

struct AgentOverviewSettingsView: View {
    @AppStorage(AgentOverviewPreferences.storageKey) private var stored = ""

    private var preferences: AgentOverviewPreferences { .init(rawValue: stored) }

    var body: some View {
        Form {
            Section {
                if let terminal = Self.previewTerminal {
                    AgentOverviewRowView(
                        terminal: terminal, state: .working,
                        context: TerminalContext(terminal: terminal, project: "sample-project"),
                        preferences: preferences, space: "sample-project")
                }
            } header: {
                Text("Preview")
            } footer: {
                Text("Title and status are always shown. Each field keeps its place in the row; what doesn't fit shortens or moves to its own line.")
            }
            fieldSection("Where", fields: [.project, .directory, .branch, .space])
            fieldSection("Who", fields: [.icon, .agent, .account, .name],
                         footer: "With an agent icon, its name is left to the icon and to VoiceOver.")
            fieldSection("Activity", fields: [.message, .time, .progress],
                         footer: "Missing values are hidden. Branch and account appear when the host provides them.")
            Section {
                Picker("Agent view", selection: binding(\.mode)) {
                    ForEach(AgentOverviewMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Sort by", selection: binding(\.sort)) {
                    ForEach(AgentOverviewSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Button("Reset to Defaults") { stored = AgentOverviewPreferences().rawValue }
                .disabled(preferences == AgentOverviewPreferences())
        }
        .navigationTitle("Agent Overview")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func fieldSection(_ title: String, fields: [AgentOverviewField], footer: String? = nil) -> some View {
        Section {
            ForEach(fields, id: \.self) { field in
                Toggle(field.title, isOn: Binding(
                    get: { preferences.fields.contains(field) },
                    set: { enabled in
                        var updated = preferences
                        if enabled { updated.fields.insert(field) } else { updated.fields.remove(field) }
                        stored = updated.rawValue
                    }))
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentOverviewPreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: keyPath] }, set: { value in
            var updated = preferences
            updated[keyPath: keyPath] = value
            stored = updated.rawValue
        })
    }

    private static var previewTerminal: Terminal? {
        // A generic fixture uses the same row and context path as the live overview.
        let since = UInt64((Date.now.timeIntervalSince1970 - 12 * 60) * 1000)
        let json = #"{"address":"preview","argv":["agent"],"cwd":"/workspace/sample-project","state":"live","name":"agent","status":{"state":"working","app":"agent","title":"Improve the mobile overview","msg":"12 of 20 files","progress":60},"status_ms":\#(since),"labels":{"context.project":"sample-project","context.agent":"codex","context.account":"sample-account","context.branch":"feature/mobile","context.directory":"/workspace/sample-project","context.created_ms":"1"},"cols":80,"rows":24,"created_ms":1}"#
        return try? JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }
}
