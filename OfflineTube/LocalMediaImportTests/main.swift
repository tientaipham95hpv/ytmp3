import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

for ext in ["mp3", "m4a", "aac", "wav"] {
    expect(LocalMediaImportPolicy.mediaType(forExtension: ext) == "audio", "\(ext) should be audio")
}
for ext in ["mp4", "mov"] {
    expect(LocalMediaImportPolicy.mediaType(forExtension: ext.uppercased()) == "video", "\(ext) should be video and case-insensitive")
}
expect(LocalMediaImportPolicy.mediaType(forExtension: "pdf") == nil, "Unsupported files must be rejected")
expect(LocalMediaImportPolicy.allowedExtensions.count == 6, "The allowlist changed unexpectedly")
print("Local media import policy tests passed")
