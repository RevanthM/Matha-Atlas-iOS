import Foundation

public enum DispatchTaskKind: String, Codable, CaseIterable, Sendable {
    case coordinator
    case code
    case research
    case document
    case device
    case terminal
}

public enum DispatchTarget: String, Codable, Sendable {
    case cloud
    case desktop
    case connectedAppleDevice
    case automatic
}

public enum DispatchTaskState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case awaitingApproval
    case paused
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        default: false
        }
    }
}

public enum HostCapability: String, Codable, Hashable, Sendable {
    case repository
    case shell
    case xcode
    case appleDevice
    case browser
    case computerUse
}

public struct DispatchTaskResult: Codable, Equatable, Sendable {
    public var summary: String
    public var artifactPaths: [String]
    public var exitCode: Int32?

    public init(summary: String, artifactPaths: [String] = [], exitCode: Int32? = nil) {
        self.summary = summary
        self.artifactPaths = artifactPaths
        self.exitCode = exitCode
    }
}

public struct DispatchTask: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let rootID: UUID
    public let parentID: UUID?
    public var title: String
    public var prompt: String
    public var kind: DispatchTaskKind
    public var target: DispatchTarget
    public var state: DispatchTaskState
    public var workspacePath: String?
    public var requiredCapabilities: Set<HostCapability>
    public var dependencyIDs: [UUID]
    public var depth: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var result: DispatchTaskResult?
    public var failureReason: String?

    public init(
        id: UUID = UUID(),
        rootID: UUID? = nil,
        parentID: UUID? = nil,
        title: String,
        prompt: String,
        kind: DispatchTaskKind,
        target: DispatchTarget = .automatic,
        state: DispatchTaskState = .queued,
        workspacePath: String? = nil,
        requiredCapabilities: Set<HostCapability> = [],
        dependencyIDs: [UUID] = [],
        depth: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        result: DispatchTaskResult? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.rootID = rootID ?? id
        self.parentID = parentID
        self.title = title
        self.prompt = prompt
        self.kind = kind
        self.target = target
        self.state = state
        self.workspacePath = workspacePath
        self.requiredCapabilities = requiredCapabilities
        self.dependencyIDs = dependencyIDs
        self.depth = depth
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.result = result
        self.failureReason = failureReason
    }
}

public struct DispatchLimits: Codable, Equatable, Sendable {
    public var maximumDepth: Int
    public var maximumTotalTasksPerRoot: Int
    public var maximumActiveTasksPerRoot: Int
    public var maximumRuntimeSeconds: TimeInterval

    public init(
        maximumDepth: Int = 4,
        maximumTotalTasksPerRoot: Int = 30,
        maximumActiveTasksPerRoot: Int = 6,
        maximumRuntimeSeconds: TimeInterval = 14_400
    ) {
        self.maximumDepth = maximumDepth
        self.maximumTotalTasksPerRoot = maximumTotalTasksPerRoot
        self.maximumActiveTasksPerRoot = maximumActiveTasksPerRoot
        self.maximumRuntimeSeconds = maximumRuntimeSeconds
    }
}

public struct DispatchHost: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var platform: String
    public var capabilities: Set<HostCapability>
    public var lastSeenAt: Date
    public var isOnline: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        platform: String,
        capabilities: Set<HostCapability>,
        lastSeenAt: Date = Date(),
        isOnline: Bool = true
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.capabilities = capabilities
        self.lastSeenAt = lastSeenAt
        self.isOnline = isOnline
    }
}

public enum DispatchEventKind: String, Codable, Sendable {
    case taskCreated
    case stateChanged
    case output
    case approvalRequested
    case approvalResolved
    case artifactProduced
    case hostConnected
    case hostDisconnected
}

public struct DispatchEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID?
    public let hostID: UUID?
    public let kind: DispatchEventKind
    public let message: String
    public let createdAt: Date
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        taskID: UUID? = nil,
        hostID: UUID? = nil,
        kind: DispatchEventKind,
        message: String,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.taskID = taskID
        self.hostID = hostID
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public struct DispatchSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var tasks: [DispatchTask]
    public var events: [DispatchEvent]

    public init(schemaVersion: Int = 1, tasks: [DispatchTask] = [], events: [DispatchEvent] = []) {
        self.schemaVersion = schemaVersion
        self.tasks = tasks
        self.events = events
    }
}
