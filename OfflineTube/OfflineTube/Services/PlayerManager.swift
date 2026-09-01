import AVFoundation
import Combine
import MediaPlayer

@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    let player = AVPlayer()
    @Published private(set) var currentItem: MediaItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private init() {
        configureAudioSession()
        configureRemoteCommands()
        observeTime()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func play(_ item: MediaItem) {
        guard FileManager.default.fileExists(atPath: item.localURL.path) else { return }
        if currentItem?.id != item.id {
            currentItem = item
            let playerItem = AVPlayerItem(url: item.localURL)
            player.replaceCurrentItem(with: playerItem)
            duration = item.duration
            seek(to: item.playbackPosition)
            observeEnd(of: playerItem)
        }
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func toggle() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        player.pause()
        isPlaying = false
        persistPosition()
        updateNowPlaying()
    }

    func resume() {
        guard currentItem != nil else { return }
        player.play()
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

    func stopIfPlaying(_ item: MediaItem) {
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
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main) { [weak self] time in
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
                self.isPlaying = false
                self.seek(to: 0)
            }
        }
    }

    private func persistPosition() {
        currentItem?.playbackPosition = currentTime
    }

    private func updateNowPlaying() {
        guard let item = currentItem else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.channel,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: positionEvent.positionTime) }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seek(to: self.currentTime + 15)
            }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seek(to: self.currentTime - 15)
            }
            return .success
        }
    }
}
