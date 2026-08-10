import DispatchCore
import Foundation

struct AppleDeviceController {
    private let runner = ProcessRunner()
    private let policyEngine = ExecutionPolicyEngine()

    func listDevices() throws -> CommandResult {
        try runner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "list", "devices"]
        )
    }

    func build(
        projectPath: String,
        scheme: String,
        destinationID: String,
        derivedDataPath: String,
        policy: ExecutionPolicy,
        approvalOverride: Bool = false
    ) throws -> CommandResult {
        let workspace = URL(fileURLWithPath: projectPath).deletingLastPathComponent().path
        let operation = OperationRequest(
            kind: .xcodeBuild,
            workspacePath: workspace,
            executable: "/usr/bin/xcrun",
            arguments: ["xcodebuild"],
            deviceID: destinationID,
            summary: "Build \(scheme) for Apple device \(destinationID)"
        )
        try requireAllowed(operation, policy: policy, approvalOverride: approvalOverride)
        return try runner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "xcodebuild",
                "-project", projectPath,
                "-scheme", scheme,
                "-configuration", "Debug",
                "-destination", "id=\(destinationID)",
                "-derivedDataPath", derivedDataPath,
                "-allowProvisioningUpdates",
                "build"
            ],
            workingDirectory: workspace
        )
    }

    func install(
        appPath: String,
        coreDeviceID: String,
        workspacePath: String,
        policy: ExecutionPolicy,
        approvalOverride: Bool = false
    ) throws -> CommandResult {
        let operation = OperationRequest(
            kind: .installSignedApp,
            workspacePath: workspacePath,
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "device", "install", "app"],
            deviceID: coreDeviceID,
            summary: "Install signed application \(URL(fileURLWithPath: appPath).lastPathComponent)"
        )
        try requireAllowed(operation, policy: policy, approvalOverride: approvalOverride)
        return try runner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "device", "install", "app", "--device", coreDeviceID, appPath],
            workingDirectory: workspacePath
        )
    }

    func launch(
        bundleID: String,
        coreDeviceID: String,
        workspacePath: String,
        policy: ExecutionPolicy,
        approvalOverride: Bool = false
    ) throws -> CommandResult {
        let operation = OperationRequest(
            kind: .launchSignedApp,
            workspacePath: workspacePath,
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "device", "process", "launch"],
            deviceID: coreDeviceID,
            summary: "Launch \(bundleID)"
        )
        try requireAllowed(operation, policy: policy, approvalOverride: approvalOverride)
        return try runner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "devicectl", "device", "process", "launch",
                "--device", coreDeviceID,
                "--terminate-existing",
                bundleID
            ],
            workingDirectory: workspacePath
        )
    }

    private func requireAllowed(
        _ operation: OperationRequest,
        policy: ExecutionPolicy,
        approvalOverride: Bool
    ) throws {
        switch policyEngine.evaluate(operation, against: policy) {
        case .allow:
            return
        case .requireApproval(let reason):
            if !approvalOverride { throw AgentOperationError.approvalRequired(reason) }
            return
        case .deny(let reason):
            throw AgentOperationError.denied(reason)
        }
    }
}

enum AgentOperationError: LocalizedError {
    case approvalRequired(String)
    case denied(String)

    var errorDescription: String? {
        switch self {
        case .approvalRequired(let reason): "Approval required: \(reason)"
        case .denied(let reason): "Operation denied: \(reason)"
        }
    }
}
