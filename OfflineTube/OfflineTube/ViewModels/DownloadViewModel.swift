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
    @Published private(set) var queueItems: [DownloadQueueItem] = [] {
        didSet { persistQueue() }
    }

    let audioQualities = [("original", "Original/M4A"), ("128", "MP3 128"), ("192", "MP3 192"), ("320", "MP3 320")]
    let videoQualities = [("360", "360p"), ("480", "480p"), ("720", "720p"), ("1080", "1080p"), ("best", "Best")]
    private var workerTasks: [UUID: Task<Void, Never>] = [:]
    private let maximumConcurrentDownloads = 2
    private var modelContext: ModelContext?
    private let logger = Logger(subsystem: "com.personal.OfflineTube", category: "Downloads")

    init() {
        quality = UserDefaults.standard.string(forKey: "defaultAudioQuality") ?? "original"
        if let data = try? Data(contentsOf: queueFileURL),
           var saved = try? JSONDecoder().decode([DownloadQueueItem].self, from: data) {
            for index in saved.indices where saved[index].state == .downloading || saved[index].state == .saving {
                saved[index].state = .queued
            }
            queueItems = saved
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

    func startDownload(modelContext: ModelContext) {
        guard let info = mediaInfo else { return }
        self.modelContext = modelContext
        do {
            try FileStore.ensureCapacity()
            let sourceID = info.id
            let existing = try modelContext.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.sourceID == sourceID }))
            guard existing.isEmpty, !queueItems.contains(where: { $0.info.id == sourceID && $0.state != .failed && $0.state != .cancelled }) else {
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
        var retry = DownloadQueueItem(id: UUID(), url: item.url, info: item.info, mediaType: item.mediaType, quality: item.quality)
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
                progress = queueItems[updateIndex].progress
                statusText = job.status == "queued" ? localized("Queued…", "Đang chờ…") : localized("Downloading \(Int(job.progress))%", "Đang tải \(Int(job.progress))%")
                if job.status == "cancelled" { queueItems[updateIndex].state = .cancelled; return }
                if job.status == "failed" { throw APIError.server(job.error ?? "Tải media thất bại.") }
                if job.status == "completed" {
                    guard let fileID = job.fileID, let filename = job.filename else { throw APIError.missingResult }
                    queueItems[updateIndex].state = .saving; statusText = localized("Saving to device…", "Đang lưu vào thiết bị…")
                    try FileStore.ensureCapacity(requiredBytes: job.totalBytes)
                    let localURL = try await APIClient.shared.download(fileID: fileID, filename: filename)
                    let item = MediaItem(sourceID: snapshot.info.id, sourceURL: snapshot.info.webpageURL, title: snapshot.info.title, channel: snapshot.info.channel, thumbnailURL: snapshot.info.thumbnail, duration: snapshot.info.duration, localFilename: localURL.lastPathComponent, mediaType: snapshot.mediaType, quality: snapshot.quality)
                    modelContext.insert(item); try modelContext.save()
                    guard let finishedIndex = queueItems.firstIndex(where: { $0.id == id }) else { return }
                    queueItems[finishedIndex].state = .completed; queueItems[finishedIndex].progress = 1
                    queueItems[finishedIndex].downloadedBytes = FileStore.fileSize(for: item)
                    queueItems[finishedIndex].totalBytes = queueItems[finishedIndex].downloadedBytes
                    queueItems[finishedIndex].speedBytesPerSecond = nil
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
                logger.warning("recovering missing backend job source=\(queueItems[failedIndex].info.id, privacy: .public)")
                return
            }
            if isTransient(error), queueItems[failedIndex].retryCount < 5 {
                queueItems[failedIndex].retryCount += 1
                queueItems[failedIndex].state = .queued
                queueItems[failedIndex].error = localized("Network interrupted. Retrying automatically…", "Mạng bị gián đoạn. Đang tự động thử lại…")
                logger.warning("transient failure source=\(queueItems[failedIndex].info.id, privacy: .public) retry=\(queueItems[failedIndex].retryCount)")
                try? await Task.sleep(for: .seconds(10))
                return
            }
            queueItems[failedIndex].state = .failed; queueItems[failedIndex].error = error.localizedDescription
            queueItems[failedIndex].speedBytesPerSecond = nil; errorMessage = error.localizedDescription
            logger.error("failed source=\(queueItems[failedIndex].info.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
