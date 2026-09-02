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

private struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @Bindable var playlist: MediaPlaylist
    let allItems: [MediaItem]
    @State private var editingName = false
    @State private var newName = ""

    private var items: [MediaItem] { playlist.itemIDs.compactMap { id in allItems.first { $0.id == id } } }

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
                    HStack { ArtworkView(url: item.thumbnailURL, isVideo: item.isVideo).frame(width: 60, height: 44); VStack(alignment: .leading) { Text(item.title).lineLimit(1); Text(item.channel).font(.caption).foregroundStyle(.secondary) } }
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
