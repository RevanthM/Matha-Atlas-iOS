import AVFoundation
import DispatchUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var store: ChatStore
    @Binding var showModelSheet: Bool

    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var speechReader = SpeechReader()
    @StateObject private var toolAuthorization = ToolAuthorizationCenter.shared
    @State private var draft = ""
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var selectedMedia: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showDrawer = false
    @State private var showPerformance = false
    @State private var showKnowledge = false
    @State private var showGenerationSettings = false
    @State private var showDispatch = false
    @State private var isProcessingAttachment = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                NavigationStack {
                    ZStack {
                        Color(red: 0.025, green: 0.031, blue: 0.047).ignoresSafeArea()

                        VStack(spacing: 0) {
                            conversation
                            Divider().overlay(.white.opacity(0.08))
                            composer
                        }
                    }
                    .navigationTitle(store.activeChatTitle == "New chat" ? "Matha Atlas" : store.activeChatTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbarContent }
                    .sheet(isPresented: $showCamera) {
                        CameraPicker { image in
                            Task { await addCameraImage(image) }
                        }
                        .ignoresSafeArea()
                    }
                    .sheet(isPresented: $showPerformance) {
                        PerformanceView()
                            .environmentObject(store)
                    }
                    .sheet(isPresented: $showKnowledge) {
                        KnowledgeView()
                    }
                    .sheet(isPresented: $showGenerationSettings) {
                        GenerationSettingsView(settings: store.generationSettings)
                            .environmentObject(store)
                    }
                    .fullScreenCover(isPresented: $showDispatch) {
                        ZStack(alignment: .topTrailing) {
                            DispatchCenterView()
                            Button {
                                showDispatch = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.body.weight(.bold))
                                    .frame(width: 38, height: 38)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .accessibilityLabel("Close Dispatch")
                            .padding(.top, 5)
                            .padding(.trailing, 12)
                        }
                    }
                    .photosPicker(
                        isPresented: $showPhotoPicker,
                        selection: $selectedMedia,
                        maxSelectionCount: 8,
                        matching: .any(of: [.images, .videos]),
                        preferredItemEncoding: .current
                    )
                    .onChange(of: selectedMedia) { _, items in
                        guard !items.isEmpty else { return }
                        Task { await processPhotosPickerItems(items) }
                    }
                    .fileImporter(
                        isPresented: $showFileImporter,
                        allowedContentTypes: [.pdf, .plainText, .sourceCode, .json, .commaSeparatedText, .audio, .movie],
                        allowsMultipleSelection: true
                    ) { result in
                        guard case .success(let urls) = result else { return }
                        Task { await processFiles(urls) }
                    }
                    .alert("Matha Atlas", isPresented: errorPresented) {
                        Button("OK") {
                            store.errorMessage = nil
                            audioRecorder.errorMessage = nil
                        }
                    } message: {
                        Text(store.errorMessage ?? audioRecorder.errorMessage ?? "Something went wrong.")
                    }
                }

                if showDrawer {
                    Color.black.opacity(0.48)
                        .ignoresSafeArea()
                        .onTapGesture { closeDrawer() }
                        .transition(.opacity)
                        .zIndex(1)

                    ChatDrawerView(
                        close: closeDrawer,
                        openModel: {
                            closeDrawer()
                            showModelSheet = true
                        },
                        openPerformance: {
                            closeDrawer()
                            showPerformance = true
                        },
                        openKnowledge: {
                            closeDrawer()
                            showKnowledge = true
                        },
                        openGenerationSettings: {
                            closeDrawer()
                            showGenerationSettings = true
                        },
                        openDispatch: {
                            closeDrawer()
                            showDispatch = true
                        }
                    )
                    .frame(width: min(geometry.size.width * 0.88, 390))
                    .transition(.move(edge: .leading))
                    .zIndex(2)
                }

                if let request = toolAuthorization.pendingRequest {
                    Color.black.opacity(0.62)
                        .ignoresSafeArea()
                        .zIndex(3)

                    ToolConfirmationCard(
                        request: request,
                        deny: { toolAuthorization.resolve(allowed: false) },
                        approve: { toolAuthorization.resolve(allowed: true) }
                    )
                    .frame(maxWidth: 430)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(4)
                }
            }
            .animation(.snappy(duration: 0.24), value: showDrawer)
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if !showDrawer, value.startLocation.x < 24, value.translation.width > 70 {
                            showDrawer = true
                        } else if showDrawer, value.translation.width < -70 {
                            closeDrawer()
                        }
                    }
            )
            .onDisappear {
                speechReader.stop()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showDrawer = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Open menu")
            .accessibilityIdentifier("hamburgerMenuButton")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await store.newChat() }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .disabled(store.isBusy)
            .accessibilityLabel("New chat")

        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if store.messages.isEmpty {
                        emptyState
                            .padding(.top, 60)
                    } else {
                        ForEach(store.messages) { message in
                            MessageBubble(
                                item: message,
                                canRegenerate: message.id == store.messages.last(where: { $0.role == .assistant })?.id && store.canSend,
                                speak: { speechReader.speak(message.text) },
                                regenerate: { Task { await store.regenerateLastResponse() } }
                            )
                                .id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.14))
                    .frame(width: 96, height: 96)
                Image(systemName: "sparkles")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.cyan)
            }

            VStack(spacing: 8) {
                Text(emptyTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(emptySubtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            if store.status == .ready {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                    SuggestionButton(icon: "camera", title: "Explain a photo") {
                        showCamera = true
                    }
                    SuggestionButton(icon: "waveform", title: "Transcribe audio") {
                        Task { await toggleRecording() }
                    }
                    SuggestionButton(icon: "doc.text", title: "Summarize a PDF") {
                        showFileImporter = true
                    }
                    SuggestionButton(icon: "curlybraces", title: "Help me code") {
                        draft = "Help me design and implement "
                        composerFocused = true
                    }
                }
                .frame(maxWidth: 440)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyTitle: String {
        switch store.status {
        case .loading: "Warming up the model"
        case .failed: "The model needs attention"
        default: "How can I help?"
        }
    }

    private var emptySubtitle: String {
        switch store.status {
        case .loading:
            "The first launch builds a private device-specific cache. This can take a minute."
        case .failed(let detail):
            detail
        default:
            "Everything in this conversation is processed on your device."
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if !store.pendingAttachments.isEmpty {
                pendingAttachmentStrip
            }

            if audioRecorder.isRecording {
                recordingBar
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Photo or Video", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("File or Audio", systemImage: "folder")
                    }
                    Button {
                        Task { await toggleRecording() }
                    } label: {
                        Label("Record Audio", systemImage: "mic")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .disabled(!store.canSend || isProcessingAttachment)

                TextField("Message Gemma 4", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .onSubmit {
                        if canSubmit { submit() }
                    }

                if store.status == .generating {
                    Button {
                        store.stopGenerating()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 36, height: 36)
                            .background(.white, in: Circle())
                            .foregroundStyle(.black)
                    }
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 36, height: 36)
                            .background(canSubmit ? Color.white : Color.white.opacity(0.12), in: Circle())
                            .foregroundStyle(canSubmit ? .black : .secondary)
                    }
                    .disabled(!canSubmit)
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                Text("On-device • Responses may be inaccurate")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 7)
        .background(.ultraThinMaterial)
    }

    private var canSubmit: Bool {
        store.canSend && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.pendingAttachments.isEmpty)
    }

    private var pendingAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.pendingAttachments) { attachment in
                    PendingAttachmentChip(attachment: attachment) {
                        store.removeAttachment(attachment)
                    }
                }
                if isProcessingAttachment {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Preparing")
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .frame(height: 54)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
            Text("Recording")
                .font(.subheadline.weight(.semibold))
            Text(audioRecorder.elapsed.formattedDuration)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) { audioRecorder.cancel() }
                .font(.subheadline)
            Button("Attach") {
                if let url = audioRecorder.stop() {
                    Task { await addRecordedAudio(url) }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil || audioRecorder.errorMessage != nil },
            set: { presented in
                if !presented {
                    store.errorMessage = nil
                    audioRecorder.errorMessage = nil
                }
            }
        )
    }

    private func submit() {
        guard canSubmit else { return }
        let text = draft
        draft = ""
        composerFocused = false
        store.send(text: text)
    }

    private func closeDrawer() {
        showDrawer = false
    }

    private func toggleRecording() async {
        if audioRecorder.isRecording {
            if let url = audioRecorder.stop() { await addRecordedAudio(url) }
        } else {
            _ = await audioRecorder.start()
        }
    }

    private func addRecordedAudio(_ url: URL) async {
        do {
            let attachment = try await AttachmentProcessor.shared.persistAudio(at: url, name: "Voice recording")
            store.addAttachment(attachment)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func addCameraImage(_ image: UIImage) async {
        do {
            let attachment = try await AttachmentProcessor.shared.persistImage(image)
            store.addAttachment(attachment)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func processPhotosPickerItems(_ items: [PhotosPickerItem]) async {
        isProcessingAttachment = true
        defer {
            isProcessingAttachment = false
            selectedMedia = []
        }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    let frames = try await AttachmentProcessor.shared.persistVideoData(data)
                    store.addAttachments(frames)
                } else {
                    let attachment = try await AttachmentProcessor.shared.persistImageData(data)
                    store.addAttachment(attachment)
                }
            } catch {
                store.errorMessage = "Could not attach media: \(error.localizedDescription)"
            }
        }
    }

    private func processFiles(_ urls: [URL]) async {
        isProcessingAttachment = true
        defer { isProcessingAttachment = false }
        for url in urls {
            do {
                let contentType = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
                if contentType?.conforms(to: .audio) == true {
                    store.addAttachment(try await AttachmentProcessor.shared.persistAudio(at: url))
                } else if contentType?.conforms(to: .movie) == true {
                    store.addAttachments(try await AttachmentProcessor.shared.extractVideoFrames(from: url))
                } else {
                    store.addAttachment(try await AttachmentProcessor.shared.persistDocument(at: url))
                }
            } catch {
                store.errorMessage = "Could not attach \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}

private struct MessageBubble: View {
    let item: ChatItem
    let canRegenerate: Bool
    let speak: () -> Void
    let regenerate: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if item.role == .user { Spacer(minLength: 42) }

            if item.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.cyan)
                    .frame(width: 28, height: 28)
                    .background(.cyan.opacity(0.12), in: Circle())
            }

            VStack(alignment: .leading, spacing: 9) {
                if !item.attachments.isEmpty {
                    AttachmentSummaryGrid(attachments: item.attachments)
                }

                if item.text.isEmpty && item.isStreaming {
                    ThinkingDots()
                } else {
                    Text(item.text)
                        .textSelection(.enabled)
                        .font(.body)
                }

                if let metrics = item.metrics {
                    Text(
                        "\(metrics.outputTokenCount) generated tokens • " +
                        "\(metrics.outputTokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s"
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                if item.role == .assistant, !item.isStreaming, !item.text.isEmpty {
                    Menu {
                        Button {
                            UIPasteboard.general.string = item.text
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Button(action: speak) {
                            Label("Read aloud", systemImage: "speaker.wave.2")
                        }
                        ShareLink(item: item.text) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        if canRegenerate {
                            Button(action: regenerate) {
                                Label("Regenerate", systemImage: "arrow.clockwise")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 24)
                            .background(.white.opacity(0.06), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, item.role == .user ? 14 : 0)
            .padding(.vertical, item.role == .user ? 11 : 2)
            .background {
                if item.role == .user {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .fill(Color.blue.opacity(0.82))
                }
            }
            .frame(maxWidth: 620, alignment: .leading)

            if item.role == .assistant { Spacer(minLength: 30) }
        }
        .frame(maxWidth: .infinity)
        .contextMenu {
            if !item.text.isEmpty {
                Button {
                    UIPasteboard.general.string = item.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                ShareLink(item: item.text) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if item.role == .assistant {
                    Button(action: speak) {
                        Label("Read aloud", systemImage: "speaker.wave.2")
                    }
                    if canRegenerate {
                        Button(action: regenerate) {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }
}

private struct ToolConfirmationCard: View {
    let request: ToolConfirmationRequest
    let deny: () -> Void
    let approve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 44, height: 44)
                    .background(.orange.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tool confirmation")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(request.title)
                        .font(.headline)
                }
            }

            Text(request.message)
                .font(.subheadline)
                .textSelection(.enabled)

            Text(request.toolName)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Not Now", role: .cancel, action: deny)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button(request.approveLabel, action: approve)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.12))
        }
    }
}

private struct AttachmentSummaryGrid: View {
    let attachments: [ChatAttachment]

    var visibleAttachments: [ChatAttachment] {
        Array(attachments.prefix(6))
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(visibleAttachments) { attachment in
                if attachment.kind == .image || attachment.kind == .videoFrame,
                   let image = UIImage(contentsOfFile: attachment.url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: attachment.kind.symbol)
                        .font(.title3)
                        .frame(width: 58, height: 58)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            if attachments.count > visibleAttachments.count {
                Text("+\(attachments.count - visibleAttachments.count)")
                    .font(.caption.bold())
            }
        }
    }
}

private struct PendingAttachmentChip: View {
    let attachment: ChatAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if attachment.kind == .image || attachment.kind == .videoFrame,
                   let image = UIImage(contentsOfFile: attachment.url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: attachment.kind.symbol)
                        .foregroundStyle(.cyan)
                        .frame(width: 32)
                }
                Text(attachment.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: 112, alignment: .leading)
            }
            .padding(6)
            .padding(.trailing, 12)
            .frame(height: 54)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .gray)
            }
            .offset(x: 5, y: -5)
        }
        .padding(.top, 5)
    }
}

private struct SuggestionButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).foregroundStyle(.cyan)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.07))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ThinkingDots: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 10)
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        let total = Int(self)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
