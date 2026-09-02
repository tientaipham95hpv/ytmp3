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
                Button { showCookieGuide = true } label: {
                    Label("Get cookies on iPhone", systemImage: "iphone.and.arrow.forward")
                }
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
        .sheet(isPresented: $showCookieGuide) {
            CookieGuideView {
                showCookieGuide = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showCookieImporter = true }
            }
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
