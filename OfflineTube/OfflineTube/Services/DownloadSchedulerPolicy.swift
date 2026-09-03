import Foundation

struct DownloadScheduleConditions: Sendable {
    let isConnected: Bool
    let isWiFi: Bool
    let isCharging: Bool
    let wifiOnly: Bool
    let chargingOnly: Bool
    let scheduledAt: Date?
    let pauseOnCellular: Bool
    let preferredWindow: (start: Int, end: Int)?
    let ignoresPreferredWindow: Bool
}

enum DownloadWaitReason: Equatable, Sendable {
    case network, wifi, charging, scheduled(Date), preferredHours
}

enum DownloadSchedulerPolicy {
    static func waitReason(_ conditions: DownloadScheduleConditions, now: Date = Date(), calendar: Calendar = .current) -> DownloadWaitReason? {
        if !conditions.isConnected { return .network }
        if (conditions.wifiOnly || conditions.pauseOnCellular) && !conditions.isWiFi { return .wifi }
        if conditions.chargingOnly && !conditions.isCharging { return .charging }
        if let scheduledAt = conditions.scheduledAt, scheduledAt > now { return .scheduled(scheduledAt) }
        if !conditions.ignoresPreferredWindow, let window = conditions.preferredWindow {
            let hour = calendar.component(.hour, from: now)
            let inside = window.start <= window.end
                ? (hour >= window.start && hour < window.end)
                : (hour >= window.start || hour < window.end)
            if !inside { return .preferredHours }
        }
        return nil
    }
}
