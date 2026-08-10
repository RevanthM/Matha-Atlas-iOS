import DispatchCore
import Darwin
import Foundation

@main
struct LocalGemmaAgentCommand {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        var configuration = try AgentConfiguration.load(from: AgentPaths.configuration)
        guard let command = arguments.first else {
            printHelp()
            return
        }

        switch command {
        case "doctor":
            try doctor(configuration: configuration)
        case "status":
            try printJSON(configuration)
        case "approve-workspace":
            guard arguments.count == 2 else { throw CLIError.usage("approve-workspace <absolute-path>") }
            let path = URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) else { throw CLIError.missingPath(path) }
            if !configuration.approvedWorkspaceRoots.contains(path) {
                configuration.approvedWorkspaceRoots.append(path)
            }
            try configuration.save(to: AgentPaths.configuration)
            print("Approved workspace: \(path)")
        case "approve-device":
            guard arguments.count == 2 else { throw CLIError.usage("approve-device <CoreDevice-identifier>") }
            configuration.approvedDeviceIDs.insert(arguments[1])
            try configuration.save(to: AgentPaths.configuration)
            print("Approved Apple device: \(arguments[1])")
        case "set-relay":
            guard arguments.count == 2, let url = URL(string: arguments[1]),
                  ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") else {
                throw CLIError.usage("set-relay <ws-or-wss-url>")
            }
            configuration.relayURL = url
            try configuration.save(to: AgentPaths.configuration)
            print("Configured relay: \(url.absoluteString)")
        case "serve":
            guard let token = ProcessInfo.processInfo.environment["LOCAL_GEMMA_RELAY_TOKEN"],
                  !token.isEmpty else { throw AgentServiceError.relayTokenMissing }
            let graph = try TaskGraphStore(fileURL: AgentPaths.taskGraph)
            print("Connecting desktop agent to \(configuration.relayURL?.absoluteString ?? "unconfigured relay")")
            try await AgentService(
                configuration: configuration,
                graph: graph,
                relay: RelayClient()
            ).run(bearerToken: token)
        case "submit":
            guard arguments.count >= 2 else { throw CLIError.usage("submit <prompt>") }
            guard let token = ProcessInfo.processInfo.environment["LOCAL_GEMMA_RELAY_TOKEN"],
                  !token.isEmpty else { throw AgentServiceError.relayTokenMissing }
            guard let relayURL = configuration.relayURL else { throw AgentServiceError.relayNotConfigured }
            let workspace = configuration.approvedWorkspaceRoots.first
            let task = DispatchTask(
                title: String(arguments.dropFirst().joined(separator: " ").prefix(64)),
                prompt: arguments.dropFirst().joined(separator: " "),
                kind: .coordinator,
                target: .desktop,
                workspacePath: workspace,
                requiredCapabilities: [.repository, .shell]
            )
            let client = RelayClient()
            let clientHost = DispatchHost(
                name: "Local CLI client",
                platform: "macOS",
                capabilities: []
            )
            try await client.connect(to: relayURL, host: clientHost, bearerToken: token)
            try await client.send(RelayEnvelope(payload: .submit(task)))
            print("Submitted task \(task.id). Waiting for the desktop agent…")
            while true {
                let envelope = try await client.receive()
                switch envelope.payload {
                case .event(let event) where event.taskID == task.id:
                    print("[\(event.kind.rawValue)] \(event.message)")
                case .submit(let updated) where updated.id == task.id && updated.state.isTerminal:
                    print("Task finished: \(updated.state.rawValue)")
                    if let reason = updated.failureReason { print(reason) }
                    return
                default:
                    continue
                }
            }
        case "devices":
            let result = try AppleDeviceController().listDevices()
            print(result.output, terminator: result.output.hasSuffix("\n") ? "" : "\n")
            if result.exitCode != 0 { throw CLIError.commandFailed(result.exitCode) }
        case "create-task":
            guard arguments.count >= 3 else { throw CLIError.usage("create-task <title> <prompt>") }
            let store = try TaskGraphStore(fileURL: AgentPaths.taskGraph)
            let task = try await store.createRoot(
                title: arguments[1],
                prompt: arguments.dropFirst(2).joined(separator: " ")
            )
            try printJSON(task)
        case "tasks":
            let store = try TaskGraphStore(fileURL: AgentPaths.taskGraph)
            try printJSON(await store.currentSnapshot())
        case "help", "--help", "-h":
            printHelp()
        default:
            throw CLIError.usage("Unknown command: \(command)")
        }
    }

    private static func doctor(configuration: AgentConfiguration) throws {
        let runner = ProcessRunner()
        let xcode = try runner.run(executable: "/usr/bin/xcode-select", arguments: ["-p"])
        let swift = try runner.run(executable: "/usr/bin/xcrun", arguments: ["swift", "--version"])
        let devices = try AppleDeviceController().listDevices()
        print("Host: \(configuration.host.name) [\(configuration.host.id)]")
        print("Xcode: \(xcode.exitCode == 0 ? xcode.output.trimmingCharacters(in: .whitespacesAndNewlines) : "unavailable")")
        print("Swift: \(swift.exitCode == 0 ? swift.output.split(separator: "\n").first.map(String.init) ?? "available" : "unavailable")")
        print("Approved workspaces: \(configuration.approvedWorkspaceRoots.count)")
        print("Approved devices: \(configuration.approvedDeviceIDs.count)")
        print("Device services: \(devices.exitCode == 0 ? "available" : "unavailable")")
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    private static func printHelp() {
        print(
            """
            local-gemma-agent

              doctor                              Check Xcode and Apple device services
              status                              Print host configuration
              approve-workspace <absolute-path>   Allow operations in a workspace
              approve-device <CoreDevice-ID>      Allow install/launch on a paired device
              set-relay <ws-or-wss-url>           Configure the outbound relay room URL
              serve                               Run the persistent relay execution loop
              submit <prompt>                     Submit a desktop mission through the relay
              devices                             List devices visible to CoreDevice
              create-task <title> <prompt>         Persist a root dispatch task
              tasks                               Print the persistent task graph and event log
            """
        )
    }
}

enum CLIError: LocalizedError {
    case usage(String)
    case missingPath(String)
    case commandFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .usage(let detail): detail
        case .missingPath(let path): "Path does not exist: \(path)"
        case .commandFailed(let code): "Command exited with status \(code)."
        }
    }
}
