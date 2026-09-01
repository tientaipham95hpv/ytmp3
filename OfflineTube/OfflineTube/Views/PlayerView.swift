import AVKit
import SwiftUI

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        NavigationStack {
            Group {
                if let item = player.currentItem {
                    VStack(spacing: 24) {
                        if item.isVideo {
                            VideoPlayer(player: player.player)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            AsyncImage(url: item.thumbnailURL.flatMap(URL.init(string:))) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() }
                                else { Color.secondary.opacity(0.15).overlay { Image(systemName: "music.note").font(.system(size: 60)) } }
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        }

                        VStack(spacing: 6) {
                            Text(item.title).font(.title3.bold()).multilineTextAlignment(.center)
                            Text(item.channel).foregroundStyle(.secondary)
                        }

                        Slider(value: Binding(
                            get: { min(player.currentTime, max(player.duration, 0)) },
                            set: { player.seek(to: $0) }
                        ), in: 0...max(player.duration, 1))

                        HStack {
                            Text(time(player.currentTime))
                            Spacer()
                            Text("-\(time(max(0, player.duration - player.currentTime)))")
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)

                        HStack(spacing: 38) {
                            Button { player.seek(to: player.currentTime - 15) } label: { Image(systemName: "gobackward.15") }
                            Button { player.toggle() } label: {
                                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 62))
                            }
                            Button { player.seek(to: player.currentTime + 15) } label: { Image(systemName: "goforward.15") }
                        }.font(.title)
                        Spacer()
                    }
                    .padding()
                } else {
                    ContentUnavailableView("Không có media", systemImage: "play.slash")
                }
            }
            .navigationTitle("Now Playing").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
    }

    private func time(_ value: Double) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
