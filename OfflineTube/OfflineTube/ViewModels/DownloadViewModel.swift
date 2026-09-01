import Combine
import Foundation
import SwiftData

@MainActor
final class DownloadViewModel: ObservableObject {
    enum MediaKind: String, CaseIterable, Identifiable {
        case audio, video
        var id: String { rawValue }
        var title: String { self == .audio ? "Audio" : "Video" }
    }

    @Published var urlText = ""
    @Published var mediaInfo: MediaInfo?
    @Published var mediaKind: MediaKind = .audio {
        didSet { quality = mediaKind == .audio ? "original" : "720" }
    }
    @Published var quality = "original"
    @Published var isLoadingInfo = false
    @Published var isDownloading = false
    @Published var progress = 0.0
    @Published var statusText = ""
    @Published var errorMessage: String?
    @Published var completedMessage: String?

    let audioQualities = [("original", "Original/M4A"), ("128", "MP3 128"), ("192", "MP3 192"), ("320", "MP3 320")]
    let videoQualities = [("360", "360p"), ("480", "480p"), ("720", "720p"), ("1080", "1080p"), ("best", "Best")]

    func fetchInfo() async {
        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            errorMessage = "Hãy dán link YouTube."
            return
        }
        isLoadingInfo = true
        errorMessage = nil
        completedMessage = nil
        defer { isLoadingInfo = false }
        do {
            mediaInfo = try await APIClient.shared.mediaInfo(url: value)
        } catch {
            mediaInfo = nil
            errorMessage = error.localizedDescription
        }
    }

    func download(modelContext: ModelContext) async {
        guard let info = mediaInfo else { return }
        isDownloading = true
        progress = 0
        errorMessage = nil
        completedMessage = nil
        statusText = "Đang tạo job…"
        defer { isDownloading = false }

        do {
            let created = try await APIClient.shared.createDownload(url: urlText, mediaType: mediaKind.rawValue, quality: quality)
            while true {
                try Task.checkCancellation()
                let job = try await APIClient.shared.job(id: created.id)
                progress = min(1, max(0, job.progress / 100))
                statusText = job.status == "queued" ? "Đang chờ…" : "Đang xử lý \(Int(job.progress))%"
                if job.status == "failed" {
                    throw APIError.server(job.error ?? "Tải media thất bại.")
                }
                if job.status == "completed" {
                    guard let fileID = job.fileID, let filename = job.filename else { throw APIError.missingResult }
                    statusText = "Đang lưu vào thiết bị…"
                    let localURL = try await APIClient.shared.download(fileID: fileID, filename: filename)
                    let item = MediaItem(
                        sourceID: info.id,
                        sourceURL: info.webpageURL,
                        title: info.title,
                        channel: info.channel,
                        thumbnailURL: info.thumbnail,
                        duration: info.duration,
                        localFilename: localURL.lastPathComponent,
                        mediaType: mediaKind.rawValue,
                        quality: quality
                    )
                    modelContext.insert(item)
                    try modelContext.save()
                    progress = 1
                    statusText = "Hoàn tất"
                    completedMessage = "Đã lưu “\(info.title)” vào Library."
                    return
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch is CancellationError {
            statusText = "Đã hủy"
        } catch {
            errorMessage = error.localizedDescription
            statusText = ""
        }
    }
}
