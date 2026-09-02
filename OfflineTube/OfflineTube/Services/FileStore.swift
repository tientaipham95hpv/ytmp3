import Foundation

enum FileStore {
    static let minimumFreeSpace: Int64 = 512 * 1024 * 1024
    static var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("OfflineTube/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var artworkDirectory: URL {
        let directory = downloadsDirectory.deletingLastPathComponent().appendingPathComponent("Artwork", isDirectory: true)
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
