import SwiftData
import SwiftUI

struct PlaylistsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MediaPlaylist.updatedAt, order: .reverse) private var playlists: [MediaPlaylist]
    @Query private var items: [MediaItem]
    @State private var showCreate = false
    @State private var name = ""

    var body: some View {
        List {
            Section("Smart Playlists") {
                NavigationLink { SmartPlaylistDetail(kind: .recent, allItems: items) } label: { Label("Recently Added", systemImage: "clock.badge.checkmark") }
                NavigationLink { SmartPlaylistDetail(kind: .mostPlayed, allItems: items) } label: { Label("Most Played", systemImage: "chart.bar.fill") }
                NavigationLink { SmartPlaylistDetail(kind: .unfinished, allItems: items) } label: { Label("Unfinished", systemImage: "gauge.with.dots.needle.33percent") }
                NavigationLink { SmartPlaylistDetail(kind: .favorites, allItems: items) } label: { Label("Favorites", systemImage: "heart.fill") }
            }
            if playlists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "music.note.list", description: Text("Create a playlist to organize downloads."))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(playlists) { playlist in
                    NavigationLink { PlaylistDetailView(playlist: playlist, allItems: items) } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(playlist.name).font(.headline)
                                Text("\(playlist.itemIDs.count) items").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "music.note.list").frame(width: 42, height: 42).background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10)) }
                    }
                }
                .onDelete { offsets in
                    offsets.map { playlists[$0] }.forEach(modelContext.delete)
                    try? modelContext.save()
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar { Button { showCreate = true } label: { Image(systemName: "plus") } }
        .alert("New Playlist", isPresented: $showCreate) {
            TextField("Name", text: $name)
            Button("Create") { create() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { name = "" }
        }
    }

    private func create() {
        modelContext.insert(MediaPlaylist(name: name.trimmingCharacters(in: .whitespacesAndNewlines)))
        try? modelContext.save(); name = ""
    }
}

private struct SmartPlaylistDetail: View {
    enum Kind { case recent, mostPlayed, unfinished, favorites }
    @EnvironmentObject private var player: PlayerManager
    let kind: Kind
    let allItems: [MediaItem]

    private var title: LocalizedStringKey {
        switch kind { case .recent: "Recently Added"; case .mostPlayed: "Most Played"; case .unfinished: "Unfinished"; case .favorites: "Favorites" }
    }
    private var items: [MediaItem] {
        let availableItems = allItems.filter(\.isAvailableOffline)
        return switch kind {
        case .recent: Array(availableItems.sorted { $0.createdAt > $1.createdAt }.prefix(50))
        case .mostPlayed: availableItems.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }
        case .unfinished: availableItems.filter { $0.playbackPosition > 10 && $0.playbackPosition < max(0, $0.duration - 10) }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .favorites: availableItems.filter(\.isFavorite).sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "sparkles")
            } else {
                Section { Button { player.playAll(items) } label: { Label("Play All", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent) }
                ForEach(items) { item in
                    Button { player.play(item, queue: items) } label: {
                        HStack { ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, isVideo: item.isVideo).frame(width: 64, height: 46); VStack(alignment: .leading) { Text(item.title).lineLimit(1); Text(item.channel).font(.caption).foregroundStyle(.secondary) }; Spacer(); ShareLink(item: item.localURL) { Image(systemName: "square.and.arrow.up") } }
                    }.buttonStyle(.plain)
                }
            }
        }.navigationTitle(title)
    }
}

private struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @Bindable var playlist: MediaPlaylist
    let allItems: [MediaItem]
    @State private var editingName = false
    @State private var newName = ""

    private var items: [MediaItem] { playlist.itemIDs.compactMap { id in allItems.first { $0.id == id && $0.isAvailableOffline } } }

    var body: some View {
        List {
            Section {
                HStack {
                    Button { player.playAll(items) } label: { Label("Play All", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    Button { player.playAll(items, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                }.buttonStyle(.borderedProminent).disabled(items.isEmpty)
            }
            ForEach(items) { item in
                Button { player.play(item, queue: items) } label: {
                    HStack { ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, isVideo: item.isVideo).frame(width: 60, height: 44); VStack(alignment: .leading) { Text(item.title).lineLimit(1); Text(item.channel).font(.caption).foregroundStyle(.secondary) } }
                }.buttonStyle(.plain)
            }
            .onDelete { offsets in playlist.itemIDs.remove(atOffsets: offsets); save() }
            .onMove { source, destination in playlist.itemIDs.move(fromOffsets: source, toOffset: destination); save() }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            EditButton()
            Button { newName = playlist.name; editingName = true } label: { Image(systemName: "pencil") }
        }
        .alert("Rename Playlist", isPresented: $editingName) {
            TextField("Name", text: $newName)
            Button("Save") { playlist.name = newName.trimmingCharacters(in: .whitespacesAndNewlines); save() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func save() { playlist.updatedAt = Date(); try? modelContext.save() }
}
