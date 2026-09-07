import SwiftData
import OSLog

enum AppModelStore {
    static let shared: ModelContainer = {
        do {
            return try ModelContainer(
                for: MediaItem.self,
                MediaPlaylist.self,
                CustomSmartPlaylist.self
            )
        } catch {
            Logger(subsystem: "com.personal.OfflineTube", category: "Persistence")
                .fault("Persistent store unavailable; using a temporary recovery store: \(error.localizedDescription, privacy: .public)")
            do {
                let schema = Schema([MediaItem.self, MediaPlaylist.self, CustomSmartPlaylist.self])
                let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try ModelContainer(for: schema, configurations: configuration)
            } catch {
                fatalError("Unable to create even the temporary recovery store: \(error)")
            }
        }
    }()
}
