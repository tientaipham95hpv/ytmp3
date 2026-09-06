import SwiftUI
import SwiftData

@main
struct OfflineTubeApp: App {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var cloudSync = CloudSyncService.shared
    @StateObject private var appLock = AppLockManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(cloudSync)
                .environmentObject(appLock)
        }
        .modelContainer(AppModelStore.shared)
    }
}
