import SwiftData
import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadViewModel
    @EnvironmentObject private var network: NetworkMonitor
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var items: [MediaItem]
    @State private var pendingCancel: DownloadQueueItem?

    private var active: [DownloadQueueItem] { downloads.queueItems.filter { [.queued, .downloading, .saving].contains($0.state) } }
    private var history: [DownloadQueueItem] { Array(downloads.queueItems.filter { [.completed, .failed, .cancelled].contains($0.state) }.reversed()) }

    var body: some View {
        List {
            if !network.isConnected {
                Section {
                    Label("Offline — active downloads will retry when the network returns", systemImage: "wifi.slash")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let batchID = downloads.activeBatchID {
                let batchItems = downloads.batchItems(batchID)
                if !batchItems.isEmpty {
                    Section("Current Batch") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("\(batchItems.filter { $0.state == .completed }.count) of \(batchItems.count) completed")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(Int(downloads.batchProgress(batchID) * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ProgressView(value: downloads.batchProgress(batchID)).animation(.smooth, value: downloads.batchProgress(batchID))
                            if batchItems.contains(where: { [.queued, .downloading, .saving].contains($0.state) }) {
                                Button(role: .destructive) { downloads.cancelBatch(batchID); Haptics.warning() } label: {
                                    Label("Cancel Entire Batch", systemImage: "xmark.circle")
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
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
                                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text("\(item.mediaType.capitalized) • \(item.quality) • \(size(item).formattedBytes)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }.padding(.vertical, 3)
                            .contextMenu { ShareLink(item: item.localURL) { Label("Share / Export", systemImage: "square.and.arrow.up") } }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Cancel this nearly completed download?", isPresented: Binding(get: { pendingCancel != nil }, set: { if !$0 { pendingCancel = nil } }), titleVisibility: .visible) {
            Button("Cancel Download", role: .destructive) { if let item = pendingCancel { downloads.cancel(item.id) }; pendingCancel = nil }
            Button("Keep Downloading", role: .cancel) { pendingCancel = nil }
        } message: { Text("Most of the file has already downloaded.") }
    }

    private func downloadRow(_ item: DownloadQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ArtworkView(url: item.info.thumbnail, isVideo: item.mediaType == "video").frame(width: 72, height: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.info.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    let waiting = downloads.waitingReason(for: item)
                    Label { Text(waiting ?? item.state.rawValue.capitalized) } icon: { Image(systemName: waiting == nil ? stateIcon(item.state) : "clock.badge.exclamationmark.fill") }
                        .font(.caption).foregroundStyle(stateColor(item.state))
                }
                Spacer()
                if item.state == .queued || item.state == .downloading || item.state == .saving {
                    Button { cancel(item) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.title3) }.buttonStyle(.plain)
                } else if item.state == .failed || item.state == .cancelled {
                    Button { downloads.retry(item.id); Haptics.selection() } label: { Image(systemName: "arrow.clockwise.circle.fill").font(.title3) }.buttonStyle(.plain).accessibilityLabel("Retry Download")
                }
            }
            if item.state == .downloading || item.state == .saving {
                ProgressView(value: item.progress).animation(.smooth, value: item.progress)
                HStack {
                    Text(byteSummary(item)).lineLimit(1)
                    Spacer()
                    if let speed = item.speedBytesPerSecond, speed > 0 { Text("\(Int64(speed).formattedBytes)/s") }
                    if let remaining = item.remainingSeconds { Text(remaining.remainingTime); Text("remaining") }
                    Text("\(Int(item.progress * 100))%")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let error = item.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
        }.padding(.vertical, 5)
            .contextMenu {
                if item.state == .failed || item.state == .cancelled {
                    Button { downloads.retry(item.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                } else if item.state == .queued || item.state == .downloading || item.state == .saving {
                    if item.state == .queued && downloads.waitingReason(for: item) != nil {
                        Button { downloads.runNow(item.id) } label: { Label("Download Now", systemImage: "bolt.fill") }
                    }
                    Button(role: .destructive) { cancel(item) } label: { Label("Cancel Download", systemImage: "xmark.circle") }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if item.state == .failed || item.state == .cancelled {
                    Button { downloads.retry(item.id); Haptics.selection() } label: { Label("Retry", systemImage: "arrow.clockwise") }.tint(.accentColor)
                } else if item.state == .queued || item.state == .downloading || item.state == .saving {
                    Button(role: .destructive) { cancel(item) } label: { Label("Cancel", systemImage: "xmark") }
                }
            }
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
    private func cancel(_ item: DownloadQueueItem) {
        if item.progress >= 0.85 { pendingCancel = item }
        else { downloads.cancel(item.id) }
    }
}
