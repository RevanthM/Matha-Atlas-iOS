import DispatchCore
import Foundation

struct AgentConfiguration: Codable {
    var host: DispatchHost
    var approvedWorkspaceRoots: [String]
    var approvedDeviceIDs: Set<String>
    var relayURL: URL?

    static func load(from url: URL) throws -> AgentConfiguration {
        if FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AgentConfiguration.self, from: Data(contentsOf: url))
        }

        let configuration = AgentConfiguration(
            host: DispatchHost(
                name: Host.current().localizedName ?? "Mac",
                platform: "macOS",
                capabilities: [.repository, .shell, .xcode, .appleDevice]
            ),
            approvedWorkspaceRoots: [],
            approvedDeviceIDs: [],
            relayURL: nil
        )
        try configuration.save(to: url)
        return configuration
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    var executionPolicy: ExecutionPolicy {
        ExecutionPolicy(
            approvedWorkspaceRoots: approvedWorkspaceRoots,
            approvedDeviceIDs: approvedDeviceIDs
        )
    }
}

enum AgentPaths {
    static let supportDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("LocalGemmaDispatch", isDirectory: true)

    static let configuration = supportDirectory.appendingPathComponent("AgentConfiguration.json")
    static let taskGraph = supportDirectory.appendingPathComponent("TaskGraph.json")
}
