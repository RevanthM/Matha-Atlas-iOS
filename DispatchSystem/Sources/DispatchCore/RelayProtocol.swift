import Foundation

public let localGemmaDispatchProtocolVersion = 1

public enum ApprovalResolution: String, Codable, Sendable {
    case approvedOnce
    case approvedForWorkspace
    case denied
}

public struct ApprovalRequest: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let operation: OperationRequest
    public let reason: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        operation: OperationRequest,
        reason: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.operation = operation
        self.reason = reason
        self.createdAt = createdAt
    }
}

public struct AgentRunRequest: Codable, Equatable, Sendable {
    public var workspacePath: String
    public var prompt: String

    public init(workspacePath: String, prompt: String) {
        self.workspacePath = workspacePath
        self.prompt = prompt
    }
}

public struct XcodeBuildRequest: Codable, Equatable, Sendable {
    public var projectPath: String
    public var scheme: String
    public var destinationID: String
    public var derivedDataPath: String

    public init(projectPath: String, scheme: String, destinationID: String, derivedDataPath: String) {
        self.projectPath = projectPath
        self.scheme = scheme
        self.destinationID = destinationID
        self.derivedDataPath = derivedDataPath
    }
}

public struct DeviceInstallRequest: Codable, Equatable, Sendable {
    public var appPath: String
    public var coreDeviceID: String
    public var workspacePath: String

    public init(appPath: String, coreDeviceID: String, workspacePath: String) {
        self.appPath = appPath
        self.coreDeviceID = coreDeviceID
        self.workspacePath = workspacePath
    }
}

public struct DeviceLaunchRequest: Codable, Equatable, Sendable {
    public var bundleID: String
    public var coreDeviceID: String
    public var workspacePath: String

    public init(bundleID: String, coreDeviceID: String, workspacePath: String) {
        self.bundleID = bundleID
        self.coreDeviceID = coreDeviceID
        self.workspacePath = workspacePath
    }
}

public enum DesktopAction: Codable, Equatable, Sendable {
    case runAgent(AgentRunRequest)
    case xcodeBuild(XcodeBuildRequest)
    case listAppleDevices
    case installApp(DeviceInstallRequest)
    case launchApp(DeviceLaunchRequest)
}

public struct DesktopExecutionRequest: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let action: DesktopAction

    public init(id: UUID = UUID(), taskID: UUID, action: DesktopAction) {
        self.id = id
        self.taskID = taskID
        self.action = action
    }
}

public enum RelayPayload: Codable, Equatable, Sendable {
    case hello(DispatchHost)
    case heartbeat(DispatchHost)
    case submit(DispatchTask)
    case event(DispatchEvent)
    case snapshot(DispatchSnapshot)
    case approvalRequest(ApprovalRequest)
    case approvalResponse(id: UUID, resolution: ApprovalResolution)
    case execute(DesktopExecutionRequest)
    case cancel(taskID: UUID)
    case pause(taskID: UUID)
    case resume(taskID: UUID)

    private enum CodingKeys: String, CodingKey { case type, value, id, resolution }
    private enum PayloadType: String, Codable {
        case hello, heartbeat, submit, event, snapshot, approvalRequest, approvalResponse, execute, cancel, pause, resume
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PayloadType.self, forKey: .type) {
        case .hello: self = .hello(try container.decode(DispatchHost.self, forKey: .value))
        case .heartbeat: self = .heartbeat(try container.decode(DispatchHost.self, forKey: .value))
        case .submit: self = .submit(try container.decode(DispatchTask.self, forKey: .value))
        case .event: self = .event(try container.decode(DispatchEvent.self, forKey: .value))
        case .snapshot: self = .snapshot(try container.decode(DispatchSnapshot.self, forKey: .value))
        case .approvalRequest: self = .approvalRequest(try container.decode(ApprovalRequest.self, forKey: .value))
        case .approvalResponse:
            self = .approvalResponse(
                id: try container.decode(UUID.self, forKey: .id),
                resolution: try container.decode(ApprovalResolution.self, forKey: .resolution)
            )
        case .execute: self = .execute(try container.decode(DesktopExecutionRequest.self, forKey: .value))
        case .cancel: self = .cancel(taskID: try container.decode(UUID.self, forKey: .id))
        case .pause: self = .pause(taskID: try container.decode(UUID.self, forKey: .id))
        case .resume: self = .resume(taskID: try container.decode(UUID.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let value):
            try container.encode(PayloadType.hello, forKey: .type)
            try container.encode(value, forKey: .value)
        case .heartbeat(let value):
            try container.encode(PayloadType.heartbeat, forKey: .type)
            try container.encode(value, forKey: .value)
        case .submit(let value):
            try container.encode(PayloadType.submit, forKey: .type)
            try container.encode(value, forKey: .value)
        case .event(let value):
            try container.encode(PayloadType.event, forKey: .type)
            try container.encode(value, forKey: .value)
        case .snapshot(let value):
            try container.encode(PayloadType.snapshot, forKey: .type)
            try container.encode(value, forKey: .value)
        case .approvalRequest(let value):
            try container.encode(PayloadType.approvalRequest, forKey: .type)
            try container.encode(value, forKey: .value)
        case .approvalResponse(let id, let resolution):
            try container.encode(PayloadType.approvalResponse, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(resolution, forKey: .resolution)
        case .execute(let value):
            try container.encode(PayloadType.execute, forKey: .type)
            try container.encode(value, forKey: .value)
        case .cancel(let id):
            try container.encode(PayloadType.cancel, forKey: .type)
            try container.encode(id, forKey: .id)
        case .pause(let id):
            try container.encode(PayloadType.pause, forKey: .type)
            try container.encode(id, forKey: .id)
        case .resume(let id):
            try container.encode(PayloadType.resume, forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }
}

public struct RelayEnvelope: Identifiable, Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let sentAt: Date
    public let payload: RelayPayload

    public init(
        protocolVersion: Int = localGemmaDispatchProtocolVersion,
        id: UUID = UUID(),
        sentAt: Date = Date(),
        payload: RelayPayload
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.sentAt = sentAt
        self.payload = payload
    }
}
