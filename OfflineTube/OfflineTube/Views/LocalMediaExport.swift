import SwiftUI
import UIKit

enum LocalMediaExportFile {
    case media
    case artwork
}

struct LocalMediaExportRequest: Identifiable {
    let id = UUID()
    let url: URL
}

enum LocalMediaExportError: LocalizedError {
    case mediaFileMissing(String)
    case artworkUnavailable
    case artworkFileMissing(String)

    var errorDescription: String? {
        switch self {
        case .mediaFileMissing(let filename):
            "The local media file “\(filename)” could not be found. It may have been removed from this device."
        case .artworkUnavailable:
            "This item does not have local artwork to export."
        case .artworkFileMissing(let filename):
            "The local artwork file “\(filename)” could not be found. It may have been removed from this device."
        }
    }
}

enum LocalMediaExport {
    static func request(for item: MediaItem, file: LocalMediaExportFile) throws -> LocalMediaExportRequest {
        let url: URL

        switch file {
        case .media:
            url = item.localURL
            guard isReadableFile(url) else {
                throw LocalMediaExportError.mediaFileMissing(url.lastPathComponent)
            }
        case .artwork:
            guard let artworkURL = item.artworkURL else {
                throw LocalMediaExportError.artworkUnavailable
            }
            url = artworkURL
            guard isReadableFile(url) else {
                throw LocalMediaExportError.artworkFileMissing(url.lastPathComponent)
            }
        }

        return LocalMediaExportRequest(url: url)
    }

    private static func isReadableFile(_ url: URL) -> Bool {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else {
            return false
        }
        return FileManager.default.isReadableFile(atPath: url.path)
    }
}

struct LocalFileShareSheet: UIViewControllerRepresentable {
    let request: LocalMediaExportRequest
    let onComplete: (Result<Void, Error>) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [request.url],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, error in
            if let error {
                onComplete(.failure(error))
            } else {
                onComplete(.success(()))
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct LocalFileDocumentExporter: UIViewControllerRepresentable {
    let request: LocalMediaExportRequest
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forExporting: [request.url],
            asCopy: true
        )
        controller.delegate = context.coordinator
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onComplete: () -> Void

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onComplete()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete()
        }
    }
}
