import Foundation
import SwiftData

@Model
final class MediaItem {
    @Attribute(.unique) var id: UUID
    var sourceID: String
    var sourceURL: String
    var title: String
    var channel: String
    var thumbnailURL: String?
    var artworkFilename: String? = nil
    var duration: Double
    var localFilename: String
    var mediaType: String
    var quality: String
    var playbackPosition: Double
    var createdAt: Date
    var isFavorite: Bool = false
    var fileSize: Int64 = 0
    var lastPlayedAt: Date?
    var playCount: Int = 0
    var lyricsText: String? = nil
    var lyricsFormat: String? = nil
    var lyricsUpdatedAt: Date? = nil

    init(sourceID: String, sourceURL: String, title: String, channel: String, thumbnailURL: String?, duration: Double, localFilename: String, mediaType: String, quality: String) {
        self.id = UUID()
        self.sourceID = sourceID
        self.sourceURL = sourceURL
        self.title = title
        self.channel = channel
        self.thumbnailURL = thumbnailURL
        self.artworkFilename = nil
        self.duration = duration
        self.localFilename = localFilename
        self.mediaType = mediaType
        self.quality = quality
        self.playbackPosition = 0
        self.createdAt = Date()
        self.isFavorite = false
        let path = FileStore.downloadsDirectory.appendingPathComponent(localFilename).path
        self.fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        self.lastPlayedAt = nil
        self.playCount = 0
        self.lyricsText = nil
        self.lyricsFormat = nil
        self.lyricsUpdatedAt = nil
    }

    var localURL: URL {
        FileStore.downloadsDirectory.appendingPathComponent(localFilename)
    }

    var artworkURL: URL? {
        guard let artworkFilename else { return nil }
        return FileStore.artworkDirectory.appendingPathComponent(artworkFilename)
    }

    var isAvailableOffline: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    var isVideo: Bool { mediaType == "video" }
}

@Model
final class MediaPlaylist {
    @Attribute(.unique) var id: UUID
    var name: String
    var itemIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(name: String, itemIDs: [UUID] = []) {
        self.id = UUID()
        self.name = name
        self.itemIDs = itemIDs
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
