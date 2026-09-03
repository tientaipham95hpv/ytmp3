import Foundation

func item(_ id: UUID = UUID(), source: String, url: String = "", title: String, channel: String,
          duration: Double, type: String = "audio", size: Int64 = 100, hash: String? = nil) -> DuplicateDescriptor {
    DuplicateDescriptor(id: id, sourceID: source, sourceURL: url, title: title, channel: channel,
                        duration: duration, mediaType: type, fileSize: size, fileHash: hash)
}

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}

let original = item(source: "youtube-1", url: "https://youtube.com/watch?v=abc&utm_source=x", title: "Café Song", channel: "Artist", duration: 200)
let sameID = item(source: "youtube-1", title: "Different", channel: "Other", duration: 99)
expect(DuplicateDetector.matches(sameID, in: [original]).first?.reason == .source, "sourceID match")

let normalized = item(source: "youtube-2", title: "  CAFE—SONG! ", channel: "ARTIST", duration: 201.8)
expect(DuplicateDetector.matches(normalized, in: [original]).first?.reason == .metadata, "normalized metadata match")

let tooLong = item(source: "youtube-3", title: "Cafe Song", channel: "Artist", duration: 210)
expect(DuplicateDetector.matches(tooLong, in: [original]).isEmpty, "duration false positive")

let video = item(source: "youtube-4", title: "Cafe Song", channel: "Artist", duration: 200, type: "video")
expect(DuplicateDetector.matches(video, in: [original]).isEmpty, "media type false positive")

let hashA = item(source: "a", title: "One", channel: "A", duration: 10, size: 999, hash: "deadbeef")
let hashB = item(source: "b", title: "Two", channel: "B", duration: 20, size: 999, hash: "deadbeef")
expect(DuplicateDetector.matches(hashB, in: [hashA]).first?.reason == .fileHash, "hash match")

let groups = DuplicateDetector.groups([original, sameID, normalized, tooLong, video, hashA, hashB])
expect(groups.count == 2, "two duplicate groups")
expect(groups.map(\.count).sorted() == [2, 3], "transitive grouping")
print("Duplicate detection tests passed")
