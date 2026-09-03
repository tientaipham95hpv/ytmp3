import CloudKit
import Combine
import Foundation
import SwiftData

@MainActor
final class CloudSyncService: ObservableObject {
    static let shared = CloudSyncService()

    enum State: Equatable {
        case disabled, idle, syncing, synced(Date), unavailable(String)
    }

    @Published private(set) var state: State = .disabled
    private weak var context: ModelContext?
    private var running = false
    private let database = CKContainer.default().privateCloudDatabase
    private let defaults = UserDefaults.standard
    private let settingsKeys = [
        "defaultAudioQuality", "defaultVideoQuality", "appTheme", "accentChoice",
        "appLanguage", "backendURL", "lyricsProviderURL", "search.recent.v1"
    ]

    var isEnabled: Bool { defaults.bool(forKey: "iCloudSyncEnabled") }

    var statusText: String {
        switch state {
        case .disabled: return "iCloud Sync is off. All data stays local."
        case .idle: return "Ready to sync metadata with iCloud."
        case .syncing: return "Syncing metadata…"
        case .synced(let date): return "Last synced \(date.formatted(date: .omitted, time: .shortened))."
        case .unavailable(let message): return message
        }
    }

    func attach(context: ModelContext) {
        self.context = context
        state = isEnabled ? .idle : .disabled
    }

    func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: "iCloudSyncEnabled")
        if enabled { await sync() } else { state = .disabled }
    }

    func sync() async {
        guard isEnabled, !running, let context else {
            if !isEnabled { state = .disabled }
            return
        }
        running = true
        state = .syncing
        defer { running = false }
        do {
            let account = try await CKContainer.default().accountStatus()
            guard account == .available else {
                state = .unavailable("iCloud is unavailable. Local data continues to work normally.")
                return
            }
            let media = try context.fetch(FetchDescriptor<MediaItem>())
            let playlists = try context.fetch(FetchDescriptor<MediaPlaylist>())
            try await syncMedia(media, context: context)
            try await syncPlaylists(playlists, media: media, context: context)
            try await syncSettings()
            try context.save()
            let now = Date()
            defaults.set(now, forKey: "iCloudLastSyncAt")
            state = .synced(now)
        } catch {
            state = .unavailable(Self.friendly(error))
        }
    }

    private func syncMedia(_ media: [MediaItem], context: ModelContext) async throws {
        let remote = try await records(type: "MediaMetadata")
        var remoteBySource = Dictionary(uniqueKeysWithValues: remote.compactMap { record in
            (record["sourceID"] as? String).map { ($0, record) }
        })
        for item in media {
            if let record = remoteBySource.removeValue(forKey: item.sourceID) {
                let remoteDate = record["modifiedAt"] as? Date ?? .distantPast
                if !item.hasCloudSyncBaseline || remoteDate > item.syncModifiedAt {
                    apply(record, to: item)
                } else {
                    try await database.save(mediaRecord(item, existing: record))
                    item.hasCloudSyncBaseline = true
                }
            } else {
                try await database.save(mediaRecord(item, existing: nil))
                item.hasCloudSyncBaseline = true
            }
        }
        // Remote-only media remains in CloudKit. It is applied when that source is downloaded locally.
    }

    private func syncPlaylists(_ playlists: [MediaPlaylist], media: [MediaItem], context: ModelContext) async throws {
        let remote = try await records(type: "MediaPlaylist")
        var localByID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id.uuidString, $0) })
        let sourceByID = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0.sourceID) })
        let idBySource = Dictionary(uniqueKeysWithValues: media.map { ($0.sourceID, $0.id) })

        for record in remote {
            guard let value = record["playlistID"] as? String else { continue }
            let modifiedAt = record["modifiedAt"] as? Date ?? .distantPast
            let sourceIDs = record["sourceIDs"] as? [String] ?? []
            let itemIDs = sourceIDs.compactMap { idBySource[$0] }
            if let playlist = localByID.removeValue(forKey: value) {
                if modifiedAt > playlist.updatedAt {
                    playlist.name = record["name"] as? String ?? playlist.name
                    playlist.itemIDs = Self.unique(itemIDs)
                    playlist.updatedAt = modifiedAt
                } else {
                    try await database.save(playlistRecord(playlist, sourceByID: sourceByID, existing: record))
                }
            } else if let id = UUID(uuidString: value) {
                let playlist = MediaPlaylist(name: record["name"] as? String ?? "Playlist", itemIDs: Self.unique(itemIDs))
                playlist.id = id
                playlist.createdAt = record["createdAt"] as? Date ?? modifiedAt
                playlist.updatedAt = modifiedAt
                context.insert(playlist)
            }
        }
        for playlist in localByID.values {
            try await database.save(playlistRecord(playlist, sourceByID: sourceByID, existing: nil))
        }
    }

    private func syncSettings() async throws {
        let recordID = CKRecord.ID(recordName: "current", zoneID: .default)
        let remote: CKRecord?
        do { remote = try await database.record(for: recordID) }
        catch let error as CKError where error.code == .unknownItem { remote = nil }
        let localDate = defaults.object(forKey: "iCloudSettingsModifiedAt") as? Date ?? .distantPast
        let remoteDate = remote?["modifiedAt"] as? Date ?? .distantPast
        if let remote, remoteDate > localDate {
            for key in settingsKeys {
                if let value = remote[key] { defaults.set(value, forKey: key) }
            }
            defaults.set(remoteDate, forKey: "iCloudSettingsModifiedAt")
        } else {
            let record = remote ?? CKRecord(recordType: "AppSettings", recordID: recordID)
            for key in settingsKeys {
                if let value = defaults.object(forKey: key) as? CKRecordValue { record[key] = value }
                else { record[key] = nil }
            }
            let modifiedAt = localDate == .distantPast ? Date() : localDate
            record["modifiedAt"] = modifiedAt
            try await database.save(record)
        }
    }

    private func mediaRecord(_ item: MediaItem, existing: CKRecord?) -> CKRecord {
        let id = CKRecord.ID(recordName: Self.safeRecordName(item.sourceID), zoneID: .default)
        let record = existing ?? CKRecord(recordType: "MediaMetadata", recordID: id)
        record["sourceID"] = item.sourceID
        record["sourceURL"] = item.sourceURL
        record["title"] = item.title
        record["channel"] = item.channel
        record["notes"] = item.notes
        record["thumbnailURL"] = item.thumbnailURL
        record["mediaType"] = item.mediaType
        record["duration"] = item.duration
        record["isFavorite"] = item.isFavorite ? 1 : 0
        record["playbackPosition"] = item.playbackPosition
        record["playCount"] = item.playCount
        record["lastPlayedAt"] = item.lastPlayedAt
        record["lyricsText"] = item.lyricsText
        record["lyricsFormat"] = item.lyricsFormat
        record["modifiedAt"] = item.syncModifiedAt
        return record
    }

    private func apply(_ record: CKRecord, to item: MediaItem) {
        item.title = record["title"] as? String ?? item.title
        item.channel = record["channel"] as? String ?? item.channel
        item.notes = record["notes"] as? String
        item.thumbnailURL = record["thumbnailURL"] as? String ?? item.thumbnailURL
        item.isFavorite = (record["isFavorite"] as? Int64 ?? 0) != 0
        item.playbackPosition = record["playbackPosition"] as? Double ?? item.playbackPosition
        item.playCount = max(item.playCount, Int(record["playCount"] as? Int64 ?? 0))
        if let remoteLastPlayed = record["lastPlayedAt"] as? Date,
           remoteLastPlayed > (item.lastPlayedAt ?? .distantPast) { item.lastPlayedAt = remoteLastPlayed }
        item.lyricsText = record["lyricsText"] as? String
        item.lyricsFormat = record["lyricsFormat"] as? String
        item.syncModifiedAt = record["modifiedAt"] as? Date ?? Date()
        item.hasCloudSyncBaseline = true
    }

    private func playlistRecord(_ playlist: MediaPlaylist, sourceByID: [UUID: String], existing: CKRecord?) -> CKRecord {
        let id = CKRecord.ID(recordName: playlist.id.uuidString, zoneID: .default)
        let record = existing ?? CKRecord(recordType: "MediaPlaylist", recordID: id)
        record["playlistID"] = playlist.id.uuidString
        record["name"] = playlist.name
        record["sourceIDs"] = Self.unique(playlist.itemIDs.compactMap { sourceByID[$0] })
        record["createdAt"] = playlist.createdAt
        record["modifiedAt"] = playlist.updatedAt
        return record
    }

    private func records(type: String) async throws -> [CKRecord] {
        do {
            var output: [CKRecord] = []
            var cursor: CKQueryOperation.Cursor?
            repeat {
                let page = try await query(type: type, cursor: cursor)
                output.append(contentsOf: page.records)
                cursor = page.cursor
            } while cursor != nil
            return output
        } catch let error as CKError where error.code == .unknownItem {
            return []
        }
    }

    private func query(type: String, cursor: CKQueryOperation.Cursor?) async throws -> (records: [CKRecord], cursor: CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            let operation: CKQueryOperation
            if let cursor { operation = CKQueryOperation(cursor: cursor) }
            else { operation = CKQueryOperation(query: CKQuery(recordType: type, predicate: NSPredicate(value: true))) }
            var records: [CKRecord] = []
            operation.recordMatchedBlock = { _, result in if case .success(let record) = result { records.append(record) } }
            operation.queryResultBlock = { result in
                switch result {
                case .success(let cursor): continuation.resume(returning: (records, cursor))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            self.database.add(operation)
        }
    }

    static func markChanged(_ item: MediaItem) { item.syncModifiedAt = Date() }

    func settingsChanged() {
        defaults.set(Date(), forKey: "iCloudSettingsModifiedAt")
    }

    private static func safeRecordName(_ value: String) -> String {
        Data(value.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func friendly(_ error: Error) -> String {
        if let cloud = error as? CKError {
            switch cloud.code {
            case .notAuthenticated: return "Sign in to iCloud to sync. Local data is unchanged."
            case .networkUnavailable, .networkFailure: return "Offline. Changes will sync when the network returns."
            case .permissionFailure, .badContainer: return "iCloud capability is not available in this build. Local data is unchanged."
            default: break
            }
        }
        return "iCloud sync is temporarily unavailable. Local data is unchanged."
    }
}
