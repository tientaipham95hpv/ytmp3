import Foundation

func expect(_ expected: DownloadWaitReason?, _ conditions: DownloadScheduleConditions, now: Date = Date(), calendar: Calendar = .current) {
    precondition(DownloadSchedulerPolicy.waitReason(conditions, now: now, calendar: calendar) == expected, "Expected \(String(describing: expected))")
}

let future = Date().addingTimeInterval(3600)
expect(.network, .init(isConnected: false, isWiFi: false, isCharging: false, wifiOnly: false, chargingOnly: false, scheduledAt: nil, pauseOnCellular: false, preferredWindow: nil, ignoresPreferredWindow: false))
expect(.wifi, .init(isConnected: true, isWiFi: false, isCharging: true, wifiOnly: true, chargingOnly: false, scheduledAt: nil, pauseOnCellular: false, preferredWindow: nil, ignoresPreferredWindow: false))
expect(.charging, .init(isConnected: true, isWiFi: true, isCharging: false, wifiOnly: true, chargingOnly: true, scheduledAt: nil, pauseOnCellular: false, preferredWindow: nil, ignoresPreferredWindow: false))
expect(.scheduled(future), .init(isConnected: true, isWiFi: true, isCharging: true, wifiOnly: false, chargingOnly: false, scheduledAt: future, pauseOnCellular: false, preferredWindow: nil, ignoresPreferredWindow: false))

var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
let noon = Date(timeIntervalSince1970: 43_200)
expect(.preferredHours, .init(isConnected: true, isWiFi: true, isCharging: true, wifiOnly: false, chargingOnly: false, scheduledAt: nil, pauseOnCellular: false, preferredWindow: (22, 7), ignoresPreferredWindow: false), now: noon, calendar: utc)
expect(nil, .init(isConnected: true, isWiFi: true, isCharging: true, wifiOnly: false, chargingOnly: false, scheduledAt: nil, pauseOnCellular: false, preferredWindow: (22, 7), ignoresPreferredWindow: true), now: noon, calendar: utc)
print("Download scheduler tests passed")
