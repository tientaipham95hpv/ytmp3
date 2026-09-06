import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var cloudSync: CloudSyncService
    @EnvironmentObject private var downloads: DownloadViewModel
    @EnvironmentObject private var appLock: AppLockManager
    @Query private var items: [MediaItem]
    @AppStorage("defaultAudioQuality") private var audioQuality = "original"
    @AppStorage("defaultVideoQuality") private var videoQuality = "720"
    @AppStorage("appTheme") private var theme = AppTheme.system.rawValue
    @AppStorage("accentChoice") private var accent = AccentChoice.pink.rawValue
    @AppStorage("appLanguage") private var language = AppLanguage.vietnamese.rawValue
    @AppStorage("backendURL") private var backendURL = "https://offlinetube.cineviet.live"
    @AppStorage("lyricsProviderURL") private var lyricsProviderURL = ""
    @State private var resultMessage: String?
    @State private var accessToken = ""
    @State private var showCookieImporter = false
    @State private var isUpdatingCookies = false
    @State private var showCookieGuide = false
    @State private var showOnboarding = false
    @State private var lyricsAPIKey = ""
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("audioCrossfadeSeconds") private var audioCrossfadeSeconds = 0
    @AppStorage("maxConcurrentDownloads") private var maxConcurrentDownloads = 2
    @AppStorage("downloadWiFiOnly") private var downloadWiFiOnly = false
    @AppStorage("pauseDownloadsOnCellular") private var pauseDownloadsOnCellular = false
    @AppStorage("preferredDownloadWindowEnabled") private var preferredWindowEnabled = false
    @AppStorage("preferredDownloadStartHour") private var preferredStartHour = 22
    @AppStorage("preferredDownloadEndHour") private var preferredEndHour = 7
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    var body: some View {
        presentedSettings
            .fileImporter(isPresented: $showCookieImporter, allowedContentTypes: [.plainText, .text], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        resultMessage = localized("No cookie file was selected.", "Chưa chọn file cookie.")
                        return
                    }
                    updateCookies(from: url)
                case .failure(let error):
                    resultMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showCookieGuide) {
                CookieGuideView {
                    showCookieGuide = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showCookieImporter = true }
                }
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView { showOnboarding = false }
                    .interactiveDismissDisabled()
            }
            .alert("OfflineTube", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) { Button("OK") { resultMessage = nil } } message: { Text(resultMessage ?? "") }
    }

    private var presentedSettings: some View {
        observedSettings
            .onChange(of: maxConcurrentDownloads) { _, _ in schedulerSettingsChanged() }
            .onChange(of: downloadWiFiOnly) { _, _ in schedulerSettingsChanged() }
            .onChange(of: pauseDownloadsOnCellular) { _, _ in schedulerSettingsChanged() }
            .onChange(of: preferredWindowEnabled) { _, _ in schedulerSettingsChanged() }
            .onChange(of: preferredStartHour) { _, _ in schedulerSettingsChanged() }
            .onChange(of: preferredEndHour) { _, _ in schedulerSettingsChanged() }
    }

    private var observedSettings: some View {
        settingsForm
            .navigationTitle("Settings")
            .task { accessToken = KeychainStore.adminToken() ?? ""; lyricsAPIKey = KeychainStore.lyricsAPIKey() ?? "" }
            .onChange(of: iCloudSyncEnabled) { _, enabled in Task { await cloudSync.setEnabled(enabled) } }
            .onChange(of: audioQuality) { _, _ in cloudSync.settingsChanged() }
            .onChange(of: videoQuality) { _, _ in cloudSync.settingsChanged() }
            .onChange(of: theme) { _, _ in cloudSync.settingsChanged() }
            .onChange(of: accent) { _, _ in cloudSync.settingsChanged() }
            .onChange(of: language) { _, _ in cloudSync.settingsChanged() }
            .onChange(of: backendURL) { _, _ in cloudSync.settingsChanged() }
            .onChange(of: lyricsProviderURL) { _, _ in cloudSync.settingsChanged() }
            .onChange(of: audioCrossfadeSeconds) { _, _ in cloudSync.settingsChanged() }
    }

    private var settingsForm: some View {
        Form {
            downloadsSection
            Section("Audio Playback") {
                Picker("Crossfade", selection: $audioCrossfadeSeconds) {
                    Text("Off").tag(0)
                    ForEach([2, 4, 6, 8, 10], id: \.self) { seconds in Text("\(seconds)s").tag(seconds) }
                }
                Text("Crossfade overlaps only two local audio tracks near the transition. Video and Repeat One use normal playback.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Storage") {
                NavigationLink { StorageManagementView() } label: {
                    Label("Manage Storage", systemImage: "internaldrive")
                }
                NavigationLink { BackupRestoreView() } label: {
                    Label("Backup & Restore", systemImage: "externaldrive.badge.timemachine")
                }
            }
            Section("iCloud Sync") {
                Toggle("Enable iCloud Sync", isOn: $iCloudSyncEnabled)
                HStack {
                    Text(cloudSync.statusText).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    if case .syncing = cloudSync.state { ProgressView().controlSize(.small) }
                }
                Button("Sync Now") { Task { await cloudSync.sync() } }
                    .disabled(!iCloudSyncEnabled || cloudSync.state == .syncing)
                Text("Syncs playlists, favorites, playback progress, play history, settings, and custom text metadata. Media and artwork files remain on this device.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Language", selection: $language) { ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) } }
                Picker("Theme", selection: $theme) { ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) } }
                Picker("Accent color", selection: $accent) {
                    ForEach(AccentChoice.allCases) { choice in Label(choice.title, systemImage: "circle.fill").foregroundStyle(choice.color).tag(choice.rawValue) }
                }
                Button {
                    Haptics.tap()
                    onboardingCompleted = false
                } label: {
                    Label("Show Onboarding Again", systemImage: "sparkles.rectangle.stack")
                }
            }
            Section("App Lock") {
                Toggle("Require \(appLock.biometryDisplayName)", isOn: Binding(
                    get: { appLock.isEnabled },
                    set: { enabled in
                        if enabled { appLock.requestEnable() }
                        else { appLock.disable() }
                    }
                ))
                if appLock.isEnabled {
                    Picker("Lock After", selection: Binding(
                        get: { appLock.lockDelay },
                        set: { appLock.setLockDelay($0) }
                    )) {
                        ForEach(AppLockManager.LockDelay.allCases) { delay in
                            Text(delay.title).tag(delay)
                        }
                    }
                }
                if let error = appLock.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Uses iOS biometrics only. Offline audio continues playing while the interface is locked.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Backend") {
                TextField("Backend URL", text: $backendURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Text("The current download service is preserved. Change this only when using another server.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Lyrics Provider") {
                TextField("Custom provider API URL (optional)", text: $lyricsProviderURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("API key (optional)", text: $lyricsAPIKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save Lyrics API Key") { saveLyricsKey() }
                Text("Find Lyrics uses LRCLIB through the app backend by default. Set a custom provider URL only to override it. The optional API key is stored in Keychain.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Server Administration") {
                SecureField("Administrator access token", text: $accessToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save administrator token") { saveToken() }
                    .disabled(accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    showCookieImporter = true
                } label: {
                    if isUpdatingCookies { HStack { ProgressView(); Text("Checking and updating cookies…") } }
                    else { Label("Replace YouTube cookies", systemImage: "lock.doc") }
                }
                .disabled(KeychainStore.adminToken() == nil || isUpdatingCookies)
                Button { showCookieGuide = true } label: {
                    Label("Get cookies on iPhone", systemImage: "iphone.and.arrow.forward")
                }
                Text("Downloads are authorized automatically per device. This administrator token is only needed to replace the server's YouTube cookie.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("About") {
                Button { showOnboarding = true } label: {
                    Label("Show Onboarding Again", systemImage: "sparkles.rectangle.stack")
                }
                LabeledContent("OfflineTube", value: "Phase 2")
            }
        }
    }

    @ViewBuilder private var downloadsSection: some View {
        Section("Downloads") {
            Picker("Default audio quality", selection: $audioQuality) {
                Text("Original / M4A").tag("original"); Text("MP3 128").tag("128"); Text("MP3 192").tag("192"); Text("MP3 320").tag("320")
            }
            Picker("Default video quality", selection: $videoQuality) {
                Text("360p").tag("360"); Text("480p").tag("480"); Text("720p").tag("720"); Text("1080p").tag("1080"); Text("Best").tag("best")
            }
            Picker("Max concurrent downloads", selection: $maxConcurrentDownloads) {
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle("Wi‑Fi only for new downloads", isOn: $downloadWiFiOnly)
            Toggle("Pause downloads on cellular", isOn: $pauseDownloadsOnCellular)
            Toggle("Preferred download hours", isOn: $preferredWindowEnabled)
            if preferredWindowEnabled {
                Picker("Start", selection: $preferredStartHour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                Picker("End", selection: $preferredEndHour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
            }
            Text("Queued jobs persist after restart. iOS decides when suspended apps receive background execution time; schedules are preferences, not exact alarms.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func schedulerSettingsChanged() {
        downloads.schedulerSettingsDidChange()
        cloudSync.settingsChanged()
    }

    private func localized(_ english: String, _ vietnamese: String) -> String { language == AppLanguage.vietnamese.rawValue ? vietnamese : english }

    private func saveToken() {
        do {
            try KeychainStore.saveToken(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))
            resultMessage = localized("Access token saved securely.", "Đã lưu token an toàn vào Keychain.")
        } catch { resultMessage = error.localizedDescription }
    }

    private func saveLyricsKey() {
        do {
            try KeychainStore.saveLyricsAPIKey(lyricsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))
            resultMessage = localized("Lyrics provider settings saved.", "Đã lưu cấu hình nhà cung cấp lời bài hát.")
        } catch { resultMessage = error.localizedDescription }
    }

    private func updateCookies(from url: URL) {
        isUpdatingCookies = true
        Task {
            defer { isUpdatingCookies = false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let contents = String(data: data, encoding: .utf8) else { throw APIError.invalidResponse }
                let response = try await APIClient.shared.updateYouTubeCookies(contents)
                resultMessage = response.message ?? localized("Cookies updated.", "Đã cập nhật cookie.")
                Haptics.success()
            } catch { resultMessage = error.localizedDescription }
        }
    }
}

private struct StorageManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @Query private var items: [MediaItem]
    @Query private var playlists: [MediaPlaylist]
    @State private var selection = Set<UUID>()
    @State private var snapshot = CacheStorageSnapshot.empty
    @State private var scanReport: CacheScanReport?
    @State private var cleanupPreview: CacheCleanupPreview?
    @State private var pendingDelete: [MediaItem] = []
    @State private var confirmDelete = false
    @State private var confirmDeleteAll = false
    @State private var resultMessage: String?
    @State private var editMode: EditMode = .inactive
    @State private var isWorking = false

    private var sortedItems: [MediaItem] {
        items.sorted { FileStore.fileSize(for: $0) > FileStore.fileSize(for: $1) }
    }

    var body: some View {
        List(selection: $selection) {
            Section("Storage Overview") {
                storageRow("Media", icon: "play.rectangle.fill", value: snapshot.media)
                storageRow("Artwork", icon: "photo.fill", value: snapshot.artwork)
                storageRow("Temporary downloads", icon: "arrow.down.circle", value: snapshot.temporaryDownloads)
                storageRow("Backend temporary metadata", icon: "server.rack", value: snapshot.backendMetadata)
                storageRow("Waveform / cache", icon: "waveform.path", value: snapshot.waveform)
                storageRow("Total managed storage", icon: "internaldrive.fill", value: snapshot.total)
                if let available = snapshot.available {
                    storageRow("Available on device", icon: "iphone", value: available)
                }
            }

            Section("Cleanup") {
                cleanupButton("Clear Artwork Cache", icon: "photo.badge.minus", scope: .artwork)
                cleanupButton("Clear Temporary Files", icon: "clock.badge.xmark", scope: .temporary)
                Button { scanForOrphans() } label: { Label("Clean Orphan Files", systemImage: "doc.badge.gearshape") }
                Button { runScan() } label: { Label("Find Missing Files", systemImage: "magnifyingglass") }
                if isWorking {
                    HStack { ProgressView(); Text("Scanning storage…").foregroundStyle(.secondary) }
                }
                Text("Cleanup always shows a preview first. Valid media referenced by the Library is never removed automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Delete all downloads", role: .destructive) { confirmDeleteAll = true }
            }

            if let report = scanReport {
                Section("Scanner Results") {
                    scanSummary("Files without a SwiftData record", count: report.orphanFiles.count, icon: "doc.questionmark")
                    scanSummary("SwiftData records with a missing file", count: report.missingMedia.count, icon: "exclamationmark.icloud")
                    scanSummary("Duplicated local file groups", count: report.duplicateFiles.count, icon: "doc.on.doc")
                    Text("Scanned \(report.scannedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !report.orphanFiles.isEmpty {
                    Section("Orphan Files") {
                        ForEach(report.orphanFiles) { file in fileRow(file) }
                    }
                }

                if !report.missingMedia.isEmpty {
                    Section("Missing Files") {
                        ForEach(report.missingMedia) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).lineLimit(1)
                                Text(entry.filename).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }

                if !report.duplicateFiles.isEmpty {
                    Section("Duplicated Local Files") {
                        ForEach(report.duplicateFiles) { group in
                            DisclosureGroup("\(group.files.count) copies • \(group.reclaimableSize.formattedBytes) reclaimable") {
                                ForEach(group.files) { file in fileRow(file) }
                            }
                        }
                        Text("Duplicates are reported only. Delete Library items manually so SwiftData and playlists remain consistent.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Media by Size") {
                if sortedItems.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "internaldrive")
                } else {
                    ForEach(sortedItems) { item in
                        HStack(spacing: 12) {
                            ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, isVideo: item.isVideo).frame(width: 64, height: 46)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).lineLimit(1)
                                Text(item.isVideo ? "Video" : "Audio").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(FileStore.fileSize(for: item).formattedBytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .tag(item.id)
                        .swipeActions {
                            Button(role: .destructive) { requestDelete([item]) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Manage Storage")
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode == .active ? "Done" : "Select") {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                    if editMode == .inactive { selection.removeAll() }
                }.disabled(items.isEmpty)
            }
            if editMode == .active && !selection.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        requestDelete(items.filter { selection.contains($0.id) })
                    } label: { Label("Delete Selected", systemImage: "trash") }
                }
            }
        }
        .task { await refresh() }
        .sheet(item: $cleanupPreview) { preview in
            CacheCleanupPreviewView(preview: preview) { clean(preview) }
        }
        .confirmationDialog("Delete selected downloads?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(pendingDelete.count) Items", role: .destructive) { delete(pendingDelete) }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: { Text("Files, Library metadata and playlist references will be removed.") }
        .confirmationDialog("Delete every downloaded file?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { delete(items) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
        .alert("OfflineTube", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("OK") { resultMessage = nil }
        } message: { Text(resultMessage ?? "") }
    }

    private func storageRow(_ title: LocalizedStringKey, icon: String, value: Int64) -> some View {
        LabeledContent { Text(value.formattedBytes).monospacedDigit() } label: { Label(title, systemImage: icon) }
    }

    private func scanSummary(_ title: LocalizedStringKey, count: Int, icon: String) -> some View {
        LabeledContent { Text("\(count)").monospacedDigit() } label: { Label(title, systemImage: icon) }
    }

    private func fileRow(_ file: CacheFileEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(file.name).lineLimit(1); Spacer(); Text(file.size.formattedBytes).monospacedDigit() }
            Text(file.category).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func cleanupButton(_ title: LocalizedStringKey, icon: String, scope: CacheCleanupScope) -> some View {
        Button { prepareCleanup(scope) } label: { Label(title, systemImage: icon) }
    }

    private func prepareCleanup(_ scope: CacheCleanupScope) {
        let records = CacheManager.records(from: items)
        isWorking = true
        Task {
            let preview = await Task.detached(priority: .utility) {
                switch scope {
                case .artwork: return CacheManager.previewArtworkCleanup(records: records)
                case .temporary: return CacheManager.previewTemporaryCleanup(records: records)
                case .orphan: return CacheCleanupPreview(scope: .orphan, files: [], includesURLCache: false, urlCacheBytes: 0)
                }
            }.value
            isWorking = false
            if preview.fileCount == 0 {
                resultMessage = "Nothing to clean."
            } else {
                cleanupPreview = preview
            }
        }
    }

    private func runScan(showOrphanPreview: Bool = false) {
        let records = CacheManager.records(from: items)
        isWorking = true
        Task {
            let report = await CacheManager.scan(records: records)
            scanReport = report
            isWorking = false
            if showOrphanPreview {
                let preview = CacheManager.previewOrphanCleanup(from: report)
                if preview.files.isEmpty { resultMessage = "No orphan files found." }
                else { cleanupPreview = preview }
            } else if report.isClean {
                resultMessage = "No missing, orphaned, or duplicated local files found."
            }
        }
    }

    private func scanForOrphans() { runScan(showOrphanPreview: true) }

    private func clean(_ preview: CacheCleanupPreview) {
        cleanupPreview = nil
        isWorking = true
        Task {
            do {
                // Keep descriptor capture + deletion on MainActor so a download cannot
                // insert a new SwiftData record between final validation and removal.
                let currentRecords = CacheManager.records(from: items)
                let result = try CacheManager.clean(preview, currentRecords: currentRecords)
                if preview.scope == .artwork {
                    let removed = Set(result.removedFiles.map(\.name))
                    items.forEach { item in
                        if let name = item.artworkFilename, removed.contains(name) { item.artworkFilename = nil }
                    }
                    try modelContext.save()
                }
                if preview.scope == .orphan { scanReport = nil }
                await refresh()
                resultMessage = "Removed \(result.removedCount) cache item(s), freeing \(result.removedSize.formattedBytes)."
                Haptics.success()
            } catch {
                resultMessage = error.localizedDescription
                await refresh()
            }
            isWorking = false
        }
    }

    private func requestDelete(_ selected: [MediaItem]) {
        pendingDelete = selected
        confirmDelete = !selected.isEmpty
    }

    private func delete(_ selected: [MediaItem]) {
        var deleted: [MediaItem] = []
        var firstError: Error?
        for item in selected {
            do {
                player.stopIfPlaying(item)
                try FileStore.remove(item)
                deleted.append(item)
            } catch { firstError = firstError ?? error }
        }
        let ids = Set(deleted.map(\.id))
        do {
            playlists.forEach { playlist in
                playlist.itemIDs.removeAll { ids.contains($0) }
                playlist.updatedAt = Date()
            }
            deleted.forEach(modelContext.delete)
            try modelContext.save()
            selection.subtract(ids); pendingDelete = []; editMode = .inactive; scanReport = nil
            Task { await refresh() }
            Haptics.success()
            if let firstError { resultMessage = firstError.localizedDescription }
        } catch {
            resultMessage = error.localizedDescription
            Task { await refresh() }
        }
    }

    private func refresh() async { snapshot = await CacheManager.storageSnapshot() }
}

private struct CacheCleanupPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let preview: CacheCleanupPreview
    let confirm: () -> Void

    private var title: String {
        switch preview.scope {
        case .artwork: return "Clear Artwork Cache"
        case .temporary: return "Clear Temporary Files"
        case .orphan: return "Clean Orphan Files"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Cleanup Preview") {
                    LabeledContent("Items", value: "\(preview.fileCount)")
                    LabeledContent("Space to reclaim", value: preview.totalSize.formattedBytes)
                    Text("Review this list before confirming. No Library media record is deleted by this cleanup.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Files") {
                    ForEach(preview.files) { file in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(file.name).lineLimit(1); Spacer(); Text(file.size.formattedBytes).monospacedDigit() }
                            Text(file.category).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if preview.includesURLCache {
                        HStack { Text("System URL cache"); Spacer(); Text(preview.urlCacheBytes.formattedBytes).monospacedDigit() }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clean", role: .destructive) { confirm() }
                }
            }
        }
    }
}

private struct CookieGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let selectFile: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 48)).foregroundStyle(.tint)
                        Text("Update cookies without a computer")
                            .font(.title2.bold()).multilineTextAlignment(.center)
                        Text("Everything is done on your iPhone. Use a secondary YouTube account and never share the exported file.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity)

                    guideStep(1, icon: "safari.fill", title: "Install Cookie-Editor", detail: "Install the Safari extension, then enable it in Settings → Apps → Safari → Extensions.", actionTitle: "Open App Store") {
                        openURL(URL(string: "https://apps.apple.com/app/cookie-editor/id6446215341")!)
                    }
                    guideStep(2, icon: "person.crop.circle.badge.checkmark", title: "Sign in to YouTube", detail: "Open YouTube in Safari and sign in with a secondary account. Allow Cookie-Editor access to youtube.com.", actionTitle: "Open YouTube") {
                        openURL(URL(string: "https://m.youtube.com")!)
                    }
                    guideStep(3, icon: "square.and.arrow.down", title: "Export Netscape cookies", detail: "From Safari’s Extensions menu, open Cookie-Editor, choose Export and select Netscape format. Save cookies.txt to Files.")
                    guideStep(4, icon: "checkmark.shield.fill", title: "Verify and replace", detail: "Select cookies.txt below. OfflineTube sends it over HTTPS; the server tests YouTube before replacing the active cookie.", actionTitle: "Choose cookies.txt", action: selectFile)
                }.padding(20)
            }
            .background(LinearGradient(colors: [Color.accentColor.opacity(0.1), Color(.systemBackground)], startPoint: .top, endPoint: .center).ignoresSafeArea())
            .navigationTitle("Cookie Setup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func guideStep(
        _ number: Int,
        icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: icon).foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Step \(number)").font(.caption.bold()).foregroundStyle(.tint)
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(action: action) { Text(actionTitle) }.buttonStyle(.borderedProminent).padding(.top, 3)
                }
            }
        }
        .padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
