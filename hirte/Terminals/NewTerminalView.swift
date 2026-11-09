import HerdrKit
import SwiftUI

/// Where a new terminal should go, e.g. "New Terminal Here" on a space.
struct NewTerminalContext: Identifiable {
    var space: HerdrAppLayout.Space?
    var folder: String?
    /// Another machine added on this core, to start the terminal there.
    var machine: String?
    var id: String { space?.id ?? machine.map { "machine:\($0)" } ?? "none" }
}

/// Starts a shell, a command or an agent template on the machine.
struct NewTerminalView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case shell, command, agent
        var id: Self { self }
        var title: String {
            switch self {
            case .shell: "Shell"
            case .command: "Command"
            case .agent: "Agent"
            }
        }
    }

    /// Where herdr-app shows the new terminal.
    enum Placement: Hashable {
        case newSpace
        case space(String)
        /// No `herdr.space` label: herdr-app never shows it (like `hc run --bg`).
        case hidden
    }

    let session: HostSession
    let context: NewTerminalContext
    /// Called with the new terminal's address.
    let onStarted: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind = Kind.shell
    @State private var command = ""
    @State private var templates: [TemplateInfo] = []
    /// Nil until `templates.list` answered; then why agents can't be started, if they can't.
    @State private var templateNote: String?
    @State private var template: String?
    @State private var task = ""
    @State private var folder = ""
    @State private var name = ""
    @State private var placement = Placement.newSpace
    @State private var machine: String?
    @State private var keep = true
    @State private var options = WorkerStartOptions()
    @State private var launch = TerminalLaunch()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            form
            .navigationTitle("New Terminal")
            .dismissesKeyboardOnTapOutside()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .alert("Could not start", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .task { await load() }
            .onChange(of: kind) { _, kind in
                // A shell is worth keeping; a one-off command or agent usually is not.
                keep = kind == .shell
            }
            .interactiveDismissDisabled(launch.isWaiting)
        }
    }

    private var form: some View {
        Form {
            if launch.phase != .editing { launchStatus }
            // Fixed once started: what was sent stays what's shown.
            Group {
                Section {
                    Picker("Start", selection: $kind) {
                        ForEach(availableKinds) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    if let templateNote { Text(templateNote) }
                }

                switch kind {
                case .shell:
                    EmptyView()
                case .command:
                    Section {
                        TextField("Command", text: $command, prompt: Text("npm run dev"), axis: .vertical)
                            .font(.body.monospaced())
                    } footer: {
                        Text("Runs through the machine's shell, so pipes and && work.")
                    }
                case .agent:
                    Section {
                        Picker("Template", selection: $template) {
                            ForEach(templates.filter { $0.error == nil }) { t in
                                Text(t.name).tag(Optional(t.name))
                            }
                        }
                        TextField("Task", text: $task, prompt: Text("Review src/x.rs. Read-only."), axis: .vertical)
                            .lineLimit(3...8)
                    } footer: {
                        if let selected = selectedTemplate {
                            Text("\(selected.description)\n\(selected.command)")
                        }
                    }
                    startOptions
                }

                Section {
                    TextField("Folder", text: $folder, prompt: Text(session.homeFolder ?? "home folder"))
                        .font(.body.monospaced())
                    TextField("Name", text: $name, prompt: Text("optional"))
                    if !session.machines.isEmpty {
                        Picker("Machine", selection: $machine) {
                            Text(session.coreName ?? "This machine").tag(String?.none)
                            ForEach(session.machines.filter { $0.state == "connected" }) { m in
                                Text(m.name).tag(Optional(m.name))
                            }
                        }
                    }
                } footer: {
                    if !name.isEmpty && !HerdrCore.isValidTerminalName(name) {
                        Text("Names use a–z, 0–9, - _ . (up to 32), start with a letter or digit, and can't look like an address such as t7.")
                            .foregroundStyle(.red)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                if machine == nil {
                    Section {
                        Picker("herdr-app", selection: $placement) {
                            Text("New space").tag(Placement.newSpace)
                            ForEach(session.layout?.spaces ?? []) { space in
                                Text("New tab in \(spaceTitle(space))").tag(Placement.space(space.id))
                            }
                            Text("Not in herdr-app").tag(Placement.hidden)
                        }
                    } footer: {
                        switch placement {
                        case .newSpace:
                            Text("herdr-app opens a new space for it, named after its folder.")
                        case .space:
                            Text("herdr-app adds it to that space as a new tab.")
                        case .hidden:
                            Text("Runs in the background: herdr-app does not show it (like `hc run --bg`). You can add it later.")
                        }
                    }
                }

                Section {
                    Toggle("Keep", isOn: $keep)
                } footer: {
                    Text("If its program is lost (a crash or reboot), start a fresh shell in its folder. The command itself is never run again.")
                }
            }
            .disabled(launch.phase != .editing)
        }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            switch launch.phase {
            case .editing: Button("Cancel") { dismiss() }
            case .starting: Button("Stop Waiting") { launch.stopWaiting() }
            case .notSent, .stoppedWaiting: Button("Close") { dismiss() }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            switch launch.phase {
            case .editing:
                Button("Start") { start() }
                    .disabled(!canStart)
            case .starting: ProgressView()
            case .notSent, .stoppedWaiting: EmptyView()
            }
        }
    }

    private func load() async {
        folder = context.folder ?? ""
        if let space = context.space { placement = .space(space.id) }
        if let machine = context.machine { self.machine = machine }
        do {
            templates = try await session.templates()
            if templates.isEmpty {
                templateNote = "No agent templates on this machine."
            } else if let broken = templates.first(where: { $0.error != nil }) {
                let usable = templates.contains { $0.error == nil }
                let detail = "\(broken.name) can't be used: \(broken.error ?? "")"
                templateNote = usable ? detail : "No template can be used. " + detail
            }
        } catch {
            templateNote = "Agent templates couldn't be listed: \(error.localizedDescription)"
        }
        template = templates.first { $0.error == nil }?.name
    }

    private var selectedTemplate: TemplateInfo? { templates.first { $0.name == template } }

    private var optionsRequired: Bool { selectedTemplate.map(WorkerStartOptions.isRequired(by:)) ?? false }

    /// See `WorkerStartOptions`: typed by the person, checked again on the machine.
    @ViewBuilder private var startOptions: some View {
        Section {
            // Labeled: a form text field shows only its prompt, and these need their names.
            LabeledContent("Runtime") {
                TextField("Runtime", text: $options.runtime, prompt: Text(optionsRequired ? "required" : "optional"))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("start-option-runtime")
            }
            LabeledContent("Model") {
                TextField("Model", text: $options.model, prompt: Text(optionsRequired ? "required" : "optional"))
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("start-option-model")
            }
            Picker("Reasoning", selection: $options.reasoning) {
                Text("Not set").tag(String?.none)
                ForEach(WorkerStartOptions.efforts, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .accessibilityIdentifier("start-option-reasoning")
        } header: {
            Text("Start options")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if optionsRequired {
                    Text("This template needs all three. Type the runtime and model you want; there's no list to pick from here. The machine checks them again and may refuse.")
                } else {
                    Text("Only for templates that ask for them; leave empty otherwise.")
                }
                if let problem = options.problem(required: optionsRequired) {
                    Text(Self.describe(problem)).foregroundStyle(.red)
                }
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    static func describe(_ problem: WorkerStartOptions.Problem) -> String {
        switch problem {
        case .incomplete: "Set runtime, model and reasoning, all three."
        case .invalidRuntime: "Runtimes use letters, digits, - and _."
        case .invalidModel: "Models use letters, digits and . _ : + -"
        case .invalidReasoning: "Pick a reasoning level."
        }
    }

    @ViewBuilder private var launchStatus: some View {
        Section {
            switch launch.phase {
            case .editing:
                EmptyView()
            case .starting(let since):
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(since))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(kind == .agent ? "Starting, then sending the first message…" : "Starting…")
                        }
                        if seconds >= 10 {
                            Text("Still waiting (\(seconds) s): a template waits until its agent is ready. Stop Waiting only stops waiting here; the terminal keeps starting on the machine.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .notSent(let address, let reason):
                Label("\(address) started, but its first message didn't go in.", systemImage: "exclamationmark.triangle")
                if let reason, !reason.isEmpty { Text(reason).foregroundStyle(.secondary) }
                Button("Open \(address)") {
                    dismiss()
                    onStarted(address)
                }
            case .stoppedWaiting:
                Label("Stopped waiting.", systemImage: "hourglass")
                Text("Nothing was stopped on the machine. If the terminal starts, it shows in the list.")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if case .notSent = launch.phase {
                Text("Nothing was sent again. Open it to see what its program shows.")
            }
        }
        .accessibilityIdentifier("new-terminal-status")
    }

    private var availableKinds: [Kind] {
        templates.contains { $0.error == nil } ? Kind.allCases : [.shell, .command]
    }

    private var canStart: Bool {
        guard launch.phase == .editing, name.isEmpty || HerdrCore.isValidTerminalName(name) else { return false }
        switch kind {
        case .shell: return true
        case .command: return !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .agent: return template != nil && options.problem(required: optionsRequired) == nil
        }
    }

    private func spaceTitle(_ space: HerdrAppLayout.Space) -> String {
        space.name.isEmpty ? (space.folder.split(separator: "/").last.map(String.init) ?? space.id) : space.name
    }

    private func start() {
        guard canStart, let request = Self.request(
            kind: kind, command: command, template: template, task: task, options: options,
            folder: folder, name: name, placement: placement, machine: machine, keep: keep,
            homeFolder: session.homeFolder)
        else { return }
        launch.start(run: { [session] in try await session.run(request) }) { address in
            dismiss()
            onStarted(address)
        } failed: { message in
            error = message
        }
    }

    /// What Start sends. The labels herdr reads (`herdr.seen`, `herdr.space`) are set last, so
    /// start options can never replace them.
    static func request(
        kind: Kind, command: String, template: String?, task: String, options: WorkerStartOptions,
        folder: String, name: String, placement: Placement, machine: String?, keep: Bool, homeFolder: String?
    ) -> RunRequest? {
        var request = RunRequest(keep: keep, on: machine)
        var labels: [String: String] = [:]
        switch kind {
        case .shell: break
        case .command: request.line = command
        case .agent:
            guard let template else { return nil }
            let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
            request.argv = task.isEmpty ? [template] : [template, task]
            labels = options.labels
        }
        let folder = folder.trimmingCharacters(in: .whitespaces)
        request.cwd = folder.isEmpty ? (machine == nil ? homeFolder : nil) : folder
        request.name = name.isEmpty ? nil : name
        // Nothing has finished yet: it starts read (herdr's shared `herdr.seen`).
        labels[Terminal.seenLabel] = "0"
        if machine == nil {
            switch placement {
            case .newSpace: labels[HerdrAppLayout.spaceLabel] = HerdrAppLayout.newSpaceID()
            case .space(let id): labels[HerdrAppLayout.spaceLabel] = id
            case .hidden: break
            }
        }
        request.labels = labels
        return request
    }
}

/// One Start of the New Terminal sheet: progress, the first-message outcome, and waiting that
/// can be stopped here. Stopping cancels nothing on the machine and sends nothing (herdr-core
/// has no request for that); a reply that comes later is dropped, never opened or retried.
/// The call stays suspended in `HerdrClient` until that reply or until the connection closes
/// (which fails every pending call): at most one per Start, and Start is one-shot per sheet.
@MainActor @Observable
final class TerminalLaunch {
    enum Phase: Equatable {
        case editing
        case starting(since: Date)
        /// The terminal exists, but its template's first message did not go in.
        case notSent(address: String, reason: String?)
        case stoppedWaiting
    }

    private(set) var phase = Phase.editing
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Held here, not by the waiting task, and dropped on Stop Waiting: a call that never gets
    /// a reply keeps only `run` and a weak reference, never the sheet's state.
    @ObservationIgnored private var started: (@MainActor (String) -> Void)?
    @ObservationIgnored private var failed: (@MainActor (String) -> Void)?

    var isWaiting: Bool {
        if case .starting = phase { true } else { false }
    }

    func start(
        run: @escaping @MainActor () async throws -> Terminal,
        started: @escaping @MainActor (String) -> Void,
        failed: @escaping @MainActor (String) -> Void
    ) {
        guard phase == .editing else { return }
        phase = .starting(since: .now)
        self.started = started
        self.failed = failed
        task = Task { [weak self, run] in
            let result: Result<Terminal, Error>
            do { result = .success(try await run()) } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            self?.finish(result)
        }
    }

    private func finish(_ result: Result<Terminal, Error>) {
        guard case .starting = phase else { return }
        let (started, failed) = (self.started, self.failed)
        task = nil
        self.started = nil
        self.failed = nil
        switch result {
        case .success(let terminal):
            if let first = terminal.firstMessage, !first.sent {
                phase = .notSent(address: terminal.address, reason: first.reason)
            } else {
                // Sent (`started` false may only mean queued), or a core that doesn't say.
                phase = .editing
                started?(terminal.address)
            }
        case .failure(let error):
            phase = .editing
            failed?(error.localizedDescription)
        }
    }

    func stopWaiting() {
        guard case .starting = phase else { return }
        task?.cancel()
        task = nil
        started = nil
        failed = nil
        phase = .stoppedWaiting
    }
}
