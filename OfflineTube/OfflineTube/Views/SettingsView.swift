import SwiftData
import SwiftUI

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
            Section("About") { LabeledContent("OfflineTube", value: "Phase 2") }
        }
        .navigationTitle("Settings")
        .task { refreshStorage() }
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
}
