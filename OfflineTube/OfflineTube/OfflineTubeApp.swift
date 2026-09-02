import SwiftUI
import SwiftData

@main
struct OfflineTubeApp: App {
    @StateObject private var player = PlayerManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
        }
        .modelContainer(for: [MediaItem.self, MediaPlaylist.self, CustomSmartPlaylist.self])
    }
}
