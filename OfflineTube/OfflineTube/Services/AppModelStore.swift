import SwiftData

enum AppModelStore {
    static let shared: ModelContainer = {
        do {
            return try ModelContainer(
                for: MediaItem.self,
                MediaPlaylist.self,
                CustomSmartPlaylist.self
            )
        } catch {
            fatalError("Unable to create the local media store: \(error)")
        }
    }()
}
