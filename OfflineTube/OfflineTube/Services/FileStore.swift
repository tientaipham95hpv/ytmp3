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

    static func fileSize(for item: MediaItem) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: item.localURL.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func storageUsage() -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.reduce(0) { result, url in
            result + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func clearOrphanedFiles(keeping items: [MediaItem]) throws {
        let filenames = Set(items.map(\.localFilename))
        let urls = try FileManager.default.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil)
        for url in urls where !filenames.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
