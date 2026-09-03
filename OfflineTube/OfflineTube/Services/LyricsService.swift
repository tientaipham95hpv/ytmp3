import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

enum LRCParser {
    private static let expression = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#)

    static func parse(_ value: String) -> [LyricLine] {
        var parsed: [(Double, String)] = []
        for rawLine in value.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..., in: rawLine)
            let matches = expression.matches(in: rawLine, range: range)
            guard !matches.isEmpty else { continue }
            let textStart = matches.last!.range.location + matches.last!.range.length
            let text = String(rawLine[String.Index(utf16Offset: textStart, in: rawLine)...]).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: rawLine), let secondRange = Range(match.range(at: 2), in: rawLine) else { continue }
                let minutes = Double(rawLine[minuteRange]) ?? 0
                let seconds = Double(rawLine[secondRange]) ?? 0
                var fraction = 0.0
                if let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let digits = String(rawLine[fractionRange])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                parsed.append((minutes * 60 + seconds + fraction, text))
            }
        }
        return parsed.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    static func isTimed(_ value: String) -> Bool { !parse(value).isEmpty }
}

actor LyricsService {
    static let shared = LyricsService()

    func fetch(title: String, channel: String, duration: Double) async throws -> String {
        let configured = UserDefaults.standard.string(forKey: "lyricsProviderURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configured.isEmpty {
            let result = try await APIClient.shared.lyrics(title: title, artist: channel, duration: duration)
            if let lyrics = result.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !lyrics.isEmpty { return lyrics }
            if let lyrics = result.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !lyrics.isEmpty { return lyrics }
            throw APIError.server("Không tìm thấy lời cho bài hát này.")
        }
        guard var components = URLComponents(string: configured) else { throw APIError.invalidServerURL }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "title", value: title))
        query.append(URLQueryItem(name: "artist", value: channel))
        components.queryItems = query
        guard let url = components.url else { throw APIError.invalidServerURL }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        if let key = KeychainStore.lyricsAPIKey(), !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw APIError.server("Lyrics provider returned an error.") }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lyrics = (object["syncedLyrics"] ?? object["lrc"] ?? object["plainLyrics"] ?? object["lyrics"]) as? String,
           !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return lyrics }
        if let plain = String(data: data, encoding: .utf8), !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return plain }
        throw APIError.missingResult
    }
}
