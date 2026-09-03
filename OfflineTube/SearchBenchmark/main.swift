import Foundation

let documentCount = 50_000
let documents = (0..<documentCount).map { index in
    LocalSearchDocument(
        id: UUID(),
        kind: .media,
        title: index.isMultiple(of: 1_000) ? "Needle Mix \(index)" : "Offline Track \(index)",
        subtitle: "Channel \(index % 250)",
        mediaType: index.isMultiple(of: 4) ? "video" : "audio",
        isFavorite: index.isMultiple(of: 20),
        duration: Double(60 + index % 2_000),
        fileSize: Int64(1_000_000 + index * 25_000),
        createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
        lastPlayedAt: index.isMultiple(of: 3) ? Date(timeIntervalSince1970: TimeInterval(index)) : nil
    )
}

let request = LocalSearchRequest(
    text: "needle",
    mediaFilter: .all,
    durationFilter: .any,
    sizeFilter: .any,
    sort: .relevance
)

let started = ContinuousClock.now
let response = LocalSearchEngine.searchSynchronously(documents: documents, request: request)
let elapsed = started.duration(to: .now)

precondition(response.hits.count == 50, "Expected 50 exact fake-dataset matches")
precondition(elapsed < .seconds(8), "Search exceeded the 8-second safety budget")

let filtered = LocalSearchEngine.searchSynchronously(
    documents: documents,
    request: LocalSearchRequest(
        text: "",
        mediaFilter: .favorites,
        durationFilter: .overTwenty,
        sizeFilter: .overFiveHundredMB,
        sort: .recentlyPlayed
    )
)
precondition(filtered.hits.allSatisfy { $0.kind == .media }, "Filtered results must contain media only")
print("Local search benchmark: \(documentCount) documents, \(response.hits.count) matches in \(elapsed)")
