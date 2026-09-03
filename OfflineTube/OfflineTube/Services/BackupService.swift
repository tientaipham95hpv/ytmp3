import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let offlineTubeBackup = UTType(exportedAs: "com.personal.offlinetube.backup", conformingTo: .package)
}

enum BackupMode: String, Codable { case metadataOnly, full }
enum RestoreMode { case merge, replace }

struct BackupMedia: Codable {
    let id: UUID; let sourceID, sourceURL, title, channel: String
    let thumbnailURL, artworkFile, customArtworkFile, notes: String?
    let duration: Double; let mediaType, quality: String; let playbackPosition: Double
    let createdAt: Date; let isFavorite: Bool; let fileSize: Int64
    let lastPlayedAt: Date?; let playCount: Int
    let lyricsText, lyricsFormat: String?; let lyricsUpdatedAt: Date?
    let mediaFile: String?
}

struct BackupPlaylist: Codable { let id: UUID; let name: String; let itemIDs: [UUID]; let createdAt, updatedAt: Date }
struct BackupSmartPlaylist: Codable { let id: UUID; let name: String; let rulesData: Data; let createdAt, updatedAt: Date }
struct BackupManifest: Codable {
    static let currentVersion = 1
    let version: Int; let createdAt: Date; let mode: BackupMode
    let media: [BackupMedia]; let playlists: [BackupPlaylist]; let smartPlaylists: [BackupSmartPlaylist]
    let settings: [String: String]; let recentSearches: [String]
}

struct BackupSummary {
    let manifest: BackupManifest
    let packageURL: URL
    let missingFiles: Int
    var restorableMedia: Int { manifest.mode == .full ? manifest.media.count - missingFiles : 0 }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.offlineTubeBackup] }
    let packageURL: URL

    static var empty: BackupDocument { BackupDocument(packageURL: FileManager.default.temporaryDirectory) }
    init(packageURL: URL) { self.packageURL = packageURL }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: packageURL, options: [])
    }
}

@MainActor
enum BackupService {
    private static let settingKeys = [
        "defaultAudioQuality", "defaultVideoQuality", "appTheme", "accentChoice",
        "appLanguage", "backendURL", "lyricsProviderURL"
    ]

    static func createPackage(
        mode: BackupMode,
        media: [MediaItem],
        playlists: [MediaPlaylist],
        smartPlaylists: [CustomSmartPlaylist]
    ) async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineTube-\(UUID().uuidString).offlinetubebackup", isDirectory: true)
        let mediaDirectory = root.appendingPathComponent("Media", isDirectory: true)
        let artworkDirectory = root.appendingPathComponent("Artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)

        var snapshots: [BackupMedia] = []
        for item in media {
            let mediaName = mode == .full ? "\(item.id.uuidString).\(item.localURL.pathExtension)" : nil
            let originalArtwork = item.artworkFilename.map { "original-\(item.id.uuidString).\(URL(fileURLWithPath: $0).pathExtension)" }
            let customArtwork = item.customArtworkFilename.map { "custom-\(item.id.uuidString).\(URL(fileURLWithPath: $0).pathExtension)" }
            if mode == .full, let mediaName {
                try await copy(item.localURL, to: mediaDirectory.appendingPathComponent(mediaName))
                if let source = item.originalArtworkURL, let originalArtwork, FileManager.default.fileExists(atPath: source.path) {
                    try await copy(source, to: artworkDirectory.appendingPathComponent(originalArtwork))
                }
                if let filename = item.customArtworkFilename, let customArtwork {
                    let source = FileStore.artworkDirectory.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: source.path) { try await copy(source, to: artworkDirectory.appendingPathComponent(customArtwork)) }
                }
            }
            snapshots.append(BackupMedia(
                id: item.id, sourceID: item.sourceID, sourceURL: item.sourceURL, title: item.title,
                channel: item.channel, thumbnailURL: item.thumbnailURL, artworkFile: mode == .full ? originalArtwork : nil,
                customArtworkFile: mode == .full ? customArtwork : nil, notes: item.notes, duration: item.duration,
                mediaType: item.mediaType, quality: item.quality, playbackPosition: item.playbackPosition,
                createdAt: item.createdAt, isFavorite: item.isFavorite, fileSize: item.fileSize,
                lastPlayedAt: item.lastPlayedAt, playCount: item.playCount, lyricsText: item.lyricsText,
                lyricsFormat: item.lyricsFormat, lyricsUpdatedAt: item.lyricsUpdatedAt, mediaFile: mediaName
            ))
        }
        let defaults = UserDefaults.standard
        let settings = Dictionary(uniqueKeysWithValues: settingKeys.compactMap { key in defaults.string(forKey: key).map { (key, $0) } })
        let manifest = BackupManifest(
            version: BackupManifest.currentVersion, createdAt: Date(), mode: mode, media: snapshots,
            playlists: playlists.map { BackupPlaylist(id: $0.id, name: $0.name, itemIDs: $0.itemIDs, createdAt: $0.createdAt, updatedAt: $0.updatedAt) },
            smartPlaylists: smartPlaylists.map { BackupSmartPlaylist(id: $0.id, name: $0.name, rulesData: $0.rulesData, createdAt: $0.createdAt, updatedAt: $0.updatedAt) },
            settings: settings, recentSearches: defaults.stringArray(forKey: "search.recent.v1") ?? []
        )
        let data = try JSONEncoder.backup.encode(manifest)
        try data.write(to: root.appendingPathComponent("manifest.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        return root
    }

    static func prepareImport(from selectedURL: URL) async throws -> BackupSummary {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Restore-\(UUID().uuidString).offlinetubebackup", isDirectory: true)
        let scoped = selectedURL.startAccessingSecurityScopedResource()
        defer { if scoped { selectedURL.stopAccessingSecurityScopedResource() } }
        try await copy(selectedURL, to: staging)
        let manifestURL = staging.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder.backup.decode(BackupManifest.self, from: data)
        guard manifest.version == BackupManifest.currentVersion else { throw BackupError.unsupportedVersion(manifest.version) }
        var missing = 0
        if manifest.mode == .full {
            for item in manifest.media {
                guard let path = item.mediaFile, safe(path),
                      FileManager.default.fileExists(atPath: staging.appendingPathComponent("Media").appendingPathComponent(path).path)
                else { missing += 1; continue }
                if let path = item.artworkFile, !safe(path) { throw BackupError.invalidPackage }
                if let path = item.customArtworkFile, !safe(path) { throw BackupError.invalidPackage }
            }
        }
        return BackupSummary(manifest: manifest, packageURL: staging, missingFiles: missing)
    }

    static func restore(
        _ summary: BackupSummary,
        mode: RestoreMode,
        context: ModelContext,
        existingMedia: [MediaItem],
        existingPlaylists: [MediaPlaylist],
        existingSmartPlaylists: [CustomSmartPlaylist],
        player: PlayerManager
    ) async throws {
        let replaceFiles = mode == .replace && summary.manifest.mode == .full
        if summary.manifest.mode == .full {
            let required = summary.manifest.media.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
            try FileStore.ensureCapacity(requiredBytes: required)
        }
        if replaceFiles {
            for item in existingMedia { player.stopIfPlaying(item); try FileStore.remove(item); context.delete(item) }
        }
        if mode == .replace {
            existingPlaylists.forEach(context.delete); existingSmartPlaylists.forEach(context.delete)
            try context.save()
        }
        let retainedMedia = replaceFiles ? [] : existingMedia
        var variantMap = Dictionary(uniqueKeysWithValues: retainedMedia.map { (variantKey($0.sourceID, $0.mediaType, $0.quality), $0) })
        var restoredIDs: [UUID: UUID] = [:]
        for snapshot in summary.manifest.media {
            let key = variantKey(snapshot.sourceID, snapshot.mediaType, snapshot.quality)
            if let existing = variantMap[key] {
                apply(snapshot, to: existing); restoredIDs[snapshot.id] = existing.id
                continue
            }
            guard summary.manifest.mode == .full, let path = snapshot.mediaFile, safe(path) else { continue }
            let source = summary.packageURL.appendingPathComponent("Media").appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = FileStore.destination(filename: path)
            try await copy(source, to: destination)
            let item = MediaItem(sourceID: snapshot.sourceID, sourceURL: snapshot.sourceURL, title: snapshot.title,
                                 channel: snapshot.channel, thumbnailURL: snapshot.thumbnailURL, duration: snapshot.duration,
                                 localFilename: destination.lastPathComponent, mediaType: snapshot.mediaType, quality: snapshot.quality)
            item.id = snapshot.id; apply(snapshot, to: item)
            item.artworkFilename = try await restoreArtwork(snapshot.artworkFile, itemID: item.id, package: summary.packageURL)
            item.customArtworkFilename = try await restoreArtwork(snapshot.customArtworkFile, itemID: item.id, package: summary.packageURL)
            context.insert(item); variantMap[key] = item; restoredIDs[snapshot.id] = item.id
        }
        let playlistNames = Set((mode == .merge ? existingPlaylists : []).map { $0.name.lowercased() })
        for value in summary.manifest.playlists where !playlistNames.contains(value.name.lowercased()) {
            let ids = value.itemIDs.compactMap { restoredIDs[$0] }
            let playlist = MediaPlaylist(name: value.name, itemIDs: ids)
            playlist.id = value.id; playlist.createdAt = value.createdAt; playlist.updatedAt = value.updatedAt
            context.insert(playlist)
        }
        let smartNames = Set((mode == .merge ? existingSmartPlaylists : []).map { $0.name.lowercased() })
        for value in summary.manifest.smartPlaylists where !smartNames.contains(value.name.lowercased()) {
            let rules = (try? JSONDecoder().decode([SmartPlaylistRule].self, from: value.rulesData)) ?? []
            let playlist = CustomSmartPlaylist(name: value.name, rules: rules)
            playlist.id = value.id; playlist.createdAt = value.createdAt; playlist.updatedAt = value.updatedAt
            context.insert(playlist)
        }
        summary.manifest.settings.forEach { UserDefaults.standard.set($0.value, forKey: $0.key) }
        UserDefaults.standard.set(summary.manifest.recentSearches, forKey: "search.recent.v1")
        try context.save()
    }

    static func removePackage(_ url: URL?) { if let url { try? FileManager.default.removeItem(at: url) } }

    private static func apply(_ source: BackupMedia, to item: MediaItem) {
        item.title = source.title; item.channel = source.channel; item.thumbnailURL = source.thumbnailURL
        item.playbackPosition = source.playbackPosition; item.createdAt = source.createdAt
        item.isFavorite = source.isFavorite; item.lastPlayedAt = source.lastPlayedAt; item.playCount = source.playCount
        item.notes = source.notes; item.lyricsText = source.lyricsText; item.lyricsFormat = source.lyricsFormat; item.lyricsUpdatedAt = source.lyricsUpdatedAt
    }

    private static func restoreArtwork(_ filename: String?, itemID: UUID, package: URL) async throws -> String? {
        guard let filename, safe(filename) else { return nil }
        let source = package.appendingPathComponent("Artwork").appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let destinationName = "restore-\(itemID.uuidString)-\(UUID().uuidString).\(source.pathExtension)"
        try await copy(source, to: FileStore.artworkDirectory.appendingPathComponent(destinationName))
        return destinationName
    }

    private static func variantKey(_ sourceID: String, _ type: String, _ quality: String) -> String { "\(sourceID)|\(type)|\(quality)" }
    private static func safe(_ path: String) -> Bool { !path.isEmpty && URL(fileURLWithPath: path).lastPathComponent == path && !path.contains("..") }
    private static func copy(_ source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: source, to: destination) }.value
    }
}

enum BackupError: LocalizedError {
    case unsupportedVersion(Int), invalidPackage
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let value): "Unsupported backup version \(value)."
        case .invalidPackage: "The backup package is invalid or unsafe."
        }
    }
}

private extension JSONEncoder {
    static var backup: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value }
}
private extension JSONDecoder {
    static var backup: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
