import AVFoundation
import Combine
import MediaPlayer
import UIKit
import SwiftData
import SwiftUI

@MainActor
final class PlayerManager: ObservableObject {
    enum RepeatMode: String, CaseIterable {
        case off, all, one

        var icon: String { self == .one ? "repeat.1" : "repeat" }
    }

    static let shared = PlayerManager()

    private var activePlayer = AVPlayer()
    var player: AVPlayer { activePlayer }
    @Published private(set) var currentItem: MediaItem?
    @Published private(set) var queue: [MediaItem] = []
    @Published private(set) var originalQueue: [MediaItem] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var isShuffling = false
    @Published var repeatMode: RepeatMode = .off
    @Published var playbackSpeed: Float = 1
    @Published private(set) var sleepTimerEnd: Date?
    @Published private(set) var currentRouteName = "iPhone"
    @Published private(set) var isAirPlayActive = false

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var sleepTask: Task<Void, Never>?
    private var externalPlaybackObserver: AnyCancellable?
    private var observedTimePlayer: AVPlayer?
    private var transitionPlayer: AVPlayer?
    private var transitionItem: MediaItem?
    private var crossfadeTask: Task<Void, Never>?
    private var isCrossfading = false
    private var routeChangeObserver: NSObjectProtocol?
    private var modelContext: ModelContext?
    private var lastSavedSecond = -1
    private var lastNowPlayingSecond = -1
    private var analyticsLastTime: Double?
    private var analyticsPendingSeconds: Double = 0
    private let stateKey = "player.session.v1"

    private struct PersistedSession: Codable {
        let queueIDs: [UUID]
        let originalQueueIDs: [UUID]?
        let currentID: UUID?
        let isShuffling: Bool
        let repeatMode: String
        let playbackSpeed: Float
    }

    private init() {
        configurePlayer(activePlayer)
        configureAudioSession()
        configureRemoteCommands()
        observeAudioSession()
        observeExternalPlayback()
        updateCurrentRoute()
        observeTime()
    }

    deinit {
        if let timeObserver, let observedTimePlayer { observedTimePlayer.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
        sleepTask?.cancel()
        crossfadeTask?.cancel()
    }

    func play(_ item: MediaItem, queue newQueue: [MediaItem]? = nil, recordReplacementAsSkip: Bool = true) {
        guard FileManager.default.fileExists(atPath: item.localURL.path) else { return }
        if currentItem?.id != item.id { cancelCrossfade() }
        if let newQueue {
            originalQueue = deduplicated(newQueue.filter(\.isAvailableOffline))
            queue = isShuffling ? shuffledQueue(originalQueue, keeping: item) : originalQueue
        }
        if queue.isEmpty { queue = [item]; originalQueue = [item] }
        if !queue.contains(where: { $0.id == item.id }) { queue.append(item) }
        if !originalQueue.contains(where: { $0.id == item.id }) { originalQueue.append(item) }
        if currentItem?.id != item.id {
            if recordReplacementAsSkip { recordSkipIfNeeded() }
            flushAnalyticsTime()
            currentItem = item
            item.lastPlayedAt = Date()
            item.playCount += 1
            CloudSyncService.markChanged(item)
            saveContext()
            let playerItem = AVPlayerItem(url: item.localURL)
            playerItem.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: playerItem)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            duration = item.duration
            seek(to: item.playbackPosition)
            observeEnd(of: playerItem)
            analyticsLastTime = item.playbackPosition
            recordAnalyticsStart(item)
        }
        player.playImmediately(atRate: playbackSpeed)
        isPlaying = true
        persistSession()
        updateNowPlaying()
    }

    func playAll(_ items: [MediaItem], shuffled: Bool = false) {
        guard !items.isEmpty else { return }
        isShuffling = shuffled
        originalQueue = deduplicated(items.filter(\.isAvailableOffline))
        guard !originalQueue.isEmpty else { return }
        queue = shuffled ? originalQueue.shuffled() : originalQueue
        play(queue[0])
    }

    func toggle() { isPlaying ? pause() : resume() }

    func pause() {
        cancelCrossfade()
        player.pause()
        isPlaying = false
        flushAnalyticsTime()
        persistPosition()
        saveContext()
        updateNowPlaying()
    }

    func resume() {
        guard currentItem?.isAvailableOffline == true else { return }
        player.playImmediately(atRate: playbackSpeed)
        isPlaying = true
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        cancelCrossfade()
        let safeValue = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.seek(to: CMTime(seconds: safeValue, preferredTimescale: 600))
        currentTime = safeValue
        persistPosition()
        saveContext()
        updateNowPlaying()
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func next() { advanceToNext(manual: true) }

    private func advanceToNext(manual: Bool) {
        if isCrossfading, let transitionItem, let transitionPlayer {
            finishCrossfade(to: transitionItem, oldPlayer: activePlayer, incoming: transitionPlayer)
            return
        }
        guard let currentItem, !queue.isEmpty,
              let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return }
        if manual { recordSkipIfNeeded() }
        let nextIndex: Int
        if index + 1 < queue.count {
            nextIndex = index + 1
        } else if repeatMode == .all {
            nextIndex = 0
        } else {
            pause()
            seek(to: 0)
            return
        }
        let target = queue[nextIndex]
        if shouldCrossfade(to: target) { beginCrossfade(to: target) }
        else { play(target, recordReplacementAsSkip: false) }
    }

    func previous() {
        cancelCrossfade()
        if currentTime > 5 { seek(to: 0); return }
        recordSkipIfNeeded()
        guard let currentItem, !queue.isEmpty,
              let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return }
        if index > 0 { play(queue[index - 1], recordReplacementAsSkip: false) }
        else if repeatMode == .all { play(queue[queue.count - 1], recordReplacementAsSkip: false) }
        else { seek(to: 0) }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        persistSession()
    }

    func toggleShuffle() {
        isShuffling.toggle()
        guard let currentItem else {
            queue = isShuffling ? originalQueue.shuffled() : originalQueue
            persistSession(); return
        }
        queue = isShuffling ? shuffledQueue(originalQueue, keeping: currentItem) : originalQueue
        persistSession()
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        originalQueue = queue
        isShuffling = false
        persistSession()
    }

    func removeFromQueue(at offsets: IndexSet) {
        let currentID = currentItem?.id
        let removedIDs = Set(offsets.compactMap { queue.indices.contains($0) ? queue[$0].id : nil })
        queue.remove(atOffsets: offsets)
        originalQueue.removeAll { removedIDs.contains($0.id) }
        if let currentID, !queue.contains(where: { $0.id == currentID }) {
            player.replaceCurrentItem(with: nil)
            currentItem = nil; currentTime = 0; duration = 0; isPlaying = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        persistSession()
    }

    func playNext(_ item: MediaItem) {
        guard item.isAvailableOffline, item.id != currentItem?.id else { return }
        let currentID = currentItem?.id
        Self.insert(item, after: currentID, into: &queue)
        Self.insert(item, after: currentID, into: &originalQueue)
        persistSession()
    }

    func playLater(_ item: MediaItem) {
        guard item.isAvailableOffline, item.id != currentItem?.id else { return }
        queue.removeAll { $0.id == item.id }; queue.append(item)
        originalQueue.removeAll { $0.id == item.id }; originalQueue.append(item)
        persistSession()
    }

    func clearQueue() {
        if let currentItem { queue = [currentItem]; originalQueue = [currentItem] }
        else { queue = []; originalQueue = [] }
        isShuffling = false
        persistSession()
    }

    func setSpeed(_ speed: Float) {
        cancelCrossfade()
        playbackSpeed = speed
        if isPlaying { player.rate = speed }
        updateNowPlaying()
        persistSession()
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
        originalQueue.removeAll { $0.id == item.id }
        guard currentItem?.id == item.id else { persistSession(); return }
        cancelCrossfade()
        pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        persistSession()
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        restoreSessionIfNeeded()
    }

    func savePlaybackState() {
        flushAnalyticsTime()
        persistPosition()
        saveContext()
        persistSession()
    }

    func metadataDidChange(for item: MediaItem) {
        guard currentItem?.id == item.id else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateNowPlaying()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session setup failed: \(error.localizedDescription)")
        }
    }

    private func observeTime() {
        if let timeObserver, let observedTimePlayer { observedTimePlayer.removeTimeObserver(timeObserver) }
        observedTimePlayer = activePlayer
        timeObserver = activePlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 4), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                }
                self.persistPosition()
                self.trackAnalyticsTime(at: self.currentTime)
                let second = Int(self.currentTime)
                if second != self.lastNowPlayingSecond {
                    self.lastNowPlayingSecond = second
                    self.updateNowPlaying()
                }
                self.startAutomaticTransitionIfNeeded()
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.isCrossfading else { return }
                if let current = self.currentItem { self.recordAnalyticsCompletion(current) }
                if self.repeatMode == .one {
                    self.seek(to: 0)
                    self.resume()
                } else {
                    self.advanceToNext(manual: false)
                }
            }
        }
    }

    private func persistPosition() {
        currentItem?.playbackPosition = currentTime
        let second = Int(currentTime)
        if second / 5 != lastSavedSecond / 5 {
            lastSavedSecond = second
            if let currentItem { CloudSyncService.markChanged(currentItem) }
            saveContext()
        }
    }

    private var crossfadeSeconds: Double {
        Double(UserDefaults.standard.integer(forKey: "audioCrossfadeSeconds"))
    }

    private func nextQueueItem() -> MediaItem? {
        guard let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return nil }
        if index + 1 < queue.count { return queue[index + 1] }
        return repeatMode == .all ? queue.first : nil
    }

    private func shouldCrossfade(to item: MediaItem) -> Bool {
        crossfadeSeconds > 0 && currentItem?.isVideo == false && !item.isVideo && repeatMode != .one && isPlaying && !isCrossfading
    }

    private func startAutomaticTransitionIfNeeded() {
        guard let target = nextQueueItem(), shouldCrossfade(to: target), duration > 0,
              duration - currentTime <= crossfadeSeconds else { return }
        if let currentItem { recordAnalyticsCompletion(currentItem) }
        beginCrossfade(to: target)
    }

    private func beginCrossfade(to item: MediaItem) {
        guard shouldCrossfade(to: item), item.isAvailableOffline else { play(item); return }
        isCrossfading = true
        let oldPlayer = activePlayer
        let incoming = AVPlayer(playerItem: makePlayerItem(for: item))
        configurePlayer(incoming)
        incoming.volume = 0
        transitionPlayer = incoming
        transitionItem = item
        incoming.playImmediately(atRate: playbackSpeed)
        let seconds = crossfadeSeconds
        crossfadeTask = Task { [weak self, oldPlayer, incoming] in
            let steps = max(1, Int(seconds * 20))
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                let progress = Float(step) / Float(steps)
                oldPlayer.volume = 1 - progress
                incoming.volume = progress
            }
            guard let self, !Task.isCancelled else { return }
            self.finishCrossfade(to: item, oldPlayer: oldPlayer, incoming: incoming)
        }
    }

    private func finishCrossfade(to item: MediaItem, oldPlayer: AVPlayer, incoming: AVPlayer) {
        crossfadeTask?.cancel()
        flushAnalyticsTime()
        persistPosition()
        oldPlayer.pause(); oldPlayer.volume = 1
        activePlayer = incoming; activePlayer.volume = 1
        transitionPlayer = nil; transitionItem = nil; crossfadeTask = nil; isCrossfading = false
        currentItem = item
        item.lastPlayedAt = Date(); item.playCount += 1; CloudSyncService.markChanged(item)
        duration = item.duration
        currentTime = max(0, incoming.currentTime().seconds.isFinite ? incoming.currentTime().seconds : 0)
        lastSavedSecond = Int(currentTime)
        analyticsLastTime = currentTime
        recordAnalyticsStart(item)
        observeTime()
        if let playerItem = incoming.currentItem { observeEnd(of: playerItem) }
        observeExternalPlayback()
        saveContext(); persistSession(); updateNowPlaying(); updateCurrentRoute()
    }

    private func cancelCrossfade() {
        guard isCrossfading || transitionPlayer != nil else { return }
        crossfadeTask?.cancel(); crossfadeTask = nil
        transitionPlayer?.pause(); transitionPlayer = nil; transitionItem = nil
        activePlayer.volume = 1; isCrossfading = false
    }

    private func makePlayerItem(for item: MediaItem) -> AVPlayerItem {
        let playerItem = AVPlayerItem(url: item.localURL)
        playerItem.audioTimePitchAlgorithm = .spectral
        return playerItem
    }

    private func configurePlayer(_ player: AVPlayer) {
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.automaticallyWaitsToMinimizeStalling = false
    }

    private func observeExternalPlayback() {
        externalPlaybackObserver = activePlayer.publisher(for: \.isExternalPlaybackActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.updateCurrentRoute() } }
    }

    private func saveContext() { try? modelContext?.save() }

    private func analyticsID(for item: MediaItem) -> String {
        item.sourceID.isEmpty ? item.id.uuidString : item.sourceID
    }

    private func recordAnalyticsStart(_ item: MediaItem) {
        let id = analyticsID(for: item), title = item.title, channel = item.channel, isVideo = item.isVideo
        Task { await LocalStatisticsStore.shared.recordStarted(id: id, title: title, channel: channel, isVideo: isVideo) }
    }

    private func recordAnalyticsCompletion(_ item: MediaItem) {
        flushAnalyticsTime()
        let id = analyticsID(for: item), title = item.title, channel = item.channel, isVideo = item.isVideo
        Task { await LocalStatisticsStore.shared.recordCompleted(id: id, title: title, channel: channel, isVideo: isVideo) }
    }

    private func recordSkipIfNeeded() {
        guard let item = currentItem, currentTime >= 3, duration <= 0 || currentTime < duration - 3 else { return }
        flushAnalyticsTime()
        let id = analyticsID(for: item), title = item.title, channel = item.channel, isVideo = item.isVideo
        Task { await LocalStatisticsStore.shared.recordSkipped(id: id, title: title, channel: channel, isVideo: isVideo) }
    }

    private func trackAnalyticsTime(at time: Double) {
        defer { analyticsLastTime = time }
        guard isPlaying, let previous = analyticsLastTime else { return }
        let delta = time - previous
        guard delta > 0, delta < 2 else { return }
        analyticsPendingSeconds += delta
        if analyticsPendingSeconds >= 5 { flushAnalyticsTime() }
    }

    private func flushAnalyticsTime() {
        guard let item = currentItem, analyticsPendingSeconds > 0 else { return }
        let seconds = analyticsPendingSeconds
        analyticsPendingSeconds = 0
        let id = analyticsID(for: item), title = item.title, channel = item.channel, isVideo = item.isVideo
        Task { await LocalStatisticsStore.shared.recordActiveTime(id: id, title: title, channel: channel, isVideo: isVideo, seconds: seconds) }
    }

    private func persistSession() {
        let session = PersistedSession(
            queueIDs: queue.map(\.id), originalQueueIDs: originalQueue.map(\.id), currentID: currentItem?.id,
            isShuffling: isShuffling, repeatMode: repeatMode.rawValue,
            playbackSpeed: playbackSpeed
        )
        if let data = try? JSONEncoder().encode(session) { UserDefaults.standard.set(data, forKey: stateKey) }
    }

    private func restoreSessionIfNeeded() {
        guard currentItem == nil, let modelContext,
              let data = UserDefaults.standard.data(forKey: stateKey),
              let session = try? JSONDecoder().decode(PersistedSession.self, from: data),
              let allItems = try? modelContext.fetch(FetchDescriptor<MediaItem>()) else { return }
        let available = Dictionary(uniqueKeysWithValues: allItems.filter(\.isAvailableOffline).map { ($0.id, $0) })
        queue = session.queueIDs.compactMap { available[$0] }
        originalQueue = (session.originalQueueIDs ?? session.queueIDs).compactMap { available[$0] }
        isShuffling = session.isShuffling
        repeatMode = RepeatMode(rawValue: session.repeatMode) ?? .off
        playbackSpeed = session.playbackSpeed
        guard let currentID = session.currentID, let item = available[currentID] else {
            persistSession(); return
        }
        if !queue.contains(where: { $0.id == item.id }) { queue.insert(item, at: 0) }
        currentItem = item
        let playerItem = AVPlayerItem(url: item.localURL)
        playerItem.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: playerItem)
        duration = item.duration
        currentTime = min(max(0, item.playbackPosition), max(item.duration, item.playbackPosition))
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
        observeEnd(of: playerItem)
        updateNowPlaying()
    }

    private func deduplicated(_ items: [MediaItem]) -> [MediaItem] {
        var seen = Set<UUID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private func shuffledQueue(_ items: [MediaItem], keeping current: MediaItem) -> [MediaItem] {
        [current] + items.filter { $0.id != current.id }.shuffled()
    }

    private static func insert(_ item: MediaItem, after currentID: UUID?, into items: inout [MediaItem]) {
        items.removeAll { $0.id == item.id }
        if let currentID, let index = items.firstIndex(where: { $0.id == currentID }) {
            items.insert(item, at: min(index + 1, items.endIndex))
        } else {
            items.insert(item, at: 0)
        }
    }

    private func observeAudioSession() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began { self.pause() }
                else if let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                        AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) { self.resume() }
            }
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateCurrentRoute()
                self?.updateNowPlaying()
            }
        }
    }

    private func updateCurrentRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let airPlayOutput = outputs.first { $0.portType == .airPlay }
        isAirPlayActive = airPlayOutput != nil || player.isExternalPlaybackActive
        currentRouteName = airPlayOutput?.portName
            ?? outputs.first?.portName
            ?? String(localized: "On This iPhone")
    }

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
        guard MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil else { return }
        if let localURL = item.artworkURL, let image = UIImage(contentsOfFile: localURL.path) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        }
        guard let value = item.thumbnailURL, let url = URL(string: value) else { return }
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
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
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
