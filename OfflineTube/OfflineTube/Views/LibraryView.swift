import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var metadataTarget: MediaItem?
    @State private var showBatchMetadataEditor = false
    @State private var showDuplicates = false
    @State private var showFileImporter = false
    @State private var isImporting = false
    @State private var importProgress = ""

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
                NavigationLink { StatisticsView() } label: { Image(systemName: "chart.bar.xaxis") }
                    .accessibilityLabel("Statistics")
                Button { showFileImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel("Import from Files")
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                Button { showBatchMetadataEditor = true } label: { Image(systemName: "pencil.and.list.clipboard") }
                    .accessibilityLabel("Batch Edit Metadata")
                Button { showDuplicates = true } label: { Image(systemName: "rectangle.stack.badge.minus") }
                    .accessibilityLabel("Find Duplicates")
                Button { withAnimation(.snappy) { gridMode.toggle() } } label: { Image(systemName: gridMode ? "list.bullet" : "square.grid.2x2") }
            }
        }
        .sheet(item: $playlistTarget) { item in AddToPlaylistSheet(item: item, playlists: playlists) }
        .sheet(item: $metadataTarget) { item in MetadataEditorView(item: item) }
        .sheet(isPresented: $showBatchMetadataEditor) { BatchMetadataEditorView(items: items.filter(\.isAvailableOffline)) }
        .sheet(isPresented: $showDuplicates) { DuplicatesView() }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: LocalMediaImporter.allowedTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await importFiles(urls) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .overlay {
            if isImporting {
                VStack(spacing: 12) { ProgressView(); Text(importProgress).font(.subheadline).multilineTextAlignment(.center) }
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).shadow(radius: 12)
            }
        }
        .alert("Couldn’t update Library", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your Library is empty", systemImage: "music.note.house")
        } description: {
            Text("Downloads and media imported from Files will appear here, ready to play offline.")
        } actions: {
            Button("Import from Files") { showFileImporter = true }
                .buttonStyle(.borderedProminent)
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
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { item.isFavorite.toggle(); CloudSyncService.markChanged(item); save(); Haptics.selection() } label: {
                            Label {
                                Text(LocalizedStringKey(item.isFavorite ? "Unfavorite" : "Favorite"))
                            } icon: {
                                Image(systemName: item.isFavorite ? "heart.slash" : "heart.fill")
                            }
                        }.tint(.pink)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { playlistTarget = item } label: { Label("Playlist", systemImage: "text.badge.plus") }.tint(.accentColor)
                        Button(role: .destructive) { delete(item) } label: { Label("Delete", systemImage: "trash") }
                    }
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
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text("\(item.channel) • \(size(item).formattedBytes)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if item.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.tint).font(.caption) }
            Image(systemName: player.currentItem?.id == item.id && player.isPlaying ? "speaker.wave.2.fill" : "ellipsis")
                .foregroundStyle(player.currentItem?.id == item.id ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 6).contentShape(Rectangle())
    }

    @ViewBuilder private func menu(_ item: MediaItem) -> some View {
        Button { player.playNext(item); Haptics.selection() } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.playLater(item); Haptics.selection() } label: { Label("Play Later", systemImage: "text.append") }
        Divider()
        Button { item.isFavorite.toggle(); CloudSyncService.markChanged(item); save() } label: {
            Label { Text(LocalizedStringKey(item.isFavorite ? "Unfavorite" : "Favorite")) } icon: { Image(systemName: item.isFavorite ? "heart.slash" : "heart") }
        }
        Button { metadataTarget = item } label: { Label("Edit Metadata", systemImage: "pencil") }
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

    @MainActor private func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        var importedCount = 0
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            importProgress = "Importing \(index + 1) of \(urls.count)…"
            do {
                let imported = try await LocalMediaImporter.importFile(from: url)
                let item = MediaItem(sourceID: imported.sourceID, sourceURL: imported.sourceURL, title: imported.title,
                    channel: imported.artist, thumbnailURL: nil, duration: imported.duration,
                    localFilename: imported.localFilename, mediaType: imported.mediaType, quality: imported.quality)
                item.fileSize = imported.fileSize
                item.artworkFilename = imported.artworkFilename
                modelContext.insert(item)
                do {
                    try modelContext.save()
                } catch {
                    try? FileStore.remove(item)
                    modelContext.delete(item)
                    throw error
                }
                importedCount += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        isImporting = false
        importProgress = ""
        if failures.isEmpty {
            Haptics.success()
        } else {
            errorMessage = "Imported \(importedCount) of \(urls.count).\n\n" + failures.prefix(5).joined(separator: "\n")
        }
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
