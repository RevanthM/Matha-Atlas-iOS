import SwiftUI

struct ModelSetupView: View {
    @EnvironmentObject private var manager: ModelManager
    @State private var showImporter = false
    @State private var showDetails = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.035, green: 0.047, blue: 0.075), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        Spacer(minLength: 40)
                        modelMark
                        introduction
                        modelCard
                        privacyRow
                        Spacer(minLength: 30)
                    }
                    .padding(.horizontal, 22)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("About") { showDetails = true }
                        .foregroundStyle(.secondary)
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.liteRTLMModel],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await manager.importModel(from: url) }
            }
            .sheet(isPresented: $showDetails) {
                ModelFactsView()
            }
        }
    }

    private var modelMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.9), Color.blue, Color.indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 104, height: 104)
                .shadow(color: .blue.opacity(0.4), radius: 30, y: 12)
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private var introduction: some View {
        VStack(spacing: 10) {
            Text("Your AI stays here")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Chat with text, photos, audio, documents, and video frames using Gemma 4 entirely on your device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(manager.model.displayName)
                        .font(.title3.bold())
                    Text("Instruction-tuned • Multimodal • LiteRT-LM")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(manager.model.sizeLabel)
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }

            Divider().overlay(.white.opacity(0.08))

            stateControls

            Button {
                showImporter = true
            } label: {
                Label("Import an existing .litertlm file", systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        }
        .frame(maxWidth: 560)
    }

    @ViewBuilder
    private var stateControls: some View {
        switch manager.state {
        case .notInstalled:
            VStack(alignment: .leading, spacing: 12) {
                Label("Requires about 2.6 GB plus temporary download space", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    manager.download()
                } label: {
                    Label("Download Gemma 4", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

        case .downloading(let progress, let received, let total):
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Downloading model")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
                    .tint(.cyan)
                HStack {
                    Text("\(format(received)) of \(format(total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .cancel) { manager.cancelDownload() }
                        .font(.caption.bold())
                }
            }

        case .importing:
            HStack(spacing: 12) {
                ProgressView()
                Text("Copying model into private app storage…")
                    .font(.subheadline)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Try download again") { manager.download() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }

        case .installed:
            EmptyView()
        }
    }

    private var privacyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            Text("After the one-time model download, prompts and attachments never need to leave your iPhone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 520)
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct ModelFactsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("What is local") {
                    Label("Prompts and responses", systemImage: "text.bubble")
                    Label("Photo and video frame analysis", systemImage: "photo.on.rectangle")
                    Label("Audio understanding", systemImage: "waveform")
                    Label("PDF and text extraction", systemImage: "doc.text")
                }
                Section("Runtime") {
                    LabeledContent("Model", value: "Gemma 4 E2B IT")
                    LabeledContent("Format", value: ".litertlm")
                    LabeledContent("Text backend", value: "Metal GPU")
                    LabeledContent("Vision / audio", value: "CPU")
                    LabeledContent("Minimum iOS", value: "17.0")
                }
                Section {
                    Text("The first load compiles and caches model components and can take noticeably longer. A recent iPhone with at least 6 GB RAM is recommended.")
                }
            }
            .navigationTitle("About Matha Atlas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
