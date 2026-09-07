import SwiftUI
import SwiftData

@main
struct OfflineTubeApp: App {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var cloudSync = CloudSyncService.shared
    @StateObject private var appLock = AppLockManager()

    init() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "backendURL") == "https://offlinetube.cineviet.live" {
            defaults.set("https://offlinetube.noza.site", forKey: "backendURL")
        }
    }

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
