import SwiftData
import SwiftUI

struct BackupRestoreView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @Query private var media: [MediaItem]
    @Query private var playlists: [MediaPlaylist]
    @Query private var smartPlaylists: [CustomSmartPlaylist]

    @State private var exportDocument = BackupDocument.empty
    @State private var exportPackageURL: URL?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var summary: BackupSummary?
    @State private var isWorking = false
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                Button { export(.metadataOnly) } label: {
                    Label("Metadata Only", systemImage: "doc.text")
                }
                Button { export(.full) } label: {
                    Label("Full Backup with Media", systemImage: "archivebox.fill")
                }
            } header: {
                Text("Export Backup")
            } footer: {
                Text("Full backup can be large. Both modes include Library metadata, playlists, favorites, playback positions and app settings.")
            }
            Section {
                Button { showImporter = true } label: {
                    Label("Choose Backup File", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Restore Backup")
            } footer: {
                Text("OfflineTube validates and stages the package before showing Merge or Replace options.")
            }
            if isWorking {
                Section { HStack { ProgressView(); Text("Working…") } }
            }
        }
        .navigationTitle("Backup & Restore")
        .disabled(isWorking)
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .offlineTubeBackup,
                      defaultFilename: "OfflineTube-Backup") { result in
            BackupService.removePackage(exportPackageURL); exportPackageURL = nil
            if case .failure(let error) = result { statusMessage = error.localizedDescription }
            else { statusMessage = String(localized: "Backup exported successfully."); Haptics.success() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.offlineTubeBackup]) { result in
            if case .success(let url) = result { prepare(url) }
            else if case .failure(let error) = result { statusMessage = error.localizedDescription }
        }
        .sheet(item: $summary) { value in
            RestoreSummaryView(summary: value, isWorking: $isWorking) { mode in restore(value, mode: mode) }
        }
        .alert("OfflineTube", isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(statusMessage ?? "") }
    }

    private func export(_ mode: BackupMode) {
        isWorking = true
        Task {
            do {
                let url = try await BackupService.createPackage(mode: mode, media: media, playlists: playlists, smartPlaylists: smartPlaylists)
                exportPackageURL = url; exportDocument = BackupDocument(packageURL: url)
                isWorking = false; showExporter = true
            } catch { isWorking = false; statusMessage = error.localizedDescription }
        }
    }

    private func prepare(_ url: URL) {
        isWorking = true
        Task {
            do { summary = try await BackupService.prepareImport(from: url); isWorking = false }
            catch { isWorking = false; statusMessage = error.localizedDescription }
        }
    }

    private func restore(_ value: BackupSummary, mode: RestoreMode) {
        isWorking = true
        Task {
            do {
                try await BackupService.restore(value, mode: mode, context: modelContext, existingMedia: media,
                                                existingPlaylists: playlists, existingSmartPlaylists: smartPlaylists, player: player)
                BackupService.removePackage(value.packageURL); summary = nil; isWorking = false
                statusMessage = String(localized: "Restore completed successfully."); Haptics.success()
            } catch { isWorking = false; statusMessage = error.localizedDescription }
        }
    }
}

extension BackupSummary: Identifiable { var id: URL { packageURL } }

private struct RestoreSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let summary: BackupSummary
    @Binding var isWorking: Bool
    let restore: (RestoreMode) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Backup Summary") {
                    LabeledContent("Version", value: "\(summary.manifest.version)")
                    LabeledContent("Created", value: summary.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Type", value: summary.manifest.mode == .full ? String(localized: "Full Backup") : String(localized: "Metadata Only"))
                    LabeledContent("Media", value: "\(summary.manifest.media.count)")
                    LabeledContent("Playlists", value: "\(summary.manifest.playlists.count + summary.manifest.smartPlaylists.count)")
                    if summary.missingFiles > 0 { LabeledContent("Missing Files", value: "\(summary.missingFiles)").foregroundStyle(.orange) }
                }
                if summary.manifest.mode == .metadataOnly {
                    Section { Text("Metadata-only restore updates matching local media. It cannot recreate deleted media files.") }
                }
                Section {
                    Button("Merge with Current Library") { restore(.merge) }.disabled(isWorking)
                    Button("Replace Current Library", role: .destructive) { restore(.replace) }.disabled(isWorking)
                } footer: {
                    Text(summary.manifest.mode == .full
                         ? "Replace deletes current downloads after the backup has passed validation."
                         : "Replace resets playlists and settings, then applies metadata to matching local files; media files are preserved.")
                }
            }
            .navigationTitle("Restore Preview").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { BackupService.removePackage(summary.packageURL); dismiss() } } }
        }
    }
}
