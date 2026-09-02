import Combine
import Foundation
import OSLog
import SwiftData
import SwiftUI

struct DownloadQueueItem: Identifiable, Codable {
    enum State: String, Codable {
        case queued, downloading, saving, completed, failed, cancelled
        var title: LocalizedStringKey {
            switch self {
            case .queued: "Queued"
            case .downloading: "Downloading"
            case .saving: "Saving"
            case .completed: "Completed"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }
    }

    let id: UUID
    let url: String
    let info: MediaInfo
    let mediaType: String
    let quality: String
    var state: State = .queued
    var progress = 0.0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64?
    var speedBytesPerSecond: Double?
    var backendJobID: String?
    var error: String?
    var retryCount: Int = 0
    var remainingSeconds: Double?
    var batchID: UUID?

    enum CodingKeys: String, CodingKey {
        case id, url, info, mediaType, quality, state, progress, downloadedBytes
        case totalBytes, speedBytesPerSecond, backendJobID, error, retryCount, remainingSeconds, batchID
    }

    init(
        id: UUID,
        url: String,
        info: MediaInfo,
        mediaType: String,
        quality: String,
        state: State = .queued,
        progress: Double = 0,
        downloadedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        speedBytesPerSecond: Double? = nil,
        backendJobID: String? = nil,
        error: String? = nil,
        retryCount: Int = 0,
        batchID: UUID? = nil
    ) {
        self.id = id
        self.url = url
        self.info = info
        self.mediaType = mediaType
        self.quality = quality
        self.state = state
        self.progress = progress
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.backendJobID = backendJobID
        self.error = error
        self.retryCount = retryCount
        self.remainingSeconds = nil
        self.batchID = batchID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        url = try values.decode(String.self, forKey: .url)
        info = try values.decode(MediaInfo.self, forKey: .info)
        mediaType = try values.decode(String.self, forKey: .mediaType)
        quality = try values.decode(String.self, forKey: .quality)
        state = try values.decodeIfPresent(State.self, forKey: .state) ?? .queued
        progress = try values.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        downloadedBytes = try values.decodeIfPresent(Int64.self, forKey: .downloadedBytes) ?? 0
        totalBytes = try values.decodeIfPresent(Int64.self, forKey: .totalBytes)
        speedBytesPerSecond = try values.decodeIfPresent(Double.self, forKey: .speedBytesPerSecond)
        backendJobID = try values.decodeIfPresent(String.self, forKey: .backendJobID)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        retryCount = try values.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        remainingSeconds = try values.decodeIfPresent(Double.self, forKey: .remainingSeconds)
        batchID = try values.decodeIfPresent(UUID.self, forKey: .batchID)
    }
}

@MainActor
final class DownloadViewModel: ObservableObject {
    enum MediaKind: String, CaseIterable, Identifiable {
        case audio, video
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .audio ? "Audio" : "Video" }
    }

    @Published var urlText = ""
    @Published var mediaInfo: MediaInfo?
    @Published var mediaKind: MediaKind = .audio {
        didSet {
            quality = mediaKind == .audio
                ? (UserDefaults.standard.string(forKey: "defaultAudioQuality") ?? "original")
                : (UserDefaults.standard.string(forKey: "defaultVideoQuality") ?? "720")
        }
    }
    @Published var quality = "original"
    @Published var isLoadingInfo = false
    @Published var isDownloading = false
    @Published var progress = 0.0
    @Published var statusText = ""
    @Published var errorMessage: String?
    @Published var completedMessage: String?
    @Published var batchInfo: PlaylistInfo?
    @Published var batchSelection = Set<String>()
    @Published var isLoadingBatch = false
    @Published var activeBatchID: UUID?
    @Published private(set) var queueItems: [DownloadQueueItem] = [] {
        didSet { persistQueue() }
    }

    let audioQualities = [("original", "Original/M4A"), ("128", "MP3 128"), ("192", "MP3 192"), ("320", "MP3 320")]
    let videoQualities = [("360", "360p"), ("480", "480p"), ("720", "720p"), ("1080", "1080p"), ("best", "Best")]
    private var workerTasks: [UUID: Task<Void, Never>] = [:]
    private let maximumConcurrentDownloads = 2
    private var modelContext: ModelContext?
    private let logger = Logger(subsystem: "com.personal.OfflineTube", category: "Downloads")
    private var speedSamples: [UUID: [Double]] = [:]

    init() {
        quality = UserDefaults.standard.string(forKey: "defaultAudioQuality") ?? "original"
        if let data = try? Data(contentsOf: queueFileURL),
           var saved = try? JSONDecoder().decode([DownloadQueueItem].self, from: data) {
            for index in saved.indices where saved[index].state == .downloading || saved[index].state == .saving {
                saved[index].state = .queued
            }
            queueItems = saved
            activeBatchID = saved.reversed().compactMap(\.batchID).first
        }
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        startWorkersIfNeeded()
    }

    func fetchInfo() async {
        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { errorMessage = "Hãy dán link YouTube."; return }
        isLoadingInfo = true; errorMessage = nil; completedMessage = nil
        defer { isLoadingInfo = false }
        do { mediaInfo = try await APIClient.shared.mediaInfo(url: value) }
        catch { mediaInfo = nil; errorMessage = error.localizedDescription }
    }

    func loadBatch(from text: String) async {
        let urls = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { errorMessage = localized("Paste at least one YouTube URL.", "Hãy dán ít nhất một URL YouTube."); return }
        isLoadingBatch = true; errorMessage = nil; batchInfo = nil; batchSelection = []
        defer { isLoadingBatch = false }
        do {
            var entries: [MediaInfo] = []
            var title = localized("Batch Download", "Tải hàng loạt")
            for url in urls {
                if url.contains("list=") || url.contains("/playlist") {
                    let playlist = try await APIClient.shared.playlistInfo(url: url)
                    title = playlist.title
                    entries.append(contentsOf: playlist.entries)
                } else {
                    entries.append(try await APIClient.shared.mediaInfo(url: url))
                }
            }
            var seen = Set<String>()
            entries = entries.filter { seen.insert($0.id).inserted }
            batchInfo = PlaylistInfo(id: UUID().uuidString, title: title, channel: "", thumbnail: entries.first?.thumbnail, entries: entries, totalEntries: entries.count, isTruncated: false)
            batchSelection = Set(entries.map(\.id))
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func enqueueBatch(modelContext: ModelContext, downloadAgain: Bool) -> Int {
        guard let batchInfo else { return 0 }
        self.modelContext = modelContext
        do {
            try FileStore.cleanupTemporaryFiles(); try FileStore.ensureCapacity()
            let existing = try modelContext.fetch(FetchDescriptor<MediaItem>())
            let batchID = UUID()
            var added = 0
            for info in batchInfo.entries where batchSelection.contains(info.id) {
                let exactExists = existing.contains { $0.sourceID == info.id && $0.mediaType == mediaKind.rawValue && $0.quality == quality }
                let exactQueued = queueItems.contains { $0.info.id == info.id && $0.mediaType == mediaKind.rawValue && $0.quality == quality && ![.failed, .cancelled].contains($0.state) }
                if !downloadAgain && (exactExists || exactQueued) { continue }
                queueItems.append(DownloadQueueItem(id: UUID(), url: info.webpageURL, info: info, mediaType: mediaKind.rawValue, quality: quality, batchID: batchID))
                added += 1
            }
            guard added > 0 else {
                errorMessage = localized("Everything selected is already in your Library or queue.", "Các mục đã chọn đều có trong Thư viện hoặc hàng đợi.")
                return 0
            }
            activeBatchID = batchID
            completedMessage = localized("Added \(added) items to the download queue.", "Đã thêm \(added) mục vào hàng đợi tải.")
            startWorkersIfNeeded()
            return added
        } catch { errorMessage = error.localizedDescription; return 0 }
    }

    func cancelBatch(_ batchID: UUID) {
        let ids = queueItems.filter { $0.batchID == batchID && [.queued, .downloading, .saving].contains($0.state) }.map(\.id)
        ids.forEach(cancel)
    }

    func batchItems(_ batchID: UUID) -> [DownloadQueueItem] { queueItems.filter { $0.batchID == batchID } }

    func batchProgress(_ batchID: UUID) -> Double {
        let items = batchItems(batchID)
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { $0 + ($1.state == .completed ? 1 : $1.progress) } / Double(items.count)
    }

    func startDownload(modelContext: ModelContext) {
        guard let info = mediaInfo else { return }
        self.modelContext = modelContext
        do {
            try FileStore.cleanupTemporaryFiles()
            try FileStore.ensureCapacity()
            let sourceID = info.id
            let existing = try modelContext.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.sourceID == sourceID }))
            let exactExists = existing.contains { $0.mediaType == self.mediaKind.rawValue && $0.quality == self.quality }
            let exactQueued = queueItems.contains { $0.info.id == sourceID && $0.mediaType == self.mediaKind.rawValue && $0.quality == self.quality && $0.state != .failed && $0.state != .cancelled }
            guard !exactExists, !exactQueued else {
                errorMessage = localized("This media is already in your Library or download queue.", "Nội dung này đã có trong Thư viện hoặc hàng đợi tải.")
                return
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("enqueue rejected source=\(info.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return
        }
        queueItems.append(DownloadQueueItem(id: UUID(), url: urlText, info: info, mediaType: mediaKind.rawValue, quality: quality))
        logger.info("queued source=\(info.id, privacy: .public) type=\(self.mediaKind.rawValue, privacy: .public)")
        completedMessage = localized("Added “\(info.title)” to the queue.", "Đã thêm “\(info.title)” vào hàng đợi.")
        errorMessage = nil
        startWorkersIfNeeded()
    }

    func download(modelContext: ModelContext) async { startDownload(modelContext: modelContext) }

    func cancel(_ id: UUID) {
        guard let index = queueItems.firstIndex(where: { $0.id == id }) else { return }
        let backendID = queueItems[index].backendJobID
        queueItems[index].state = .cancelled
        queueItems[index].speedBytesPerSecond = nil
        if let backendID { Task { _ = try? await APIClient.shared.cancelJob(id: backendID) } }
    }

    func cancelDownload() {
        if let active = queueItems.first(where: { $0.state == .downloading || $0.state == .queued }) { cancel(active.id) }
    }

    func retry(_ id: UUID) {
        guard let item = queueItems.first(where: { $0.id == id }) else { return }
        var retry = DownloadQueueItem(id: UUID(), url: item.url, info: item.info, mediaType: item.mediaType, quality: item.quality, batchID: item.batchID)
        retry.state = .queued
        queueItems.append(retry)
        startWorkersIfNeeded()
    }

    func retry(modelContext: ModelContext) {
        self.modelContext = modelContext
        if let failed = queueItems.last(where: { $0.state == .failed || $0.state == .cancelled }) { retry(failed.id) }
        else { startDownload(modelContext: modelContext) }
    }

    func removeFinished(at offsets: IndexSet) {
        let removable = queueItems.indices.filter { queueItems[$0].state != .downloading && queueItems[$0].state != .saving }
        for offset in offsets.sorted(by: >) where offset < removable.count { queueItems.remove(at: removable[offset]) }
    }

    private func startWorkersIfNeeded() {
        while workerTasks.count < maximumConcurrentDownloads,
              queueItems.contains(where: { $0.state == .queued }) {
            let workerID = UUID()
            workerTasks[workerID] = Task { [weak self] in
                await self?.processQueue()
                self?.workerTasks.removeValue(forKey: workerID)
                self?.startWorkersIfNeeded()
            }
        }
    }

    private func processQueue() async {
        while let id = queueItems.first(where: { $0.state == .queued })?.id {
            await processItem(id: id)
        }
        if !queueItems.contains(where: { $0.state == .downloading || $0.state == .saving }) {
            isDownloading = false; progress = 0; statusText = ""
        }
    }

    private func processItem(id: UUID) async {
        guard let index = queueItems.firstIndex(where: { $0.id == id }), let modelContext else { return }
        queueItems[index].state = .downloading
        isDownloading = true; errorMessage = nil; completedMessage = nil; progress = 0; statusText = localized("Creating job…", "Đang tạo tác vụ…")
        do {
            let snapshot = queueItems[index]
            let created: JobCreated
            if let existingJobID = snapshot.backendJobID {
                created = JobCreated(id: existingJobID, status: "downloading")
            } else {
                created = try await APIClient.shared.createDownload(url: snapshot.url, mediaType: snapshot.mediaType, quality: snapshot.quality)
            }
            guard let createdIndex = queueItems.firstIndex(where: { $0.id == id }), queueItems[createdIndex].state != .cancelled else {
                _ = try? await APIClient.shared.cancelJob(id: created.id); return
            }
            queueItems[createdIndex].backendJobID = created.id
            while let currentIndex = queueItems.firstIndex(where: { $0.id == id }), queueItems[currentIndex].state != .cancelled {
                let job = try await APIClient.shared.job(id: created.id)
                guard let updateIndex = queueItems.firstIndex(where: { $0.id == id }) else { return }
                queueItems[updateIndex].progress = min(1, max(0, job.progress / 100))
                queueItems[updateIndex].downloadedBytes = job.downloadedBytes ?? 0
                queueItems[updateIndex].totalBytes = job.totalBytes
                queueItems[updateIndex].speedBytesPerSecond = job.speedBytesPerSecond
                updateETA(at: updateIndex, id: id)
                progress = queueItems[updateIndex].progress
                statusText = job.status == "queued" ? localized("Queued…", "Đang chờ…") : localized("Downloading \(Int(job.progress))%", "Đang tải \(Int(job.progress))%")
                if job.status == "cancelled" { queueItems[updateIndex].state = .cancelled; return }
                if job.status == "failed" { throw APIError.server(job.error ?? "Tải media thất bại.") }
                if job.status == "completed" {
                    guard let fileID = job.fileID, let filename = job.filename else { throw APIError.missingResult }
                    queueItems[updateIndex].state = .saving; statusText = localized("Saving to device…", "Đang lưu vào thiết bị…")
                    try FileStore.ensureCapacity(requiredBytes: job.totalBytes)
                    let localURL = try await APIClient.shared.download(fileID: fileID, filename: filename)
                    guard let savingIndex = queueItems.firstIndex(where: { $0.id == id }), queueItems[savingIndex].state != .cancelled else {
                        try? FileManager.default.removeItem(at: localURL)
                        return
                    }
                    let item = MediaItem(sourceID: snapshot.info.id, sourceURL: snapshot.info.webpageURL, title: snapshot.info.title, channel: snapshot.info.channel, thumbnailURL: snapshot.info.thumbnail, duration: snapshot.info.duration, localFilename: localURL.lastPathComponent, mediaType: snapshot.mediaType, quality: snapshot.quality)
                    item.artworkFilename = await FileStore.saveArtwork(from: snapshot.info.thumbnail, sourceID: snapshot.info.id)
                    modelContext.insert(item); try modelContext.save()
                    guard let finishedIndex = queueItems.firstIndex(where: { $0.id == id }) else { return }
                    queueItems[finishedIndex].state = .completed; queueItems[finishedIndex].progress = 1
                    queueItems[finishedIndex].downloadedBytes = FileStore.fileSize(for: item)
                    queueItems[finishedIndex].totalBytes = queueItems[finishedIndex].downloadedBytes
                    queueItems[finishedIndex].speedBytesPerSecond = nil
                    queueItems[finishedIndex].remainingSeconds = nil
                    speedSamples[id] = nil
                    completedMessage = localized("Downloaded “\(snapshot.info.title)”.", "Đã tải “\(snapshot.info.title)”."); Haptics.success()
                    logger.info("completed source=\(snapshot.info.id, privacy: .public)")
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            guard let failedIndex = queueItems.firstIndex(where: { $0.id == id }), queueItems[failedIndex].state != .cancelled else { return }
            if let apiError = error as? APIError, apiError.statusCode == 404, queueItems[failedIndex].backendJobID != nil {
                queueItems[failedIndex].backendJobID = nil
                queueItems[failedIndex].state = .queued
                queueItems[failedIndex].error = localized("Server restarted; recreating download job…", "Máy chủ vừa khởi động lại; đang tạo lại tác vụ tải…")
                logger.warning("recovering missing backend job source=\(self.queueItems[failedIndex].info.id, privacy: .public)")
                return
            }
            if isTransient(error), queueItems[failedIndex].retryCount < 5 {
                queueItems[failedIndex].retryCount += 1
                queueItems[failedIndex].state = .queued
                queueItems[failedIndex].error = localized("Network interrupted. Retrying automatically…", "Mạng bị gián đoạn. Đang tự động thử lại…")
                logger.warning("transient failure source=\(self.queueItems[failedIndex].info.id, privacy: .public) retry=\(self.queueItems[failedIndex].retryCount)")
                try? await Task.sleep(for: .seconds(10))
                return
            }
            queueItems[failedIndex].state = .failed; queueItems[failedIndex].error = error.localizedDescription
            queueItems[failedIndex].speedBytesPerSecond = nil; errorMessage = error.localizedDescription
            queueItems[failedIndex].remainingSeconds = nil; speedSamples[id] = nil
            logger.error("failed source=\(self.queueItems[failedIndex].info.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func localized(_ english: String, _ vietnamese: String) -> String {
        UserDefaults.standard.string(forKey: "appLanguage") == AppLanguage.vietnamese.rawValue ? vietnamese : english
    }

    private func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let apiError = error as? APIError, case .network = apiError { return true }
        if let code = (error as? APIError)?.statusCode { return [408, 429, 500, 502, 503, 504].contains(code) }
        return false
    }

    func estimatedSize(for info: MediaInfo) -> Int64? {
        info.estimatedSizes?["\(mediaKind.rawValue):\(quality)"]
    }

    func variantExists(in items: [MediaItem], info: MediaInfo) -> Bool {
        items.contains { $0.sourceID == info.id && $0.mediaType == mediaKind.rawValue && $0.quality == quality }
    }

    func hasOtherVariant(in items: [MediaItem], info: MediaInfo) -> Bool {
        items.contains { $0.sourceID == info.id && ($0.mediaType != mediaKind.rawValue || $0.quality != quality) }
    }

    private func updateETA(at index: Int, id: UUID) {
        guard let speed = queueItems[index].speedBytesPerSecond, speed > 0,
              let total = queueItems[index].totalBytes, total > queueItems[index].downloadedBytes else {
            queueItems[index].remainingSeconds = nil; return
        }
        var samples = speedSamples[id] ?? []
        samples.append(speed)
        samples = Array(samples.suffix(5))
        speedSamples[id] = samples
        guard samples.count >= 3 else { queueItems[index].remainingSeconds = nil; return }
        let average = samples.reduce(0, +) / Double(samples.count)
        let maxDeviation = samples.map { abs($0 - average) / average }.max() ?? 1
        queueItems[index].remainingSeconds = maxDeviation <= 0.35
            ? Double(total - queueItems[index].downloadedBytes) / average : nil
    }

    private var queueFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineTube", isDirectory: true)
            .appendingPathComponent("download-queue.json")
    }

    private func persistQueue() {
        let url = queueFileURL
        let snapshot = queueItems
        Task { await QueuePersistence.shared.save(snapshot, to: url) }
    }
}

private actor QueuePersistence {
    static let shared = QueuePersistence()
    func save(_ queue: [DownloadQueueItem], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(queue).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch { Logger(subsystem: "com.personal.OfflineTube", category: "Downloads").error("queue persistence failed=\(error.localizedDescription, privacy: .public)") }
    }
}
