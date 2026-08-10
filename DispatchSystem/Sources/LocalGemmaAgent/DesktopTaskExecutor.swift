import DispatchCore
import Foundation

struct DesktopTaskExecutor {
    private let runner = ProcessRunner()
    private let devices = AppleDeviceController()
    private let policyEngine = ExecutionPolicyEngine()

    func execute(
        _ request: DesktopExecutionRequest,
        policy: ExecutionPolicy,
        approvalOverride: Bool = false
    ) throws -> CommandResult {
        switch request.action {
        case .runAgent(let action):
            return try runAgent(action, policy: policy, approvalOverride: approvalOverride)
        case .xcodeBuild(let action):
            return try devices.build(
                projectPath: action.projectPath,
                scheme: action.scheme,
                destinationID: action.destinationID,
                derivedDataPath: action.derivedDataPath,
                policy: policy,
                approvalOverride: approvalOverride
            )
        case .listAppleDevices:
            return try devices.listDevices()
        case .installApp(let action):
            return try devices.install(
                appPath: action.appPath,
                coreDeviceID: action.coreDeviceID,
                workspacePath: action.workspacePath,
                policy: policy,
                approvalOverride: approvalOverride
            )
        case .launchApp(let action):
            return try devices.launch(
                bundleID: action.bundleID,
                coreDeviceID: action.coreDeviceID,
                workspacePath: action.workspacePath,
                policy: policy,
                approvalOverride: approvalOverride
            )
        }
    }

    private func runAgent(
        _ action: AgentRunRequest,
        policy: ExecutionPolicy,
        approvalOverride: Bool
    ) throws -> CommandResult {
        let codex = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let operation = OperationRequest(
            kind: .executeProcess,
            workspacePath: action.workspacePath,
            executable: codex,
            arguments: ["exec"],
            summary: "Run an isolated coding agent in the approved workspace"
        )
        switch policyEngine.evaluate(operation, against: policy) {
        case .allow:
            break
        case .requireApproval(let reason):
            if !approvalOverride { throw AgentOperationError.approvalRequired(reason) }
        case .deny(let reason):
            throw AgentOperationError.denied(reason)
        }

        let result = try runner.run(
            executable: codex,
            arguments: [
                "exec",
                "--json",
                "--sandbox", "workspace-write",
                "--cd", action.workspacePath,
                "--skip-git-repo-check",
                action.prompt
            ],
            workingDirectory: action.workspacePath
        )
        return CommandResult(
            executable: result.executable,
            arguments: result.arguments,
            exitCode: result.exitCode,
            output: Self.userFacingCodexOutput(from: result.output),
            durationSeconds: result.durationSeconds
        )
    }

    private static func userFacingCodexOutput(from raw: String) -> String {
        var entries: [String] = []
        for line in raw.split(separator: "\n") {
            guard line.first == "{",
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "item.completed",
                  let item = object["item"] as? [String: Any],
                  let type = item["type"] as? String else { continue }

            if type == "agent_message", let text = item["text"] as? String, !text.isEmpty {
                entries.append(text)
            } else if type == "command_execution",
                      let output = item["aggregated_output"] as? String,
                      !output.isEmpty {
                entries.append(output)
            } else if type == "error", let message = item["message"] as? String, !message.isEmpty {
                entries.append("Agent warning: \(message)")
            }
        }
        let cleaned = entries.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? String(raw.suffix(20_000)) : cleaned
    }
}
