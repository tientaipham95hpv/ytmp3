import AVFoundation
import Combine
import MediaPlayer
import UIKit

@MainActor
final class PlayerManager: ObservableObject {
    enum RepeatMode: String, CaseIterable {
        case off, all, one

        var icon: String { self == .one ? "repeat.1" : "repeat" }
    }

    static let shared = PlayerManager()

    let player = AVPlayer()
    @Published private(set) var currentItem: MediaItem?
    @Published private(set) var queue: [MediaItem] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var isShuffling = false
    @Published var repeatMode: RepeatMode = .off
    @Published var playbackSpeed: Float = 1
    @Published private(set) var sleepTimerEnd: Date?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var sleepTask: Task<Void, Never>?

    private init() {
        configureAudioSession()
        configureRemoteCommands()
        observeTime()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        sleepTask?.cancel()
    }

    func play(_ item: MediaItem, queue newQueue: [MediaItem]? = nil) {
        guard FileManager.default.fileExists(atPath: item.localURL.path) else { return }
        if let newQueue { queue = newQueue }
        if queue.isEmpty { queue = [item] }
        if currentItem?.id != item.id {
            currentItem = item
            item.lastPlayedAt = Date()
            let playerItem = AVPlayerItem(url: item.localURL)
            player.replaceCurrentItem(with: playerItem)
            duration = item.duration
            seek(to: item.playbackPosition)
            observeEnd(of: playerItem)
        }
        player.playImmediately(atRate: playbackSpeed)
        isPlaying = true
        updateNowPlaying()
    }

    func playAll(_ items: [MediaItem], shuffled: Bool = false) {
        guard !items.isEmpty else { return }
        isShuffling = shuffled
        let newQueue = shuffled ? items.shuffled() : items
        play(newQueue[0], queue: newQueue)
    }

    func toggle() { isPlaying ? pause() : resume() }

    func pause() {
        player.pause()
        isPlaying = false
        persistPosition()
        updateNowPlaying()
    }

    func resume() {
        guard currentItem != nil else { return }
        player.playImmediately(atRate: playbackSpeed)
        isPlaying = true
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        let safeValue = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.seek(to: CMTime(seconds: safeValue, preferredTimescale: 600))
        currentTime = safeValue
        persistPosition()
        updateNowPlaying()
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func next() {
        guard let currentItem, !queue.isEmpty,
              let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return }
        let nextIndex: Int
        if isShuffling, queue.count > 1 {
            nextIndex = queue.indices.filter { $0 != index }.randomElement() ?? index
        } else if index + 1 < queue.count {
            nextIndex = index + 1
        } else if repeatMode == .all {
            nextIndex = 0
        } else {
            pause()
            seek(to: 0)
            return
        }
        play(queue[nextIndex])
    }

    func previous() {
        if currentTime > 5 { seek(to: 0); return }
        guard let currentItem, !queue.isEmpty,
              let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return }
        play(queue[index > 0 ? index - 1 : max(0, queue.count - 1)])
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func setSpeed(_ speed: Float) {
        playbackSpeed = speed
        if isPlaying { player.rate = speed }
        updateNowPlaying()
    }

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else {
            sleepTimerEnd = nil
            return
        }
        let end = Date().addingTimeInterval(Double(minutes * 60))
        sleepTimerEnd = end
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            guard !Task.isCancelled else { return }
            self?.pause()
            self?.sleepTimerEnd = nil
        }
    }

    func stopIfPlaying(_ item: MediaItem) {
        queue.removeAll { $0.id == item.id }
        guard currentItem?.id == item.id else { return }
        pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session setup failed: \(error.localizedDescription)")
        }
    }

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 2), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                }
                self.persistPosition()
                self.updateNowPlaying()
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.repeatMode == .one {
                    self.seek(to: 0)
                    self.resume()
                } else {
                    self.next()
                }
            }
        }
    }

    private func persistPosition() { currentItem?.playbackPosition = currentTime }

    private func updateNowPlaying() {
        guard let item = currentItem else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.channel,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackSpeed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackSpeed
        ]
        if let existingArtwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtwork(for: item)
    }

    private func loadArtwork(for item: MediaItem) {
        guard MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil,
              let value = item.thumbnailURL, let url = URL(string: value) else { return }
        Task.detached {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                guard self.currentItem?.id == item.id else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(by: 10) }; return .success }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(by: -10) }; return .success }
    }
}
