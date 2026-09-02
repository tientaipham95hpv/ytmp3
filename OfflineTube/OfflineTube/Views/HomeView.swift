import SwiftData
import SwiftUI
import UIKit

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadViewModel
    @EnvironmentObject private var network: NetworkMonitor
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var items: [MediaItem]
    @FocusState private var isURLFocused: Bool
    @State private var showBatchDownload = false

    private var recentlyPlayed: [MediaItem] {
        items.filter { $0.lastPlayedAt != nil }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                greeting
                if !network.isConnected {
                    Label("You’re offline. Downloads will resume when the network returns.", systemImage: "wifi.slash")
                        .font(.subheadline).foregroundStyle(.secondary).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                }
                pasteCard
                if downloads.isLoadingInfo { metadataSkeleton }
                if let error = downloads.errorMessage { errorState(error) }
                if let info = downloads.mediaInfo { mediaCard(info) }
                mediaSection("Recent Downloads", items: Array(items.prefix(8)))
                mediaSection("Recently Played", items: Array(recentlyPlayed.prefix(8)))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.11), Color(.systemBackground), Color(.systemBackground)], startPoint: .topLeading, endPoint: .center)
                .ignoresSafeArea()
        )
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showBatchDownload = true; Haptics.selection() } label: { Image(systemName: "square.stack.3d.up") }
                    .accessibilityLabel("Batch Download")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isURLFocused = false }
            }
        }
        .sheet(isPresented: $showBatchDownload) { BatchDownloadView() }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Your music, offline.").font(.largeTitle.bold())
            Text("Paste a YouTube link and keep it with you.").foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var pasteCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Paste URL", systemImage: "link").font(.headline)
            HStack(spacing: 10) {
                TextField("youtube.com/watch…", text: $downloads.urlText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .submitLabel(.go).focused($isURLFocused).onSubmit(fetchInfo)
                if !downloads.urlText.isEmpty {
                    Button { downloads.urlText = ""; downloads.mediaInfo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
                Button {
                    if let value = UIPasteboard.general.string { downloads.urlText = value }
                    fetchInfo()
                } label: { Image(systemName: "doc.on.clipboard.fill") }
            }
            .padding(13).background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 13))
            Button(action: fetchInfo) {
                Label(downloads.isLoadingInfo ? "Reading video…" : "Continue", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!network.isConnected || downloads.isLoadingInfo || downloads.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button { showBatchDownload = true; Haptics.selection() } label: {
                Label("Multiple URLs or Playlist", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
        }
        .padding(AppMetrics.card)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var metadataSkeleton: some View {
        SkeletonRow().padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: AppMetrics.card, style: .continuous))
    }

    private func errorState(_ error: String) -> some View {
        AppStateView(title: "Couldn’t load this link", message: LocalizedStringKey(error), icon: "exclamationmark.triangle.fill", actionTitle: "Retry") {
            downloads.errorMessage = nil
            fetchInfo()
        }
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: AppMetrics.card, style: .continuous))
    }

    private func mediaCard(_ info: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ArtworkView(url: info.thumbnail, isVideo: true, cornerRadius: 18).frame(height: 190)
            Text(info.title).font(.title3.bold()).lineLimit(2)
            Text("\(info.channel) • \(info.duration.mediaTime)").font(.subheadline).foregroundStyle(.secondary)
            Picker("Type", selection: $downloads.mediaKind) {
                ForEach(DownloadViewModel.MediaKind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Text("Quality").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Quality", selection: $downloads.quality) {
                    ForEach(downloads.mediaKind == .audio ? downloads.audioQualities : downloads.videoQualities, id: \.0) { Text($0.1).tag($0.0) }
                }.pickerStyle(.menu)
            }
            if let estimate = downloads.estimatedSize(for: info) {
                HStack { Image(systemName: "internaldrive"); Text("Estimated size"); Text(estimate.formattedBytes) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if downloads.variantExists(in: items, info: info) {
                Label("Already in Library at this format and quality", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
            } else if downloads.hasOtherVariant(in: items, info: info) {
                Label("Another version is in Library. You can download this variant.", systemImage: "square.stack.3d.up")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Haptics.tap()
                downloads.startDownload(modelContext: modelContext)
            } label: {
                Label(downloads.isDownloading ? downloads.statusText : "Download", systemImage: downloads.mediaKind == .audio ? "waveform" : "video.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(downloads.variantExists(in: items, info: info))
        }
        .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private func mediaSection(_ title: String, items: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            if items.isEmpty {
                HStack { Image(systemName: "sparkles"); Text("Nothing here yet").foregroundStyle(.secondary); Spacer() }
                    .padding().background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(items) { item in
                            Button { player.play(item, queue: items) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, isVideo: item.isVideo).frame(width: 190, height: 110)
                                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    Text(item.channel).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(width: 190, alignment: .leading)
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    Button { player.play(item, queue: items) } label: { Label("Play", systemImage: "play.fill") }
                                    ShareLink(item: item.localURL) { Label("Share / Export", systemImage: "square.and.arrow.up") }
                                }
                        }
                    }
                }
            }
        }
    }

    private func fetchInfo() {
        isURLFocused = false
        Haptics.tap()
        Task { await downloads.fetchInfo() }
    }
}
