import Foundation

enum LocalMediaImportPolicy {
    static let audioExtensions = Set(["mp3", "m4a", "aac", "wav"])
    static let videoExtensions = Set(["mp4", "mov"])
    static let allowedExtensions = audioExtensions.union(videoExtensions)

    static func mediaType(forExtension value: String) -> String? {
        let ext = value.lowercased()
        if audioExtensions.contains(ext) { return "audio" }
        if videoExtensions.contains(ext) { return "video" }
        return nil
    }
}
