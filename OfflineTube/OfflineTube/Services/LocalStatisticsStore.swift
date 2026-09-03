import Foundation

struct StatisticsMediaRecord: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var channel: String
    var isVideo: Bool
    var playCount = 0
    var completionCount = 0
    var skipCount = 0
    var activeSeconds: Double = 0
    var lastPlayedAt: Date?
}

struct StatisticsDayRecord: Codable, Identifiable, Sendable {
    var id: String
    var audioSeconds: Double = 0
    var videoSeconds: Double = 0
    var totalSeconds: Double { audioSeconds + videoSeconds }
}

struct StatisticsSnapshot: Codable, Sendable {
    var media: [String: StatisticsMediaRecord] = [:]
    var days: [String: StatisticsDayRecord] = [:]

    var totalListeningSeconds: Double { media.values.filter { !$0.isVideo }.reduce(0) { $0 + $1.activeSeconds } }
    var totalWatchSeconds: Double { media.values.filter(\.isVideo).reduce(0) { $0 + $1.activeSeconds } }
    var playCount: Int { media.values.reduce(0) { $0 + $1.playCount } }
    var completionCount: Int { media.values.reduce(0) { $0 + $1.completionCount } }
    var skipCount: Int { media.values.reduce(0) { $0 + $1.skipCount } }

    func streak(referenceDate: Date = Date(), calendar: Calendar = .current) -> Int {
        let activeDays = Set(days.values.filter { $0.totalSeconds >= 60 }.map(\.id))
        var cursor = calendar.startOfDay(for: referenceDate)
        if !activeDays.contains(Self.dayKey(cursor, calendar: calendar)),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) { cursor = yesterday }
        var count = 0
        while activeDays.contains(Self.dayKey(cursor, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

actor LocalStatisticsStore {
    static let shared = LocalStatisticsStore()
    private var snapshot: StatisticsSnapshot
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let resolvedURL = fileURL ?? directory.appendingPathComponent("OfflineTube/statistics-v1.json")
        self.fileURL = resolvedURL
        if let data = try? Data(contentsOf: resolvedURL), let decoded = try? JSONDecoder().decode(StatisticsSnapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = StatisticsSnapshot()
        }
    }

    func current() -> StatisticsSnapshot { snapshot }

    func recordStarted(id: String, title: String, channel: String, isVideo: Bool, at date: Date = Date()) {
        updateMedia(id: id, title: title, channel: channel, isVideo: isVideo) {
            $0.playCount += 1
            $0.lastPlayedAt = date
        }
        persist()
    }

    func recordActiveTime(id: String, title: String, channel: String, isVideo: Bool, seconds: Double, at date: Date = Date()) {
        guard seconds > 0, seconds.isFinite else { return }
        updateMedia(id: id, title: title, channel: channel, isVideo: isVideo) { $0.activeSeconds += seconds }
        let key = StatisticsSnapshot.dayKey(date)
        var day = snapshot.days[key] ?? StatisticsDayRecord(id: key)
        if isVideo { day.videoSeconds += seconds } else { day.audioSeconds += seconds }
        snapshot.days[key] = day
        persist()
    }

    func recordCompleted(id: String, title: String, channel: String, isVideo: Bool) {
        updateMedia(id: id, title: title, channel: channel, isVideo: isVideo) { $0.completionCount += 1 }
        persist()
    }

    func recordSkipped(id: String, title: String, channel: String, isVideo: Bool) {
        updateMedia(id: id, title: title, channel: channel, isVideo: isVideo) { $0.skipCount += 1 }
        persist()
    }

    private func updateMedia(id: String, title: String, channel: String, isVideo: Bool, mutation: (inout StatisticsMediaRecord) -> Void) {
        var record = snapshot.media[id] ?? StatisticsMediaRecord(id: id, title: title, channel: channel, isVideo: isVideo)
        record.title = title
        record.channel = channel
        record.isVideo = isVideo
        mutation(&record)
        snapshot.media[id] = record
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Analytics must never interrupt playback.
        }
    }
}
