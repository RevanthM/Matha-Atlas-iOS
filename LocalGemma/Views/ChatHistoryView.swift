import SwiftUI

struct ChatHistoryView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.sortedChats) { chat in
                        Button {
                            open(chat)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: chat.id == store.activeChatID ? "checkmark.circle.fill" : "bubble.left")
                                    .foregroundStyle(chat.id == store.activeChatID ? .cyan : .secondary)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chat.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(chat.preview)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(chat.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .disabled(store.isBusy)
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await store.deleteChat(chat.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(store.isBusy)
                        }
                    }
                } header: {
                    Text("Stored only on this device")
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await store.newChat()
                            dismiss()
                        }
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    .disabled(store.isBusy)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func open(_ chat: ChatSession) {
        guard chat.id != store.activeChatID else {
            dismiss()
            return
        }
        Task {
            await store.selectChat(chat.id)
            dismiss()
        }
    }
}
