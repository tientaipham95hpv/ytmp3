import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @Query private var items: [MediaItem]
    @AppStorage("defaultAudioQuality") private var audioQuality = "original"
    @AppStorage("defaultVideoQuality") private var videoQuality = "720"
    @AppStorage("appTheme") private var theme = AppTheme.system.rawValue
    @AppStorage("accentChoice") private var accent = AccentChoice.pink.rawValue
    @AppStorage("appLanguage") private var language = AppLanguage.vietnamese.rawValue
    @AppStorage("backendURL") private var backendURL = "https://offlinetube.cineviet.live"
    @State private var resultMessage: String?
    @State private var accessToken = ""
    @State private var showCookieImporter = false
    @State private var isUpdatingCookies = false
    @State private var showCookieGuide = false

    var body: some View {
        Form {
            Section("Downloads") {
                Picker("Default audio quality", selection: $audioQuality) {
                    Text("Original / M4A").tag("original"); Text("MP3 128").tag("128"); Text("MP3 192").tag("192"); Text("MP3 320").tag("320")
                }
                Picker("Default video quality", selection: $videoQuality) {
                    Text("360p").tag("360"); Text("480p").tag("480"); Text("720p").tag("720"); Text("1080p").tag("1080"); Text("Best").tag("best")
                }
            }
            Section("Storage") {
                NavigationLink { StorageManagementView() } label: {
                    Label("Manage Storage", systemImage: "internaldrive")
                }
            }
            Section("Appearance") {
                Picker("Language", selection: $language) { ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) } }
                Picker("Theme", selection: $theme) { ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) } }
                Picker("Accent color", selection: $accent) {
                    ForEach(AccentChoice.allCases) { choice in Label(choice.title, systemImage: "circle.fill").foregroundStyle(choice.color).tag(choice.rawValue) }
                }
            }
            Section("Backend") {
                TextField("Backend URL", text: $backendURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Text("The current download service is preserved. Change this only when using another server.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Server Security") {
                SecureField("Device access token", text: $accessToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save access token") { saveToken() }.disabled(accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    showCookieImporter = true
                } label: {
                    if isUpdatingCookies { HStack { ProgressView(); Text("Checking and updating cookies…") } }
                    else { Label("Replace YouTube cookies", systemImage: "lock.doc") }
                }.disabled(KeychainStore.token() == nil || isUpdatingCookies)
                Button { showCookieGuide = true } label: {
                    Label("Get cookies on iPhone", systemImage: "iphone.and.arrow.forward")
                }
                Text("The token stays in iOS Keychain. Cookie files are verified by the server before replacing the active cookie.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("About") { LabeledContent("OfflineTube", value: "Phase 2") }
        }
        .navigationTitle("Settings")
        .task { accessToken = KeychainStore.token() ?? "" }
        .fileImporter(isPresented: $showCookieImporter, allowedContentTypes: [.plainText, .text], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            updateCookies(from: url)
        }
        .sheet(isPresented: $showCookieGuide) {
            CookieGuideView {
                showCookieGuide = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showCookieImporter = true }
            }
        }
        .alert("OfflineTube", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) { Button("OK") { resultMessage = nil } } message: { Text(resultMessage ?? "") }
    }

    private func localized(_ english: String, _ vietnamese: String) -> String { language == AppLanguage.vietnamese.rawValue ? vietnamese : english }

    private func saveToken() {
        do {
            try KeychainStore.saveToken(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))
            resultMessage = localized("Access token saved securely.", "Đã lưu token an toàn vào Keychain.")
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
    @State private var snapshot = FileStore.StorageSnapshot(total: 0, audio: 0, video: 0, artwork: 0, temporary: 0, available: nil)
    @State private var pendingDelete: [MediaItem] = []
    @State private var confirmDelete = false
    @State private var confirmDeleteAll = false
    @State private var confirmClearArtwork = false
    @State private var resultMessage: String?
    @State private var editMode: EditMode = .inactive

    private var sortedItems: [MediaItem] {
        items.sorted { FileStore.fileSize(for: $0) > FileStore.fileSize(for: $1) }
    }

    var body: some View {
        List(selection: $selection) {
            Section("Storage Overview") {
                storageRow("Total app storage", icon: "internaldrive.fill", value: snapshot.total)
                storageRow("Audio", icon: "waveform", value: snapshot.audio)
                storageRow("Video", icon: "video.fill", value: snapshot.video)
                storageRow("Artwork / Cache", icon: "photo.fill", value: snapshot.artwork)
                storageRow("Temporary / Other", icon: "clock.arrow.circlepath", value: snapshot.temporary)
                if let available = snapshot.available {
                    storageRow("Available on device", icon: "iphone", value: available)
                }
            }

            Section("Cleanup") {
                Button { confirmClearArtwork = true } label: { Label("Clear artwork cache", systemImage: "photo.badge.minus") }
                Button("Delete all downloads", role: .destructive) { confirmDeleteAll = true }
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
        .task { cleanupTempAndRefresh() }
        .confirmationDialog("Delete selected downloads?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(pendingDelete.count) Items", role: .destructive) { delete(pendingDelete) }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: { Text("Files, Library metadata and playlist references will be removed.") }
        .confirmationDialog("Delete every downloaded file?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { delete(items) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
        .confirmationDialog("Clear artwork cache?", isPresented: $confirmClearArtwork, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) { clearArtwork() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Artwork can be downloaded again when the device is online.") }
        .alert("OfflineTube", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("OK") { resultMessage = nil }
        } message: { Text(resultMessage ?? "") }
    }

    private func storageRow(_ title: LocalizedStringKey, icon: String, value: Int64) -> some View {
        LabeledContent { Text(value.formattedBytes).monospacedDigit() } label: { Label(title, systemImage: icon) }
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
            selection.subtract(ids); pendingDelete = []; editMode = .inactive
            refresh(); Haptics.success()
            if let firstError { resultMessage = firstError.localizedDescription }
        } catch {
            resultMessage = error.localizedDescription
            refresh()
        }
    }

    private func clearArtwork() {
        do {
            try FileStore.clearArtworkCache(items: items)
            try modelContext.save(); refresh(); Haptics.success()
        } catch { resultMessage = error.localizedDescription }
    }

    private func cleanupTempAndRefresh() {
        do {
            try FileStore.cleanupTemporaryFiles()
            try FileStore.clearOrphanedFiles(keeping: items)
        } catch { resultMessage = error.localizedDescription }
        refresh()
    }

    private func refresh() { snapshot = FileStore.storageSnapshot(items: items) }
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
