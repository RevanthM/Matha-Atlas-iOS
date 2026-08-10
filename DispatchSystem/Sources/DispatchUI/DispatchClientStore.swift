import Combine
import DispatchCore
import Foundation

public enum DispatchConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    public var label: String {
        switch self {
        case .disconnected: "Offline queue"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed: "Connection failed"
        }
    }
}

public actor WebSocketDispatchTransport {
    private let url: URL
    private let bearerToken: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var socket: URLSessionWebSocketTask?

    public init(url: URL, bearerToken: String) {
        self.url = url
        self.bearerToken = bearerToken
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func connect() async throws {
        guard socket == nil else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            socket = nil
            throw error
        }
    }

    public func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    public func send(_ envelope: RelayEnvelope) async throws {
        guard let socket else { throw DispatchTransportError.notConnected }
        try await socket.send(.data(try encoder.encode(envelope)))
    }

    public func receive() async throws -> RelayEnvelope {
        guard let socket else { throw DispatchTransportError.notConnected }
        switch try await socket.receive() {
        case .data(let data):
            return try decoder.decode(RelayEnvelope.self, from: data)
        case .string(let string):
            return try decoder.decode(RelayEnvelope.self, from: Data(string.utf8))
        @unknown default:
            throw DispatchTransportError.unsupportedMessage
        }
    }
}

public enum DispatchTransportError: LocalizedError {
    case notConnected
    case unsupportedMessage

    public var errorDescription: String? {
        switch self {
        case .notConnected: "The dispatch relay is not connected."
        case .unsupportedMessage: "The relay returned an unsupported message."
        }
    }
}

@MainActor
public final class DispatchClientStore: ObservableObject {
    @Published public private(set) var snapshot: DispatchSnapshot
    @Published public private(set) var hosts: [DispatchHost] = []
    @Published public private(set) var pendingApprovals: [ApprovalRequest] = []
    @Published public private(set) var connectionState: DispatchConnectionState = .disconnected
    @Published public var selectedTaskID: UUID?
    @Published public var errorMessage: String?

    private let persistenceURL: URL
    private var transport: WebSocketDispatchTransport?
    private var receiveTask: Task<Void, Never>?
    private var outboundQueue: [RelayEnvelope] = []
    private var reconnectEnabled = false

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL
        snapshot = Self.load(from: self.persistenceURL)
        if let pairing = DispatchPairing.current(), let url = pairing.socketURL {
            Task { @MainActor [weak self] in
                self?.connect(to: url, bearerToken: pairing.bearerToken)
            }
        }
    }

    deinit {
        receiveTask?.cancel()
    }

    public var rootTasks: [DispatchTask] {
        snapshot.tasks.filter { $0.parentID == nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public var activeTasks: [DispatchTask] {
        snapshot.tasks.filter { !$0.state.isTerminal }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func children(of taskID: UUID) -> [DispatchTask] {
        snapshot.tasks.filter { $0.parentID == taskID }.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func submitChild(
        parent: DispatchTask,
        prompt: String,
        kind: DispatchTaskKind
    ) -> DispatchTask? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let limits = DispatchLimits()
        guard !trimmed.isEmpty, parent.depth < limits.maximumDepth else { return nil }
        let title = String(trimmed.split(separator: "\n").first.map(String.init)?.prefix(64) ?? "Child agent")
        let child = DispatchTask(
            rootID: parent.rootID,
            parentID: parent.id,
            title: title,
            prompt: trimmed,
            kind: kind,
            target: .automatic,
            workspacePath: parent.workspacePath,
            depth: parent.depth + 1
        )
        snapshot.tasks.append(child)
        snapshot.events.append(
            DispatchEvent(taskID: child.id, kind: .taskCreated, message: "Delegated from \(parent.title)")
        )
        selectedTaskID = child.id
        persist()
        enqueue(RelayEnvelope(payload: .submit(child)))
        return child
    }

    @discardableResult
    public func submit(prompt: String, workspacePath: String? = nil) -> DispatchTask? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let title = String(trimmed.split(separator: "\n").first.map(String.init)?.prefix(64) ?? "Dispatch task")
        let task = DispatchTask(
            title: title,
            prompt: trimmed,
            kind: .coordinator,
            target: .automatic,
            workspacePath: workspacePath
        )
        snapshot.tasks.append(task)
        snapshot.events.append(
            DispatchEvent(taskID: task.id, kind: .taskCreated, message: "Submitted from iPhone")
        )
        selectedTaskID = task.id
        persist()
        enqueue(RelayEnvelope(payload: .submit(task)))
        return task
    }

    public func connect(to relayURL: URL, bearerToken: String) {
        receiveTask?.cancel()
        reconnectEnabled = true
        connectionState = .connecting
        receiveTask = Task { [weak self] in
            await self?.runConnectionLoop(relayURL: relayURL, bearerToken: bearerToken)
        }
    }

    public func disconnect() {
        reconnectEnabled = false
        receiveTask?.cancel()
        receiveTask = nil
        let transport = transport
        self.transport = nil
        connectionState = .disconnected
        Task { await transport?.disconnect() }
    }

    private func runConnectionLoop(relayURL: URL, bearerToken: String) async {
        var retryDelaySeconds: UInt64 = 1

        while reconnectEnabled, !Task.isCancelled {
            connectionState = .connecting
            let candidate = WebSocketDispatchTransport(url: relayURL, bearerToken: bearerToken)
            transport = candidate

            do {
                try await candidate.connect()
                guard reconnectEnabled, !Task.isCancelled else {
                    await candidate.disconnect()
                    return
                }

                connectionState = .connected
                errorMessage = nil
                retryDelaySeconds = 1
                await flushOutboundQueue()

                while reconnectEnabled, !Task.isCancelled {
                    let envelope = try await candidate.receive()
                    ingest(envelope)
                }
            } catch is CancellationError {
                await candidate.disconnect()
                return
            } catch {
                await candidate.disconnect()
                guard reconnectEnabled, !Task.isCancelled else { return }

                hosts.removeAll()
                connectionState = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription

                do {
                    try await Task.sleep(for: .seconds(retryDelaySeconds))
                } catch {
                    return
                }
                retryDelaySeconds = min(retryDelaySeconds * 2, 8)
            }
        }
    }

    public func cancel(_ task: DispatchTask) {
        update(taskID: task.id, state: .cancelled)
        enqueue(RelayEnvelope(payload: .cancel(taskID: task.id)))
    }

    public func pause(_ task: DispatchTask) {
        update(taskID: task.id, state: .paused)
        enqueue(RelayEnvelope(payload: .pause(taskID: task.id)))
    }

    public func resume(_ task: DispatchTask) {
        update(taskID: task.id, state: .queued)
        enqueue(RelayEnvelope(payload: .resume(taskID: task.id)))
    }

    public func resolve(_ approval: ApprovalRequest, as resolution: ApprovalResolution) {
        pendingApprovals.removeAll { $0.id == approval.id }
        snapshot.events.append(
            DispatchEvent(
                taskID: approval.taskID,
                kind: .approvalResolved,
                message: "Approval \(resolution.rawValue)"
            )
        )
        persist()
        enqueue(RelayEnvelope(payload: .approvalResponse(id: approval.id, resolution: resolution)))
    }

    public func events(for task: DispatchTask) -> [DispatchEvent] {
        snapshot.events.filter { $0.taskID == task.id }.sorted { $0.createdAt < $1.createdAt }
    }

    private func ingest(_ envelope: RelayEnvelope) {
        guard envelope.protocolVersion == localGemmaDispatchProtocolVersion else {
            errorMessage = "The relay protocol version is incompatible."
            return
        }
        switch envelope.payload {
        case .hello(let host), .heartbeat(let host):
            guard !host.capabilities.isEmpty else { break }
            hosts.removeAll { $0.id == host.id }
            hosts.append(host)
        case .submit(let task):
            replace(task)
        case .event(let event):
            if !snapshot.events.contains(where: { $0.id == event.id }) { snapshot.events.append(event) }
        case .snapshot(let incoming):
            snapshot = incoming
        case .approvalRequest(let approval):
            if !pendingApprovals.contains(where: { $0.id == approval.id }) { pendingApprovals.append(approval) }
        case .approvalResponse, .execute, .cancel, .pause, .resume:
            break
        }
        persist()
    }

    private func replace(_ task: DispatchTask) {
        snapshot.tasks.removeAll { $0.id == task.id }
        snapshot.tasks.append(task)
    }

    private func update(taskID: UUID, state: DispatchTaskState) {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        snapshot.tasks[index].state = state
        snapshot.tasks[index].updatedAt = Date()
        persist()
    }

    private func enqueue(_ envelope: RelayEnvelope) {
        guard connectionState == .connected, let transport else {
            outboundQueue.append(envelope)
            return
        }
        Task {
            do { try await transport.send(envelope) }
            catch {
                outboundQueue.append(envelope)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func flushOutboundQueue() async {
        guard let transport else { return }
        let queued = outboundQueue
        outboundQueue.removeAll()
        for envelope in queued {
            do { try await transport.send(envelope) }
            catch {
                outboundQueue.append(envelope)
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: persistenceURL, options: .atomic)
        } catch {
            errorMessage = "Dispatch history could not be saved: \(error.localizedDescription)"
        }
    }

    private static func load(from url: URL) -> DispatchSnapshot {
        guard let data = try? Data(contentsOf: url) else { return DispatchSnapshot() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DispatchSnapshot.self, from: data)) ?? DispatchSnapshot()
    }

    private static var defaultPersistenceURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalGemmaDispatch", isDirectory: true)
            .appendingPathComponent("DispatchClient.json")
    }
}
