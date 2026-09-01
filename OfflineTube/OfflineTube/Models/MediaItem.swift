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
    var duration: Double
    var localFilename: String
    var mediaType: String
    var quality: String
    var playbackPosition: Double
    var createdAt: Date

    init(sourceID: String, sourceURL: String, title: String, channel: String, thumbnailURL: String?, duration: Double, localFilename: String, mediaType: String, quality: String) {
        self.id = UUID()
        self.sourceID = sourceID
        self.sourceURL = sourceURL
        self.title = title
        self.channel = channel
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.localFilename = localFilename
        self.mediaType = mediaType
        self.quality = quality
        self.playbackPosition = 0
        self.createdAt = Date()
    }

    var localURL: URL {
        FileStore.downloadsDirectory.appendingPathComponent(localFilename)
    }

    var isVideo: Bool { mediaType == "video" }
}
