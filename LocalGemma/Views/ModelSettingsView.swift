import SwiftUI

struct ModelSettingsView: View {
    @EnvironmentObject private var manager: ModelManager
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    let beforeDelete: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Installed model") {
                    LabeledContent("Name", value: manager.model.displayName)
                    LabeledContent(
                        "On disk",
                        value: ByteCountFormatter.string(fromByteCount: manager.installedSize, countStyle: .file)
                    )
                    LabeledContent("Inference", value: "100% on-device")
                }

                Section("Capabilities") {
                    Label("Text and code", systemImage: "text.alignleft")
                    Label("Images and camera", systemImage: "camera")
                    Label("Audio and voice recordings", systemImage: "waveform")
                    Label("Video through sampled frames", systemImage: "film.stack")
                    Label("PDF and text documents", systemImage: "doc.text")
                }

                Section {
                    Link(destination: manager.model.repositoryURL) {
                        Label("Open official model card", systemImage: "arrow.up.right.square")
                    }
                }

                Section {
                    Button("Delete downloaded model", role: .destructive) {
                        confirmDelete = true
                    }
                } footer: {
                    Text("This removes the model and compilation cache. Your model can be downloaded or imported again later.")
                }
            }
            .navigationTitle("Local model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
            .confirmationDialog(
                "Delete Gemma 4 from this device?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete model", role: .destructive) {
                    beforeDelete()
                    try? manager.deleteModel()
                    dismiss()
                }
            }
        }
    }
}
