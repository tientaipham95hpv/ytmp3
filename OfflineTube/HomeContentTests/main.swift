import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let now = Date(timeIntervalSince1970: 2_000_000_000)
let recent = UUID(), unfinished = UUID(), favorite = UUID(), forgotten = UUID(), large = UUID(), sameChannel = UUID()
let items = [
    HomeMediaSnapshot(id: recent, channel: "New", duration: 200, playbackPosition: 0, createdAt: now, isFavorite: false, fileSize: 10, lastPlayedAt: nil, playCount: 0, localPath: nil),
    HomeMediaSnapshot(id: unfinished, channel: "Daily", duration: 200, playbackPosition: 80, createdAt: now.addingTimeInterval(-100), isFavorite: false, fileSize: 20, lastPlayedAt: now.addingTimeInterval(-10), playCount: 5, localPath: nil),
    HomeMediaSnapshot(id: favorite, channel: "Daily", duration: 100, playbackPosition: 100, createdAt: now.addingTimeInterval(-200), isFavorite: true, fileSize: 30, lastPlayedAt: now.addingTimeInterval(-20), playCount: 12, localPath: nil),
    HomeMediaSnapshot(id: sameChannel, channel: "Daily", duration: 100, playbackPosition: 0, createdAt: now.addingTimeInterval(-300), isFavorite: false, fileSize: 40, lastPlayedAt: nil, playCount: 0, localPath: nil),
    HomeMediaSnapshot(id: forgotten, channel: "Old", duration: 100, playbackPosition: 0, createdAt: now.addingTimeInterval(-90 * 86_400), isFavorite: false, fileSize: 50, lastPlayedAt: nil, playCount: 0, localPath: nil),
    HomeMediaSnapshot(id: large, channel: "Film", duration: 100, playbackPosition: 0, createdAt: now.addingTimeInterval(-400), isFavorite: false, fileSize: 150 * 1_048_576, lastPlayedAt: nil, playCount: 2, localPath: nil)
]
let highUse = HomePlaylistSnapshot(id: UUID(), itemIDs: [favorite, unfinished], updatedAt: now.addingTimeInterval(-100))
let recentPlaylist = HomePlaylistSnapshot(id: UUID(), itemIDs: [recent], updatedAt: now)
let result = HomeContentService.make(items: items, playlists: [recentPlaylist, highUse], now: now)

expect(result.continueListening == [unfinished], "Continue Listening must exclude completed and untouched media")
expect(result.recentlyAdded.first == recent, "Recently Added ordering is wrong")
expect(result.recentlyPlayed == [unfinished, favorite], "Recently Played ordering is wrong")
expect(result.favorites == [favorite], "Favorites filter is wrong")
expect(result.mostPlayed.first == favorite, "Most Played ordering is wrong")
expect(result.forgottenDownloads == [forgotten], "Forgotten Downloads cutoff is wrong")
expect(result.largeFiles == [large], "Large Files threshold is wrong")
expect(Array(result.recommendations.prefix(2)) == [unfinished, sameChannel], "Recommendations should prefer unfinished then familiar channels")
expect(Set(result.recommendations).count == result.recommendations.count, "Recommendations contain duplicates")
expect(result.playlists.first == highUse.id, "Frequently used playlist should rank first")
print("Home content tests passed")
