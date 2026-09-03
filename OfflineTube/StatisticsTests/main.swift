import Foundation

let file = FileManager.default.temporaryDirectory.appendingPathComponent("statistics-\(UUID().uuidString).json")
let store = LocalStatisticsStore(fileURL: file)
let now = Date()

await store.recordStarted(id: "song", title: "Song", channel: "Artist", isVideo: false, at: now)
await store.recordActiveTime(id: "song", title: "Song", channel: "Artist", isVideo: false, seconds: 125, at: now)
await store.recordCompleted(id: "song", title: "Song", channel: "Artist", isVideo: false)
await store.recordStarted(id: "video", title: "Video", channel: "Channel", isVideo: true, at: now)
await store.recordActiveTime(id: "video", title: "Video", channel: "Channel", isVideo: true, seconds: 65, at: now)
await store.recordSkipped(id: "video", title: "Video", channel: "Channel", isVideo: true)

let snapshot = await store.current()
precondition(snapshot.playCount == 2)
precondition(snapshot.completionCount == 1)
precondition(snapshot.skipCount == 1)
precondition(snapshot.totalListeningSeconds == 125)
precondition(snapshot.totalWatchSeconds == 65)
precondition(snapshot.days.count == 1)
precondition(snapshot.streak(referenceDate: now) == 1)

let restored = LocalStatisticsStore(fileURL: file)
let restoredSnapshot = await restored.current()
precondition(restoredSnapshot.playCount == 2)
precondition(restoredSnapshot.media["song"]?.title == "Song")
try? FileManager.default.removeItem(at: file)
print("Statistics tests passed")
