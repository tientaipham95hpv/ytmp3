import Foundation

enum FileStore {
    static var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("OfflineTube/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func destination(filename: String) -> URL {
        let safeExtension = URL(fileURLWithPath: filename).pathExtension
        let name = UUID().uuidString + (safeExtension.isEmpty ? "" : ".\(safeExtension)")
        return downloadsDirectory.appendingPathComponent(name)
    }

    static func remove(_ item: MediaItem) throws {
        if FileManager.default.fileExists(atPath: item.localURL.path) {
            try FileManager.default.removeItem(at: item.localURL)
        }
    }
}
