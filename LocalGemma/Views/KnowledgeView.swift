import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var knowledgeStore: KnowledgeStore
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(
                        "Use knowledge in this chat",
                        isOn: Binding(
                            get: { store.knowledgeEnabled },
                            set: { store.setKnowledgeEnabled($0) }
                        )
                    )
                    .disabled(store.isBusy)
                    Text("Relevant passages are retrieved locally and inserted into the prompt. Files and vectors never leave this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Library") {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import files", systemImage: "doc.badge.plus")
                    }

                    if knowledgeStore.isImporting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(knowledgeStore.importProgress)
                                .font(.subheadline)
                        }
                    }

                    ForEach(knowledgeStore.documents.sorted { $0.importedAt > $1.importedAt }) { document in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(document.name).font(.subheadline.weight(.medium))
                            Text("\(document.chunks.count) vector chunks • \(document.characterCount.formatted()) characters")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) { knowledgeStore.delete(document) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }

                    if knowledgeStore.documents.isEmpty && !knowledgeStore.isImporting {
                        ContentUnavailableView(
                            "No local knowledge yet",
                            systemImage: "books.vertical",
                            description: Text("Import PDFs, notes, Markdown, CSV, JSON, or source code.")
                        )
                    }
                }

                if !knowledgeStore.documents.isEmpty {
                    Section {
                        Button("Clear knowledge library", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .navigationTitle("Private knowledge")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.pdf, .plainText, .sourceCode, .json, .commaSeparatedText],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    Task { await knowledgeStore.importFiles(urls) }
                }
            }
            .confirmationDialog("Delete all indexed files?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { knowledgeStore.removeAll() }
            }
            .alert("Knowledge library", isPresented: Binding(
                get: { knowledgeStore.errorMessage != nil },
                set: { if !$0 { knowledgeStore.errorMessage = nil } }
            )) {
                Button("OK") { knowledgeStore.errorMessage = nil }
            } message: {
                Text(knowledgeStore.errorMessage ?? "Something went wrong.")
            }
        }
    }
}
