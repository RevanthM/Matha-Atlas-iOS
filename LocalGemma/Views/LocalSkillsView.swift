import SwiftUI
import UniformTypeIdentifiers

struct LocalSkillsView: View {
    @EnvironmentObject private var chatStore: ChatStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var skillStore = LocalSkillStore.shared
    @State private var showImporter = false
    @State private var importError: String?
    @State private var skillToDelete: LocalSkill?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Private instruction bundles", systemImage: "shippingbox.and.arrow.backward")
                        .font(.subheadline.weight(.semibold))
                    Text("Enabled skills are inserted into this chat's on-device system prompt. A skill can teach workflows and tool-use patterns, but it cannot silently add native code or bypass tool confirmations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Installed") {
                    if skillStore.installedSkills.isEmpty {
                        ContentUnavailableView(
                            "No local skills",
                            systemImage: "puzzlepiece.extension",
                            description: Text("Import a SKILL.md, Markdown, text, or JSON instruction bundle.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(skillStore.installedSkills) { skill in
                            skillRow(skill)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) { skillToDelete = skill }
                            }
                        }
                    }
                }

                Section("Import format") {
                    Text("Markdown may start with YAML-style name, description, and version fields. A selected folder must contain SKILL.md. JSON uses name, description, instructions, and optional version fields.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Restore starter skills") { skillStore.restoreStarterSkills() }
                }
            }
            .navigationTitle("Local skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showImporter = true } label: {
                        Label("Import skill", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: skillContentTypes,
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let skill = try skillStore.importSkill(from: url)
                    Task { await chatStore.setSkillEnabled(skill.id, enabled: true) }
                } catch {
                    importError = error.localizedDescription
                }
            }
            .alert(
                "Skill could not be imported",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "Unknown import error")
            }
            .confirmationDialog(
                "Delete this local skill?",
                isPresented: Binding(
                    get: { skillToDelete != nil },
                    set: { if !$0 { skillToDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: skillToDelete
            ) { skill in
                Button("Delete \(skill.name)", role: .destructive) {
                    Task {
                        await chatStore.removeSkillReferences(skill.id)
                        skillStore.remove(skill.id)
                    }
                }
            } message: { skill in
                Text("The bundle will be removed from the library and disabled in every chat.")
            }
        }
    }

    private func skillRow(_ skill: LocalSkill) -> some View {
        let isEnabled = chatStore.activeSkills.contains(where: { $0.id == skill.id })
        let enabledBinding = Binding<Bool>(
            get: { isEnabled },
            set: { enabled in
                Task { await chatStore.setSkillEnabled(skill.id, enabled: enabled) }
            }
        )

        return HStack(alignment: .top, spacing: 11) {
            NavigationLink {
                LocalSkillDetailView(skill: skill)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(skill.name).font(.subheadline.weight(.semibold))
                        Text(skill.source.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(skill.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Toggle("Enable \(skill.name)", isOn: enabledBinding)
                .labelsHidden()
                .disabled(chatStore.isBusy)
        }
        .padding(.vertical, 3)
    }

    private var skillContentTypes: [UTType] {
        [UTType(filenameExtension: "md") ?? .plainText, .plainText, .json, .folder]
    }
}

private struct LocalSkillDetailView: View {
    let skill: LocalSkill

    var body: some View {
        List {
            Section("About") {
                LabeledContent("Source", value: skill.source.title)
                if let version = skill.version {
                    LabeledContent("Version", value: version)
                }
                LabeledContent("Installed") {
                    Text(skill.installedAt == Date(timeIntervalSince1970: 0) ? "Bundled with app" : skill.installedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Text(skill.summary)
                    .font(.subheadline)
            }

            Section("Instructions") {
                Text(skill.instructions)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
