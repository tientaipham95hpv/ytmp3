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
    @State private var storage: Int64 = 0
    @State private var confirmDeleteAll = false
    @State private var resultMessage: String?
    @State private var accessToken = ""
    @State private var showCookieImporter = false
    @State private var isUpdatingCookies = false

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
                LabeledContent("Downloaded media", value: storage.formattedBytes)
                LabeledContent("Items", value: "\(items.count)")
                Button("Clear orphaned cache") { clearCache() }
                Button("Delete all downloads", role: .destructive) { confirmDeleteAll = true }
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
                Text("The token stays in iOS Keychain. Cookie files are verified by the server before replacing the active cookie.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("About") { LabeledContent("OfflineTube", value: "Phase 2") }
        }
        .navigationTitle("Settings")
        .task { refreshStorage(); accessToken = KeychainStore.token() ?? "" }
        .fileImporter(isPresented: $showCookieImporter, allowedContentTypes: [.plainText, .text], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            updateCookies(from: url)
        }
        .confirmationDialog("Delete every downloaded file?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
        .alert("OfflineTube", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) { Button("OK") { resultMessage = nil } } message: { Text(resultMessage ?? "") }
    }

    private func refreshStorage() { storage = FileStore.storageUsage() }
    private func clearCache() {
        do { try FileStore.clearOrphanedFiles(keeping: items); refreshStorage(); resultMessage = localized("Cache cleared.", "Đã dọn bộ nhớ đệm.") }
        catch { resultMessage = error.localizedDescription }
    }
    private func deleteAll() {
        do {
            for item in items { player.stopIfPlaying(item); try FileStore.remove(item); modelContext.delete(item) }
            try modelContext.save(); refreshStorage(); Haptics.success(); resultMessage = localized("All downloads were deleted.", "Đã xóa toàn bộ nội dung tải về.")
        } catch { resultMessage = error.localizedDescription }
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
