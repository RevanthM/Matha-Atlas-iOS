import SwiftUI

struct ChatDrawerView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var knowledgeStore: KnowledgeStore
    @ObservedObject private var bridge = InferenceBridge.shared

    let close: () -> Void
    let openModel: () -> Void
    let openPerformance: () -> Void
    let openKnowledge: () -> Void
    let openGenerationSettings: () -> Void
    let openDispatch: () -> Void
    let openBridge: () -> Void

    @State private var searchText = ""
    @State private var chatToRename: ChatSession?
    @State private var showLocalTools = false
    @State private var showLocalSkills = false
    @State private var controlsAreInteractive = false

    private var filteredChats: [ChatSession] {
        guard !searchText.isEmpty else { return store.sortedChats }
        return store.sortedChats.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.preview.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            search

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredChats) { chat in
                        chatRow(chat)
                    }

                    if filteredChats.isEmpty {
                        ContentUnavailableView(
                            "No conversations",
                            systemImage: "text.magnifyingglass",
                            description: Text("Try a different search.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }

            Divider().overlay(.white.opacity(0.08))
            tools
        }
        .background(Color(red: 0.055, green: 0.061, blue: 0.078))
        .task {
            try? await Task.sleep(for: .milliseconds(280))
            controlsAreInteractive = true
        }
        .sheet(item: $chatToRename) { chat in
            RenameChatView(chat: chat) { title in
                store.renameChat(chat.id, title: title)
            }
            .presentationDetents([.height(230)])
        }
        .sheet(isPresented: $showLocalTools) {
            LocalToolsView()
                .environmentObject(store)
        }
        .sheet(isPresented: $showLocalSkills) {
            LocalSkillsView()
                .environmentObject(store)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: openModel) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "cpu")
                        .font(.system(size: 18, weight: .semibold))
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.black, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(controlsAreInteractive)
            .accessibilityLabel("Model status: \(store.status.label)")

            VStack(alignment: .leading, spacing: 2) {
                Text("Matha Atlas")
                    .font(.headline)
                Text(store.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task {
                    await store.newChat()
                    close()
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            .disabled(store.isBusy)
            .accessibilityLabel("New chat")

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Close menu")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var search: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search chats", text: $searchText)
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func chatRow(_ chat: ChatSession) -> some View {
        Button {
            Task {
                await store.selectChat(chat.id)
                close()
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: chat.isPinned ? "pin.fill" : "bubble.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(chat.isPinned ? .cyan : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.title)
                        .font(.subheadline.weight(chat.id == store.activeChatID ? .semibold : .regular))
                        .lineLimit(1)
                    Text(chat.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if chat.id == store.activeChatID {
                    Circle().fill(.cyan).frame(width: 7, height: 7)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 58)
            .background(
                chat.id == store.activeChatID ? Color.white.opacity(0.09) : .clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
        .contextMenu {
            Button {
                store.togglePin(chat.id)
            } label: {
                Label(chat.isPinned ? "Unpin" : "Pin", systemImage: chat.isPinned ? "pin.slash" : "pin")
            }
            Button {
                chatToRename = chat
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await store.deleteChat(chat.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var tools: some View {
        VStack(spacing: 2) {
            Menu {
                ForEach(AssistantMode.allCases) { mode in
                    Button {
                        Task { await store.setAssistantMode(mode) }
                    } label: {
                        Label(mode.title, systemImage: mode.symbol)
                    }
                }
            } label: {
                toolRow(
                    icon: store.activeAssistantMode.symbol,
                    title: "Assistant mode",
                    detail: store.activeAssistantMode.title
                )
            }

            Button { showLocalTools = true } label: {
                toolRow(
                    icon: "wrench.and.screwdriver",
                    title: "Local tools",
                    detail: "\(store.activeLocalTools.count) enabled"
                )
            }

            Button { showLocalSkills = true } label: {
                toolRow(
                    icon: "puzzlepiece.extension",
                    title: "Local skills",
                    detail: "\(store.activeSkills.count) enabled for this chat"
                )
            }

            Button(action: openDispatch) {
                toolRow(
                    icon: "paperplane",
                    title: "Dispatch center",
                    detail: "Agents · desktop · iPhone"
                )
            }

            Button(action: openBridge) {
                toolRow(
                    icon: "eyeglasses",
                    title: "Inference bridge",
                    detail: bridge.runState.isServing ? bridge.advertisedBaseURL : "Off · paired apps use Gemma here"
                )
            }

            Button(action: openKnowledge) {
                toolRow(
                    icon: "books.vertical",
                    title: "Private knowledge",
                    detail: "\(knowledgeStore.documents.count) indexed \(knowledgeStore.documents.count == 1 ? "file" : "files")"
                )
            }
            Button(action: openGenerationSettings) {
                toolRow(
                    icon: "slider.horizontal.3",
                    title: "Generation controls",
                    detail: "Max \(store.generationSettings.maxOutputTokens.formatted()) tokens"
                )
            }
            Button(action: openPerformance) {
                toolRow(
                    icon: "gauge.with.dots.needle.67percent",
                    title: "Token speed tests",
                    detail: "128 · 500 · 1,000 token presets"
                )
            }
            ShareLink(item: store.activeChatMarkdown, subject: Text(store.activeChatTitle)) {
                toolRow(icon: "square.and.arrow.up", title: "Export this chat", detail: "Markdown file")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func toolRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.cyan)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption2.bold())
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 50)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch store.status {
        case .ready: .green
        case .generating: .cyan
        case .failed: .orange
        default: .secondary
        }
    }
}

private struct LocalToolsView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var activityStore = ToolActivityStore.shared
    @StateObject private var mcpStore = MCPConnectionStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("On-device with permission controls", systemImage: "lock.shield")
                        .font(.subheadline.weight(.medium))
                    Text("Read-only tools may run automatically. Any tool that changes your data pauses and shows the exact action for approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Enabled for this chat") {
                    ForEach(store.activeLocalTools) { tool in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: tool.symbol)
                                .foregroundStyle(.cyan)
                                .frame(width: 25)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tool.title).font(.subheadline.weight(.medium))
                                Text(tool.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(tool.name)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                Label(tool.permissionPolicy.title, systemImage: tool.permissionPolicy.symbol)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(tool.permissionPolicy == .requiresConfirmation ? .orange : .green)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }

                if !store.knowledgeEnabled {
                    Section {
                        Text("Enable Private knowledge to add local semantic-search and knowledge-library tools to this chat.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Safety policy") {
                    Label("Read-only tools can run automatically", systemImage: "checkmark.shield")
                    Label("Write tools always ask first", systemImage: "hand.raised")
                    Label("Every remote MCP call asks first", systemImage: "network")
                }
                .font(.subheadline)

                Section("Model Context Protocol") {
                    NavigationLink {
                        MCPServersView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("MCP servers")
                                Text("\(mcpStore.connectedServerCount) connected · \(mcpStore.connectedToolCount) tools")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "server.rack")
                                .foregroundStyle(.cyan)
                        }
                    }
                }

                Section("Recent activity") {
                    if activityStore.records.isEmpty {
                        Text("Tool calls will appear here. Prompts, arguments, and results are not stored in this log.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(activityStore.records.prefix(20)) { record in
                            HStack(spacing: 11) {
                                Image(systemName: record.outcome.symbol)
                                    .foregroundStyle(activityColor(record.outcome))
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.title).font(.subheadline.weight(.medium))
                                    HStack(spacing: 6) {
                                        Text(record.outcome.title)
                                        Text(record.startedAt, style: .relative)
                                        if let duration = record.duration {
                                            Text(String(format: "%.2fs", duration))
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Button("Clear activity", role: .destructive) {
                            activityStore.clear()
                        }
                    }
                }
            }
            .navigationTitle("Local tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func activityColor(_ outcome: ToolActivityOutcome) -> Color {
        switch outcome {
        case .running: .cyan
        case .succeeded: .green
        case .denied: .orange
        case .failed: .red
        }
    }
}

private struct RenameChatView: View {
    @Environment(\.dismiss) private var dismiss
    let chat: ChatSession
    let save: (String) -> Void
    @State private var title: String

    init(chat: ChatSession, save: @escaping (String) -> Void) {
        self.chat = chat
        self.save = save
        _title = State(initialValue: chat.title)
    }

    var body: some View {
        NavigationStack {
            Form { TextField("Chat name", text: $title) }
                .navigationTitle("Rename chat")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save(title)
                            dismiss()
                        }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
