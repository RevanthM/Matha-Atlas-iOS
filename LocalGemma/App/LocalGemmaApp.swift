import DispatchUI
import SwiftUI

@main
struct LocalGemmaApp: App {
    @StateObject private var modelManager = ModelManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(modelManager)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    _ = DispatchPairing.accept(url)
                }
        }
    }
}
