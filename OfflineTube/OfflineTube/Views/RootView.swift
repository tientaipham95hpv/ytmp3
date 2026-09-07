import SwiftUI
import SwiftData

struct RootView: View {
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @AppStorage("appTheme") private var theme = AppTheme.system.rawValue
    @AppStorage("accentChoice") private var accent = AccentChoice.pink.rawValue
    @AppStorage("appLanguage") private var language = AppLanguage.vietnamese.rawValue

    private var selectedTheme: AppTheme { AppTheme(rawValue: theme) ?? .system }
    private var accentColor: Color { (AccentChoice(rawValue: accent) ?? .pink).color }

    var body: some View {
        Group {
            if onboardingCompleted {
                MainAppView()
            } else {
                OnboardingView()
            }
        }
        .preferredColorScheme(selectedTheme.colorScheme)
        .environment(\.locale, Locale(identifier: language))
        .tint(accentColor)
    }
}

private struct MainAppView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var cloudSync: CloudSyncService
    @EnvironmentObject private var appLock: AppLockManager
    @StateObject private var downloads = DownloadViewModel()
    @StateObject private var network = NetworkMonitor.shared
    @Query private var mediaItems: [MediaItem]
    @State private var artworkRecoveryTask: Task<Void, Never>?
    @State private var selectedTab = 0
    @State private var showPlayer = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: OnboardingView.completedKey)

    var body: some View {
        ZStack {
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
            NavigationStack { SearchView() }.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(2)
            NavigationStack { DownloadsView() }.tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }.tag(3)
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentItem != nil && !showPlayer {
                MiniPlayerView {
                    Haptics.selection()
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { showPlayer = true }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        }
        if showPlayer {
            PlayerView(onClose: { withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { showPlayer = false } })
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
        }
        if appLock.isPrivacyShieldVisible || appLock.isLocked {
            AppLockView(showsUnlockControls: appLock.isLocked && !appLock.isPrivacyShieldVisible)
                .environmentObject(appLock)
                .transition(.opacity)
                .zIndex(100)
        }
        }
        .environmentObject(downloads)
        .environmentObject(network)
        .task {
            downloads.attach(modelContext: modelContext)
            player.attach(modelContext: modelContext)
            cloudSync.attach(context: modelContext)
            reconcileOfflineLibrary()
            await cloudSync.sync()
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .animation(.snappy, value: player.currentItem?.id)
        .animation(.snappy, value: network.isConnected)
        .overlay(alignment: .top) {
            if let message = downloads.completedMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.green, in: Capsule()).shadow(radius: 10)
                    .padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(4))
                        if downloads.completedMessage == message { downloads.completedMessage = nil }
                    }
            }
        }
        .animation(.snappy, value: downloads.completedMessage)
        .animation(.easeInOut(duration: 0.15), value: appLock.isPrivacyShieldVisible)
        .animation(.easeInOut(duration: 0.2), value: appLock.isLocked)
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
                .interactiveDismissDisabled()
        }
        .onChange(of: selectedTab) { _, _ in Haptics.selection() }
        .onAppear {
            appLock.sceneDidBecomeActive()
            if appLock.isLocked { appLock.unlock() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                appLock.sceneDidBecomeActive()
                if appLock.isLocked { appLock.unlock() }
                reconcileOfflineLibrary()
                Task { await cloudSync.sync() }
            } else if phase == .inactive {
                appLock.sceneDidBecomeInactive()
                player.savePlaybackState()
                Task { await cloudSync.sync() }
            } else if phase == .background {
                appLock.sceneDidEnterBackground()
                player.savePlaybackState()
                Task { await cloudSync.sync() }
            }
        }
        .onChange(of: network.isConnected) { _, connected in
            if connected {
                Task { await cloudSync.sync() }
                cacheMissingArtwork()
            } else {
                artworkRecoveryTask?.cancel()
            }
        }
        .onDisappear { artworkRecoveryTask?.cancel() }
    }


    private func reconcileOfflineLibrary() {
        let missing = mediaItems.filter { !$0.isAvailableOffline }
        let missingIDs = Set(missing.map(\.id))
        if let current = player.currentItem, missingIDs.contains(current.id) { player.stopIfPlaying(current) }
        // Preserve metadata and playlist membership: a file may only be temporarily
        // unavailable during a restore or file-provider transition.
        cacheMissingArtwork()
    }

    private func cacheMissingArtwork() {
        guard network.isConnected else { return }
        let candidates = mediaItems.filter { $0.isAvailableOffline && $0.artworkFilename == nil && $0.thumbnailURL != nil }
        artworkRecoveryTask?.cancel()
        artworkRecoveryTask = Task {
            for (index, item) in candidates.enumerated() {
                guard !Task.isCancelled, network.isConnected else { return }
                if let filename = await FileStore.saveArtwork(from: item.thumbnailURL, sourceID: item.sourceID) {
                    item.artworkFilename = filename
                    if index.isMultiple(of: 20) { try? modelContext.save() }
                }
            }
            try? modelContext.save()
        }
    }
}
