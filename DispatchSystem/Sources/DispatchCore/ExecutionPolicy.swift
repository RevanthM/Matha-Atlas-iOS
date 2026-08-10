import Foundation

public enum OperationKind: String, Codable, Sendable {
    case readWorkspace
    case writeWorkspace
    case executeProcess
    case gitCommit
    case gitPush
    case xcodeBuild
    case installSignedApp
    case launchSignedApp
    case destructive
    case externalMessage
    case secretAccess
}

public struct OperationRequest: Codable, Equatable, Sendable {
    public var kind: OperationKind
    public var workspacePath: String?
    public var executable: String?
    public var arguments: [String]
    public var deviceID: String?
    public var summary: String

    public init(
        kind: OperationKind,
        workspacePath: String? = nil,
        executable: String? = nil,
        arguments: [String] = [],
        deviceID: String? = nil,
        summary: String
    ) {
        self.kind = kind
        self.workspacePath = workspacePath
        self.executable = executable
        self.arguments = arguments
        self.deviceID = deviceID
        self.summary = summary
    }
}

public struct ExecutionPolicy: Codable, Equatable, Sendable {
    public var approvedWorkspaceRoots: [String]
    public var approvedDeviceIDs: Set<String>
    public var automaticallyAllowedOperations: Set<OperationKind>
    public var automaticallyAllowedExecutables: Set<String>

    public init(
        approvedWorkspaceRoots: [String],
        approvedDeviceIDs: Set<String> = [],
        automaticallyAllowedOperations: Set<OperationKind> = [
            .readWorkspace, .writeWorkspace, .executeProcess, .xcodeBuild, .launchSignedApp
        ],
        automaticallyAllowedExecutables: Set<String> = [
            "/usr/bin/git", "/usr/bin/xcrun", "/usr/bin/xcodebuild", "/usr/bin/swift",
            "/Applications/ChatGPT.app/Contents/Resources/codex"
        ]
    ) {
        self.approvedWorkspaceRoots = approvedWorkspaceRoots
        self.approvedDeviceIDs = approvedDeviceIDs
        self.automaticallyAllowedOperations = automaticallyAllowedOperations
        self.automaticallyAllowedExecutables = automaticallyAllowedExecutables
    }
}

public enum PolicyDecision: Equatable, Sendable {
    case allow
    case requireApproval(String)
    case deny(String)
}

public struct ExecutionPolicyEngine: Sendable {
    public init() {}

    public func evaluate(_ request: OperationRequest, against policy: ExecutionPolicy) -> PolicyDecision {
        switch request.kind {
        case .destructive, .externalMessage, .secretAccess:
            return .requireApproval("This operation is consequential and cannot be silently pre-approved.")
        default:
            break
        }

        if let workspace = request.workspacePath,
           !WorkspaceScope.isPath(workspace, insideAnyOf: policy.approvedWorkspaceRoots) {
            return .deny("The requested path is outside every approved workspace root.")
        }

        if request.kind == .installSignedApp || request.kind == .launchSignedApp,
           let deviceID = request.deviceID,
           !policy.approvedDeviceIDs.contains(deviceID) {
            return .requireApproval("The Apple device has not been approved for remote deployment.")
        }

        if request.kind == .executeProcess,
           let executable = request.executable,
           !policy.automaticallyAllowedExecutables.contains(executable) {
            return .requireApproval("The executable is not in this workspace's automatic allowlist.")
        }

        if policy.automaticallyAllowedOperations.contains(request.kind) {
            return .allow
        }
        return .requireApproval("The operation is not covered by an automatic workspace policy.")
    }
}

public enum WorkspaceScope {
    public static func isPath(_ candidate: String, insideAnyOf roots: [String]) -> Bool {
        let candidateURL = URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath()
        return roots.contains { root in
            let rootURL = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
            if candidateURL == rootURL { return true }
            let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            return candidateURL.path.hasPrefix(prefix)
        }
    }
}
