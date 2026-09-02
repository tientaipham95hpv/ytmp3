import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerManager
    @StateObject private var downloads = DownloadViewModel()
    @AppStorage("appTheme") private var theme = AppTheme.system.rawValue
    @AppStorage("accentChoice") private var accent = AccentChoice.pink.rawValue
    @AppStorage("appLanguage") private var language = AppLanguage.vietnamese.rawValue
    @State private var selectedTab = 0
    @State private var showPlayer = false

    private var selectedTheme: AppTheme { AppTheme(rawValue: theme) ?? .system }
    private var accentColor: Color { (AccentChoice(rawValue: accent) ?? .pink).color }

    var body: some View {
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
        .environmentObject(downloads)
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
    }
}
