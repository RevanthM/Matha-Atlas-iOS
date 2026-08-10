import Foundation

struct CommandResult: Codable {
    let executable: String
    let arguments: [String]
    let exitCode: Int32
    let output: String
    let durationSeconds: TimeInterval
}

enum ProcessRunnerError: LocalizedError {
    case executableNotAbsolute
    case workingDirectoryMissing(String)

    var errorDescription: String? {
        switch self {
        case .executableNotAbsolute: "Executables must be provided as absolute paths."
        case .workingDirectoryMissing(let path): "The working directory does not exist: \(path)"
        }
    }
}

struct ProcessRunner {
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) throws -> CommandResult {
        guard executable.hasPrefix("/") else { throw ProcessRunnerError.executableNotAbsolute }
        if let workingDirectory,
           !FileManager.default.fileExists(atPath: workingDirectory) {
            throw ProcessRunnerError.workingDirectoryMissing(workingDirectory)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment.removeValue(forKey: "LOCAL_GEMMA_RELAY_TOKEN")
        childEnvironment.removeValue(forKey: "PAIRING_SECRET")
        process.environment = childEnvironment.merging(environment) { _, requested in requested }

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let startedAt = Date()
        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            executable: executable,
            arguments: arguments,
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            durationSeconds: Date().timeIntervalSince(startedAt)
        )
    }
}
