import Charts
import SwiftData
import SwiftUI

struct StatisticsView: View {
    enum Range: String, CaseIterable, Identifiable { case week = "Week", month = "Month"; var id: String { rawValue } }

    @Query private var items: [MediaItem]
    @State private var snapshot = StatisticsSnapshot()
    @State private var range: Range = .week

    private var topMedia: [StatisticsMediaRecord] {
        snapshot.media.values.sorted {
            if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
            return $0.activeSeconds > $1.activeSeconds
        }.prefix(10).map { $0 }
    }

    private var topChannels: [(name: String, plays: Int, seconds: Double)] {
        let grouped = Dictionary(grouping: snapshot.media.values, by: { $0.channel.isEmpty ? "Unknown" : $0.channel })
        return grouped.map { name, records in
            (name, records.reduce(0) { $0 + $1.playCount }, records.reduce(0) { $0 + $1.activeSeconds })
        }.sorted { $0.plays == $1.plays ? $0.seconds > $1.seconds : $0.plays > $1.plays }.prefix(10).map { $0 }
    }

    private var chartDays: [StatisticsDayRecord] {
        let limit = range == .week ? 7 : 30
        let calendar = Calendar.current
        return (0..<limit).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let key = StatisticsSnapshot.dayKey(date, calendar: calendar)
            return snapshot.days[key] ?? StatisticsDayRecord(id: key)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                overview
                activityChart
                rankedMedia
                rankedChannels
                recent
            }.padding(16)
        }
        .navigationTitle("Statistics")
        .task { snapshot = await LocalStatisticsStore.shared.current() }
        .refreshable { snapshot = await LocalStatisticsStore.shared.current() }
    }

    private var overview: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metric("Listening", value: snapshot.totalListeningSeconds.statisticsDuration, icon: "headphones")
            metric("Watching", value: snapshot.totalWatchSeconds.statisticsDuration, icon: "play.rectangle")
            metric("Plays", value: "\(snapshot.playCount)", icon: "play.fill")
            metric("Completed", value: "\(snapshot.completionCount)", icon: "checkmark.circle")
            metric("Skipped", value: "\(snapshot.skipCount)", icon: "forward.end")
            metric("Streak", value: "\(snapshot.streak()) days", icon: "flame.fill")
            metric("Downloads", value: "\(items.count)", icon: "arrow.down.circle")
            metric("Storage", value: items.reduce(Int64(0)) { $0 + ($1.fileSize > 0 ? $1.fileSize : FileStore.fileSize(for: $1)) }.formattedBytes, icon: "internaldrive")
        }
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.tint)
            Text(value).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var activityChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity").font(.title3.bold())
                Spacer()
                Picker("Range", selection: $range) { ForEach(Range.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 150)
            }
            Chart(chartDays) { day in
                BarMark(x: .value("Day", day.id), y: .value("Minutes", day.audioSeconds / 60))
                    .foregroundStyle(by: .value("Type", "Audio"))
                BarMark(x: .value("Day", day.id), y: .value("Minutes", day.videoSeconds / 60))
                    .foregroundStyle(by: .value("Type", "Video"))
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: range == .week ? 7 : 6)) }
            .frame(height: 220)
        }
    }

    private var rankedMedia: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top 10 Media").font(.title3.bold())
            if topMedia.isEmpty { Text("Play something to build your statistics.").foregroundStyle(.secondary) }
            ForEach(Array(topMedia.enumerated()), id: \.element.id) { index, media in
                HStack {
                    Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading) { Text(media.title).lineLimit(1); Text(media.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Text("\(media.playCount) plays").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.vertical, 3)
            }
        }
    }

    private var rankedChannels: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Channels / Artists").font(.title3.bold())
            ForEach(Array(topChannels.enumerated()), id: \.element.name) { index, channel in
                HStack { Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 24); Text(channel.name).lineLimit(1); Spacer(); Text("\(channel.plays)").font(.caption.monospacedDigit()) }
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recently Played").font(.title3.bold())
            ForEach(snapshot.media.values.filter { $0.lastPlayedAt != nil }.sorted { $0.lastPlayedAt! > $1.lastPlayedAt! }.prefix(10).map { $0 }) { media in
                HStack { VStack(alignment: .leading) { Text(media.title).lineLimit(1); Text(media.channel).font(.caption).foregroundStyle(.secondary) }; Spacer(); if let date = media.lastPlayedAt { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) } }
            }
        }
    }
}

private extension Double {
    var statisticsDuration: String {
        let totalMinutes = Int(self / 60)
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }
}
