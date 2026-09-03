import Foundation

let documentCount = 50_000
var documents: [LocalSearchDocument] = []
documents.reserveCapacity(documentCount)
for index in 0..<documentCount {
    let title = index.isMultiple(of: 1_000) ? "Needle Mix \(index)" : "Offline Track \(index)"
    let mediaType = index.isMultiple(of: 4) ? "video" : "audio"
    let lastPlayedAt: Date? = index.isMultiple(of: 3)
        ? Date(timeIntervalSince1970: TimeInterval(index))
        : nil
    let document = LocalSearchDocument(
        id: UUID(),
        kind: SearchDocumentKind.media,
        title: title,
        subtitle: "Channel \(index % 250)",
        mediaType: mediaType,
        isFavorite: index.isMultiple(of: 20),
        duration: Double(60 + index % 2_000),
        fileSize: Int64(1_000_000 + index * 25_000),
        createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
        lastPlayedAt: lastPlayedAt
    )
    documents.append(document)
}

let request = LocalSearchRequest(
    text: "needle",
    mediaFilter: .all,
    durationFilter: .any,
    sizeFilter: .any,
    sort: .relevance
)

let started = Date()
let response = LocalSearchEngine.searchSynchronously(documents: documents, request: request)
let elapsed = Date().timeIntervalSince(started)

precondition(response.hits.count == 50, "Expected 50 exact fake-dataset matches")
precondition(elapsed < 8, "Optimized search exceeded the 8-second safety budget")

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
precondition(
    filtered.hits.allSatisfy { $0.kind == SearchDocumentKind.media },
    "Filtered results must contain media only"
)
print(String(format: "Local search benchmark: %d documents, %d matches in %.3f seconds", documentCount, response.hits.count, elapsed))
