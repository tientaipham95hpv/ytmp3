import Foundation

struct SmokeManifest: Codable {
    let version: Int
    let title: String
    let mediaFile: String
}

let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent("BackupSmoke-\(UUID().uuidString)")
let source = root.appendingPathComponent("source", isDirectory: true)
let package = root.appendingPathComponent("backup.offlinetubebackup", isDirectory: true)
let restored = root.appendingPathComponent("restored", isDirectory: true)
defer { try? manager.removeItem(at: root) }

try manager.createDirectory(at: source, withIntermediateDirectories: true)
try manager.createDirectory(at: package.appendingPathComponent("Media"), withIntermediateDirectories: true)
let payload = Data("offline-media-payload".utf8)
try payload.write(to: source.appendingPathComponent("track.m4a"))
try manager.copyItem(at: source.appendingPathComponent("track.m4a"), to: package.appendingPathComponent("Media/track.m4a"))
let manifest = SmokeManifest(version: 1, title: "Restored Track", mediaFile: "track.m4a")
try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))

try manager.removeItem(at: source)
let decoded = try JSONDecoder().decode(SmokeManifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
precondition(decoded.version == 1)
precondition(URL(fileURLWithPath: decoded.mediaFile).lastPathComponent == decoded.mediaFile)
try manager.createDirectory(at: restored, withIntermediateDirectories: true)
try manager.copyItem(at: package.appendingPathComponent("Media").appendingPathComponent(decoded.mediaFile),
                     to: restored.appendingPathComponent(decoded.mediaFile))
let restoredPayload = try Data(contentsOf: restored.appendingPathComponent(decoded.mediaFile))
precondition(restoredPayload == payload)
print("Backup smoke test: export -> delete -> validate -> restore passed")
