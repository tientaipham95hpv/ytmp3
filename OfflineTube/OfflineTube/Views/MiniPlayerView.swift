import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    let openPlayer: () -> Void

    var body: some View {
        if let item = player.currentItem {
            VStack(spacing: 0) {
                ProgressView(value: player.currentTime, total: max(1, player.duration)).tint(.accentColor)
                HStack(spacing: 12) {
                    Button(action: openPlayer) {
                        HStack(spacing: 11) {
                            ArtworkView(url: item.thumbnailURL, isVideo: item.isVideo, cornerRadius: 7).frame(width: 46, height: 46)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(item.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button { player.toggle(); Haptics.tap() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 32, height: 42) }
                    Button { player.next() } label: { Image(systemName: "forward.fill").frame(width: 30, height: 42) }
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 8).padding(.bottom, 2)
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}
