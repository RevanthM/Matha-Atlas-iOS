import DispatchCore
import Foundation

struct AgentService {
    let configuration: AgentConfiguration
    let graph: TaskGraphStore
    let relay: RelayClient
    private let pendingExecutions = PendingExecutionStore()

    func run(bearerToken: String) async throws {
        guard let relayURL = configuration.relayURL else { throw AgentServiceError.relayNotConfigured }
        try await relay.connect(to: relayURL, host: configuration.host, bearerToken: bearerToken)
        let heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                var heartbeatHost = configuration.host
                heartbeatHost.lastSeenAt = Date()
                heartbeatHost.isOnline = true
                try? await relay.send(RelayEnvelope(payload: .heartbeat(heartbeatHost)))
            }
        }
        defer { heartbeatTask.cancel() }

        while !Task.isCancelled {
            let envelope = try await relay.receive()
            guard envelope.protocolVersion == localGemmaDispatchProtocolVersion else { continue }
            switch envelope.payload {
            case .submit(let task):
                try await accept(task)
            case .execute(let request):
                try await execute(request)
            case .cancel(let taskID):
                try await updateRequestedState(taskID: taskID, state: .cancelled)
            case .pause(let taskID):
                try await updateRequestedState(taskID: taskID, state: .paused)
            case .resume(let taskID):
                try await updateRequestedState(taskID: taskID, state: .queued)
            case .approvalResponse(let id, let resolution):
                try await resolveApproval(id: id, resolution: resolution)
            case .hello, .heartbeat, .event, .snapshot, .approvalRequest:
                break
            }
        }
    }

    private func accept(_ incoming: DispatchTask) async throws {
        try await graph.upsert(incoming)
        guard incoming.target != .cloud else { return }
        guard incoming.requiredCapabilities.isSubset(of: configuration.host.capabilities) else {
            try await sendEvent(
                taskID: incoming.id,
                kind: .output,
                message: "This desktop does not provide every capability required by the task."
            )
            return
        }

        let workspace: String
        if let requested = incoming.workspacePath {
            workspace = requested
        } else if configuration.approvedWorkspaceRoots.count == 1,
                  let onlyWorkspace = configuration.approvedWorkspaceRoots.first {
            workspace = onlyWorkspace
        } else {
            try await fail(incoming, reason: "Select one approved workspace before dispatching this task.")
            return
        }

        let request = DesktopExecutionRequest(
            taskID: incoming.id,
            action: .runAgent(AgentRunRequest(workspacePath: workspace, prompt: incoming.prompt))
        )
        try await execute(request)
    }

    private func execute(_ request: DesktopExecutionRequest, approvalOverride: Bool = false) async throws {
        guard var task = await graph.task(id: request.taskID) else { return }
        task.state = .running
        task.updatedAt = Date()
        try await graph.upsert(task)
        try await relay.send(RelayEnvelope(payload: .submit(task)))
        try await sendEvent(taskID: task.id, kind: .stateChanged, message: "Desktop agent started the task.")

        do {
            let result = try DesktopTaskExecutor().execute(
                request,
                policy: configuration.executionPolicy,
                approvalOverride: approvalOverride
            )
            let output = String(result.output.suffix(120_000))
            if !output.isEmpty {
                try await sendEvent(taskID: task.id, kind: .output, message: output)
            }
            task.state = result.exitCode == 0 ? .succeeded : .failed
            task.updatedAt = Date()
            task.result = DispatchTaskResult(
                summary: result.exitCode == 0 ? "Desktop task completed." : "Desktop command failed.",
                exitCode: result.exitCode
            )
            task.failureReason = result.exitCode == 0 ? nil : "Command exited with status \(result.exitCode)."
        } catch AgentOperationError.approvalRequired(let reason) {
            task.state = .awaitingApproval
            task.updatedAt = Date()
            let operation = OperationRequest(kind: .executeProcess, summary: task.title)
            let approval = ApprovalRequest(taskID: task.id, operation: operation, reason: reason)
            await pendingExecutions.store(request, for: approval.id)
            try await relay.send(
                RelayEnvelope(payload: .approvalRequest(approval))
            )
        } catch {
            task.state = .failed
            task.updatedAt = Date()
            task.failureReason = error.localizedDescription
            task.result = DispatchTaskResult(summary: "Desktop task failed: \(error.localizedDescription)")
        }

        try await graph.upsert(task)
        try await relay.send(RelayEnvelope(payload: .submit(task)))
        try await sendEvent(
            taskID: task.id,
            kind: .stateChanged,
            message: "Task is now \(task.state.rawValue)."
        )
    }

    private func resolveApproval(id: UUID, resolution: ApprovalResolution) async throws {
        guard let request = await pendingExecutions.take(id: id),
              let task = await graph.task(id: request.taskID) else { return }

        switch resolution {
        case .denied:
            try await fail(task, reason: "The requested desktop operation was denied on iPhone.")
        case .approvedOnce, .approvedForWorkspace:
            try await sendEvent(
                taskID: request.taskID,
                kind: .approvalResolved,
                message: "Desktop operation approved from iPhone."
            )
            try await execute(request, approvalOverride: true)
        }
    }

    private func updateRequestedState(taskID: UUID, state: DispatchTaskState) async throws {
        guard var task = await graph.task(id: taskID), !task.state.isTerminal else { return }
        task.state = state
        task.updatedAt = Date()
        try await graph.upsert(task)
        try await relay.send(RelayEnvelope(payload: .submit(task)))
    }

    private func fail(_ task: DispatchTask, reason: String) async throws {
        var failed = task
        failed.state = .failed
        failed.updatedAt = Date()
        failed.failureReason = reason
        try await graph.upsert(failed)
        try await relay.send(RelayEnvelope(payload: .submit(failed)))
        try await sendEvent(taskID: failed.id, kind: .stateChanged, message: reason)
    }

    private func sendEvent(taskID: UUID, kind: DispatchEventKind, message: String) async throws {
        let event = DispatchEvent(
            taskID: taskID,
            hostID: configuration.host.id,
            kind: kind,
            message: message
        )
        try await graph.append(event)
        try await relay.send(RelayEnvelope(payload: .event(event)))
    }
}

private actor PendingExecutionStore {
    private var requests: [UUID: DesktopExecutionRequest] = [:]

    func store(_ request: DesktopExecutionRequest, for approvalID: UUID) {
        requests[approvalID] = request
    }

    func take(id: UUID) -> DesktopExecutionRequest? {
        requests.removeValue(forKey: id)
    }
}

enum AgentServiceError: LocalizedError {
    case relayNotConfigured
    case relayTokenMissing

    var errorDescription: String? {
        switch self {
        case .relayNotConfigured: "Configure a relay URL with set-relay before starting the service."
        case .relayTokenMissing: "Set LOCAL_GEMMA_RELAY_TOKEN before starting the service."
        }
    }
}
