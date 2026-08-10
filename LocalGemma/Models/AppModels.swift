import Foundation
import UniformTypeIdentifiers

struct LocalModel: Equatable {
    static let gemma4E2B = LocalModel(
        displayName: "Gemma 4 E2B",
        filename: "gemma-4-E2B-it.litertlm",
        downloadURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm?download=true")!,
        expectedBytes: 2_588_147_712,
        repositoryURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm")!
    )

    let displayName: String
    let filename: String
    let downloadURL: URL
    let expectedBytes: Int64
    let repositoryURL: URL

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
    }
}

enum ModelState: Equatable {
    case notInstalled
    case downloading(progress: Double, received: Int64, total: Int64)
    case importing
    case installed(URL)
    case failed(String)
}

enum AttachmentKind: String, Codable {
    case image
    case audio
    case document
    case videoFrame

    var symbol: String {
        switch self {
        case .image: "photo"
        case .audio: "waveform"
        case .document: "doc.text"
        case .videoFrame: "film.stack"
        }
    }
}

struct ChatAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: AttachmentKind
    let url: URL
    let displayName: String
    let extractedText: String?
    let groupID: UUID?

    init(
        id: UUID = UUID(),
        kind: AttachmentKind,
        url: URL,
        displayName: String,
        extractedText: String? = nil,
        groupID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.displayName = displayName
        self.extractedText = extractedText
        self.groupID = groupID
    }
}

enum ChatRole: String, Codable {
    case user
    case assistant
    case system
}

enum AssistantMode: String, Codable, CaseIterable, Identifiable {
    case general
    case coder
    case researcher
    case writer
    case tutor
    case creative

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .coder: "Code"
        case .researcher: "Research"
        case .writer: "Writing"
        case .tutor: "Tutor"
        case .creative: "Creative"
        }
    }

    var symbol: String {
        switch self {
        case .general: "sparkles"
        case .coder: "chevron.left.forwardslash.chevron.right"
        case .researcher: "magnifyingglass"
        case .writer: "pencil.line"
        case .tutor: "graduationcap"
        case .creative: "paintpalette"
        }
    }

    var instruction: String {
        switch self {
        case .general:
            "Be accurate, practical, and concise."
        case .coder:
            "Act as a senior software engineer. Give correct, runnable solutions, call out trade-offs, and explain failure modes."
        case .researcher:
            "Analyze evidence carefully. Separate facts from inference, cite provided source names, and identify uncertainty."
        case .writer:
            "Act as an expert editor and writer. Optimize structure, clarity, voice, and audience fit."
        case .tutor:
            "Teach step by step, check assumptions, use examples, and adapt explanations to the learner."
        case .creative:
            "Generate original, vivid ideas and explore multiple directions before recommending the strongest one."
        }
    }
}

struct GenerationSettings: Codable, Equatable {
    var temperature: Double = 0.7
    var topP: Double = 0.95
    var topK: Int = 40
    var maxOutputTokens: Int = 1_024
    var thinkingEnabled: Bool = true
    var thinkingBudget: Int = 256
}

enum GenerationMetricSource: String, Codable {
    case chatResponse
    case performanceTest

    var label: String {
        switch self {
        case .chatResponse: "Latest response"
        case .performanceTest: "Performance test"
        }
    }
}

struct GenerationMetrics: Codable, Equatable {
    let source: GenerationMetricSource
    let outputTokenLimit: Int?
    let measuredAt: Date
    let prefillTokenCount: Int
    let outputTokenCount: Int
    let contextTokenCount: Int
    let prefillTokensPerSecond: Double
    let outputTokensPerSecond: Double
    let timeToFirstToken: Double
    let initializationTime: Double

    var displayLabel: String {
        if source == .performanceTest, let outputTokenLimit {
            return "\(outputTokenLimit)-token test"
        }
        return source.label
    }
}

struct ChatItem: Identifiable, Codable, Equatable {
    let id: UUID
    let role: ChatRole
    var text: String
    let attachments: [ChatAttachment]
    let createdAt: Date
    var isStreaming: Bool
    var metrics: GenerationMetrics?

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        attachments: [ChatAttachment] = [],
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        metrics: GenerationMetrics? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.metrics = metrics
    }
}

struct ChatSession: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [ChatItem]
    let createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var assistantMode: AssistantMode
    var knowledgeEnabled: Bool
    var enabledSkillIDs: [UUID]

    init(
        id: UUID = UUID(),
        title: String = "New chat",
        messages: [ChatItem] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        assistantMode: AssistantMode = .general,
        knowledgeEnabled: Bool = false,
        enabledSkillIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.assistantMode = assistantMode
        self.knowledgeEnabled = knowledgeEnabled
        self.enabledSkillIDs = enabledSkillIDs
    }

    var preview: String {
        messages.last(where: { !$0.text.isEmpty })?.text ?? "No messages yet"
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, updatedAt, isPinned, assistantMode, knowledgeEnabled, enabledSkillIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([ChatItem].self, forKey: .messages)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        assistantMode = try container.decodeIfPresent(AssistantMode.self, forKey: .assistantMode) ?? .general
        knowledgeEnabled = try container.decodeIfPresent(Bool.self, forKey: .knowledgeEnabled) ?? false
        enabledSkillIDs = try container.decodeIfPresent([UUID].self, forKey: .enabledSkillIDs) ?? []
    }
}

enum EngineStatus: Equatable {
    case unloaded
    case loading(String)
    case ready
    case generating
    case failed(String)

    var label: String {
        switch self {
        case .unloaded: "Model offline"
        case .loading(let detail): detail
        case .ready: "On-device"
        case .generating: "Thinking locally"
        case .failed: "Needs attention"
        }
    }
}

extension UTType {
    static var liteRTLMModel: UTType {
        UTType(filenameExtension: "litertlm") ?? .data
    }
}
