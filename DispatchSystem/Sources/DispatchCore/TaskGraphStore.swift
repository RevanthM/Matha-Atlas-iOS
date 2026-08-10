import Foundation

public actor TaskGraphStore {
    private let fileURL: URL
    private var snapshot: DispatchSnapshot

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshot = try decoder.decode(DispatchSnapshot.self, from: data)
        } else {
            snapshot = DispatchSnapshot()
        }
    }

    public func currentSnapshot() -> DispatchSnapshot { snapshot }

    public func task(id: UUID) -> DispatchTask? {
        snapshot.tasks.first { $0.id == id }
    }

    public func upsert(_ task: DispatchTask) throws {
        snapshot.tasks.removeAll { $0.id == task.id }
        snapshot.tasks.append(task)
        try persist()
    }

    @discardableResult
    public func createRoot(
        title: String,
        prompt: String,
        kind: DispatchTaskKind = .coordinator,
        target: DispatchTarget = .automatic,
        workspacePath: String? = nil,
        capabilities: Set<HostCapability> = []
    ) throws -> DispatchTask {
        let task = DispatchTask(
            title: title,
            prompt: prompt,
            kind: kind,
            target: target,
            workspacePath: workspacePath,
            requiredCapabilities: capabilities
        )
        snapshot.tasks.append(task)
        snapshot.events.append(
            DispatchEvent(taskID: task.id, kind: .taskCreated, message: "Created root task: \(title)")
        )
        try persist()
        return task
    }

    @discardableResult
    public func createChild(
        parentID: UUID,
        title: String,
        prompt: String,
        kind: DispatchTaskKind,
        target: DispatchTarget = .automatic,
        workspacePath: String? = nil,
        capabilities: Set<HostCapability> = [],
        limits: DispatchLimits = DispatchLimits()
    ) throws -> DispatchTask {
        guard let parent = snapshot.tasks.first(where: { $0.id == parentID }) else {
            throw TaskGraphError.parentNotFound
        }
        let rootTasks = snapshot.tasks.filter { $0.rootID == parent.rootID }
        guard parent.depth + 1 <= limits.maximumDepth else { throw TaskGraphError.maximumDepthReached }
        guard rootTasks.count < limits.maximumTotalTasksPerRoot else { throw TaskGraphError.maximumTaskCountReached }

        let child = DispatchTask(
            rootID: parent.rootID,
            parentID: parent.id,
            title: title,
            prompt: prompt,
            kind: kind,
            target: target,
            workspacePath: workspacePath ?? parent.workspacePath,
            requiredCapabilities: capabilities,
            depth: parent.depth + 1
        )
        snapshot.tasks.append(child)
        snapshot.events.append(
            DispatchEvent(taskID: child.id, kind: .taskCreated, message: "Created child task: \(title)")
        )
        try persist()
        return child
    }

    public func transition(
        taskID: UUID,
        to newState: DispatchTaskState,
        result: DispatchTaskResult? = nil,
        failureReason: String? = nil
    ) throws {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw TaskGraphError.taskNotFound
        }
        let oldState = snapshot.tasks[index].state
        guard Self.validTransitions[oldState, default: []].contains(newState) else {
            throw TaskGraphError.invalidTransition(from: oldState, to: newState)
        }
        snapshot.tasks[index].state = newState
        snapshot.tasks[index].updatedAt = Date()
        snapshot.tasks[index].result = result
        snapshot.tasks[index].failureReason = failureReason
        snapshot.events.append(
            DispatchEvent(
                taskID: taskID,
                kind: .stateChanged,
                message: "Task changed from \(oldState.rawValue) to \(newState.rawValue)."
            )
        )
        try persist()
    }

    public func append(_ event: DispatchEvent) throws {
        snapshot.events.append(event)
        if snapshot.events.count > 10_000 {
            snapshot.events.removeFirst(snapshot.events.count - 10_000)
        }
        try persist()
    }

    public func readyTasks(for host: DispatchHost, limits: DispatchLimits = DispatchLimits()) -> [DispatchTask] {
        let activeByRoot = Dictionary(grouping: snapshot.tasks.filter { $0.state == .running }, by: \.rootID)
        return snapshot.tasks.filter { task in
            guard task.state == .queued,
                  task.requiredCapabilities.isSubset(of: host.capabilities),
                  activeByRoot[task.rootID, default: []].count < limits.maximumActiveTasksPerRoot else {
                return false
            }
            return task.dependencyIDs.allSatisfy { dependencyID in
                snapshot.tasks.first(where: { $0.id == dependencyID })?.state == .succeeded
            }
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    private static let validTransitions: [DispatchTaskState: Set<DispatchTaskState>] = [
        .queued: [.running, .paused, .cancelled, .awaitingApproval],
        .running: [.succeeded, .failed, .paused, .cancelled, .awaitingApproval],
        .awaitingApproval: [.queued, .running, .cancelled, .failed],
        .paused: [.queued, .running, .cancelled],
        .succeeded: [],
        .failed: [.queued],
        .cancelled: [.queued]
    ]
}

public enum TaskGraphError: LocalizedError, Equatable {
    case parentNotFound
    case taskNotFound
    case maximumDepthReached
    case maximumTaskCountReached
    case invalidTransition(from: DispatchTaskState, to: DispatchTaskState)

    public var errorDescription: String? {
        switch self {
        case .parentNotFound: "The parent task does not exist."
        case .taskNotFound: "The task does not exist."
        case .maximumDepthReached: "This task would exceed the configured recursive depth limit."
        case .maximumTaskCountReached: "This root task has reached its configured total-task limit."
        case .invalidTransition(let from, let to): "A task cannot move from \(from.rawValue) to \(to.rawValue)."
        }
    }
}
