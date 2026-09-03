import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct ImportedMedia: Sendable {
    let sourceID: String
    let sourceURL: String
    let title: String
    let artist: String
    let duration: Double
    let localFilename: String
    let mediaType: String
    let quality: String
    let fileSize: Int64
    let artworkFilename: String?
}

enum LocalMediaImportError: LocalizedError {
    case unsupportedFile(String)
    case notAFile(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name): "Unsupported media format: \(name)"
        case .notAFile(let name): "The selected item is not a readable file: \(name)"
        }
    }
}

enum LocalMediaImporter {
    static let allowedTypes: [UTType] = [.mp3, .mpeg4Audio, .audio, .mpeg4Movie, .quickTimeMovie]

    static func importFile(from source: URL) async throws -> ImportedMedia {
        try await Task.detached(priority: .userInitiated) {
            let ext = source.pathExtension.lowercased()
            guard let mediaType = LocalMediaImportPolicy.mediaType(forExtension: ext) else {
                throw LocalMediaImportError.unsupportedFile(source.lastPathComponent)
            }
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }

            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw LocalMediaImportError.notAFile(source.lastPathComponent) }
            try FileStore.ensureCapacity(requiredBytes: Int64(values.fileSize ?? 0))
            let destination = FileStore.destination(filename: source.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                let asset = AVURLAsset(url: destination)
                let durationValue = try? await asset.load(.duration)
                let duration = durationValue.flatMap { $0.isNumeric ? CMTimeGetSeconds($0) : nil } ?? 0
                let metadata = (try? await asset.load(.commonMetadata)) ?? []
                let title = await stringValue(for: .commonKeyTitle, in: metadata)
                let metadataArtist = await stringValue(for: .commonKeyArtist, in: metadata)
                let metadataAuthor = await stringValue(for: .commonKeyAuthor, in: metadata)
                let artist = metadataArtist ?? metadataAuthor
                let artworkData = await dataValue(for: .commonKeyArtwork, in: metadata)
                let sourceID = "local-\(UUID().uuidString)"
                let artworkFilename = try saveArtwork(artworkData, sourceID: sourceID)
                let copiedSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                return ImportedMedia(
                    sourceID: sourceID,
                    sourceURL: "local://\(sourceID)",
                    title: title?.nilIfBlank ?? source.deletingPathExtension().lastPathComponent,
                    artist: artist?.nilIfBlank ?? "Unknown Artist",
                    duration: duration.isFinite ? max(0, duration) : 0,
                    localFilename: destination.lastPathComponent,
                    mediaType: mediaType,
                    quality: "Imported • \(ext.uppercased())",
                    fileSize: copiedSize,
                    artworkFilename: artworkFilename
                )
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }.value
    }

    private static func stringValue(for key: AVMetadataKey, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = metadata.first(where: { $0.commonKey == key }) else { return nil }
        return try? await item.load(.stringValue)
    }

    private static func dataValue(for key: AVMetadataKey, in metadata: [AVMetadataItem]) async -> Data? {
        guard let item = metadata.first(where: { $0.commonKey == key }) else { return nil }
        return try? await item.load(.dataValue)
    }

    private static func saveArtwork(_ data: Data?, sourceID: String) throws -> String? {
        guard let data, !data.isEmpty, data.count <= 20 * 1024 * 1024 else { return nil }
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF])
        guard isPNG || isJPEG else { return nil }
        let filename = "\(sourceID)-embedded.\(isPNG ? "png" : "jpg")"
        try data.write(to: FileStore.artworkDirectory.appendingPathComponent(filename), options: [.atomic, .completeFileProtectionUnlessOpen])
        return filename
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
