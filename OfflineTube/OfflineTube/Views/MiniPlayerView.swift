import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    let openPlayer: () -> Void

    var body: some View {
        if let item = player.currentItem {
            HStack(spacing: 12) {
                Button(action: openPlayer) {
                    VStack(alignment: .leading) {
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(item.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal).padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider() }
        }
    }
}
