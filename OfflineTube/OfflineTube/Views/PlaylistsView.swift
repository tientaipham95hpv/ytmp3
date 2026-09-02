import SwiftData
import SwiftUI

struct PlaylistsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MediaPlaylist.updatedAt, order: .reverse) private var playlists: [MediaPlaylist]
    @Query(sort: \CustomSmartPlaylist.updatedAt, order: .reverse) private var smartPlaylists: [CustomSmartPlaylist]
    @Query private var items: [MediaItem]
    @State private var showCreate = false
    @State private var name = ""
    @State private var showSmartBuilder = false

    var body: some View {
        List {
            Section("Smart Playlists") {
                NavigationLink { SmartPlaylistDetail(kind: .recentlyAdded, allItems: items) } label: { Label("Recently Added", systemImage: "clock.badge.checkmark") }
                NavigationLink { SmartPlaylistDetail(kind: .recentlyPlayed, allItems: items) } label: { Label("Recently Played", systemImage: "clock.arrow.circlepath") }
                NavigationLink { SmartPlaylistDetail(kind: .mostPlayed, allItems: items) } label: { Label("Most Played", systemImage: "chart.bar.fill") }
                NavigationLink { SmartPlaylistDetail(kind: .favorites, allItems: items) } label: { Label("Favorites", systemImage: "heart.fill") }
                NavigationLink { SmartPlaylistDetail(kind: .neverPlayed, allItems: items) } label: { Label("Never Played", systemImage: "play.slash") }
                NavigationLink { SmartPlaylistDetail(kind: .largeFiles, allItems: items) } label: { Label("Large Files", systemImage: "externaldrive.fill") }
                NavigationLink { SmartPlaylistDetail(kind: .audioOnly, allItems: items) } label: { Label("Audio Only", systemImage: "waveform") }
                NavigationLink { SmartPlaylistDetail(kind: .videoOnly, allItems: items) } label: { Label("Video Only", systemImage: "video.fill") }
            }
            if !smartPlaylists.isEmpty {
                Section("Custom Smart Playlists") {
                    ForEach(smartPlaylists) { playlist in
                        NavigationLink { CustomSmartPlaylistDetail(playlist: playlist, allItems: items) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name).font(.headline)
                                    Text("\(playlist.rules.count) rules • AND").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "wand.and.stars").foregroundStyle(.tint) }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { smartPlaylists[$0] }.forEach(modelContext.delete)
                        try? modelContext.save()
                    }
                }
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
                    .contextMenu {
                        Button(role: .destructive) { modelContext.delete(playlist); try? modelContext.save(); Haptics.success() } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .onDelete { offsets in
                    offsets.map { playlists[$0] }.forEach(modelContext.delete)
                    try? modelContext.save()
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            Menu {
                Button { showCreate = true } label: { Label("New Playlist", systemImage: "music.note.list") }
                Button { showSmartBuilder = true } label: { Label("New Smart Playlist", systemImage: "wand.and.stars") }
            } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $showSmartBuilder) { SmartPlaylistBuilderView() }
        .alert("New Playlist", isPresented: $showCreate) {
            TextField("Name", text: $name)
            Button("Create") { create() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { name = "" }
        }
    }

    private func create() {
        modelContext.insert(MediaPlaylist(name: name.trimmingCharacters(in: .whitespacesAndNewlines)))
        try? modelContext.save(); name = ""; Haptics.success()
    }
}

private struct SmartPlaylistDetail: View {
    enum Kind { case recentlyAdded, recentlyPlayed, mostPlayed, favorites, neverPlayed, largeFiles, audioOnly, videoOnly }
    @EnvironmentObject private var player: PlayerManager
    let kind: Kind
    let allItems: [MediaItem]

    private var title: LocalizedStringKey {
        switch kind {
        case .recentlyAdded: "Recently Added"; case .recentlyPlayed: "Recently Played"; case .mostPlayed: "Most Played"
        case .favorites: "Favorites"; case .neverPlayed: "Never Played"; case .largeFiles: "Large Files"
        case .audioOnly: "Audio Only"; case .videoOnly: "Video Only"
        }
    }
    private var items: [MediaItem] {
        let availableItems = allItems.filter(\.isAvailableOffline)
        return switch kind {
        case .recentlyAdded: availableItems.sorted { $0.createdAt > $1.createdAt }
        case .recentlyPlayed: availableItems.filter { $0.lastPlayedAt != nil }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .mostPlayed: availableItems.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }
        case .favorites: availableItems.filter(\.isFavorite).sorted { $0.createdAt > $1.createdAt }
        case .neverPlayed: availableItems.filter { $0.playCount == 0 }.sorted { $0.createdAt > $1.createdAt }
        case .largeFiles: availableItems.sorted { $0.fileSize > $1.fileSize }.filter { $0.fileSize >= 100 * 1_048_576 }
        case .audioOnly: availableItems.filter { !$0.isVideo }.sorted { $0.createdAt > $1.createdAt }
        case .videoOnly: availableItems.filter(\.isVideo).sorted { $0.createdAt > $1.createdAt }
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
                    .contextMenu {
                        Button { player.play(item, queue: items) } label: { Label("Play", systemImage: "play.fill") }
                        Button { player.playNext(item) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                        Button { player.playLater(item) } label: { Label("Play Later", systemImage: "text.append") }
                        ShareLink(item: item.localURL) { Label("Share / Export", systemImage: "square.and.arrow.up") }
                    }
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

private struct CustomSmartPlaylistDetail: View {
    @EnvironmentObject private var player: PlayerManager
    let playlist: CustomSmartPlaylist
    let allItems: [MediaItem]

    private var items: [MediaItem] {
        allItems.filter { playlist.matches($0) }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Rules", value: "\(playlist.rules.count) • AND")
                HStack {
                    Button { player.playAll(items) } label: { Label("Play All", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    Button { player.playAll(items, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                }.buttonStyle(.borderedProminent).disabled(items.isEmpty)
            }
            if items.isEmpty {
                ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle", description: Text("This playlist updates automatically when Library items match every rule."))
            } else {
                ForEach(items) { item in
                    Button { player.play(item, queue: items) } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, isVideo: item.isVideo).frame(width: 64, height: 46)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).lineLimit(2)
                                Text("\(item.channel) • \(item.fileSize.formattedBytes)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
        }.navigationTitle(playlist.name)
    }
}

private struct SmartPlaylistBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name = ""
    @State private var rules = [SmartPlaylistRule.defaultRule(for: .mediaType)]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Smart playlist name", text: $name) }
                Section {
                    ForEach($rules) { $rule in ruleEditor($rule) }
                        .onDelete { rules.remove(atOffsets: $0) }
                    Menu {
                        ForEach(SmartRuleField.allCases) { field in
                            Button(field.title) { rules.append(.defaultRule(for: field)); Haptics.selection() }
                        }
                    } label: { Label("Add Rule", systemImage: "plus.circle.fill") }
                } header: {
                    Text("Rules")
                } footer: {
                    Text("An item must match every rule (AND). Results update automatically from your local Library.")
                }
            }
            .navigationTitle("New Smart Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
            }
        }
    }

    @ViewBuilder private func ruleEditor(_ rule: Binding<SmartPlaylistRule>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Rule", selection: Binding(get: { rule.wrappedValue.field }, set: { rule.wrappedValue = .defaultRule(for: $0) })) {
                ForEach(SmartRuleField.allCases) { Text($0.title).tag($0) }
            }
            switch rule.wrappedValue.field {
            case .mediaType:
                Picker("Value", selection: rule.value) { Text("Audio").tag("audio"); Text("Video").tag("video") }.pickerStyle(.segmented)
            case .favorite:
                Picker("Value", selection: rule.value) { Text("Favorite").tag("true"); Text("Not Favorite").tag("false") }.pickerStyle(.segmented)
            case .textContains:
                TextField("Text to find", text: rule.value).textInputAutocapitalization(.never)
            case .minimumFileSizeMB:
                HStack { TextField("100", text: rule.value).keyboardType(.decimalPad); Text("MB").foregroundStyle(.secondary) }
            case .addedWithinDays:
                HStack { TextField("30", text: rule.value).keyboardType(.numberPad); Text("days").foregroundStyle(.secondary) }
            case .minimumPlayCount:
                HStack { TextField("1", text: rule.value).keyboardType(.numberPad); Text("plays").foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 4)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !rules.isEmpty && rules.allSatisfy { $0.field != .textContains || !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func save() {
        modelContext.insert(CustomSmartPlaylist(name: name.trimmingCharacters(in: .whitespacesAndNewlines), rules: rules))
        try? modelContext.save(); Haptics.success(); dismiss()
    }
}
