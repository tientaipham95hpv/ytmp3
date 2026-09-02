import SwiftData
import SwiftUI

struct DownloadsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var downloads: DownloadViewModel
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var items: [MediaItem]

    var body: some View {
        List {
            if downloads.isDownloading || !downloads.statusText.isEmpty || downloads.errorMessage != nil {
                Section("Current") { currentDownload }
            }
            Section("Completed") {
                if items.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Start a download from Home."))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            ArtworkView(url: item.thumbnailURL, isVideo: item.isVideo).frame(width: 72, height: 50)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(item.mediaType.capitalized) • \(item.quality) • \(size(item).formattedBytes)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }.padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .refreshable { if downloads.errorMessage != nil { downloads.retry(modelContext: modelContext) } }
    }

    private var currentDownload: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let info = downloads.mediaInfo {
                HStack(spacing: 12) {
                    ArtworkView(url: info.thumbnail, isVideo: downloads.mediaKind == .video).frame(width: 76, height: 52)
                    VStack(alignment: .leading) { Text(info.title).font(.subheadline.weight(.semibold)).lineLimit(2); Text(downloads.statusText).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if downloads.isDownloading {
                ProgressView(value: downloads.progress).animation(.smooth, value: downloads.progress)
                HStack {
                    Text("\(Int(downloads.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .destructive) { downloads.cancelDownload() }.buttonStyle(.bordered)
                }
            } else if let error = downloads.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
                Button { downloads.retry(modelContext: modelContext) } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(.borderedProminent)
            } else if let message = downloads.completedMessage {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }.padding(.vertical, 6)
    }

    private func size(_ item: MediaItem) -> Int64 { item.fileSize > 0 ? item.fileSize : FileStore.fileSize(for: item) }
}
