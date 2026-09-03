import Foundation
import SwiftData

enum BuiltInSmartPlaylist: CaseIterable {
    case recentlyAdded, recentlyPlayed, mostPlayed, favorites, neverPlayed, largeFiles, audioOnly, videoOnly

    func sortedItems(from items: [MediaItem]) -> [MediaItem] {
        let availableItems = items.filter(\.isAvailableOffline)
        return switch self {
        case .recentlyAdded: availableItems.sorted { $0.createdAt > $1.createdAt }
        case .recentlyPlayed: availableItems.filter { $0.lastPlayedAt != nil }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .mostPlayed: availableItems.filter { $0.playCount > 0 }.sorted { $0.playCount != $1.playCount ? $0.playCount > $1.playCount : $0.createdAt > $1.createdAt }
        case .favorites: availableItems.filter(\.isFavorite).sorted { $0.createdAt > $1.createdAt }
        case .neverPlayed: availableItems.filter { $0.playCount == 0 }.sorted { $0.createdAt > $1.createdAt }
        case .largeFiles: availableItems.filter { $0.fileSize >= 100 * 1_048_576 }.sorted { $0.fileSize > $1.fileSize }
        case .audioOnly: availableItems.filter { !$0.isVideo }.sorted { $0.createdAt > $1.createdAt }
        case .videoOnly: availableItems.filter(\.isVideo).sorted { $0.createdAt > $1.createdAt }
        }
    }
}

enum SmartRuleField: String, Codable, CaseIterable, Identifiable {
    case mediaType, favorite, textContains, minimumFileSizeMB, addedWithinDays, minimumPlayCount
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mediaType: "Media Type"
        case .favorite: "Favorite"
        case .textContains: "Title or Channel Contains"
        case .minimumFileSizeMB: "File Size At Least"
        case .addedWithinDays: "Added Within"
        case .minimumPlayCount: "Play Count At Least"
        }
    }
}

struct SmartPlaylistRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var field: SmartRuleField
    var value: String

    func matches(_ item: MediaItem) -> Bool {
        switch field {
        case .mediaType:
            return value == "any" || item.mediaType == value
        case .favorite:
            return item.isFavorite == (value == "true")
        case .textContains:
            let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty || item.title.localizedCaseInsensitiveContains(query) || item.channel.localizedCaseInsensitiveContains(query)
        case .minimumFileSizeMB:
            return item.fileSize >= Int64((Double(value) ?? 0) * 1_048_576)
        case .addedWithinDays:
            let days = max(1, Double(value) ?? 30)
            return item.createdAt >= Date().addingTimeInterval(-days * 86_400)
        case .minimumPlayCount:
            return item.playCount >= max(0, Int(value) ?? 0)
        }
    }

    static func defaultRule(for field: SmartRuleField) -> SmartPlaylistRule {
        let value = switch field {
        case .mediaType: "audio"
        case .favorite: "true"
        case .textContains: ""
        case .minimumFileSizeMB: "100"
        case .addedWithinDays: "30"
        case .minimumPlayCount: "1"
        }
        return SmartPlaylistRule(field: field, value: value)
    }
}

@Model
final class CustomSmartPlaylist {
    @Attribute(.unique) var id: UUID
    var name: String
    var rulesData: Data
    var createdAt: Date
    var updatedAt: Date

    init(name: String, rules: [SmartPlaylistRule]) {
        id = UUID(); self.name = name
        rulesData = (try? JSONEncoder().encode(rules)) ?? Data()
        createdAt = Date(); updatedAt = Date()
    }

    var rules: [SmartPlaylistRule] {
        get { (try? JSONDecoder().decode([SmartPlaylistRule].self, from: rulesData)) ?? [] }
        set { rulesData = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = Date() }
    }

    func matches(_ item: MediaItem) -> Bool {
        item.isAvailableOffline && rules.allSatisfy { $0.matches(item) }
    }
}
