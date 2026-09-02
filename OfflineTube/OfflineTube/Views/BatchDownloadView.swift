import SwiftData
import SwiftUI

struct BatchDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var downloads: DownloadViewModel
    @Query private var library: [MediaItem]
    @State private var input = ""
    @State private var downloadAgain = false

    var body: some View {
        NavigationStack {
            Group {
                if let batch = downloads.batchInfo { selectionView(batch) }
                else { inputView }
            }
            .navigationTitle("Batch Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private var inputView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.card) {
                AppStateView(title: "Add multiple videos", message: "Paste one YouTube URL per line, or paste a playlist URL.", icon: "square.stack.3d.up.fill")
                TextEditor(text: $input)
                    .frame(minHeight: 150).padding(10).scrollContentBackground(.hidden)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: AppMetrics.compactCard))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("YouTube URLs")
                Button {
                    Haptics.tap()
                    Task { await downloads.loadBatch(from: input) }
                } label: {
                    if downloads.isLoadingBatch { ProgressView().frame(maxWidth: .infinity) }
                    else { Label("Load Videos", systemImage: "list.bullet.rectangle").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || downloads.isLoadingBatch)
                if let error = downloads.errorMessage {
                    AppStateView(title: "Couldn’t load videos", message: LocalizedStringKey(error), icon: "exclamationmark.triangle.fill", actionTitle: "Retry") {
                        Task { await downloads.loadBatch(from: input) }
                    }
                }
            }.padding(AppMetrics.page)
        }
    }

    private func selectionView(_ batch: PlaylistInfo) -> some View {
        VStack(spacing: 0) {
            List(selection: $downloads.batchSelection) {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(batch.title).font(.headline).lineLimit(2)
                            Text("\(downloads.batchSelection.count) of \(batch.entries.count) selected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(downloads.batchSelection.count == batch.entries.count ? "Deselect All" : "Select All") {
                            downloads.batchSelection = downloads.batchSelection.count == batch.entries.count ? [] : Set(batch.entries.map(\.id))
                            Haptics.selection()
                        }.font(.subheadline.weight(.semibold))
                    }
                }
                Section("Videos") {
                    ForEach(batch.entries, id: \.id) { item in
                        Button {
                            if downloads.batchSelection.contains(item.id) { downloads.batchSelection.remove(item.id) }
                            else { downloads.batchSelection.insert(item.id) }
                            Haptics.selection()
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(url: item.thumbnail, isVideo: true).frame(width: 76, height: 52)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(item.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: downloads.batchSelection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(downloads.batchSelection.contains(item.id) ? Color.accentColor : .secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            VStack(spacing: 10) {
                HStack {
                    Picker("Type", selection: $downloads.mediaKind) {
                        ForEach(DownloadViewModel.MediaKind.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Quality", selection: $downloads.quality) {
                        ForEach(downloads.mediaKind == .audio ? downloads.audioQualities : downloads.videoQualities, id: \.0) { Text($0.1).tag($0.0) }
                    }.pickerStyle(.menu)
                }
                Toggle("Download again if already in Library", isOn: $downloadAgain).font(.subheadline)
                Button {
                    let count = downloads.enqueueBatch(modelContext: modelContext, downloadAgain: downloadAgain)
                    if count > 0 { Haptics.success(); dismiss() }
                } label: { Label("Queue \(downloads.batchSelection.count) Downloads", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(downloads.batchSelection.isEmpty)
            }
            .padding(AppMetrics.card).background(.regularMaterial)
        }
    }
}
