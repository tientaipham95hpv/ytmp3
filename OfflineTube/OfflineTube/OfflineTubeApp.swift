import SwiftUI
import SwiftData

@main
struct OfflineTubeApp: App {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var cloudSync = CloudSyncService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(cloudSync)
        }
        .modelContainer(AppModelStore.shared)
    }
}
