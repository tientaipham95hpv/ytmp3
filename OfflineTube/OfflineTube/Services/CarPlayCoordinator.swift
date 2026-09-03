import CarPlay
import SwiftData
import UIKit

/// CarPlay support is intentionally dormant until Apple grants the
/// `com.apple.developer.carplay-audio` managed entitlement and the CarPlay
/// scene is registered in Info.plist. Keeping the integration compiled but
/// unregistered lets unsigned builds continue to install normally.
@MainActor
final class CarPlayCoordinator {
    static let shared = CarPlayCoordinator()

    private weak var interfaceController: CPInterfaceController?
    private let modelContext = AppModelStore.shared.mainContext
    private let player = PlayerManager.shared

    private init() {}

    func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(makeRootTemplate(), animated: false, completion: nil)
    }

    func disconnect(_ interfaceController: CPInterfaceController) {
        if self.interfaceController === interfaceController {
            self.interfaceController = nil
        }
    }

    private func makeRootTemplate() -> CPTemplate {
        let playlists = makePlaylistsTemplate()
        playlists.tabTitle = String(localized: "Playlists")
        playlists.tabImage = UIImage(systemName: "music.note.list")

        let recent = makeMediaTemplate(
            title: String(localized: "Recently Played"),
            items: recentlyPlayedItems()
        )
        recent.tabTitle = String(localized: "Recently Played")
        recent.tabImage = UIImage(systemName: "clock.fill")

        let favorites = makeMediaTemplate(
            title: String(localized: "Favorites"),
            items: favoriteItems()
        )
        favorites.tabTitle = String(localized: "Favorites")
        favorites.tabImage = UIImage(systemName: "heart.fill")

        return CPTabBarTemplate(templates: [playlists, recent, favorites])
    }

    private func makePlaylistsTemplate() -> CPListTemplate {
        let playlists = fetchPlaylists()
        let rows = playlists.prefix(50).map { playlist in
            let count = mediaItems(for: playlist).count
            let row = CPListItem(
                text: playlist.name,
                detailText: String(localized: "\(count) songs")
            )
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, completion in
                self?.showPlaylist(playlist)
                completion()
            }
            return row
        }
        return listTemplate(
            title: String(localized: "Playlists"),
            rows: rows,
            emptyMessage: String(localized: "No Playlists")
        )
    }

    private func makeMediaTemplate(title: String, items: [MediaItem]) -> CPListTemplate {
        let playableItems = Array(items.prefix(50))
        let rows = playableItems.map { item in
            let row = CPListItem(text: item.title, detailText: item.channel)
            row.isPlaying = player.currentItem?.id == item.id && player.isPlaying
            row.handler = { [weak self] _, completion in
                self?.play(item, in: playableItems)
                completion()
            }
            return row
        }
        return listTemplate(
            title: title,
            rows: rows,
            emptyMessage: String(localized: "No audio available offline")
        )
    }

    private func listTemplate(title: String, rows: [CPListItem], emptyMessage: String) -> CPListTemplate {
        let displayRows: [CPListItem]
        if rows.isEmpty {
            let empty = CPListItem(text: emptyMessage, detailText: nil)
            empty.isEnabled = false
            displayRows = [empty]
        } else {
            displayRows = rows
        }
        return CPListTemplate(title: title, sections: [CPListSection(items: displayRows)])
    }

    private func showPlaylist(_ playlist: MediaPlaylist) {
        guard let interfaceController else { return }
        let template = makeMediaTemplate(title: playlist.name, items: mediaItems(for: playlist))
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func play(_ item: MediaItem, in items: [MediaItem]) {
        player.play(item, queue: items)
        guard let interfaceController else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func fetchAudioItems() -> [MediaItem] {
        let descriptor = FetchDescriptor<MediaItem>()
        let items = (try? modelContext.fetch(descriptor)) ?? []
        return items.filter { !$0.isVideo && $0.isAvailableOffline }
    }

    private func fetchPlaylists() -> [MediaPlaylist] {
        var descriptor = FetchDescriptor<MediaPlaylist>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func mediaItems(for playlist: MediaPlaylist) -> [MediaItem] {
        let byID = Dictionary(uniqueKeysWithValues: fetchAudioItems().map { ($0.id, $0) })
        return playlist.itemIDs.compactMap { byID[$0] }
    }

    private func recentlyPlayedItems() -> [MediaItem] {
        fetchAudioItems()
            .filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    private func favoriteItems() -> [MediaItem] {
        fetchAudioItems()
            .filter(\.isFavorite)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

/// Add this delegate to the CarPlay scene configuration only after Apple
/// approves the audio entitlement. It is not registered by unsigned builds.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        CarPlayCoordinator.shared.connect(interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        CarPlayCoordinator.shared.disconnect(interfaceController)
    }
}
