import SwiftUI

struct RootView: View {
    @EnvironmentObject private var modelManager: ModelManager
    @StateObject private var chatStore = ChatStore()
    @StateObject private var knowledgeStore = KnowledgeStore.shared
    @State private var showModelSheet = false

    var body: some View {
        Group {
            switch modelManager.state {
            case .installed(let modelURL):
                ChatView(showModelSheet: $showModelSheet)
                    .environmentObject(chatStore)
                    .environmentObject(knowledgeStore)
                    .task(id: modelURL) {
                        await chatStore.loadModel(at: modelURL)
                    }
            default:
                ModelSetupView()
            }
        }
        .sheet(isPresented: $showModelSheet) {
            ModelSettingsView {
                chatStore.unload()
            }
        }
    }
}
