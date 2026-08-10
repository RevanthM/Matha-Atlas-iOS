import Foundation
import MCP
import Security

struct MCPServerProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var endpoint: String
    var isEnabled: Bool
    var hasBearerToken: Bool

    init(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        isEnabled: Bool = true,
        hasBearerToken: Bool = false
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.isEnabled = isEnabled
        self.hasBearerToken = hasBearerToken
    }
}

enum MCPConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var title: String {
        switch self {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .failed: "Connection failed"
        }
    }

    var symbol: String {
        switch self {
        case .disconnected: "circle"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var errorMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

struct MCPToolSummary: Identifiable, Equatable {
    let serverID: UUID
    let name: String
    let title: String
    let detail: String
    let inputSchemaJSON: String
    let readOnlyHint: Bool?
    let destructiveHint: Bool?
    let openWorldHint: Bool?

    var id: String { "\(serverID.uuidString):\(name)" }

    var riskSummary: String {
        if destructiveHint == true { return "Server marks this as potentially destructive" }
        if readOnlyHint == true { return "Server marks this as read only" }
        return "Effect not verified — confirmation required"
    }
}

@MainActor
final class MCPConnectionStore: ObservableObject {
    static let shared = MCPConnectionStore()

    @Published private(set) var servers: [MCPServerProfile]
    @Published private(set) var connectionStates: [UUID: MCPConnectionState] = [:]
    @Published private(set) var toolsByServer: [UUID: [MCPToolSummary]] = [:]

    private var clients: [UUID: Client] = [:]
    private let defaultsKey = "localGemma.mcpServers.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([MCPServerProfile].self, from: data) {
            servers = decoded
        } else {
            servers = []
        }
        for server in servers {
            connectionStates[server.id] = .disconnected
        }
    }

    var connectedServerCount: Int {
        servers.filter { connectionStates[$0.id] == .connected }.count
    }

    var connectedToolCount: Int {
        servers
            .filter { $0.isEnabled && connectionStates[$0.id] == .connected }
            .reduce(0) { $0 + (toolsByServer[$1.id]?.count ?? 0) }
    }

    func state(for serverID: UUID) -> MCPConnectionState {
        connectionStates[serverID] ?? .disconnected
    }

    func tools(for serverID: UUID) -> [MCPToolSummary] {
        toolsByServer[serverID] ?? []
    }

    func addServer(name: String, endpoint: String, bearerToken: String?) throws -> UUID {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try validatedEndpoint(cleanedEndpoint)
        guard !cleanedName.isEmpty else { throw MCPConnectionError.emptyName }

        let server = MCPServerProfile(
            name: cleanedName,
            endpoint: cleanedEndpoint,
            hasBearerToken: !(bearerToken?.isEmpty ?? true)
        )
        if let bearerToken, !bearerToken.isEmpty {
            try MCPSecretStore.set(bearerToken, for: server.id)
        }
        servers.append(server)
        connectionStates[server.id] = .disconnected
        persist()
        return server.id
    }

    func setEnabled(_ enabled: Bool, for serverID: UUID) async {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[index].isEnabled = enabled
        persist()
        if !enabled {
            await disconnect(serverID)
        }
    }

    func connect(_ serverID: UUID) async {
        guard let profile = servers.first(where: { $0.id == serverID }) else { return }
        guard profile.isEnabled else {
            connectionStates[serverID] = .failed("Enable this server before connecting.")
            return
        }

        connectionStates[serverID] = .connecting
        if let existing = clients.removeValue(forKey: serverID) {
            await existing.disconnect()
        }

        var connectingClient: Client?
        do {
            let endpoint = try validatedEndpoint(profile.endpoint)
            let token = try MCPSecretStore.get(for: serverID)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120

            let transport = HTTPClientTransport(
                endpoint: endpoint,
                configuration: configuration,
                streaming: true,
                requestModifier: { request in
                    var request = request
                    if let token, !token.isEmpty {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    return request
                }
            )
            let client = Client(
                name: "Matha Atlas for iOS",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            )
            connectingClient = client
            _ = try await client.connect(transport: transport)
            let summaries = try await fetchAllTools(client: client, serverID: serverID)

            clients[serverID] = client
            connectingClient = nil
            toolsByServer[serverID] = summaries
            connectionStates[serverID] = .connected
        } catch {
            if let connectingClient {
                await connectingClient.disconnect()
            }
            clients[serverID] = nil
            toolsByServer[serverID] = nil
            connectionStates[serverID] = .failed(error.localizedDescription)
        }
    }

    func refreshTools(_ serverID: UUID) async {
        guard let client = clients[serverID] else {
            await connect(serverID)
            return
        }
        do {
            toolsByServer[serverID] = try await fetchAllTools(client: client, serverID: serverID)
            connectionStates[serverID] = .connected
        } catch {
            connectionStates[serverID] = .failed(error.localizedDescription)
        }
    }

    func disconnect(_ serverID: UUID) async {
        if let client = clients.removeValue(forKey: serverID) {
            await client.disconnect()
        }
        toolsByServer[serverID] = nil
        connectionStates[serverID] = .disconnected
    }

    func removeServer(_ serverID: UUID) async {
        await disconnect(serverID)
        servers.removeAll { $0.id == serverID }
        connectionStates[serverID] = nil
        MCPSecretStore.remove(for: serverID)
        persist()
    }

    func availableToolListing() -> [[String: Any]] {
        servers.compactMap { server -> [String: Any]? in
            guard server.isEnabled, connectionStates[server.id] == .connected else { return nil }
            return [
                "server_id": server.id.uuidString,
                "server_name": server.name,
                "endpoint": server.endpoint,
                "tools": (toolsByServer[server.id] ?? []).map { tool in
                    var result: [String: Any] = [
                        "name": tool.name,
                        "title": tool.title,
                        "description": tool.detail,
                        "input_schema": tool.inputSchemaJSON
                    ]
                    if let value = tool.readOnlyHint { result["server_claims_read_only"] = value }
                    if let value = tool.destructiveHint { result["server_claims_destructive"] = value }
                    if let value = tool.openWorldHint { result["server_claims_open_world"] = value }
                    return result
                }
            ]
        }
    }

    func callTool(
        serverIdentifier: String,
        toolName: String,
        argumentsJSON: String
    ) async throws -> [String: Any] {
        let server = try resolveServer(serverIdentifier)
        guard server.isEnabled else { throw MCPConnectionError.serverDisabled }
        guard let client = clients[server.id], connectionStates[server.id] == .connected else {
            throw MCPConnectionError.serverNotConnected
        }
        guard toolsByServer[server.id]?.contains(where: { $0.name == toolName }) == true else {
            throw MCPConnectionError.unknownTool
        }

        let arguments = try decodeArguments(argumentsJSON)
        let response = try await client.callTool(name: toolName, arguments: arguments)
        return [
            "server": server.name,
            "tool": toolName,
            "is_error": response.isError ?? false,
            "content": response.content.map(Self.modelSafeContent)
        ]
    }

    func serverAndTool(
        serverIdentifier: String,
        toolName: String
    ) throws -> (MCPServerProfile, MCPToolSummary) {
        let server = try resolveServer(serverIdentifier)
        guard server.isEnabled else { throw MCPConnectionError.serverDisabled }
        guard connectionStates[server.id] == .connected else {
            throw MCPConnectionError.serverNotConnected
        }
        guard let tool = toolsByServer[server.id]?.first(where: { $0.name == toolName }) else {
            throw MCPConnectionError.unknownTool
        }
        return (server, tool)
    }

    private func fetchAllTools(client: Client, serverID: UUID) async throws -> [MCPToolSummary] {
        var allTools: [MCP.Tool] = []
        var cursor: String?
        var pageCount = 0
        repeat {
            let page = try await client.listTools(cursor: cursor)
            allTools.append(contentsOf: page.tools)
            cursor = page.nextCursor
            pageCount += 1
        } while cursor != nil && pageCount < 50

        return allTools.map { tool in
            let schemaData = try? JSONEncoder().encode(tool.inputSchema)
            let schemaObject = schemaData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let prettyData = schemaObject.flatMap {
                try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys])
            }
            return MCPToolSummary(
                serverID: serverID,
                name: tool.name,
                title: tool.title ?? tool.annotations.title ?? tool.name,
                detail: tool.description ?? "No description supplied by this server.",
                inputSchemaJSON: prettyData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}",
                readOnlyHint: tool.annotations.readOnlyHint,
                destructiveHint: tool.annotations.destructiveHint,
                openWorldHint: tool.annotations.openWorldHint
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func validatedEndpoint(_ endpoint: String) throws -> URL {
        guard let components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let url = components.url else {
            throw MCPConnectionError.invalidEndpoint
        }
        return url
    }

    private func resolveServer(_ identifier: String) throws -> MCPServerProfile {
        if let id = UUID(uuidString: identifier),
           let server = servers.first(where: { $0.id == id }) {
            return server
        }
        let matches = servers.filter { $0.name.localizedCaseInsensitiveCompare(identifier) == .orderedSame }
        guard matches.count == 1, let server = matches.first else {
            throw matches.isEmpty ? MCPConnectionError.unknownServer : MCPConnectionError.ambiguousServer
        }
        return server
    }

    private func decodeArguments(_ value: String) throws -> [String: MCP.Value]? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "{}" { return nil }
        guard cleaned.utf8.count <= 64_000, let data = cleaned.data(using: .utf8) else {
            throw MCPConnectionError.argumentsTooLarge
        }
        let decoded = try JSONDecoder().decode(MCP.Value.self, from: data)
        guard case .object(let arguments) = decoded else {
            throw MCPConnectionError.argumentsMustBeObject
        }
        return arguments
    }

    nonisolated private static func modelSafeContent(_ content: MCP.Tool.Content) -> [String: Any] {
        switch content {
        case .text(let text, _, _):
            return ["type": "text", "text": String(text.prefix(24_000))]
        case .image(let data, let mimeType, _, _):
            return [
                "type": "image",
                "mime_type": mimeType,
                "encoded_bytes": data.utf8.count,
                "note": "Binary image omitted from the text tool result."
            ]
        case .audio(let data, let mimeType, _, _):
            return [
                "type": "audio",
                "mime_type": mimeType,
                "encoded_bytes": data.utf8.count,
                "note": "Binary audio omitted from the text tool result."
            ]
        case .resource(let resource, _, _):
            var result: [String: Any] = ["type": "resource", "uri": resource.uri]
            if let mimeType = resource.mimeType { result["mime_type"] = mimeType }
            if let text = resource.text { result["text"] = String(text.prefix(24_000)) }
            if let blob = resource.blob {
                result["encoded_bytes"] = blob.utf8.count
                result["note"] = "Binary resource omitted from the text tool result."
            }
            return result
        case .resourceLink(let uri, let name, let title, let description, let mimeType, _):
            var result: [String: Any] = ["type": "resource_link", "uri": uri, "name": name]
            if let title { result["title"] = title }
            if let description { result["description"] = description }
            if let mimeType { result["mime_type"] = mimeType }
            return result
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

private enum MCPSecretStore {
    private static let service = "com.matha.atlas.mcp"

    static func set(_ token: String, for serverID: UUID) throws {
        remove(for: serverID)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverID.uuidString,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(token.utf8)
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw MCPConnectionError.keychain(status) }
    }

    static func get(for serverID: UUID) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverID.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MCPConnectionError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func remove(for serverID: UUID) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverID.uuidString
        ] as CFDictionary)
    }
}

private enum MCPConnectionError: LocalizedError {
    case emptyName
    case invalidEndpoint
    case unknownServer
    case ambiguousServer
    case serverDisabled
    case serverNotConnected
    case unknownTool
    case argumentsTooLarge
    case argumentsMustBeObject
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a server name."
        case .invalidEndpoint: "Enter a complete HTTP or HTTPS MCP endpoint without embedded credentials."
        case .unknownServer: "No matching MCP server is configured."
        case .ambiguousServer: "More than one MCP server has that name. Use the server ID."
        case .serverDisabled: "That MCP server is disabled."
        case .serverNotConnected: "That MCP server is not connected."
        case .unknownTool: "That tool was not advertised by the connected MCP server."
        case .argumentsTooLarge: "The MCP arguments are too large."
        case .argumentsMustBeObject: "MCP arguments must be a JSON object."
        case .keychain(let status): "The bearer token could not be stored securely (Keychain status \(status))."
        }
    }
}
