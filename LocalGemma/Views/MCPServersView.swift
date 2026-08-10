import SwiftUI

struct MCPServersView: View {
    @StateObject private var store = MCPConnectionStore.shared
    @State private var showAddServer = false
    @State private var serverToDelete: MCPServerProfile?

    var body: some View {
        List {
            Section {
                Label("MCP calls are not fully on-device", systemImage: "network.badge.shield.half.filled")
                    .font(.subheadline.weight(.semibold))
                Text("The model stays on your iPhone, but an approved MCP call sends its displayed arguments to the selected server. Server descriptions and safety annotations are untrusted metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("HTTP MCP servers") {
                if store.servers.isEmpty {
                    ContentUnavailableView(
                        "No MCP servers",
                        systemImage: "server.rack",
                        description: Text("Add a Streamable HTTP or HTTP+SSE endpoint. iOS apps cannot launch desktop stdio servers.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(store.servers) { server in
                        NavigationLink {
                            MCPServerDetailView(serverID: server.id)
                        } label: {
                            MCPServerRow(server: server)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                serverToDelete = server
                            }
                        }
                    }
                }
            }

            Section("Model access") {
                Label("Gemma can inspect the connected tool catalog", systemImage: "list.bullet.rectangle")
                Label("Every remote invocation requires approval", systemImage: "hand.raised.fill")
                Label("Bearer tokens are stored in this device's Keychain", systemImage: "key.fill")
            }
            .font(.subheadline)
        }
        .navigationTitle("MCP servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddServer = true } label: {
                    Label("Add server", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddServer) {
            AddMCPServerView()
        }
        .confirmationDialog(
            "Remove this MCP server?",
            isPresented: Binding(
                get: { serverToDelete != nil },
                set: { if !$0 { serverToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: serverToDelete
        ) { server in
            Button("Remove \(server.name)", role: .destructive) {
                Task { await store.removeServer(server.id) }
            }
        } message: { server in
            Text("The profile and its Keychain token will be removed from this iPhone.")
        }
    }
}

private struct MCPServerRow: View {
    @StateObject private var store = MCPConnectionStore.shared
    let server: MCPServerProfile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbol)
                .foregroundStyle(statusColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.name).font(.subheadline.weight(.semibold))
                    if !server.isEnabled {
                        Text("OFF")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.2), in: Capsule())
                    }
                }
                Text(server.endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(state.title) · \(store.tools(for: server.id).count) tools")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var state: MCPConnectionState { store.state(for: server.id) }

    private var statusColor: Color {
        switch state {
        case .connected: .green
        case .connecting: .cyan
        case .failed: .orange
        case .disconnected: .secondary
        }
    }
}

private struct MCPServerDetailView: View {
    @StateObject private var store = MCPConnectionStore.shared
    let serverID: UUID

    private var server: MCPServerProfile? {
        store.servers.first(where: { $0.id == serverID })
    }

    var body: some View {
        List {
            if let server {
                Section("Server") {
                    LabeledContent("Endpoint") {
                        Text(server.endpoint)
                            .font(.caption.monospaced())
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Authentication", value: server.hasBearerToken ? "Bearer token · Keychain" : "None")
                    Toggle(
                        "Allow model access",
                        isOn: Binding(
                            get: { server.isEnabled },
                            set: { enabled in Task { await store.setEnabled(enabled, for: serverID) } }
                        )
                    )
                }

                Section {
                    switch store.state(for: serverID) {
                    case .connected:
                        Button {
                            Task { await store.refreshTools(serverID) }
                        } label: {
                            Label("Refresh tool catalog", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            Task { await store.disconnect(serverID) }
                        } label: {
                            Label("Disconnect", systemImage: "network.slash")
                        }
                    case .connecting:
                        HStack {
                            ProgressView()
                            Text("Negotiating MCP connection…")
                        }
                    case .disconnected, .failed:
                        Button {
                            Task { await store.connect(serverID) }
                        } label: {
                            Label("Connect and discover tools", systemImage: "bolt.horizontal.circle")
                        }
                        .disabled(!server.isEnabled)
                    }

                    if let error = store.state(for: serverID).errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                Section("Advertised tools") {
                    if store.tools(for: serverID).isEmpty {
                        Text("Connect to discover this server's tools.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.tools(for: serverID)) { tool in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(tool.detail)
                                    Label(tool.riskSummary, systemImage: riskSymbol(tool))
                                        .foregroundStyle(riskColor(tool))
                                    Text("Input schema")
                                        .font(.caption.weight(.semibold))
                                        .padding(.top, 3)
                                    Text(tool.inputSchemaJSON)
                                        .font(.caption2.monospaced())
                                        .textSelection(.enabled)
                                }
                                .font(.caption)
                                .padding(.vertical, 6)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.title).font(.subheadline.weight(.medium))
                                    Text(tool.name)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Server removed", systemImage: "server.rack")
            }
        }
        .navigationTitle(server?.name ?? "MCP server")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func riskSymbol(_ tool: MCPToolSummary) -> String {
        if tool.destructiveHint == true { return "exclamationmark.triangle.fill" }
        if tool.readOnlyHint == true { return "checkmark.shield.fill" }
        return "questionmark.diamond.fill"
    }

    private func riskColor(_ tool: MCPToolSummary) -> Color {
        if tool.destructiveHint == true { return .orange }
        if tool.readOnlyHint == true { return .green }
        return .secondary
    }
}

private struct AddMCPServerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = MCPConnectionStore.shared
    @State private var name = ""
    @State private var endpoint = ""
    @State private var bearerToken = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $name)
                    TextField("https://example.com/mcp", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("Bearer token (optional)", text: $bearerToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Text("Use the MCP server's Streamable HTTP endpoint. The token is stored in Keychain and is never shown to Gemma or written into the chat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Add MCP server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add & Connect") {
                        do {
                            let serverID = try store.addServer(
                                name: name,
                                endpoint: endpoint,
                                bearerToken: bearerToken.isEmpty ? nil : bearerToken
                            )
                            dismiss()
                            Task { await store.connect(serverID) }
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpoint.isEmpty)
                }
            }
        }
    }
}
