import Foundation

enum FileStore {
    struct StorageSnapshot {
        let total: Int64
        let audio: Int64
        let video: Int64
        let artwork: Int64
        let temporary: Int64
        let available: Int64?
    }

    static let minimumFreeSpace: Int64 = 512 * 1024 * 1024
    static var appDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("OfflineTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static var downloadsDirectory: URL {
        let directory = appDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var artworkDirectory: URL {
        let directory = appDirectory.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func destination(filename: String) -> URL {
        let safeExtension = URL(fileURLWithPath: filename).pathExtension
        let name = UUID().uuidString + (safeExtension.isEmpty ? "" : ".\(safeExtension)")
        return downloadsDirectory.appendingPathComponent(name)
    }

    static func availableCapacity() -> Int64? {
        let values = try? downloadsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func ensureCapacity(requiredBytes: Int64? = nil) throws {
        guard let available = availableCapacity() else { return }
        let required = max(minimumFreeSpace, (requiredBytes ?? 0) + 100 * 1024 * 1024)
        if available < required { throw APIError.insufficientStorage }
    }

    static func remove(_ item: MediaItem) throws {
        if FileManager.default.fileExists(atPath: item.localURL.path) {
            try FileManager.default.removeItem(at: item.localURL)
        }
        if let artworkURL = item.artworkURL, FileManager.default.fileExists(atPath: artworkURL.path) {
            try FileManager.default.removeItem(at: artworkURL)
        }
    }

    static func saveArtwork(from remoteValue: String?, sourceID: String) async -> String? {
        guard let remoteValue, let remoteURL = URL(string: remoteValue),
              let (data, response) = try? await URLSession.shared.data(from: remoteURL),
              data.count <= 15 * 1024 * 1024,
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let ext = response.mimeType == "image/png" ? "png" : "jpg"
        let safeID = sourceID.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let filename = "\(safeID)-\(UUID().uuidString).\(ext)"
        let destination = artworkDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
            return filename
        } catch { return nil }
    }

    static func fileSize(for item: MediaItem) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: item.localURL.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func storageUsage() -> Int64 {
        directorySize(appDirectory)
    }

    static func storageSnapshot(items: [MediaItem]) -> StorageSnapshot {
        let audio = items.filter { !$0.isVideo }.reduce(Int64(0)) { $0 + fileSize(for: $1) }
        let video = items.filter(\.isVideo).reduce(Int64(0)) { $0 + fileSize(for: $1) }
        let artwork = directorySize(artworkDirectory)
        let total = storageUsage()
        return StorageSnapshot(total: total, audio: audio, video: video, artwork: artwork,
                               temporary: max(0, total - audio - video - artwork), available: availableCapacity())
    }

    static func clearArtworkCache(items: [MediaItem]) throws {
        let urls = try FileManager.default.contentsOfDirectory(at: artworkDirectory, includingPropertiesForKeys: nil)
        for url in urls { try FileManager.default.removeItem(at: url) }
        items.forEach { $0.artworkFilename = nil }
    }

    static func cleanupTemporaryFiles(olderThan age: TimeInterval = 3600) throws {
        let cutoff = Date().addingTimeInterval(-age)
        let urls = try FileManager.default.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsSubdirectoryDescendants]
        )
        let temporaryExtensions = Set(["tmp", "temp", "part", "download"])
        for url in urls where temporaryExtensions.contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values?.isRegularFile == true, (values?.contentModificationDate ?? .distantPast) < cutoff {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    static func clearOrphanedFiles(keeping items: [MediaItem]) throws {
        let filenames = Set(items.map(\.localFilename))
        let urls = try FileManager.default.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil)
        for url in urls where !filenames.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
        let artworkFilenames = Set(items.compactMap(\.artworkFilename))
        let artworkURLs = try FileManager.default.contentsOfDirectory(at: artworkDirectory, includingPropertiesForKeys: nil)
        for url in artworkURLs where !artworkFilenames.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]), values.isRegularFile == true {
                total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }
}
