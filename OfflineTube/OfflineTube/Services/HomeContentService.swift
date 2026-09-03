import Foundation

struct HomeMediaSnapshot: Sendable {
    let id: UUID
    let channel: String
    let duration: Double
    let playbackPosition: Double
    let createdAt: Date
    let isFavorite: Bool
    let fileSize: Int64
    let lastPlayedAt: Date?
    let playCount: Int
    let localPath: String?
}

struct HomePlaylistSnapshot: Sendable {
    let id: UUID
    let itemIDs: [UUID]
    let updatedAt: Date
}

struct HomeContent: Sendable, Equatable {
    var continueListening: [UUID] = []
    var recentlyAdded: [UUID] = []
    var recentlyPlayed: [UUID] = []
    var favorites: [UUID] = []
    var mostPlayed: [UUID] = []
    var forgottenDownloads: [UUID] = []
    var largeFiles: [UUID] = []
    var recommendations: [UUID] = []
    var playlists: [UUID] = []
}

enum HomeContentService {
    static func make(items: [HomeMediaSnapshot], playlists: [HomePlaylistSnapshot], now: Date = Date(), limit: Int = 10) -> HomeContent {
        let items = items.filter { snapshot in
            guard let path = snapshot.localPath else { return true }
            return FileManager.default.fileExists(atPath: path)
        }
        let recent = items.sorted { $0.createdAt > $1.createdAt }
        let played = items.filter { $0.lastPlayedAt != nil }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        let mostPlayed = items.filter { $0.playCount > 0 }.sorted { $0.playCount != $1.playCount ? $0.playCount > $1.playCount : $0.createdAt > $1.createdAt }
        let unfinished = items.filter { $0.duration > 0 && $0.playbackPosition >= 15 && $0.playbackPosition < $0.duration * 0.92 }
            .sorted { ($0.lastPlayedAt ?? $0.createdAt) > ($1.lastPlayedAt ?? $1.createdAt) }
        let forgottenCutoff = now.addingTimeInterval(-60 * 86_400)
        let forgotten = items.filter { ($0.lastPlayedAt ?? $0.createdAt) < forgottenCutoff }
            .sorted { ($0.lastPlayedAt ?? $0.createdAt) < ($1.lastPlayedAt ?? $1.createdAt) }

        var recommendationIDs: [UUID] = []
        func appendUnique(_ candidates: [HomeMediaSnapshot]) {
            for item in candidates where !recommendationIDs.contains(item.id) {
                recommendationIDs.append(item.id)
                if recommendationIDs.count == limit { return }
            }
        }
        appendUnique(unfinished)
        let favoriteChannels = Dictionary(grouping: played.prefix(30), by: { $0.channel.lowercased() })
            .sorted { lhs, rhs in
                lhs.value.reduce(0) { $0 + $1.playCount } > rhs.value.reduce(0) { $0 + $1.playCount }
            }
            .prefix(3).map(\.key)
        appendUnique(items.filter { favoriteChannels.contains($0.channel.lowercased()) && $0.playCount == 0 }.sorted { $0.createdAt > $1.createdAt })
        appendUnique(forgotten)

        let playCountByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.playCount) })
        let rankedPlaylists = playlists.sorted {
            let lhs = $0.itemIDs.reduce(0) { $0 + playCountByID[$1, default: 0] }
            let rhs = $1.itemIDs.reduce(0) { $0 + playCountByID[$1, default: 0] }
            return lhs != rhs ? lhs > rhs : $0.updatedAt > $1.updatedAt
        }
        return HomeContent(
            continueListening: unfinished.prefix(limit).map(\.id),
            recentlyAdded: recent.prefix(limit).map(\.id),
            recentlyPlayed: played.prefix(limit).map(\.id),
            favorites: items.filter(\.isFavorite).sorted { $0.createdAt > $1.createdAt }.prefix(limit).map(\.id),
            mostPlayed: mostPlayed.prefix(limit).map(\.id),
            forgottenDownloads: forgotten.prefix(limit).map(\.id),
            largeFiles: items.filter { $0.fileSize >= 100 * 1_048_576 }.sorted { $0.fileSize > $1.fileSize }.prefix(limit).map(\.id),
            recommendations: recommendationIDs,
            playlists: rankedPlaylists.prefix(limit).map(\.id)
        )
    }
}
