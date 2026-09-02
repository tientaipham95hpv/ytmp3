import SwiftData
import SwiftUI

struct LibraryView: View {
    enum Filter: String, CaseIterable, Identifiable { case all = "All", audio = "Audio", video = "Video", favorites = "Favorites"; var id: String { rawValue } }
    enum Sort: String, CaseIterable, Identifiable { case newest = "Newest", title = "Title", size = "Size", played = "Recently Played"; var id: String { rawValue } }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var items: [MediaItem]
    @Query(sort: \MediaPlaylist.updatedAt, order: .reverse) private var playlists: [MediaPlaylist]
    @State private var filter: Filter = .all
    @State private var sort: Sort = .newest
    @State private var searchText = ""
    @State private var gridMode = false
    @State private var errorMessage: String?
    @State private var playlistTarget: MediaItem?

    private var filteredItems: [MediaItem] {
        var result = items.filter { item in
            let matchesSearch = searchText.isEmpty || item.title.localizedCaseInsensitiveContains(searchText) || item.channel.localizedCaseInsensitiveContains(searchText)
            let matchesFilter = switch filter {
            case .all: true
            case .audio: !item.isVideo
            case .video: item.isVideo
            case .favorites: item.isFavorite
            }
            return matchesSearch && matchesFilter
        }
        switch sort {
        case .newest: result.sort { $0.createdAt > $1.createdAt }
        case .title: result.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .size: result.sort { size($0) > size($1) }
        case .played: result.sort { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        }
        return result
    }

    var body: some View {
        Group {
            if items.isEmpty { emptyState }
            else {
                ScrollView {
                    VStack(spacing: 14) {
                        filterBar
                        if filteredItems.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                                .padding(.top, 50)
                        } else if gridMode { grid }
                        else { list }
                    }.padding(.horizontal, 16)
                }
            }
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Songs, videos, artists")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                Button { withAnimation(.snappy) { gridMode.toggle() } } label: { Image(systemName: gridMode ? "list.bullet" : "square.grid.2x2") }
            }
        }
        .sheet(item: $playlistTarget) { item in AddToPlaylistSheet(item: item, playlists: playlists) }
        .alert("Couldn’t update Library", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your Library is empty", systemImage: "music.note.house")
        } description: {
            Text("Downloads will appear here, ready to play offline.")
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { item in
                    Button { withAnimation(.snappy) { filter = item }; Haptics.tap() } label: { Text(LocalizedStringKey(item.rawValue)) }
                        .buttonStyle(.borderedProminent)
                        .tint(filter == item ? .accentColor : .secondary.opacity(0.16))
                        .foregroundStyle(filter == item ? .white : .primary)
                }
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 6) {
            ForEach(filteredItems) { item in
                Button { player.play(item, queue: filteredItems) } label: { row(item) }
                    .buttonStyle(.plain).contextMenu { menu(item) }
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 18) {
            ForEach(filteredItems) { item in
                Button { player.play(item, queue: filteredItems) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, isVideo: item.isVideo).aspectRatio(1.35, contentMode: .fit)
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(item.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.buttonStyle(.plain).contextMenu { menu(item) }
            }
        }
    }

    private func row(_ item: MediaItem) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, isVideo: item.isVideo, cornerRadius: 10).frame(width: 82, height: 58)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(item.channel) • \(size(item).formattedBytes)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if item.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.tint).font(.caption) }
            Image(systemName: player.currentItem?.id == item.id && player.isPlaying ? "speaker.wave.2.fill" : "ellipsis")
                .foregroundStyle(player.currentItem?.id == item.id ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 6).contentShape(Rectangle())
    }

    @ViewBuilder private func menu(_ item: MediaItem) -> some View {
        Button { item.isFavorite.toggle(); save() } label: {
            Label { Text(LocalizedStringKey(item.isFavorite ? "Unfavorite" : "Favorite")) } icon: { Image(systemName: item.isFavorite ? "heart.slash" : "heart") }
        }
        Button { playlistTarget = item } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
        ShareLink(item: item.localURL) { Label("Share / Export", systemImage: "square.and.arrow.up") }
        Divider()
        Button(role: .destructive) { delete(item) } label: { Label("Delete Download", systemImage: "trash") }
    }

    private func size(_ item: MediaItem) -> Int64 { item.fileSize > 0 ? item.fileSize : FileStore.fileSize(for: item) }
    private func save() { do { try modelContext.save() } catch { errorMessage = error.localizedDescription } }

    private func delete(_ item: MediaItem) {
        do {
            player.stopIfPlaying(item)
            try FileStore.remove(item)
            playlists.forEach { playlist in playlist.itemIDs.removeAll { $0 == item.id } }
            modelContext.delete(item)
            try modelContext.save()
            Haptics.success()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct AddToPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    let playlists: [MediaPlaylist]
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Playlists") {
                    ForEach(playlists) { playlist in
                        Button {
                            if !playlist.itemIDs.contains(item.id) { playlist.itemIDs.append(item.id); playlist.updatedAt = Date() }
                            try? modelContext.save(); dismiss()
                        } label: { Label(playlist.name, systemImage: playlist.itemIDs.contains(item.id) ? "checkmark.circle.fill" : "music.note.list") }
                    }
                }
                Section("New Playlist") {
                    TextField("Playlist name", text: $newName)
                    Button("Create and Add") {
                        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        modelContext.insert(MediaPlaylist(name: name, itemIDs: [item.id]))
                        try? modelContext.save(); dismiss()
                    }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Add to Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
