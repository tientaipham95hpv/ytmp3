import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @Query private var items: [MediaItem]
    @Query(sort: \MediaPlaylist.updatedAt, order: .reverse) private var playlists: [MediaPlaylist]

    @State private var searchText = ""
    @State private var mediaFilter: SearchMediaFilter = .all
    @State private var durationFilter: SearchDurationFilter = .any
    @State private var sizeFilter: SearchSizeFilter = .any
    @State private var sort: SearchSort = .relevance
    @State private var hits: [LocalSearchHit] = []
    @State private var suggestions: [String] = []
    @State private var recentSearches: [String] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var mediaByID: [UUID: MediaItem] = [:]
    @State private var playlistByID: [UUID: MediaPlaylist] = [:]
    @State private var suggestedChannels: [String] = []

    private var matchedMedia: [MediaItem] {
        let lookup = mediaByID
        return hits.compactMap { $0.kind == .media ? lookup[$0.id] : nil }
    }

    private var activeFilterCount: Int {
        (mediaFilter == .all ? 0 : 1) + (durationFilter == .any ? 0 : 1) +
        (sizeFilter == .any ? 0 : 1) + (sort == .relevance ? 0 : 1)
    }

    var body: some View {
        Group {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && activeFilterCount == 0 {
                startContent
            } else if isSearching && hits.isEmpty {
                searchLoading
            } else if hits.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                resultsList
            }
        }
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Titles, channels, playlists, media type")
        .searchSuggestions {
            ForEach(suggestions, id: \.self) { suggestion in
                Button { choose(suggestion) } label: {
                    Label(suggestion, systemImage: "magnifyingglass")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
        }
        .task {
            loadRecentSearches()
            scheduleSearch(immediate: true)
        }
        .onAppear { scheduleSearch(immediate: true) }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: searchText) { _, _ in scheduleSearch() }
        .onChange(of: mediaFilter) { _, _ in scheduleSearch(immediate: true) }
        .onChange(of: durationFilter) { _, _ in scheduleSearch(immediate: true) }
        .onChange(of: sizeFilter) { _, _ in scheduleSearch(immediate: true) }
        .onChange(of: sort) { _, _ in scheduleSearch(immediate: true) }
        .onChange(of: items.count) { _, _ in scheduleSearch(immediate: true) }
        .onChange(of: playlists.count) { _, _ in scheduleSearch(immediate: true) }
        .onSubmit(of: .search) { saveRecentSearch(searchText) }
    }

    private var startContent: some View {
        List {
            if !recentSearches.isEmpty {
                Section {
                    ForEach(recentSearches, id: \.self) { value in
                        Button { choose(value) } label: {
                            Label(value, systemImage: "clock.arrow.circlepath")
                        }
                    }
                    .onDelete(perform: deleteRecentSearches)
                } header: {
                    HStack {
                        Text("Recent Searches")
                        Spacer()
                        Button("Clear") { clearRecentSearches() }
                            .font(.caption)
                    }
                }
            }
            Section("Suggestions") {
                Button {
                    mediaFilter = .audio
                    searchText = ""
                } label: { Label("Audio", systemImage: "waveform") }
                Button {
                    mediaFilter = .video
                    searchText = ""
                } label: { Label("Video", systemImage: "play.rectangle") }
                Button {
                    mediaFilter = .favorites
                    searchText = ""
                } label: { Label("Favorites", systemImage: "heart.fill") }
                ForEach(suggestedChannels, id: \.self) { channel in
                    Button { choose(channel) } label: { Label(channel, systemImage: "person.crop.circle") }
                }
            }
            Section {
                Label("Search works entirely offline", systemImage: "checkmark.icloud.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var searchLoading: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { _ in SkeletonRow() }
            }.padding()
        }
    }

    private var resultsList: some View {
        List {
            Section {
                ForEach(hits) { hit in
                    if hit.kind == .media, let item = mediaByID[hit.id] {
                        mediaRow(item)
                    } else if hit.kind == .playlist, let playlist = playlistByID[hit.id] {
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist, allItems: items)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name).font(.headline).lineLimit(2)
                                    Text("\(playlist.itemIDs.count) items").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "music.note.list")
                                    .frame(width: 48, height: 48)
                                    .background(.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
            } header: {
                Text("\(hits.count) results")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isSearching { ProgressView().padding().background(.ultraThinMaterial, in: Circle()).padding() }
        }
    }

    private func mediaRow(_ item: MediaItem) -> some View {
        Button {
            saveRecentSearch(searchText)
            player.play(item, queue: matchedMedia)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, isVideo: item.isVideo, cornerRadius: 10)
                    .frame(width: 76, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text("\(item.channel) • \(item.isVideo ? String(localized: "Video") : String(localized: "Audio"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("\(item.duration.mediaTime) • \(item.fileSize.formattedBytes)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if item.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.tint).font(.caption) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { player.playNext(item) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { player.playLater(item) } label: { Label("Play Later", systemImage: "text.append") }
            Button {
                item.isFavorite.toggle()
                CloudSyncService.markChanged(item)
                try? modelContext.save()
                scheduleSearch(immediate: true)
            } label: {
                Label {
                    Text(LocalizedStringKey(item.isFavorite ? "Unfavorite" : "Favorite"))
                } icon: {
                    Image(systemName: item.isFavorite ? "heart.slash" : "heart")
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Section("Media") {
                Picker("Media", selection: $mediaFilter) {
                    Label("All", systemImage: "square.stack").tag(SearchMediaFilter.all)
                    Label("Audio", systemImage: "waveform").tag(SearchMediaFilter.audio)
                    Label("Video", systemImage: "play.rectangle").tag(SearchMediaFilter.video)
                    Label("Favorites", systemImage: "heart").tag(SearchMediaFilter.favorites)
                }
            }
            Section("Duration") {
                Picker("Duration", selection: $durationFilter) {
                    Text("Any duration").tag(SearchDurationFilter.any)
                    Text("Under 5 minutes").tag(SearchDurationFilter.underFive)
                    Text("5–20 minutes").tag(SearchDurationFilter.fiveToTwenty)
                    Text("Over 20 minutes").tag(SearchDurationFilter.overTwenty)
                }
            }
            Section("File Size") {
                Picker("File Size", selection: $sizeFilter) {
                    Text("Any size").tag(SearchSizeFilter.any)
                    Text("Under 100 MB").tag(SearchSizeFilter.underHundredMB)
                    Text("100–500 MB").tag(SearchSizeFilter.hundredToFiveHundredMB)
                    Text("Over 500 MB").tag(SearchSizeFilter.overFiveHundredMB)
                }
            }
            Section("Sort") {
                Picker("Sort", selection: $sort) {
                    Text("Relevance").tag(SearchSort.relevance)
                    Text("Title").tag(SearchSort.title)
                    Text("Date Added").tag(SearchSort.dateAdded)
                    Text("Recently Played").tag(SearchSort.recentlyPlayed)
                }
            }
            if activeFilterCount > 0 {
                Button("Reset Filters", role: .destructive) { resetFilters() }
            }
        } label: {
            Image(systemName: activeFilterCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .accessibilityLabel("Search Filters")
        }
    }

    private func documents() -> [LocalSearchDocument] {
        mediaByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        playlistByID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        var channelCounts: [String: Int] = [:]
        items.forEach { if !$0.channel.isEmpty { channelCounts[$0.channel, default: 0] += 1 } }
        suggestedChannels = channelCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        let media = items.filter(\.isAvailableOffline).map {
            LocalSearchDocument(
                id: $0.id, kind: .media, title: $0.title, subtitle: $0.channel,
                mediaType: $0.isVideo ? "video" : "audio", isFavorite: $0.isFavorite,
                duration: $0.duration, fileSize: $0.fileSize, createdAt: $0.createdAt,
                lastPlayedAt: $0.lastPlayedAt
            )
        }
        let playlistDocuments = playlists.map {
            LocalSearchDocument(
                id: $0.id, kind: .playlist, title: $0.name, subtitle: String(localized: "Playlist"),
                mediaType: nil, isFavorite: false, duration: 0, fileSize: 0,
                createdAt: $0.createdAt, lastPlayedAt: nil
            )
        }
        return media + playlistDocuments
    }

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let request = LocalSearchRequest(
            text: searchText, mediaFilter: mediaFilter, durationFilter: durationFilter,
            sizeFilter: sizeFilter, sort: sort
        )
        let snapshot = documents()
        isSearching = true
        searchTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
            }
            let response = await LocalSearchEngine.search(documents: snapshot, request: request)
            guard !Task.isCancelled else { return }
            hits = response.hits
            suggestions = response.suggestions
            isSearching = false
        }
    }

    private func choose(_ value: String) {
        searchText = value
        saveRecentSearch(value)
    }

    private func resetFilters() {
        mediaFilter = .all; durationFilter = .any; sizeFilter = .any; sort = .relevance
    }

    private func loadRecentSearches() {
        recentSearches = UserDefaults.standard.stringArray(forKey: "search.recent.v1") ?? []
    }

    private func saveRecentSearch(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentSearches.removeAll { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        recentSearches = Array(recentSearches.prefix(10))
        UserDefaults.standard.set(recentSearches, forKey: "search.recent.v1")
        CloudSyncService.shared.settingsChanged()
    }

    private func deleteRecentSearches(at offsets: IndexSet) {
        recentSearches.remove(atOffsets: offsets)
        UserDefaults.standard.set(recentSearches, forKey: "search.recent.v1")
        CloudSyncService.shared.settingsChanged()
    }

    private func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: "search.recent.v1")
        CloudSyncService.shared.settingsChanged()
    }
}
