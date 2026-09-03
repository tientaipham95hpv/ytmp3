import Foundation

enum SearchDocumentKind: String, Sendable {
    case media, playlist
}

enum SearchMediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all, audio, video, favorites
    var id: String { rawValue }
}

enum SearchDurationFilter: String, CaseIterable, Identifiable, Sendable {
    case any, underFive, fiveToTwenty, overTwenty
    var id: String { rawValue }
}

enum SearchSizeFilter: String, CaseIterable, Identifiable, Sendable {
    case any, underHundredMB, hundredToFiveHundredMB, overFiveHundredMB
    var id: String { rawValue }
}

enum SearchSort: String, CaseIterable, Identifiable, Sendable {
    case relevance, title, dateAdded, recentlyPlayed
    var id: String { rawValue }
}

struct LocalSearchDocument: Identifiable, Sendable {
    let id: UUID
    let kind: SearchDocumentKind
    let title: String
    let subtitle: String
    let mediaType: String?
    let isFavorite: Bool
    let duration: Double
    let fileSize: Int64
    let createdAt: Date
    let lastPlayedAt: Date?
}

struct LocalSearchRequest: Sendable {
    let text: String
    let mediaFilter: SearchMediaFilter
    let durationFilter: SearchDurationFilter
    let sizeFilter: SearchSizeFilter
    let sort: SearchSort
}

struct LocalSearchHit: Identifiable, Sendable {
    let id: UUID
    let kind: SearchDocumentKind
    let score: Int
}

struct LocalSearchResponse: Sendable {
    let hits: [LocalSearchHit]
    let suggestions: [String]
}

enum LocalSearchEngine {
    static func search(
        documents: [LocalSearchDocument],
        request: LocalSearchRequest
    ) async -> LocalSearchResponse {
        await Task.detached(priority: .userInitiated) {
            searchSynchronously(documents: documents, request: request)
        }.value
    }

    static func searchSynchronously(
        documents: [LocalSearchDocument],
        request: LocalSearchRequest
    ) -> LocalSearchResponse {
        let normalizedQuery = normalize(request.text)
        let tokens = normalizedQuery.split(separator: " ").map(String.init)
        var matches: [(document: LocalSearchDocument, score: Int)] = []
        matches.reserveCapacity(min(documents.count, 512))

        for document in documents {
            guard matchesFilters(document, request: request) else { continue }
            let score = relevanceScore(document, query: normalizedQuery, tokens: tokens)
            guard normalizedQuery.isEmpty || score > 0 else { continue }
            matches.append((document, score))
        }

        matches.sort { lhs, rhs in
            switch request.sort {
            case .relevance:
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.document.title.localizedStandardCompare(rhs.document.title) == .orderedAscending
            case .title:
                return lhs.document.title.localizedStandardCompare(rhs.document.title) == .orderedAscending
            case .dateAdded:
                return lhs.document.createdAt > rhs.document.createdAt
            case .recentlyPlayed:
                return (lhs.document.lastPlayedAt ?? .distantPast) > (rhs.document.lastPlayedAt ?? .distantPast)
            }
        }

        let hits = matches.prefix(500).map {
            LocalSearchHit(id: $0.document.id, kind: $0.document.kind, score: $0.score)
        }
        return LocalSearchResponse(
            hits: hits,
            suggestions: suggestions(from: documents, query: normalizedQuery)
        )
    }

    private static func matchesFilters(
        _ document: LocalSearchDocument,
        request: LocalSearchRequest
    ) -> Bool {
        switch request.mediaFilter {
        case .all: break
        case .audio: guard document.mediaType == "audio" else { return false }
        case .video: guard document.mediaType == "video" else { return false }
        case .favorites: guard document.kind == .media, document.isFavorite else { return false }
        }

        if request.durationFilter != .any {
            guard document.kind == .media else { return false }
            switch request.durationFilter {
            case .any: break
            case .underFive: guard document.duration < 300 else { return false }
            case .fiveToTwenty: guard (300..<1_200).contains(document.duration) else { return false }
            case .overTwenty: guard document.duration >= 1_200 else { return false }
            }
        }

        if request.sizeFilter != .any {
            guard document.kind == .media else { return false }
            switch request.sizeFilter {
            case .any: break
            case .underHundredMB: guard document.fileSize < 100 * 1_048_576 else { return false }
            case .hundredToFiveHundredMB:
                guard (100 * 1_048_576..<500 * 1_048_576).contains(document.fileSize) else { return false }
            case .overFiveHundredMB: guard document.fileSize >= 500 * 1_048_576 else { return false }
            }
        }
        return true
    }

    private static func relevanceScore(
        _ document: LocalSearchDocument,
        query: String,
        tokens: [String]
    ) -> Int {
        guard !query.isEmpty else { return 1 }
        let title = normalize(document.title)
        let subtitle = normalize(document.subtitle)
        let type = document.mediaType ?? "playlist"
        let favoriteTerms = document.isFavorite ? " favorite favorites" : ""
        let searchable = "\(title) \(subtitle) \(type)\(favoriteTerms)"
        guard tokens.allSatisfy(searchable.contains) else { return 0 }

        var score = 0
        if title == query { score += 1_000 }
        if title.hasPrefix(query) { score += 500 }
        if title.contains(query) { score += 250 }
        if subtitle.hasPrefix(query) { score += 140 }
        if subtitle.contains(query) { score += 80 }
        if type == query { score += 120 }
        score += tokens.reduce(0) { partial, token in
            partial + (title.hasPrefix(token) ? 30 : title.contains(token) ? 15 : 5)
        }
        return score
    }

    private static func suggestions(from documents: [LocalSearchDocument], query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        var seen = Set<String>()
        var values: [String] = []
        for document in documents {
            for candidate in [document.title, document.subtitle] where !candidate.isEmpty {
                let normalized = normalize(candidate)
                guard normalized.contains(query), seen.insert(normalized).inserted else { continue }
                values.append(candidate)
                if values.count == 8 { return values }
            }
        }
        return values
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
