import SwiftData
import SwiftUI

struct DuplicatesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var player: PlayerManager
    @Query private var items: [MediaItem]
    @Query private var playlists: [MediaPlaylist]
    @State private var groups: [[MediaItem]] = []
    @State private var keepByGroup: [String: UUID] = [:]
    @State private var scanning = true
    @State private var pendingGroup: [MediaItem]?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if scanning { ProgressView("Comparing metadata and file hashes…") }
                else if groups.isEmpty {
                    ContentUnavailableView("No Duplicates Found", systemImage: "checkmark.circle", description: Text("Your local Library has no likely duplicate media."))
                } else {
                    List {
                        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                            let key = groupKey(group)
                            Section {
                                Picker("Keep", selection: keepBinding(key: key, group: group)) {
                                    ForEach(group) { item in
                                        Text("\(item.quality) • \(size(item).formattedBytes) • \(item.createdAt.formatted(date: .abbreviated, time: .omitted))").tag(item.id)
                                    }
                                }
                                ForEach(group) { item in
                                    duplicateRow(item, isKept: keepByGroup[key] == item.id)
                                }
                                Button(role: .destructive) { pendingGroup = group } label: {
                                    Label("Delete Other Copies", systemImage: "trash")
                                }
                            } header: {
                                Text("Group \(index + 1) • \(group.count) copies")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Find Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { Task { await scan() } } label: { Image(systemName: "arrow.clockwise") }.disabled(scanning) }
            }
        }
        .task { await scan() }
        .confirmationDialog("Delete duplicate files?", isPresented: Binding(get: { pendingGroup != nil }, set: { if !$0 { pendingGroup = nil } }), titleVisibility: .visible) {
            Button("Delete Other Copies", role: .destructive) { deletePendingGroup() }
            Button("Cancel", role: .cancel) { pendingGroup = nil }
        } message: {
            if let group = pendingGroup {
                let keep = keepByGroup[groupKey(group)] ?? group[0].id
                let bytes = group.filter { $0.id != keep }.reduce(Int64(0)) { $0 + size($1) }
                Text("The selected copy stays. \(group.count - 1) local file(s) will be removed, freeing about \(bytes.formattedBytes). This cannot be undone.")
            }
        }
        .alert("Couldn’t remove all duplicates", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func duplicateRow(_ item: MediaItem, isKept: Bool) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.thumbnailURL, localURL: item.artworkURL, isVideo: item.isVideo, cornerRadius: 8).frame(width: 64, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(item.channel) • \(item.duration.mediaTime)").font(.caption).foregroundStyle(.secondary)
                Text("\(item.quality) • \(size(item).formattedBytes) • \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if isKept { Label("Keep", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green) }
        }
    }

    private func scan() async {
        scanning = true
        let available = items.filter(\.isAvailableOffline)
        var hashes: [UUID: String] = [:]
        let sizeBuckets = Dictionary(grouping: available, by: size).values.filter { $0.count > 1 }
        for bucket in sizeBuckets {
            for item in bucket { hashes[item.id] = await MediaFileHasher.sha256(url: item.localURL) }
        }
        let descriptors = available.map { $0.duplicateDescriptor(hash: hashes[$0.id]) }
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        groups = DuplicateDetector.groups(descriptors).map { $0.compactMap { byID[$0.id] } }.filter { $0.count > 1 }
        keepByGroup = Dictionary(uniqueKeysWithValues: groups.map { group in
            (groupKey(group), group.max(by: { preferredScore($0) < preferredScore($1) })!.id)
        })
        scanning = false
    }

    private func deletePendingGroup() {
        guard let group = pendingGroup else { return }
        let keepID = keepByGroup[groupKey(group)] ?? group[0].id
        guard let keep = group.first(where: { $0.id == keepID }) else { return }
        let duplicates = group.filter { $0.id != keepID }
        var failures: [String] = []
        let duplicateIDs = Set(duplicates.map(\.id))
        keep.isFavorite = keep.isFavorite || duplicates.contains(where: \.isFavorite)
        keep.playCount = max(keep.playCount, duplicates.map(\.playCount).max() ?? 0)
        keep.lastPlayedAt = ([keep.lastPlayedAt] + duplicates.map(\.lastPlayedAt)).compactMap { $0 }.max()
        CloudSyncService.markChanged(keep)
        for playlist in playlists where playlist.itemIDs.contains(where: duplicateIDs.contains) {
            playlist.itemIDs = replacing(duplicateIDs, with: keepID, in: playlist.itemIDs)
            playlist.updatedAt = Date()
        }
        for duplicate in duplicates {
            do {
                player.stopIfPlaying(duplicate)
                try FileStore.remove(duplicate)
                modelContext.delete(duplicate)
            } catch { failures.append(duplicate.title) }
        }
        do { try modelContext.save() } catch { failures.append(error.localizedDescription) }
        pendingGroup = nil
        if failures.isEmpty { Haptics.success(); Task { await scan() } }
        else { errorMessage = "Kept files that could not be removed: \(failures.joined(separator: ", "))"; Task { await scan() } }
    }

    private func keepBinding(key: String, group: [MediaItem]) -> Binding<UUID> {
        Binding(get: { keepByGroup[key] ?? group[0].id }, set: { keepByGroup[key] = $0 })
    }

    private func groupKey(_ group: [MediaItem]) -> String { group.map { $0.id.uuidString }.sorted().joined(separator: ":") }
    private func size(_ item: MediaItem) -> Int64 { item.fileSize > 0 ? item.fileSize : FileStore.fileSize(for: item) }
    private func preferredScore(_ item: MediaItem) -> Int64 { size(item) + (Int64(item.quality.filter(\.isNumber)) ?? 0) * 1_000_000 }

    private func replacing(_ oldIDs: Set<UUID>, with keepID: UUID, in values: [UUID]) -> [UUID] {
        var output: [UUID] = []
        for value in values {
            let candidate = oldIDs.contains(value) ? keepID : value
            if !output.contains(candidate) { output.append(candidate) }
        }
        return output
    }
}
