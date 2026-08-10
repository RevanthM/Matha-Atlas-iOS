import DispatchCore
import SwiftUI

public struct DispatchCenterView: View {
    @StateObject private var store: DispatchClientStore

    public init(store: @autoclosure @escaping () -> DispatchClientStore = DispatchClientStore()) {
        _store = StateObject(wrappedValue: store())
    }

    public var body: some View {
        TabView {
            DispatchComposerView()
                .tabItem { Label("Dispatch", systemImage: "paperplane") }
            AgentView()
                .tabItem { Label("Agents", systemImage: "square.stack.3d.up") }
                .badge(store.activeTasks.count)
            RemoteControlView()
                .tabItem { Label("Remote", systemImage: "terminal") }
                .badge(store.pendingApprovals.count)
        }
        .environmentObject(store)
    }
}

private struct DispatchComposerView: View {
    @EnvironmentObject private var store: DispatchClientStore
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(connectionColor)
                            .frame(width: 8, height: 8)
                        Text(store.connectionState.label)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(store.hosts.filter(\.isOnline).count) hosts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Outcome") {
                    TextField("What should the agent team accomplish?", text: $prompt, axis: .vertical)
                        .lineLimit(4...10)
                    Button {
                        if store.submit(prompt: prompt) != nil { prompt = "" }
                    } label: {
                        Label("Dispatch task", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Recent missions") {
                    ForEach(store.rootTasks) { task in
                        NavigationLink {
                            TaskDetailView(taskID: task.id)
                        } label: {
                            TaskRow(task: task)
                        }
                    }
                }
            }
            .navigationTitle("Dispatch")
        }
    }

    private var connectionColor: Color {
        switch store.connectionState {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}

private struct AgentView: View {
    @EnvironmentObject private var store: DispatchClientStore

    var body: some View {
        NavigationStack {
            List {
                if store.activeTasks.isEmpty {
                    ContentUnavailableView(
                        "No active agents",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Start a mission from Dispatch.")
                    )
                }
                ForEach(store.activeTasks) { task in
                    NavigationLink {
                        TaskDetailView(taskID: task.id)
                    } label: {
                        HStack(spacing: 10) {
                            Color.clear.frame(width: CGFloat(task.depth * 12))
                            TaskRow(task: task)
                        }
                    }
                }
            }
            .navigationTitle("Agent view")
        }
    }
}

private struct RemoteControlView: View {
    @EnvironmentObject private var store: DispatchClientStore
    @State private var showPairing = false

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    HStack {
                        Label(store.connectionState.label, systemImage: "network")
                        Spacer()
                        Circle()
                            .fill(store.connectionState == .connected ? .green : .secondary)
                            .frame(width: 8, height: 8)
                    }
                    Button("Pair or configure desktop") { showPairing = true }
                }

                Section("Desktop hosts") {
                    ForEach(store.hosts) { host in
                        HStack {
                            Image(systemName: host.platform == "macOS" ? "desktopcomputer" : "cloud")
                            VStack(alignment: .leading) {
                                Text(host.name)
                                Text(host.capabilities.map(\.rawValue).sorted().joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle().fill(host.isOnline ? .green : .secondary).frame(width: 8, height: 8)
                        }
                    }
                    if store.hosts.isEmpty {
                        Text("No paired desktop or cloud worker is connected.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Waiting for you") {
                    ForEach(store.pendingApprovals) { approval in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(approval.operation.summary).font(.subheadline.weight(.semibold))
                            Text(approval.reason).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Deny", role: .destructive) { store.resolve(approval, as: .denied) }
                                Spacer()
                                Button("Allow once") { store.resolve(approval, as: .approvedOnce) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    if store.pendingApprovals.isEmpty {
                        Text("No operations need a decision.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Remote control")
            .sheet(isPresented: $showPairing) {
                PairingView()
                    .environmentObject(store)
            }
        }
    }
}

private struct PairingView: View {
    @EnvironmentObject private var store: DispatchClientStore
    @Environment(\.dismiss) private var dismiss
    @State private var relay = ""
    @State private var room = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Relay") {
                    TextField("wss://relay.example.com", text: $relay)
                    TextField("Pairing room", text: $room)
                    SecureField("Pairing token", text: $token)
                }
                Section {
                    Text("The token is stored in this device's Keychain. The Mac makes an outbound connection to the same authenticated room.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if DispatchPairing.current() != nil {
                    Section {
                        Button("Forget pairing", role: .destructive) {
                            store.disconnect()
                            DispatchPairing.clear()
                            relay = ""
                            room = ""
                            token = ""
                        }
                    }
                }
            }
            .navigationTitle("Pair desktop")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        let configuration = DispatchPairingConfiguration(
                            relayBaseURL: relay,
                            roomID: room,
                            bearerToken: token
                        )
                        if DispatchPairing.save(configuration), let url = configuration.socketURL {
                            store.connect(to: url, bearerToken: token)
                            dismiss()
                        }
                    }
                    .disabled(relay.isEmpty || room.isEmpty || token.isEmpty)
                }
            }
            .onAppear {
                if let pairing = DispatchPairing.current() {
                    relay = pairing.relayBaseURL
                    room = pairing.roomID
                    token = pairing.bearerToken
                }
            }
        }
    }
}

private struct TaskDetailView: View {
    @EnvironmentObject private var store: DispatchClientStore
    let taskID: UUID
    @State private var showChildComposer = false

    private var task: DispatchTask? { store.snapshot.tasks.first { $0.id == taskID } }

    var body: some View {
        List {
            if let task {
                Section("Task") {
                    TaskRow(task: task)
                    Text(task.prompt)
                    if let workspace = task.workspacePath {
                        Label(workspace, systemImage: "folder")
                            .font(.caption)
                    }
                }

                if !store.children(of: task.id).isEmpty {
                    Section("Child agents") {
                        ForEach(store.children(of: task.id)) { child in
                            NavigationLink {
                                TaskDetailView(taskID: child.id)
                            } label: {
                                TaskRow(task: child)
                            }
                        }
                    }
                }

                if task.depth < DispatchLimits().maximumDepth {
                    Section("Coordinator") {
                        Button {
                            showChildComposer = true
                        } label: {
                            Label("Delegate child agent", systemImage: "person.2.badge.plus")
                        }
                    }
                }

                Section("Live transcript") {
                    ForEach(store.events(for: task)) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.message)
                            Text(event.createdAt, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Control") {
                    if task.state == .paused {
                        Button { store.resume(task) } label: { Label("Resume", systemImage: "play.fill") }
                    } else if !task.state.isTerminal {
                        Button { store.pause(task) } label: { Label("Pause", systemImage: "pause.fill") }
                    }
                    if !task.state.isTerminal {
                        Button(role: .destructive) { store.cancel(task) } label: {
                            Label("Stop task", systemImage: "stop.fill")
                        }
                    }
                }
            }
        }
        .navigationTitle(task?.title ?? "Task")
        .sheet(isPresented: $showChildComposer) {
            if let task {
                ChildTaskComposer(parent: task)
                    .environmentObject(store)
            }
        }
    }
}

private struct ChildTaskComposer: View {
    @EnvironmentObject private var store: DispatchClientStore
    @Environment(\.dismiss) private var dismiss
    let parent: DispatchTask
    @State private var prompt = ""
    @State private var kind: DispatchTaskKind = .code

    var body: some View {
        NavigationStack {
            Form {
                Section("Parent coordinator") {
                    Text(parent.title)
                }
                Section("Child assignment") {
                    Picker("Agent type", selection: $kind) {
                        ForEach(DispatchTaskKind.allCases, id: \.self) { option in
                            Text(option.rawValue.capitalized).tag(option)
                        }
                    }
                    TextField("What should this child agent accomplish?", text: $prompt, axis: .vertical)
                        .lineLimit(4...10)
                }
            }
            .navigationTitle("Delegate agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Dispatch") {
                        if store.submitChild(parent: parent, prompt: prompt, kind: kind) != nil {
                            dismiss()
                        }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct TaskRow: View {
    let task: DispatchTask

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(task.kind.rawValue.capitalized) · \(task.state.rawValue.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var symbol: String {
        switch task.state {
        case .queued: "clock"
        case .running: "bolt.fill"
        case .awaitingApproval: "hand.raised.fill"
        case .paused: "pause.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var color: Color {
        switch task.state {
        case .running: .cyan
        case .awaitingApproval: .orange
        case .succeeded: .green
        case .failed: .red
        default: .secondary
        }
    }
}
