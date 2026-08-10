import Foundation
import EventKit
import LiteRTLM

enum LocalToolPermissionPolicy: String, Codable, Equatable {
    case automaticReadOnly
    case requiresConfirmation

    var title: String {
        switch self {
        case .automaticReadOnly: "Automatic · Read only"
        case .requiresConfirmation: "Asks before changes"
        }
    }

    var symbol: String {
        switch self {
        case .automaticReadOnly: "checkmark.shield"
        case .requiresConfirmation: "hand.raised"
        }
    }
}

struct LocalToolDescriptor: Identifiable, Equatable {
    let name: String
    let title: String
    let detail: String
    let symbol: String
    let permissionPolicy: LocalToolPermissionPolicy

    var id: String { name }
}

enum LocalToolCatalog {
    static func tools(includeKnowledge: Bool) -> [Tool] {
        var tools: [Tool] = [
            GetCurrentDateTimeTool(),
            CalculateTool(),
            CreateReminderTool(),
            ListMCPToolsTool(),
            CallMCPTool()
        ]
        if includeKnowledge {
            tools.append(ListPrivateKnowledgeTool())
            tools.append(SearchPrivateKnowledgeTool())
        }
        return tools
    }

    static func descriptors(includeKnowledge: Bool) -> [LocalToolDescriptor] {
        var descriptors = [
            LocalToolDescriptor(
                name: GetCurrentDateTimeTool.name,
                title: "Current date and time",
                detail: "Returns the device's current date, time, and time zone.",
                symbol: "clock",
                permissionPolicy: .automaticReadOnly
            ),
            LocalToolDescriptor(
                name: CalculateTool.name,
                title: "Safe calculator",
                detail: "Evaluates arithmetic locally without executing code.",
                symbol: "function",
                permissionPolicy: .automaticReadOnly
            ),
            LocalToolDescriptor(
                name: CreateReminderTool.name,
                title: "Create reminder",
                detail: "Creates an Apple Reminder only after you approve the exact action.",
                symbol: "checklist",
                permissionPolicy: .requiresConfirmation
            ),
            LocalToolDescriptor(
                name: ListMCPToolsTool.name,
                title: "List connected MCP tools",
                detail: "Reads the cached tool catalog for enabled MCP servers.",
                symbol: "server.rack",
                permissionPolicy: .automaticReadOnly
            ),
            LocalToolDescriptor(
                name: CallMCPTool.name,
                title: "Call MCP tool",
                detail: "Sends approved arguments to a connected MCP server. Every call asks first.",
                symbol: "network",
                permissionPolicy: .requiresConfirmation
            )
        ]
        if includeKnowledge {
            descriptors.append(
                LocalToolDescriptor(
                    name: ListPrivateKnowledgeTool.name,
                    title: "List private knowledge",
                    detail: "Lists the files indexed in the on-device knowledge library.",
                    symbol: "books.vertical",
                    permissionPolicy: .automaticReadOnly
                )
            )
            descriptors.append(
                LocalToolDescriptor(
                    name: SearchPrivateKnowledgeTool.name,
                    title: "Search private knowledge",
                    detail: "Runs semantic search over locally indexed files.",
                    symbol: "doc.text.magnifyingglass",
                    permissionPolicy: .automaticReadOnly
                )
            )
        }
        return descriptors
    }
}

enum ToolActivityOutcome: String, Codable, Equatable {
    case running
    case succeeded
    case denied
    case failed

    var title: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Completed"
        case .denied: "Not allowed"
        case .failed: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .running: "ellipsis.circle"
        case .succeeded: "checkmark.circle.fill"
        case .denied: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct ToolActivityRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let toolName: String
    let title: String
    let startedAt: Date
    var completedAt: Date?
    var outcome: ToolActivityOutcome

    var duration: TimeInterval? {
        completedAt?.timeIntervalSince(startedAt)
    }
}

@MainActor
final class ToolActivityStore: ObservableObject {
    static let shared = ToolActivityStore()

    @Published private(set) var records: [ToolActivityRecord]

    private let defaultsKey = "localGemma.toolActivity.v1"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ToolActivityRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded.map { record in
            guard record.outcome == .running else { return record }
            var recovered = record
            recovered.completedAt = Date()
            recovered.outcome = .failed
            return recovered
        }
    }

    func begin(toolName: String, title: String) -> UUID {
        let id = UUID()
        records.insert(
            ToolActivityRecord(
                id: id,
                toolName: toolName,
                title: title,
                startedAt: Date(),
                completedAt: nil,
                outcome: .running
            ),
            at: 0
        )
        records = Array(records.prefix(50))
        persist()
        return id
    }

    func finish(_ id: UUID, outcome: ToolActivityOutcome) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].completedAt = Date()
        records[index].outcome = outcome
        persist()
    }

    func clear() {
        records.removeAll { $0.outcome != .running }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

struct ToolConfirmationRequest: Identifiable, Equatable {
    let id: UUID
    let toolName: String
    let title: String
    let message: String
    let approveLabel: String
}

@MainActor
final class ToolAuthorizationCenter: ObservableObject {
    static let shared = ToolAuthorizationCenter()

    @Published private(set) var pendingRequest: ToolConfirmationRequest?
    private var continuation: CheckedContinuation<Bool, Never>?

    private init() {}

    func request(
        toolName: String,
        title: String,
        message: String,
        approveLabel: String
    ) async -> Bool {
        guard pendingRequest == nil, continuation == nil else { return false }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            pendingRequest = ToolConfirmationRequest(
                id: UUID(),
                toolName: toolName,
                title: title,
                message: message,
                approveLabel: approveLabel
            )
        }
    }

    func resolve(allowed: Bool) {
        let pendingContinuation = continuation
        continuation = nil
        pendingRequest = nil
        pendingContinuation?.resume(returning: allowed)
    }

    func cancelPending() {
        resolve(allowed: false)
    }
}

private enum LocalToolControlError: LocalizedError {
    case denied

    var errorDescription: String? {
        "The user did not approve this action."
    }
}

private enum LocalToolRunner {
    static func execute(
        name: String,
        title: String,
        operation: () async throws -> Any
    ) async -> Any {
        let activityID = await ToolActivityStore.shared.begin(toolName: name, title: title)
        do {
            let result = try await operation()
            await ToolActivityStore.shared.finish(activityID, outcome: .succeeded)
            return result
        } catch LocalToolControlError.denied {
            await ToolActivityStore.shared.finish(activityID, outcome: .denied)
            return ["status": "denied", "message": "The user did not approve this action."]
        } catch {
            await ToolActivityStore.shared.finish(activityID, outcome: .failed)
            return ["status": "failed", "error": error.localizedDescription]
        }
    }
}

struct GetCurrentDateTimeTool: Tool {
    static let name = "get_current_date_time"
    static let description = "Get the current date, time, calendar, and time zone from this iPhone. Use this instead of guessing the current time or date."

    init() {}

    func run() async throws -> Any {
        await LocalToolRunner.execute(name: Self.name, title: "Read current date and time") {
            let now = Date()
            let timeZone = TimeZone.current
            let calendar = Calendar.current
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = timeZone

            return [
                "iso_8601": formatter.string(from: now),
                "localized": now.formatted(date: .complete, time: .complete),
                "time_zone_identifier": timeZone.identifier,
                "time_zone_abbreviation": timeZone.abbreviation(for: now) ?? "",
                "calendar_identifier": String(describing: calendar.identifier)
            ]
        }
    }
}

struct CalculateTool: Tool {
    static let name = "calculate"
    static let description = "Safely evaluate a mathematical expression on device. Supports parentheses, +, -, *, /, %, ^, pi, e, and common functions such as sqrt, abs, sin, cos, tan, log, ln, exp, min, and max."

    @ToolParam(description: "The arithmetic expression to evaluate, for example (18.5 * 4) + sqrt(81).")
    var expression: String

    init() {}

    func run() async throws -> Any {
        await LocalToolRunner.execute(name: Self.name, title: "Calculate expression") {
            guard expression.count <= 500 else {
                throw LocalCalculationError.expressionTooLong
            }
            var parser = LocalCalculationParser(expression)
            let result = try parser.parse()
            guard result.isFinite else { throw LocalCalculationError.nonFiniteResult }

            return [
                "expression": expression,
                "result": result,
                "formatted_result": result.formatted(.number.precision(.fractionLength(0...12)))
            ]
        }
    }
}

struct CreateReminderTool: Tool {
    static let name = "create_reminder"
    static let description = "Create an item in Apple Reminders on this iPhone. This tool always displays a confirmation containing the exact reminder before making any change."

    @ToolParam(description: "The concise reminder title.")
    var title: String

    @ToolParam(description: "Optional additional notes for the reminder.")
    var notes: String?

    @ToolParam(description: "Optional due date in ISO 8601 form, including a time zone when a time is specified. Example: 2026-08-10T09:00:00-07:00.")
    var dueDateISO8601: String?

    init() {}

    func run() async throws -> Any {
        await LocalToolRunner.execute(name: Self.name, title: "Create Apple Reminder") {
            let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTitle.isEmpty else { throw ReminderToolError.emptyTitle }

            let dueDate = try parseDueDate(dueDateISO8601)
            var confirmationLines = ["Title: \(cleanedTitle)"]
            if let dueDate {
                confirmationLines.append("Due: \(dueDate.formatted(date: .abbreviated, time: .shortened))")
            }
            if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                confirmationLines.append("Notes will be included.")
            }

            let approved = await ToolAuthorizationCenter.shared.request(
                toolName: Self.name,
                title: "Create this reminder?",
                message: confirmationLines.joined(separator: "\n"),
                approveLabel: "Create Reminder"
            )
            guard approved else { throw LocalToolControlError.denied }

            return try await saveReminder(title: cleanedTitle, notes: notes, dueDate: dueDate)
        }
    }

    private func parseDueDate(_ value: String?) throws -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }

        let internetFormatter = ISO8601DateFormatter()
        internetFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = internetFormatter.date(from: value) { return date }
        internetFormatter.formatOptions = [.withInternetDateTime]
        if let date = internetFormatter.date(from: value) { return date }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.timeZone = .current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        if let date = dayFormatter.date(from: value) { return date }

        throw ReminderToolError.invalidDueDate
    }

    @MainActor
    private func saveReminder(title: String, notes: String?, dueDate: Date?) async throws -> Any {
        let eventStore = EKEventStore()
        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else { throw ReminderToolError.permissionDenied }
        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            throw ReminderToolError.noDefaultCalendar
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.calendar = calendar
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                in: .current,
                from: dueDate
            )
        }
        try eventStore.save(reminder, commit: true)

        var result: [String: Any] = [
            "status": "created",
            "title": title,
            "calendar": calendar.title,
            "identifier": reminder.calendarItemIdentifier
        ]
        if let dueDate {
            result["due_date"] = ISO8601DateFormatter().string(from: dueDate)
        }
        return result
    }
}

struct ListMCPToolsTool: Tool {
    static let name = "list_mcp_tools"
    static let description = "List the tools currently advertised by enabled, connected MCP servers. This reads a cached catalog and does not itself make a network request. Call it before call_mcp_tool so you use the exact server ID, tool name, and JSON input schema."

    init() {}

    func run() async throws -> Any {
        await LocalToolRunner.execute(name: Self.name, title: "List connected MCP tools") {
            let servers = await MCPConnectionStore.shared.availableToolListing()
            if servers.isEmpty {
                return [
                    "connected_server_count": 0,
                    "message": "No enabled MCP server is connected. Ask the user to open Local tools → MCP servers and connect one."
                ]
            }
            return [
                "connected_server_count": servers.count,
                "servers": servers,
                "warning": "Tool annotations are untrusted server claims. call_mcp_tool always requires user approval."
            ]
        }
    }
}

struct CallMCPTool: Tool {
    static let name = "call_mcp_tool"
    static let description = "Call a tool on an enabled, connected MCP server. First use list_mcp_tools to obtain the exact server ID, tool name, and input schema. This sends the supplied arguments off device and always pauses for user confirmation."

    @ToolParam(description: "The exact server_id returned by list_mcp_tools. Prefer the UUID instead of a server name.")
    var serverIdentifier: String

    @ToolParam(description: "The exact MCP tool name returned by list_mcp_tools.")
    var toolName: String

    @ToolParam(description: "A valid JSON object matching the tool's input_schema. Use {} when the tool has no arguments.")
    var argumentsJSON: String = "{}"

    init() {}

    func run() async throws -> Any {
        await LocalToolRunner.execute(name: Self.name, title: "Call remote MCP tool") {
            let (server, tool) = try await MCPConnectionStore.shared.serverAndTool(
                serverIdentifier: serverIdentifier,
                toolName: toolName
            )

            let cleanedArguments = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = cleanedArguments.isEmpty
                ? "{}"
                : String(cleanedArguments.prefix(1_200)) + (cleanedArguments.count > 1_200 ? "…" : "")
            let approved = await ToolAuthorizationCenter.shared.request(
                toolName: Self.name,
                title: "Allow remote MCP call?",
                message: "Server: \(server.name)\nEndpoint: \(server.endpoint)\nTool: \(tool.name)\n\nArguments sent off device:\n\(preview)",
                approveLabel: "Send & Run"
            )
            guard approved else { throw LocalToolControlError.denied }

            return try await MCPConnectionStore.shared.callTool(
                serverIdentifier: server.id.uuidString,
                toolName: tool.name,
                argumentsJSON: cleanedArguments
            )
        }
    }
}

struct ListPrivateKnowledgeTool: Tool {
    static let name = "list_private_knowledge"
    static let description = "List the document names and index sizes in the user's private on-device knowledge library. The tool reads metadata only and never sends data off device."

    init() {}

    func run() async throws -> Any {
        await LocalToolRunner.execute(name: Self.name, title: "List private knowledge") {
            await MainActor.run {
                let store = KnowledgeStore.shared
                return [
                    "document_count": store.documents.count,
                    "chunk_count": store.chunkCount,
                    "documents": store.documents.map { document in
                        [
                            "name": document.name,
                            "character_count": document.characterCount,
                            "chunk_count": document.chunks.count
                        ] as [String: Any]
                    }
                ] as [String: Any]
            }
        }
    }
}

struct SearchPrivateKnowledgeTool: Tool {
    static let name = "search_private_knowledge"
    static let description = "Search the private on-device knowledge library for passages relevant to a question. Returns excerpts labeled with their source filenames. Use only when private knowledge is enabled for the chat."

    @ToolParam(description: "A focused semantic search query describing the information to find.")
    var query: String

    @ToolParam(description: "Maximum number of matching passages to return, from 1 through 6.")
    var limit: Int = 4

    init() {}

    func run() async throws -> Any {
        await LocalToolRunner.execute(name: Self.name, title: "Search private knowledge") {
            let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedQuery.isEmpty else { throw KnowledgeToolError.emptyQuery }

            let safeLimit = min(max(limit, 1), 6)
            let context = await MainActor.run {
                KnowledgeStore.shared.context(
                    for: cleanedQuery,
                    limit: safeLimit,
                    maximumCharacters: 6_000
                )
            }

            guard let context, !context.isEmpty else {
                return [
                    "query": cleanedQuery,
                    "found": false,
                    "message": "No indexed passages are available. Ask the user to import files into Private knowledge."
                ]
            }

            return [
                "query": cleanedQuery,
                "found": true,
                "passages": context
            ]
        }
    }
}

private enum ReminderToolError: LocalizedError {
    case emptyTitle
    case invalidDueDate
    case permissionDenied
    case noDefaultCalendar

    var errorDescription: String? {
        switch self {
        case .emptyTitle: "The reminder title is empty."
        case .invalidDueDate: "The due date is not valid ISO 8601."
        case .permissionDenied: "Reminders access was not granted."
        case .noDefaultCalendar: "No writable Reminders list is available."
        }
    }
}

private enum KnowledgeToolError: LocalizedError {
    case emptyQuery

    var errorDescription: String? {
        "The private-knowledge search query is empty."
    }
}

private enum LocalCalculationError: LocalizedError {
    case unexpectedToken(String)
    case expected(String)
    case invalidNumber(String)
    case unknownIdentifier(String)
    case invalidArguments(String)
    case divisionByZero
    case expressionTooLong
    case nonFiniteResult

    var errorDescription: String? {
        switch self {
        case .unexpectedToken(let token): "Unexpected token: \(token)."
        case .expected(let token): "Expected \(token)."
        case .invalidNumber(let number): "Invalid number: \(number)."
        case .unknownIdentifier(let name): "Unknown constant or function: \(name)."
        case .invalidArguments(let name): "Invalid arguments for \(name)."
        case .divisionByZero: "Division by zero is not allowed."
        case .expressionTooLong: "The expression is too long."
        case .nonFiniteResult: "The calculation did not produce a finite result."
        }
    }
}

private struct LocalCalculationParser {
    private let characters: [Character]
    private var index = 0

    init(_ expression: String) {
        characters = Array(expression)
    }

    mutating func parse() throws -> Double {
        let value = try parseExpression()
        skipWhitespace()
        guard isAtEnd else {
            throw LocalCalculationError.unexpectedToken(String(characters[index]))
        }
        return value
    }

    private mutating func parseExpression() throws -> Double {
        var value = try parseTerm()
        while true {
            if consume("+") {
                value += try parseTerm()
            } else if consume("-") {
                value -= try parseTerm()
            } else {
                return value
            }
        }
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parsePower()
        while true {
            if consume("*") {
                value *= try parsePower()
            } else if consume("/") {
                let divisor = try parsePower()
                guard divisor != 0 else { throw LocalCalculationError.divisionByZero }
                value /= divisor
            } else if consume("%") {
                let divisor = try parsePower()
                guard divisor != 0 else { throw LocalCalculationError.divisionByZero }
                value.formTruncatingRemainder(dividingBy: divisor)
            } else {
                return value
            }
        }
    }

    private mutating func parsePower() throws -> Double {
        let base = try parseUnary()
        if consume("^") {
            return Foundation.pow(base, try parsePower())
        }
        return base
    }

    private mutating func parseUnary() throws -> Double {
        if consume("+") { return try parseUnary() }
        if consume("-") { return -(try parseUnary()) }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> Double {
        if consume("(") {
            let value = try parseExpression()
            guard consume(")") else { throw LocalCalculationError.expected("a closing parenthesis") }
            return value
        }

        skipWhitespace()
        guard !isAtEnd else { throw LocalCalculationError.expected("a number or function") }

        if characters[index].isNumber || characters[index] == "." {
            return try parseNumber()
        }

        if characters[index].isLetter {
            let identifier = parseIdentifier().lowercased()
            if consume("(") {
                return try parseFunction(named: identifier)
            }
            switch identifier {
            case "pi": return .pi
            case "e": return M_E
            default: throw LocalCalculationError.unknownIdentifier(identifier)
            }
        }

        throw LocalCalculationError.unexpectedToken(String(characters[index]))
    }

    private mutating func parseFunction(named name: String) throws -> Double {
        var arguments: [Double] = []
        if !consume(")") {
            repeat {
                arguments.append(try parseExpression())
            } while consume(",")
            guard consume(")") else { throw LocalCalculationError.expected("a closing parenthesis") }
        }

        switch (name, arguments.count) {
        case ("sqrt", 1):
            guard arguments[0] >= 0 else { throw LocalCalculationError.invalidArguments(name) }
            return Foundation.sqrt(arguments[0])
        case ("abs", 1): return Swift.abs(arguments[0])
        case ("sin", 1): return Foundation.sin(arguments[0])
        case ("cos", 1): return Foundation.cos(arguments[0])
        case ("tan", 1): return Foundation.tan(arguments[0])
        case ("log", 1):
            guard arguments[0] > 0 else { throw LocalCalculationError.invalidArguments(name) }
            return Foundation.log10(arguments[0])
        case ("ln", 1):
            guard arguments[0] > 0 else { throw LocalCalculationError.invalidArguments(name) }
            return Foundation.log(arguments[0])
        case ("exp", 1): return Foundation.exp(arguments[0])
        case ("floor", 1): return Foundation.floor(arguments[0])
        case ("ceil", 1): return Foundation.ceil(arguments[0])
        case ("round", 1): return arguments[0].rounded()
        case ("min", 2): return Swift.min(arguments[0], arguments[1])
        case ("max", 2): return Swift.max(arguments[0], arguments[1])
        case ("pow", 2): return Foundation.pow(arguments[0], arguments[1])
        default: throw LocalCalculationError.invalidArguments(name)
        }
    }

    private mutating func parseNumber() throws -> Double {
        skipWhitespace()
        let start = index
        var sawExponent = false

        while !isAtEnd {
            let character = characters[index]
            if character.isNumber || character == "." {
                index += 1
            } else if (character == "e" || character == "E") && !sawExponent {
                sawExponent = true
                index += 1
                if !isAtEnd, (characters[index] == "+" || characters[index] == "-") {
                    index += 1
                }
            } else {
                break
            }
        }

        let string = String(characters[start..<index])
        guard let value = Double(string) else { throw LocalCalculationError.invalidNumber(string) }
        return value
    }

    private mutating func parseIdentifier() -> String {
        skipWhitespace()
        let start = index
        while !isAtEnd, (characters[index].isLetter || characters[index] == "_") {
            index += 1
        }
        return String(characters[start..<index])
    }

    private mutating func consume(_ expected: Character) -> Bool {
        skipWhitespace()
        guard !isAtEnd, characters[index] == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while !isAtEnd, characters[index].isWhitespace { index += 1 }
    }

    private var isAtEnd: Bool { index >= characters.count }
}
