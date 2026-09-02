import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var player: PlayerManager
    @StateObject private var downloads = DownloadViewModel()
    @StateObject private var network = NetworkMonitor.shared
    @Query private var mediaItems: [MediaItem]
    @Query private var playlists: [MediaPlaylist]
    @AppStorage("appTheme") private var theme = AppTheme.system.rawValue
    @AppStorage("accentChoice") private var accent = AccentChoice.pink.rawValue
    @AppStorage("appLanguage") private var language = AppLanguage.vietnamese.rawValue
    @State private var selectedTab = 0
    @State private var showPlayer = false

    private var selectedTheme: AppTheme { AppTheme(rawValue: theme) ?? .system }
    private var accentColor: Color { (AccentChoice(rawValue: accent) ?? .pink).color }

    var body: some View {
        VStack(spacing: 0) {
            if !network.isConnected {
                Label("Offline — local Library and playback are available", systemImage: "wifi.slash")
                    .font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
                    .padding(.vertical, 7).background(.orange.opacity(0.18))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView() }.tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            NavigationStack {
                LibraryView().toolbar {
                    ToolbarItem(placement: .topBarLeading) { NavigationLink { PlaylistsView() } label: { Image(systemName: "music.note.list") } }
                }
            }.tabItem { Label("Library", systemImage: "square.stack.fill") }.tag(1)
            NavigationStack { DownloadsView() }.tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }.tag(2)
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
        }
        }
        .environmentObject(downloads)
        .environmentObject(network)
        .task {
            downloads.attach(modelContext: modelContext)
            player.attach(modelContext: modelContext)
            reconcileOfflineLibrary()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentItem != nil { MiniPlayerView { showPlayer = true } }
        }
        .fullScreenCover(isPresented: $showPlayer) { PlayerView() }
        .preferredColorScheme(selectedTheme.colorScheme)
        .environment(\.locale, Locale(identifier: language))
        .tint(accentColor)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .animation(.snappy, value: player.currentItem?.id)
        .animation(.snappy, value: network.isConnected)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reconcileOfflineLibrary() }
            else if phase == .inactive || phase == .background { player.savePlaybackState() }
        }
    }


    private func reconcileOfflineLibrary() {
        let missing = mediaItems.filter { !$0.isAvailableOffline }
        if !missing.isEmpty {
            let missingIDs = Set(missing.map(\.id))
            if let current = player.currentItem, missingIDs.contains(current.id) { player.stopIfPlaying(current) }
            playlists.forEach { playlist in
                playlist.itemIDs.removeAll { missingIDs.contains($0) }
                playlist.updatedAt = Date()
            }
            missing.forEach(modelContext.delete)
            try? modelContext.save()
        }
        cacheMissingArtwork()
    }

    private func cacheMissingArtwork() {
        guard network.isConnected else { return }
        let candidates = mediaItems.filter { $0.isAvailableOffline && $0.artworkFilename == nil && $0.thumbnailURL != nil }
        for item in candidates {
            Task {
                if let filename = await FileStore.saveArtwork(from: item.thumbnailURL, sourceID: item.sourceID) {
                    item.artworkFilename = filename
                    try? modelContext.save()
                }
            }
        }
    }
}
