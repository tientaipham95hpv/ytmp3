import CryptoKit
import Foundation

struct DuplicateDescriptor: Identifiable, Sendable {
    let id: UUID
    let sourceID: String
    let sourceURL: String
    let title: String
    let channel: String
    let duration: Double
    let mediaType: String
    let fileSize: Int64
    let fileHash: String?
}

enum DuplicateReason: String, Sendable {
    case source = "Same source"
    case metadata = "Matching title, channel, and duration"
    case fileHash = "Identical file content"
}

struct DuplicateMatch: Identifiable, Sendable {
    let item: DuplicateDescriptor
    let reason: DuplicateReason
    var id: UUID { item.id }
}

enum DuplicateDetector {
    static func matches(_ candidate: DuplicateDescriptor, in library: [DuplicateDescriptor]) -> [DuplicateMatch] {
        library.compactMap { item in
            guard item.id != candidate.id, item.mediaType == candidate.mediaType else { return nil }
            if sameSource(candidate, item) { return DuplicateMatch(item: item, reason: .source) }
            if sameMetadata(candidate, item) { return DuplicateMatch(item: item, reason: .metadata) }
            if candidate.fileSize > 0, candidate.fileSize == item.fileSize,
               let lhs = candidate.fileHash, let rhs = item.fileHash, lhs == rhs {
                return DuplicateMatch(item: item, reason: .fileHash)
            }
            return nil
        }
    }

    static func groups(_ items: [DuplicateDescriptor]) -> [[DuplicateDescriptor]] {
        guard items.count > 1 else { return [] }
        var parent = Array(items.indices)
        func root(_ value: Int) -> Int {
            var current = value
            while parent[current] != current { current = parent[current] }
            return current
        }
        func connected(_ lhs: DuplicateDescriptor, _ rhs: DuplicateDescriptor) -> Bool {
            guard lhs.mediaType == rhs.mediaType else { return false }
            return sameSource(lhs, rhs) || sameMetadata(lhs, rhs) ||
                (lhs.fileSize > 0 && lhs.fileSize == rhs.fileSize && lhs.fileHash != nil && lhs.fileHash == rhs.fileHash)
        }
        for lhs in items.indices {
            for rhs in items.indices where rhs > lhs && connected(items[lhs], items[rhs]) {
                let leftRoot = root(lhs), rightRoot = root(rhs)
                if leftRoot != rightRoot { parent[rightRoot] = leftRoot }
            }
        }
        return Dictionary(grouping: items.indices, by: root)
            .values.map { $0.map { items[$0] } }.filter { $0.count > 1 }
            .sorted { ($0.map(\.fileSize).reduce(0, +)) > ($1.map(\.fileSize).reduce(0, +)) }
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased().replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func sameSource(_ lhs: DuplicateDescriptor, _ rhs: DuplicateDescriptor) -> Bool {
        if !lhs.sourceID.isEmpty && lhs.sourceID == rhs.sourceID { return true }
        guard !lhs.sourceURL.isEmpty, !rhs.sourceURL.isEmpty else { return false }
        return canonicalURL(lhs.sourceURL) == canonicalURL(rhs.sourceURL)
    }

    private static func sameMetadata(_ lhs: DuplicateDescriptor, _ rhs: DuplicateDescriptor) -> Bool {
        let title = normalized(lhs.title)
        let channel = normalized(lhs.channel)
        return !title.isEmpty && !channel.isEmpty && title == normalized(rhs.title) &&
            channel == normalized(rhs.channel) && abs(lhs.duration - rhs.duration) <= max(2, min(lhs.duration, rhs.duration) * 0.01)
    }

    private static func canonicalURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return normalized(value) }
        components.scheme = nil; components.host = components.host?.lowercased()
        components.queryItems = components.queryItems?.filter { ["v", "list"].contains($0.name.lowercased()) }
        components.fragment = nil
        return components.string ?? normalized(value)
    }
}

#if !DUPLICATE_CORE_TEST
enum MediaFileHasher {
    static func sha256(url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var digest = SHA256()
            while let data = try? handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
#endif

extension MediaItem {
    func duplicateDescriptor(hash: String? = nil) -> DuplicateDescriptor {
        DuplicateDescriptor(id: id, sourceID: sourceID, sourceURL: sourceURL, title: title, channel: channel,
                            duration: duration, mediaType: mediaType, fileSize: fileSize > 0 ? fileSize : FileStore.fileSize(for: self), fileHash: hash)
    }
}
