import Foundation

struct MockMedia {
    let id: UUID
    let title: String
    let channel: String
    let fileSize: Int64
    let createdAt: Date
    let isFavorite: Bool
}

// Deterministic, file-free stress data. This exercises the same collection work
// used by Library and large playlists without requiring media assets in CI.
let mediaCount = 10_000
let playlistCount = 8_000
let media: [MockMedia] = (0..<mediaCount).map { index in
    MockMedia(
        id: UUID(),
        title: index.isMultiple(of: 137) ? "Needle \(index)" : "Offline media \(index)",
        channel: "Channel \(index % 300)",
        fileSize: Int64((index % 2_048) + 1) * 1_048_576,
        createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
        isFavorite: index.isMultiple(of: 17)
    )
}
let playlistIDs = Array(media.prefix(playlistCount).reversed().map(\.id))

let started = Date()
let query = "needle"
let filtered = media.filter {
    $0.title.localizedCaseInsensitiveContains(query) || $0.channel.localizedCaseInsensitiveContains(query)
}.sorted { $0.fileSize > $1.fileSize }
let byID = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
let playlist = playlistIDs.compactMap { byID[$0] }
let elapsed = Date().timeIntervalSince(started)

precondition(filtered.count == 73, "Unexpected deterministic search result count")
precondition(playlist.count == playlistCount, "Large playlist lookup lost records")
precondition(playlist.first?.id == media[playlistCount - 1].id, "Playlist order changed")
precondition(elapsed < 8, "Library stress pass exceeded the CI safety budget")
print(String(format: "Library stress: %d media, %d playlist items in %.3f seconds", mediaCount, playlistCount, elapsed))
