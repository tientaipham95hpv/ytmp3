import AVKit
import SwiftUI

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager
    @State private var sleepSheet = false
    @State private var showVideoFullscreen = false
    @State private var showQueue = false
    @State private var selectedPage = 0
    @State private var showAudioControls = false
    var onClose: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    if let item = player.currentItem {
                        VStack(spacing: 24) {
                            if !item.isVideo {
                                Picker("Player Section", selection: $selectedPage) {
                                    Label("Player", systemImage: "play.circle").tag(0)
                                    Label("Lyrics", systemImage: "quote.bubble").tag(1)
                                }.pickerStyle(.segmented)
                            }
                            if selectedPage == 1 && !item.isVideo {
                                metadata(item)
                                LyricsView(item: item)
                            } else {
                                media(item, width: proxy.size.width)
                                metadata(item)
                                timeline
                                transport
                                secondaryControls
                            }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 28)
                        .frame(minHeight: proxy.size.height)
                    } else {
                        ContentUnavailableView("Nothing Playing", systemImage: "play.slash")
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                }
                .background(background)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if let onClose { onClose() } else { dismiss() }
                    } label: { Image(systemName: "chevron.down").font(.headline) }
                    .accessibilityLabel("Close Player")
                }
                ToolbarItem(placement: .principal) { Text("Now Playing").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
                ToolbarItem(placement: .topBarTrailing) { Button { showQueue = true; Haptics.selection() } label: { Image(systemName: "text.line.first.and.arrowtriangle.forward") }.accessibilityLabel("Up Next") }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $sleepSheet) { SleepTimerSheet() }
        .sheet(isPresented: $showQueue) { UpNextSheet() }
        .sheet(isPresented: $showAudioControls) { AudioControlsView() }
        .fullScreenCover(isPresented: $showVideoFullscreen) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                PlayerController(player: player.player).ignoresSafeArea()
                Button { showVideoFullscreen = false } label: { Image(systemName: "xmark.circle.fill").font(.largeTitle).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.45)) }.padding()
            }.statusBarHidden()
        }
    }

    @ViewBuilder private func media(_ item: MediaItem, width: CGFloat) -> some View {
        if item.isVideo {
            ZStack(alignment: .bottomTrailing) {
                PlayerController(player: player.player).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18))
                Button { showVideoFullscreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").padding(10).background(.ultraThinMaterial, in: Circle()) }.padding(10)
            }
        } else {
            ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, cornerRadius: 24)
                .frame(width: min(width - 48, 390), height: min(width - 48, 390))
                .shadow(color: .black.opacity(0.28), radius: 24, y: 14)
        }
    }

    private func metadata(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title).font(.title2.bold()).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Text(item.channel).font(.title3).foregroundStyle(.tint).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeline: some View {
        VStack(spacing: 7) {
            Slider(value: Binding(get: { min(player.currentTime, max(player.duration, 0)) }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
            HStack { Text(player.currentTime.mediaTime); Spacer(); Text("-\(max(0, player.duration - player.currentTime).mediaTime)") }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        ViewThatFits(in: .horizontal) {
        HStack(spacing: 28) { transportButtons }
        HStack(spacing: 18) { transportButtons }
        }
        .font(.title2).buttonStyle(.plain)
    }

    @ViewBuilder private var transportButtons: some View {
            Button { player.skip(by: -10); Haptics.selection() } label: { Image(systemName: "gobackward.10") }.accessibilityLabel("Back 10 seconds")
            Button { player.previous(); Haptics.selection() } label: { Image(systemName: "backward.fill") }.accessibilityLabel("Previous")
            Button { player.toggle(); Haptics.tap() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 68)) }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next(); Haptics.selection() } label: { Image(systemName: "forward.fill") }.accessibilityLabel("Next")
            Button { player.skip(by: 10); Haptics.selection() } label: { Image(systemName: "goforward.10") }.accessibilityLabel("Forward 10 seconds")
    }

    private var secondaryControls: some View {
        HStack {
            Button { player.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(player.isShuffling ? Color.accentColor : .primary) }.frame(maxWidth: .infinity)
            Button { showAudioControls = true } label: {
                VStack(spacing: 2) { Image(systemName: "slider.vertical.3"); Text("\(player.playbackSpeed, specifier: "%g")×").font(.caption2.bold()) }
            }.frame(maxWidth: .infinity).accessibilityLabel("Audio Controls")
            Button { sleepSheet = true } label: { Image(systemName: player.sleepTimerEnd == nil ? "moon.zzz" : "moon.zzz.fill") }.frame(maxWidth: .infinity)
            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode.icon).foregroundStyle(player.repeatMode == .off ? .primary : Color.accentColor)
            }.frame(maxWidth: .infinity)
        }.font(.title3).buttonStyle(.plain).padding(.top, 4)
    }

    private var background: some View {
        LinearGradient(colors: [Color.accentColor.opacity(0.16), Color(.systemBackground)], startPoint: .top, endPoint: .center).ignoresSafeArea()
    }
}

private struct AudioControlsView: View {
    private enum EQPreset: String, CaseIterable, Identifiable {
        case flat = "Flat", bass = "Bass Boost", treble = "Treble Boost", vocal = "Vocal", rock = "Rock", pop = "Pop"
        var id: String { rawValue }
        var gains: [CGFloat] {
            switch self {
            case .flat: [0, 0, 0, 0, 0, 0]
            case .bass: [8, 6, 3, 0, -1, -2]
            case .treble: [-2, -1, 0, 3, 6, 8]
            case .vocal: [-2, 0, 4, 6, 3, 0]
            case .rock: [5, 3, -1, 2, 5, 6]
            case .pop: [-1, 3, 5, 4, 2, -1]
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager
    @State private var previewPreset = EQPreset.flat
    private let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        NavigationStack {
            List {
                Section("Playback Speed") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 10) {
                        ForEach(speeds, id: \.self) { speed in
                            Button { player.setSpeed(speed); Haptics.selection() } label: {
                                Text("\(speed, specifier: "%g")×").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent).tint(player.playbackSpeed == speed ? .accentColor : .secondary.opacity(0.25))
                            .foregroundStyle(player.playbackSpeed == speed ? .white : .primary)
                        }
                    }.padding(.vertical, 4)
                    Text("Uses AVPlayer spectral time-pitch processing to preserve voice and music quality.").font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Label("Realtime EQ needs AVAudioEngine", systemImage: "exclamationmark.shield.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    Text("OfflineTube keeps AVPlayer for video, Picture in Picture, background audio and Lock Screen reliability. Presets below are an interface preview and do not alter sound in this build.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Equalizer Presets") {
                    Picker("Preset Preview", selection: $previewPreset) {
                        ForEach(EQPreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    equalizerPreview
                    ForEach(EQPreset.allCases) { preset in
                        HStack { Text(preset.rawValue); Spacer(); Text(preset == .flat ? "AVPlayer default" : "Requires Audio Engine").font(.caption).foregroundStyle(.secondary) }
                    }
                }

                Section("Custom EQ") {
                    ForEach(Array(["60", "250", "1K", "4K", "12K"].enumerated()), id: \.offset) { _, frequency in
                        LabeledContent(frequency) { Slider(value: .constant(0.0), in: -12.0...12.0).disabled(true).frame(maxWidth: 210) }
                    }
                } footer: { Text("Disabled to avoid introducing a second audio pipeline that could desynchronize playback and remote controls.") }

                Section("Balance & Normalization") {
                    LabeledContent("Balance") { Slider(value: .constant(0.0), in: -1.0...1.0).disabled(true).frame(maxWidth: 180) }
                    Toggle("Volume Normalization", isOn: .constant(false)).disabled(true)
                } footer: { Text("AVPlayer does not expose realtime pan, multiband EQ, or loudness normalization. These controls require an AVAudioEngine migration.") }
            }
            .navigationTitle("Audio Controls").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.large])
    }

    private var equalizerPreview: some View {
        HStack(alignment: .center, spacing: 10) {
            ForEach(Array(previewPreset.gains.enumerated()), id: \.offset) { _, gain in
                Capsule().fill(gain == 0 ? Color.secondary.opacity(0.3) : Color.accentColor)
                    .frame(maxWidth: .infinity).frame(height: max(4, 28 + gain * 3))
                    .animation(.snappy, value: previewPreset)
            }
        }.frame(height: 58).accessibilityLabel("Equalizer curve preview")
    }
}

private struct UpNextSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @State private var showSave = false
    @State private var playlistName = ""
    @State private var showClear = false

    var body: some View {
        NavigationStack {
            List {
                if player.queue.isEmpty {
                    ContentUnavailableView("Queue is empty", systemImage: "text.line.first.and.arrowtriangle.forward")
                } else {
                    Section {
                        HStack {
                            Label("\(max(0, player.queue.count - 1)) Up Next", systemImage: player.isShuffling ? "shuffle" : "text.line.first.and.arrowtriangle.forward")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Menu {
                                Button { playlistName = ""; showSave = true } label: { Label("Save Queue as Playlist", systemImage: "text.badge.plus") }
                                Button(role: .destructive) { showClear = true } label: { Label("Clear Queue", systemImage: "trash") }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                    }
                    ForEach(player.queue) { item in
                        Button { player.play(item) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, isVideo: item.isVideo).frame(width: 58, height: 42)
                                VStack(alignment: .leading) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if player.currentItem?.id == item.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                            }
                        }.buttonStyle(.plain)
                            .contextMenu {
                                Button { player.playNext(item) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                                Button { player.playLater(item) } label: { Label("Play Later", systemImage: "text.append") }
                            }
                            .swipeActions {
                                if player.currentItem?.id != item.id {
                                    Button(role: .destructive) {
                                        if let index = player.queue.firstIndex(where: { $0.id == item.id }) { player.removeFromQueue(at: IndexSet(integer: index)) }
                                    } label: { Label("Remove", systemImage: "trash") }
                                }
                            }
                    }
                    .onMove(perform: player.moveQueue)
                    .onDelete(perform: player.removeFromQueue)
                }
            }
            .navigationTitle("Up Next")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        .alert("Save Queue as Playlist", isPresented: $showSave) {
            TextField("Playlist name", text: $playlistName)
            Button("Save") { saveQueue() }.disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Clear everything after the current item?", isPresented: $showClear, titleVisibility: .visible) {
            Button("Clear Queue", role: .destructive) { player.clearQueue(); Haptics.success() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func saveQueue() {
        let items = player.originalQueue.isEmpty ? player.queue : player.originalQueue
        let playlist = MediaPlaylist(name: playlistName.trimmingCharacters(in: .whitespacesAndNewlines), itemIDs: items.map(\.id))
        modelContext.insert(playlist)
        try? modelContext.save()
        Haptics.success()
    }
}

struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = false
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}

private struct SleepTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager
    var body: some View {
        NavigationStack {
            List {
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in Button("\(minutes) minutes") { player.setSleepTimer(minutes: minutes); dismiss() } }
                Button("Off", role: .destructive) { player.setSleepTimer(minutes: nil); dismiss() }
            }.navigationTitle("Sleep Timer").navigationBarTitleDisplayMode(.inline)
        }.presentationDetents([.medium])
    }
}
