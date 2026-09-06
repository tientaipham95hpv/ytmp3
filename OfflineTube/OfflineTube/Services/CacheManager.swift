import CryptoKit
import Foundation

struct CacheStorageSnapshot: Sendable {
    let media: Int64
    let artwork: Int64
    let temporaryDownloads: Int64
    let backendMetadata: Int64
    let waveform: Int64
    let available: Int64?

    var total: Int64 { media + artwork + temporaryDownloads + backendMetadata + waveform }

    static let empty = CacheStorageSnapshot(
        media: 0, artwork: 0, temporaryDownloads: 0,
        backendMetadata: 0, waveform: 0, available: nil
    )
}

struct CacheFileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let category: String
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct MissingMediaEntry: Identifiable, Sendable {
    let id: UUID
    let title: String
    let filename: String
}

struct DuplicateFileGroup: Identifiable, Sendable {
    let id: String
    let files: [CacheFileEntry]
    var reclaimableSize: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } }
}

struct CacheScanReport: Sendable {
    let orphanFiles: [CacheFileEntry]
    let missingMedia: [MissingMediaEntry]
    let duplicateFiles: [DuplicateFileGroup]
    let scannedAt: Date

    var isClean: Bool { orphanFiles.isEmpty && missingMedia.isEmpty && duplicateFiles.isEmpty }
}

struct CacheRecordDescriptor: Sendable {
    let id: UUID
    let title: String
    let localFilename: String
    let artworkFilenames: Set<String>
    let customArtworkFilenames: Set<String>
}

enum CacheCleanupScope: String, Sendable {
    case artwork
    case temporary
    case orphan
}

struct CacheCleanupPreview: Identifiable, Sendable {
    let id = UUID()
    let scope: CacheCleanupScope
    let files: [CacheFileEntry]
    let includesURLCache: Bool
    let urlCacheBytes: Int64

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } + urlCacheBytes }
    var fileCount: Int { files.count + (includesURLCache ? 1 : 0) }
}

struct CacheCleanupResult: Sendable {
    let removedFiles: [CacheFileEntry]
    let clearedURLCache: Bool

    var removedSize: Int64 { removedFiles.reduce(0) { $0 + $1.size } }
    var removedCount: Int { removedFiles.count + (clearedURLCache ? 1 : 0) }
}

enum CacheManager {
    private static let temporaryExtensions = Set(["tmp", "temp", "part", "download"])

    static var temporaryDownloadsDirectory: URL { managedDirectory("TemporaryDownloads") }
    static var backendMetadataDirectory: URL { managedDirectory("BackendMetadata") }
    static var waveformDirectory: URL { managedDirectory("Waveforms") }

    static func records(from items: [MediaItem]) -> [CacheRecordDescriptor] {
        items.map {
            CacheRecordDescriptor(
                id: $0.id,
                title: $0.title,
                localFilename: $0.localFilename,
                artworkFilenames: Set([$0.artworkFilename, $0.customArtworkFilename].compactMap { $0 }),
                customArtworkFilenames: Set([$0.customArtworkFilename].compactMap { $0 })
            )
        }
    }

    static func storageSnapshot() async -> CacheStorageSnapshot {
        await Task.detached(priority: .utility) {
            let downloadFiles = regularFiles(in: FileStore.downloadsDirectory)
            let temporaryInDownloads = downloadFiles.filter { isTemporaryDownload($0.url) }
            let mediaFiles = downloadFiles.filter { !isTemporaryDownload($0.url) }
            return CacheStorageSnapshot(
                media: size(of: mediaFiles),
                artwork: directorySize(FileStore.artworkDirectory),
                temporaryDownloads: size(of: temporaryInDownloads) + directorySize(temporaryDownloadsDirectory),
                backendMetadata: directorySize(backendMetadataDirectory) + Int64(URLCache.shared.currentDiskUsage),
                waveform: directorySize(waveformDirectory),
                available: FileStore.availableCapacity()
            )
        }.value
    }

    static func previewArtworkCleanup(records: [CacheRecordDescriptor]) -> CacheCleanupPreview {
        let protectedCustom = Set(records.flatMap(\.customArtworkFilenames).map(safeFilename))
        let files = regularFiles(in: FileStore.artworkDirectory)
            .filter { !protectedCustom.contains($0.url.lastPathComponent) }
            .map { CacheFileEntry(url: $0.url, size: $0.size, category: "Artwork") }
        return CacheCleanupPreview(scope: .artwork, files: files, includesURLCache: false, urlCacheBytes: 0)
    }

    static func previewTemporaryCleanup(records: [CacheRecordDescriptor], olderThan age: TimeInterval = 3600) -> CacheCleanupPreview {
        let cutoff = Date().addingTimeInterval(-age)
        let protectedMedia = Set(records.map { safeFilename($0.localFilename) })
        let downloadParts = regularFiles(in: FileStore.downloadsDirectory)
            .filter {
                isTemporaryDownload($0.url)
                    && !protectedMedia.contains($0.url.lastPathComponent)
                    && modificationDate(of: $0.url) < cutoff
            }
            .map { CacheFileEntry(url: $0.url, size: $0.size, category: "Temporary download") }
        let temporary = regularFiles(in: temporaryDownloadsDirectory)
            .map { CacheFileEntry(url: $0.url, size: $0.size, category: "Temporary download") }
        let backend = regularFiles(in: backendMetadataDirectory)
            .map { CacheFileEntry(url: $0.url, size: $0.size, category: "Backend metadata") }
        let waveforms = regularFiles(in: waveformDirectory)
            .map { CacheFileEntry(url: $0.url, size: $0.size, category: "Waveform cache") }
        let urlCacheBytes = Int64(URLCache.shared.currentDiskUsage)
        return CacheCleanupPreview(
            scope: .temporary,
            files: downloadParts + temporary + backend + waveforms,
            includesURLCache: urlCacheBytes > 0,
            urlCacheBytes: urlCacheBytes
        )
    }

    static func previewOrphanCleanup(from report: CacheScanReport) -> CacheCleanupPreview {
        CacheCleanupPreview(scope: .orphan, files: report.orphanFiles, includesURLCache: false, urlCacheBytes: 0)
    }

    /// Executes a previously reviewed preview, but revalidates every candidate against
    /// the latest SwiftData descriptors. A stale preview can therefore never delete
    /// media or artwork that became referenced after the scan.
    static func clean(_ preview: CacheCleanupPreview, currentRecords: [CacheRecordDescriptor]) throws -> CacheCleanupResult {
        let referencedMedia = Set(currentRecords.map { safeFilename($0.localFilename) })
        let referencedArtwork = Set(currentRecords.flatMap(\.artworkFilenames).map(safeFilename))
        let protectedCustomArtwork = Set(currentRecords.flatMap(\.customArtworkFilenames).map(safeFilename))
        var removed: [CacheFileEntry] = []

        for file in preview.files where FileManager.default.fileExists(atPath: file.url.path) {
            guard isRegularFileWithoutFollowingAliases(file.url) else { continue }
            let filename = file.url.lastPathComponent
            let root = managedRoot(containing: file.url)
            let mayDelete: Bool
            switch preview.scope {
            case .artwork:
                mayDelete = root == FileStore.artworkDirectory.standardizedFileURL.path
                    && !protectedCustomArtwork.contains(filename)
            case .temporary:
                if root == FileStore.downloadsDirectory.standardizedFileURL.path {
                    mayDelete = isTemporaryDownload(file.url)
                        && !referencedMedia.contains(filename)
                        && modificationDate(of: file.url) < Date().addingTimeInterval(-3600)
                } else {
                    mayDelete = root == temporaryDownloadsDirectory.standardizedFileURL.path
                        || root == backendMetadataDirectory.standardizedFileURL.path
                        || root == waveformDirectory.standardizedFileURL.path
                }
            case .orphan:
                if root == FileStore.downloadsDirectory.standardizedFileURL.path {
                    mayDelete = !isTemporaryDownload(file.url) && !referencedMedia.contains(filename)
                } else if root == FileStore.artworkDirectory.standardizedFileURL.path {
                    mayDelete = !referencedArtwork.contains(filename)
                } else {
                    mayDelete = false
                }
            }
            guard mayDelete else { continue }
            try FileManager.default.removeItem(at: file.url)
            removed.append(file)
        }
        if preview.includesURLCache { URLCache.shared.removeAllCachedResponses() }
        return CacheCleanupResult(removedFiles: removed, clearedURLCache: preview.includesURLCache)
    }

    static func scan(records: [CacheRecordDescriptor]) async -> CacheScanReport {
        await Task.detached(priority: .utility) {
            let referencedMedia = Set(records.map { safeFilename($0.localFilename) })
            let referencedArtwork = Set(records.flatMap(\.artworkFilenames).map(safeFilename))
            let mediaFiles = regularFiles(in: FileStore.downloadsDirectory).filter { !isTemporaryDownload($0.url) }
            let artworkFiles = regularFiles(in: FileStore.artworkDirectory)

            let orphanMedia = mediaFiles.filter { !referencedMedia.contains($0.url.lastPathComponent) }
                .map { CacheFileEntry(url: $0.url, size: $0.size, category: "Media") }
            let orphanArtwork = artworkFiles.filter { !referencedArtwork.contains($0.url.lastPathComponent) }
                .map { CacheFileEntry(url: $0.url, size: $0.size, category: "Artwork") }
            let missing = records.compactMap { record -> MissingMediaEntry? in
                let filename = safeFilename(record.localFilename)
                let url = FileStore.downloadsDirectory.appendingPathComponent(filename)
                guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
                return MissingMediaEntry(id: record.id, title: record.title, filename: record.localFilename)
            }
            let duplicates = duplicateGroups(in: mediaFiles)
            return CacheScanReport(
                orphanFiles: (orphanMedia + orphanArtwork).sorted { $0.size > $1.size },
                missingMedia: missing.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending },
                duplicateFiles: duplicates,
                scannedAt: Date()
            )
        }.value
    }

    private static func duplicateGroups(in files: [(url: URL, size: Int64)]) -> [DuplicateFileGroup] {
        let candidates = Dictionary(grouping: files.filter { $0.size > 0 }, by: \.size).values.filter { $0.count > 1 }
        var groups: [DuplicateFileGroup] = []
        for sameSize in candidates {
            let hashed = Dictionary(grouping: sameSize, by: { sha256($0.url) ?? UUID().uuidString })
            for (hash, matches) in hashed where matches.count > 1 {
                let entries = matches.map { CacheFileEntry(url: $0.url, size: $0.size, category: "Media") }
                    .sorted { $0.name < $1.name }
                groups.append(DuplicateFileGroup(id: hash, files: entries))
            }
        }
        return groups.sorted { $0.reclaimableSize > $1.reclaimableSize }
    }

    private static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try? handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func managedDirectory(_ name: String) -> URL {
        let directory = FileStore.appDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func isTemporaryDownload(_ url: URL) -> Bool {
        temporaryExtensions.contains(url.pathExtension.lowercased())
    }

    private static func safeFilename(_ value: String) -> String {
        URL(fileURLWithPath: value).lastPathComponent
    }

    private static func managedRoot(containing url: URL) -> String? {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let roots = [
            FileStore.downloadsDirectory, FileStore.artworkDirectory, temporaryDownloadsDirectory,
            backendMetadataDirectory, waveformDirectory
        ].map { $0.standardizedFileURL.path }
        return roots.first { parent == $0 }
    }

    private static func isRegularFileWithoutFollowingAliases(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true && values.isAliasFile != true
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func regularFiles(in directory: URL) -> [(url: URL, size: Int64)] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { value -> (URL, Int64)? in
            guard let url = value as? URL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]),
                  values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileAllocatedSize ?? values.fileSize ?? 0))
        }
    }

    private static func directorySize(_ directory: URL) -> Int64 { size(of: regularFiles(in: directory)) }
    private static func size(of files: [(url: URL, size: Int64)]) -> Int64 { files.reduce(0) { $0 + $1.size } }
}
