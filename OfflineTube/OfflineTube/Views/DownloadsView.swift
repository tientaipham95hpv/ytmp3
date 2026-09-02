import SwiftData
import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadViewModel
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var items: [MediaItem]

    private var active: [DownloadQueueItem] { downloads.queueItems.filter { [.queued, .downloading, .saving].contains($0.state) } }
    private var history: [DownloadQueueItem] { Array(downloads.queueItems.filter { [.completed, .failed, .cancelled].contains($0.state) }.reversed()) }

    var body: some View {
        List {
            if !active.isEmpty {
                Section("Queue") { ForEach(active) { downloadRow($0) } }
            }
            if !history.isEmpty {
                Section("Recent Activity") { ForEach(history) { downloadRow($0) } }
            }
            Section("On This iPhone") {
                if items.isEmpty && downloads.queueItems.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Add videos from Home. Multiple items can wait in the queue."))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, isVideo: item.isVideo).frame(width: 72, height: 50)
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
    }

    private func downloadRow(_ item: DownloadQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ArtworkView(url: item.info.thumbnail, isVideo: item.mediaType == "video").frame(width: 72, height: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.info.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Label { Text(item.state.title) } icon: { Image(systemName: stateIcon(item.state)) }
                        .font(.caption).foregroundStyle(stateColor(item.state))
                }
                Spacer()
                if item.state == .queued || item.state == .downloading || item.state == .saving {
                    Button { downloads.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.title3) }.buttonStyle(.plain)
                } else if item.state == .failed || item.state == .cancelled {
                    Button { downloads.retry(item.id) } label: { Image(systemName: "arrow.clockwise.circle.fill").font(.title3) }.buttonStyle(.plain)
                }
            }
            if item.state == .downloading || item.state == .saving {
                ProgressView(value: item.progress).animation(.smooth, value: item.progress)
                HStack {
                    Text(byteSummary(item)).lineLimit(1)
                    Spacer()
                    if let speed = item.speedBytesPerSecond, speed > 0 { Text("\(Int64(speed).formattedBytes)/s") }
                    Text("\(Int(item.progress * 100))%")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let error = item.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
        }.padding(.vertical, 5)
    }

    private func byteSummary(_ item: DownloadQueueItem) -> String {
        if let total = item.totalBytes { return "\(item.downloadedBytes.formattedBytes) / \(total.formattedBytes)" }
        return item.downloadedBytes > 0 ? item.downloadedBytes.formattedBytes : "Preparing…"
    }

    private func stateIcon(_ state: DownloadQueueItem.State) -> String {
        switch state {
        case .queued: "clock.fill"
        case .downloading: "arrow.down.circle.fill"
        case .saving: "internaldrive.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    private func stateColor(_ state: DownloadQueueItem.State) -> Color {
        switch state { case .completed: .green; case .failed: .red; case .cancelled: .secondary; default: .accentColor }
    }
    private func size(_ item: MediaItem) -> Int64 { item.fileSize > 0 ? item.fileSize : FileStore.fileSize(for: item) }
}
