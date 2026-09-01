import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var items: [MediaItem]
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("Chưa có media", systemImage: "arrow.down.circle", description: Text("Tải audio hoặc video để nghe/xem offline."))
            } else {
                List {
                    ForEach(items) { item in
                        Button { player.play(item) } label: { row(item) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { delete(item) } label: { Label("Xóa", systemImage: "trash") }
                            }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .alert("Không thể xóa", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Lỗi không xác định") }
    }

    private func row(_ item: MediaItem) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.thumbnailURL.flatMap(URL.init(string:))) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Color.secondary.opacity(0.15).overlay { Image(systemName: item.isVideo ? "video" : "waveform") } }
            }
            .frame(width: 72, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(item.channel) • \(item.mediaType.capitalized) \(item.quality)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: player.currentItem?.id == item.id && player.isPlaying ? "speaker.wave.2.fill" : "play.circle")
                .foregroundStyle(.tint)
        }
        .contentShape(Rectangle())
    }

    private func delete(_ item: MediaItem) {
        do {
            player.stopIfPlaying(item)
            try FileStore.remove(item)
            modelContext.delete(item)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
