import Foundation
import LiteRTLM

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var messages: [ChatItem] = []
    @Published private(set) var chats: [ChatSession] = []
    @Published private(set) var activeChatID = UUID()
    @Published var pendingAttachments: [ChatAttachment] = []
    @Published private(set) var status: EngineStatus = .unloaded
    @Published private(set) var lastMetrics: GenerationMetrics?
    @Published private(set) var metricHistory: [GenerationMetrics] = []
    @Published private(set) var runningPerformanceTestTokenLimit: Int?
    @Published private(set) var generationSettings: GenerationSettings
    @Published private(set) var bridgeInFlight = false
    @Published var errorMessage: String?

    private var engine: Engine?
    private var conversation: Conversation?
    private var generationTask: Task<Void, Never>?
    private var loadedModelURL: URL?

    init() {
        generationSettings = GenerationSettingsPersistence.load()
        do {
            let archive = try ChatArchivePersistence.load()
            chats = archive.chats.map(Self.recoverInterruptedResponse)
            metricHistory = archive.metricHistory
            lastMetrics = metricHistory.first

            if let selectedID = archive.selectedChatID,
               chats.contains(where: { $0.id == selectedID }) {
                activeChatID = selectedID
            } else if let first = chats.first {
                activeChatID = first.id
            }
        } catch {
            chats = []
        }

        if chats.isEmpty {
            let chat = ChatSession()
            chats = [chat]
            activeChatID = chat.id
        }
        messages = activeChat?.messages ?? []
    }

    var canSend: Bool {
        status == .ready && !isBusy
    }

    var isBusy: Bool {
        generationTask != nil || isRunningPerformanceTest || bridgeInFlight
    }

    var isRunningPerformanceTest: Bool {
        runningPerformanceTestTokenLimit != nil
    }

    var activeChatTitle: String {
        activeChat?.title ?? "New chat"
    }

    var activeAssistantMode: AssistantMode {
        activeChat?.assistantMode ?? .general
    }

    var knowledgeEnabled: Bool {
        activeChat?.knowledgeEnabled ?? false
    }

    var activeSkills: [LocalSkill] {
        LocalSkillStore.shared.skills(for: activeChat?.enabledSkillIDs ?? [])
    }

    var activeLocalTools: [LocalToolDescriptor] {
        LocalToolCatalog.descriptors(includeKnowledge: knowledgeEnabled)
    }

    var activeChatMarkdown: String {
        var lines = [
            "# \(activeChatTitle)",
            "",
            "- Local skill: \(activeAssistantMode.title)",
            "- Skill bundles: \(activeSkills.isEmpty ? "None" : activeSkills.map(\.name).joined(separator: ", "))",
            "- Exported: \(Date().formatted(date: .abbreviated, time: .shortened))",
            ""
        ]
        for message in messages where message.role != .system {
            lines.append("## \(message.role == .user ? "You" : "Matha Atlas")")
            if !message.attachments.isEmpty {
                lines.append("Attachments: \(message.attachments.map(\.displayName).joined(separator: ", "))")
                lines.append("")
            }
            lines.append(message.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    var sortedChats: [ChatSession] {
        chats.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func loadModel(at modelURL: URL) async {
        guard loadedModelURL != modelURL || conversation == nil else { return }
        generationTask?.cancel()
        status = .loading("Loading Gemma 4")
        errorMessage = nil

        do {
            let cache = modelURL.deletingLastPathComponent()
                .appendingPathComponent("CompilationCache", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

            ExperimentalFlags.optIntoExperimentalAPIs()
            ExperimentalFlags.enableBenchmark = true
            ExperimentalFlags.enableSpeculativeDecoding = true
            ExperimentalFlags.visualTokenBudget = 140
            // Needed so bridge clients can pin answers to a JSON schema.
            ExperimentalFlags.enableConversationConstrainedDecoding = true

            let config = try EngineConfig(
                modelPath: modelURL.path,
                backend: .gpu,
                visionBackend: .cpu(),
                audioBackend: .cpu(),
                maxNumTokens: 4_096,
                cacheDir: cache.path
            )
            let newEngine = Engine(engineConfig: config)
            try await newEngine.initialize()
            engine = newEngine
            loadedModelURL = modelURL
            try await createConversation(history: messages)
            status = .ready
        } catch {
            engine = nil
            conversation = nil
            status = .failed(error.localizedDescription)
            errorMessage = "Gemma 4 could not load: \(error.localizedDescription)"
        }
        InferenceBridge.shared.attach(provider: self)
    }

    func unload() {
        generationTask?.cancel()
        ToolAuthorizationCenter.shared.cancelPending()
        generationTask = nil
        conversation = nil
        engine = nil
        loadedModelURL = nil
        status = .unloaded
    }

    func newChat() async {
        guard engine != nil, !isBusy else { return }
        let inheritedMode = activeAssistantMode
        let inheritedSkillIDs = activeChat?.enabledSkillIDs ?? []
        syncActiveChat()

        if !messages.isEmpty {
            let chat = ChatSession(assistantMode: inheritedMode, enabledSkillIDs: inheritedSkillIDs)
            chats.append(chat)
            activeChatID = chat.id
            messages = []
        }

        pendingAttachments = []
        status = .loading("Starting a new chat")
        do {
            try await createConversation(history: [])
            status = .ready
            persistArchive()
        } catch {
            status = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func selectChat(_ id: UUID) async {
        guard id != activeChatID, !isBusy,
              let selected = chats.first(where: { $0.id == id }) else { return }

        syncActiveChat()
        activeChatID = id
        messages = selected.messages
        pendingAttachments = []

        guard engine != nil else {
            persistArchive()
            return
        }

        status = .loading("Opening chat")
        do {
            try await createConversation(history: messages)
            status = .ready
            persistArchive()
        } catch {
            status = .failed(error.localizedDescription)
            errorMessage = "This chat could not be restored: \(error.localizedDescription)"
        }
    }

    func deleteChat(_ id: UUID) async {
        guard !isBusy, let index = chats.firstIndex(where: { $0.id == id }) else { return }
        let deletedActiveChat = activeChatID == id
        chats.remove(at: index)

        if chats.isEmpty {
            let replacement = ChatSession()
            chats = [replacement]
        }

        if deletedActiveChat {
            let replacement = sortedChats[0]
            activeChatID = replacement.id
            messages = replacement.messages
            pendingAttachments = []

            if engine != nil {
                status = .loading("Opening chat")
                do {
                    try await createConversation(history: messages)
                    status = .ready
                } catch {
                    status = .failed(error.localizedDescription)
                    errorMessage = "The next chat could not be restored: \(error.localizedDescription)"
                }
            }
        }
        persistArchive()
    }

    func renameChat(_ id: UUID, title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].title = String(cleaned.prefix(80))
        chats[index].updatedAt = Date()
        persistArchive()
    }

    func togglePin(_ id: UUID) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].isPinned.toggle()
        persistArchive()
    }

    func setKnowledgeEnabled(_ enabled: Bool) {
        guard !isBusy,
              enabled != knowledgeEnabled,
              let index = chats.firstIndex(where: { $0.id == activeChatID }) else { return }
        chats[index].knowledgeEnabled = enabled
        persistArchive()
        Task {
            await rebuildConversation(
                statusText: enabled ? "Enabling private knowledge tools" : "Disabling private knowledge tools"
            )
        }
    }

    func setAssistantMode(_ mode: AssistantMode) async {
        guard !isBusy, mode != activeAssistantMode,
              let index = chats.firstIndex(where: { $0.id == activeChatID }) else { return }
        chats[index].assistantMode = mode
        persistArchive()
        await rebuildConversation(statusText: "Switching to \(mode.title) mode")
    }

    func setSkillEnabled(_ skillID: UUID, enabled: Bool) async {
        guard !isBusy,
              let index = chats.firstIndex(where: { $0.id == activeChatID }) else { return }
        var enabledIDs = chats[index].enabledSkillIDs
        if enabled {
            guard !enabledIDs.contains(skillID) else { return }
            enabledIDs.append(skillID)
        } else {
            guard enabledIDs.contains(skillID) else { return }
            enabledIDs.removeAll { $0 == skillID }
        }
        chats[index].enabledSkillIDs = enabledIDs
        chats[index].updatedAt = Date()
        persistArchive()
        await rebuildConversation(statusText: enabled ? "Enabling local skill" : "Disabling local skill")
    }

    func removeSkillReferences(_ skillID: UUID) async {
        let affectedActiveChat = activeChat?.enabledSkillIDs.contains(skillID) == true
        var changed = false
        for index in chats.indices where chats[index].enabledSkillIDs.contains(skillID) {
            chats[index].enabledSkillIDs.removeAll { $0 == skillID }
            chats[index].updatedAt = Date()
            changed = true
        }
        guard changed else { return }
        persistArchive()
        if affectedActiveChat {
            await rebuildConversation(statusText: "Removing local skill")
        }
    }

    func applyGenerationSettings(_ settings: GenerationSettings) async {
        guard !isBusy else { return }
        generationSettings = GenerationSettings(
            temperature: min(max(settings.temperature, 0), 1.5),
            topP: min(max(settings.topP, 0.1), 1),
            topK: min(max(settings.topK, 1), 100),
            maxOutputTokens: min(max(settings.maxOutputTokens, 64), 2_048),
            thinkingEnabled: settings.thinkingEnabled,
            thinkingBudget: min(max(settings.thinkingBudget, 0), 1_024)
        )
        GenerationSettingsPersistence.save(generationSettings)
        await rebuildConversation(statusText: "Applying generation settings")
    }

    func send(text rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard canSend, !trimmed.isEmpty || !attachments.isEmpty, let conversation else { return }

        let visibleText = trimmed.isEmpty ? "Analyze the attached content." : trimmed
        pendingAttachments = []
        messages.append(ChatItem(role: .user, text: visibleText, attachments: attachments))
        let responseID = UUID()
        messages.append(ChatItem(id: responseID, role: .assistant, text: "", isStreaming: true))
        status = .generating
        syncActiveChat()

        let knowledgeContext = knowledgeEnabled
            ? KnowledgeStore.shared.context(for: visibleText)
            : nil
        let contents = makeContents(
            prompt: visibleText,
            attachments: attachments,
            knowledgeContext: knowledgeContext
        )
        let modelMessage = Message(contents: contents)

        generationTask = Task { [weak self] in
            do {
                for try await chunk in conversation.sendMessageStream(
                    modelMessage,
                    maxOutputTokens: self?.generationSettings.maxOutputTokens ?? 1_024,
                    thinkingConfig: ThinkingConfig(
                        enableThinking: self?.generationSettings.thinkingEnabled ?? true,
                        thinkingTokenBudget: self?.generationSettings.thinkingBudget ?? 256
                    )
                ) {
                    guard !Task.isCancelled else { break }
                    self?.append(chunk.toString, to: responseID)
                }
                self?.finish(responseID: responseID, conversation: conversation)
            } catch {
                self?.finish(responseID: responseID, conversation: conversation, error: error)
            }
        }
    }

    func stopGenerating() {
        generationTask?.cancel()
        ToolAuthorizationCenter.shared.cancelPending()
        try? conversation?.cancel()
        generationTask = nil
        if let index = messages.lastIndex(where: { $0.isStreaming }) {
            messages[index].isStreaming = false
            if messages[index].text.isEmpty { messages[index].text = "Stopped." }
        }
        status = .ready
        syncActiveChat()
    }

    func regenerateLastResponse() async {
        guard canSend,
              let assistantIndex = messages.lastIndex(where: { $0.role == .assistant && !$0.isStreaming }),
              let userIndex = messages[..<assistantIndex].lastIndex(where: { $0.role == .user }) else { return }
        let userMessage = messages[userIndex]
        messages = Array(messages[..<userIndex])
        pendingAttachments = userMessage.attachments
        syncActiveChat()
        await rebuildConversation(statusText: "Regenerating")
        send(text: userMessage.text)
    }

    func runPerformanceTest(maxOutputTokens: Int) async {
        let supportedTokenLimits = [128, 500, 1_000]
        guard supportedTokenLimits.contains(maxOutputTokens),
              status == .ready, !isBusy, let engine else { return }
        runningPerformanceTestTokenLimit = maxOutputTokens
        errorMessage = nil
        defer { runningPerformanceTestTokenLimit = nil }

        do {
            let testConversation = try await engine.createConversation(
                with: try conversationConfig(initialMessages: [], includeTools: false)
            )
            _ = try await testConversation.sendMessage(
                Message(
                    "Write a numbered list of brief, distinct facts about on-device AI. " +
                    "Do not conclude or stop early; continue until the system reaches the output-token limit."
                ),
                maxOutputTokens: maxOutputTokens,
                thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0)
            )
            guard let metrics = captureMetrics(
                from: testConversation,
                source: .performanceTest,
                outputTokenLimit: maxOutputTokens
            ) else {
                throw PerformanceTestError.metricsUnavailable
            }
            record(metrics)
        } catch {
            errorMessage = "Performance test failed: \(error.localizedDescription)"
        }
    }

    func addAttachment(_ attachment: ChatAttachment) {
        pendingAttachments.append(attachment)
    }

    func addAttachments(_ attachments: [ChatAttachment]) {
        pendingAttachments.append(contentsOf: attachments)
    }

    func removeAttachment(_ attachment: ChatAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    private var activeChat: ChatSession? {
        chats.first(where: { $0.id == activeChatID })
    }

    private func createConversation(history: [ChatItem]) async throws {
        guard let engine else { return }
        let initialMessages = replayableHistory(from: history)
        conversation = try await engine.createConversation(
            with: try conversationConfig(initialMessages: initialMessages)
        )
    }

    private func conversationConfig(
        initialMessages: [Message],
        includeTools: Bool = true
    ) throws -> ConversationConfig {
        let sampler = try SamplerConfig(
            topK: generationSettings.topK,
            topP: Float(generationSettings.topP),
            temperature: Float(generationSettings.temperature)
        )
        let localTools = includeTools
            ? LocalToolCatalog.tools(includeKnowledge: knowledgeEnabled)
            : []
        let localSkills = LocalSkillStore.shared.systemInstruction(
            for: activeChat?.enabledSkillIDs ?? []
        )
        return ConversationConfig(
            systemMessage: Message(
                "You are Matha Atlas, a private assistant running entirely on this iPhone. " +
                "Clearly say when an attachment is unreadable or evidence is insufficient. " +
                "When knowledge excerpts are supplied, ground the answer in them and cite their [Source: filename] labels. " +
                "Use registered tools when they materially improve correctness. Never claim a tool ran unless you received its result. " +
                activeAssistantMode.instruction + localSkills
            ),
            initialMessages: initialMessages,
            tools: localTools,
            samplerConfig: sampler,
            enableToolCallStreaming: includeTools,
            thinkingConfig: ThinkingConfig(
                enableThinking: generationSettings.thinkingEnabled,
                thinkingTokenBudget: generationSettings.thinkingBudget
            ),
            automaticToolCalling: true,
            visualTokenBudget: 140
        )
    }

    private func replayableHistory(from history: [ChatItem]) -> [Message] {
        var selected: [ChatItem] = []
        var approximateCharacters = 0

        for item in history.reversed() where !item.isStreaming && !item.text.isEmpty {
            let cost = min(item.text.count, 6_000) + (item.attachments.count * 500)
            if !selected.isEmpty && approximateCharacters + cost > 8_000 { break }
            selected.append(item)
            approximateCharacters += cost
        }

        return selected.reversed().compactMap { item in
            let text = String(item.text.prefix(6_000))
            switch item.role {
            case .user:
                return Message(contents: makeContents(prompt: text, attachments: item.attachments), role: .user)
            case .assistant:
                return Message(text, role: .model)
            case .system:
                return nil
            }
        }
    }

    private func makeContents(
        prompt: String,
        attachments: [ChatAttachment],
        knowledgeContext: String? = nil
    ) -> [Content] {
        var contents: [Content] = []
        var seenVideoGroups = Set<UUID>()
        var remainingDocumentCharacters = 8_000

        for attachment in attachments {
            switch attachment.kind {
            case .image:
                if FileManager.default.fileExists(atPath: attachment.url.path) {
                    contents.append(.imageFile(attachment.url.path))
                }
            case .videoFrame:
                guard FileManager.default.fileExists(atPath: attachment.url.path) else { continue }
                if let group = attachment.groupID, seenVideoGroups.insert(group).inserted {
                    contents.append(.text("The following images are chronological frames sampled locally from one video."))
                }
                contents.append(.imageFile(attachment.url.path))
            case .audio:
                if FileManager.default.fileExists(atPath: attachment.url.path) {
                    contents.append(.audioFile(attachment.url.path))
                }
            case .document:
                if let text = attachment.extractedText, remainingDocumentCharacters > 0 {
                    let excerpt = String(text.prefix(remainingDocumentCharacters))
                    remainingDocumentCharacters -= excerpt.count
                    let truncationNote = excerpt.count < text.count
                        ? "\n[Excerpt shortened to fit the on-device context window.]"
                        : ""
                    contents.append(
                        .text("Document named \(attachment.displayName):\n---\n\(excerpt)\(truncationNote)\n---")
                    )
                }
            }
        }
        if let knowledgeContext, !knowledgeContext.isEmpty {
            contents.append(.text(
                "Relevant excerpts retrieved from the private on-device knowledge library:\n---\n" +
                knowledgeContext + "\n---"
            ))
        }
        contents.append(.text(prompt))
        return contents
    }

    private func rebuildConversation(statusText: String) async {
        guard engine != nil else { return }
        status = .loading(statusText)
        do {
            try await createConversation(history: messages)
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
            errorMessage = "The conversation could not be rebuilt: \(error.localizedDescription)"
        }
    }

    private func append(_ text: String, to responseID: UUID) {
        guard !text.isEmpty, let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
        messages[index].text += text
    }

    private func finish(responseID: UUID, conversation: Conversation, error: Error? = nil) {
        if let index = messages.firstIndex(where: { $0.id == responseID }) {
            messages[index].isStreaming = false
            if error != nil, messages[index].text.isEmpty {
                messages[index].text = "I couldn’t finish that response."
            }
            if error == nil,
               let metrics = captureMetrics(from: conversation, source: .chatResponse) {
                messages[index].metrics = metrics
                record(metrics, persist: false)
            }
        }
        generationTask = nil
        status = .ready
        syncActiveChat()
        if let error { errorMessage = "Inference failed: \(error.localizedDescription)" }
    }

    private func captureMetrics(
        from conversation: Conversation,
        source: GenerationMetricSource,
        outputTokenLimit: Int? = nil
    ) -> GenerationMetrics? {
        guard let info = try? conversation.getBenchmarkInfo() else { return nil }
        return GenerationMetrics(
            source: source,
            outputTokenLimit: outputTokenLimit,
            measuredAt: Date(),
            prefillTokenCount: info.lastPrefillTokenCount,
            outputTokenCount: info.lastDecodeTokenCount,
            contextTokenCount: (try? conversation.getTokenCount()) ?? 0,
            prefillTokensPerSecond: info.lastPrefillTokensPerSecond,
            outputTokensPerSecond: info.lastDecodeTokensPerSecond,
            timeToFirstToken: info.timeToFirstTokenInSecond,
            initializationTime: info.initTimeInSecond
        )
    }

    private func record(_ metrics: GenerationMetrics, persist: Bool = true) {
        lastMetrics = metrics
        metricHistory.insert(metrics, at: 0)
        metricHistory = Array(metricHistory.prefix(20))
        if persist { persistArchive() }
    }

    private func syncActiveChat() {
        guard let index = chats.firstIndex(where: { $0.id == activeChatID }) else { return }
        chats[index].messages = messages
        chats[index].updatedAt = Date()
        chats[index].title = Self.title(for: messages)
        persistArchive()
    }

    private func persistArchive() {
        do {
            try ChatArchivePersistence.save(
                ChatArchive(
                    selectedChatID: activeChatID,
                    chats: chats,
                    metricHistory: metricHistory
                )
            )
        } catch {
            errorMessage = "Chat history could not be saved: \(error.localizedDescription)"
        }
    }

    private static func title(for messages: [ChatItem]) -> String {
        guard let firstUserMessage = messages.first(where: { $0.role == .user }) else {
            return "New chat"
        }
        let collapsed = firstUserMessage.text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? "Attachment chat" : String(collapsed.prefix(48))
    }

    private static func recoverInterruptedResponse(_ chat: ChatSession) -> ChatSession {
        var recovered = chat
        recovered.messages = chat.messages.map { message in
            guard message.isStreaming else { return message }
            var recoveredMessage = message
            recoveredMessage.isStreaming = false
            if recoveredMessage.text.isEmpty {
                recoveredMessage.text = "Response interrupted."
            }
            return recoveredMessage
        }
        return recovered
    }
}

// MARK: - Local inference bridge

/// Serves prompts from trusted local clients (the InspectAR glasses survey app)
/// using the engine that is already resident for chat. A second `Engine` would
/// mean a second 2.5 GB of weights, so the bridge borrows this one instead.
///
/// Each request gets a throwaway `Conversation`: bridge traffic never lands in
/// the operator's chat history, and one client cannot read another's context.
extension ChatStore: BridgeInferenceProviding {
    var bridgeModelName: String { "Gemma 4 E2B" }

    var bridgeEngineState: String {
        switch status {
        case .unloaded: "unloaded"
        case .loading: "loading"
        case .ready: "ready"
        case .generating: "generating"
        case .failed: "failed"
        }
    }

    var bridgeAcceptsWork: Bool {
        engine != nil && !isBusy
    }

    func runBridgeGeneration(
        _ request: BridgeGenerationRequest,
        onDelta: @escaping (String) -> Void
    ) async throws -> BridgeGenerationResult {
        guard let engine else { throw BridgeInferenceError.modelNotLoaded }
        guard !isBusy else { throw BridgeInferenceError.busy }

        bridgeInFlight = true
        defer { bridgeInFlight = false }

        let responseFormat: ResponseFormat?
        if let schema = request.jsonSchema {
            do {
                responseFormat = try ResponseFormat.json(schema: schema)
            } catch {
                throw BridgeInferenceError.invalidSchema
            }
        } else {
            responseFormat = nil
        }

        let sampler = try SamplerConfig(
            topK: request.topK,
            topP: Float(request.topP),
            temperature: Float(request.temperature)
        )
        let thinking = ThinkingConfig(
            enableThinking: request.thinkingEnabled,
            thinkingTokenBudget: request.thinkingBudget
        )
        let conversation = try await engine.createConversation(
            with: ConversationConfig(
                systemMessage: Message(request.system ?? Self.bridgeSystemMessage),
                initialMessages: [],
                tools: [],
                samplerConfig: sampler,
                enableToolCallStreaming: false,
                thinkingConfig: thinking,
                automaticToolCalling: false,
                enableResponseFormat: responseFormat != nil,
                visualTokenBudget: 140
            )
        )

        var contents: [Content] = request.images.map { .imageData($0) }
        contents.append(.text(request.prompt))

        var text = ""
        for try await chunk in conversation.sendMessageStream(
            Message(contents: contents),
            maxOutputTokens: request.maxOutputTokens,
            thinkingConfig: thinking,
            responseFormat: responseFormat
        ) {
            if Task.isCancelled { break }
            let piece = chunk.toString
            guard !piece.isEmpty else { continue }
            text += piece
            onDelta(piece)
        }

        let info = try? conversation.getBenchmarkInfo()
        return BridgeGenerationResult(
            text: text,
            promptTokens: info?.lastPrefillTokenCount ?? 0,
            outputTokens: info?.lastDecodeTokenCount ?? 0,
            timeToFirstToken: info?.timeToFirstTokenInSecond ?? 0,
            outputTokensPerSecond: info?.lastDecodeTokensPerSecond ?? 0
        )
    }

    private static var bridgeSystemMessage: String {
        "You are the on-device reasoning engine for a paired field application. " +
        "Answer only from the supplied prompt and images. " +
        "If the evidence is insufficient, say so instead of guessing. " +
        "When a response schema is supplied, emit only data that conforms to it."
    }
}

private struct ChatArchive: Codable {
    let schemaVersion: Int
    let selectedChatID: UUID?
    let chats: [ChatSession]
    let metricHistory: [GenerationMetrics]

    init(
        schemaVersion: Int = 1,
        selectedChatID: UUID?,
        chats: [ChatSession],
        metricHistory: [GenerationMetrics]
    ) {
        self.schemaVersion = schemaVersion
        self.selectedChatID = selectedChatID
        self.chats = chats
        self.metricHistory = metricHistory
    }
}

private enum ChatArchivePersistence {
    static func load() throws -> ChatArchive {
        let data = try Data(contentsOf: archiveURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatArchive.self, from: data)
    }

    static func save(_ archive: ChatArchive) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        try data.write(to: archiveURL, options: .atomic)
    }

    private static var archiveURL: URL {
        get throws {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalGemma", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: nil
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableRoot = root
            try? mutableRoot.setResourceValues(values)
            return root.appendingPathComponent("ChatArchive.json")
        }
    }
}

private enum PerformanceTestError: LocalizedError {
    case metricsUnavailable

    var errorDescription: String? {
        "LiteRT-LM did not return benchmark metrics for this run."
    }
}

private enum GenerationSettingsPersistence {
    private static let key = "localGemma.generationSettings.v1"

    static func load() -> GenerationSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(GenerationSettings.self, from: data) else {
            return GenerationSettings()
        }
        return settings
    }

    static func save(_ settings: GenerationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
