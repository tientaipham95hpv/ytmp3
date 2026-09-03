import Foundation
import OSLog

struct MediaInfo: Codable, Sendable {
    let id: String
    let title: String
    let thumbnail: String?
    let channel: String
    let duration: Double
    let webpageURL: String
    let estimatedSizes: [String: Int64]?

    enum CodingKeys: String, CodingKey {
        case id, title, thumbnail, channel, duration
        case webpageURL = "webpage_url"
        case estimatedSizes = "estimated_sizes"
    }
}

struct PlaylistInfo: Codable, Sendable {
    let id: String
    let title: String
    let channel: String
    let thumbnail: String?
    let entries: [MediaInfo]
    let totalEntries: Int
    let isTruncated: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, channel, thumbnail, entries
        case totalEntries = "total_entries"
        case isTruncated = "is_truncated"
    }
}

struct JobCreated: Codable, Sendable {
    let id: String
    let status: String
}

struct ServerMessage: Codable, Sendable { let status: String; let message: String? }

struct LyricsResult: Codable, Sendable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let source: String
}

private struct DeviceRegistration: Codable, Sendable {
    let accessToken: String
    let tokenType: String
    let dailyJobLimit: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case dailyJobLimit = "daily_job_limit"
    }
}

struct DownloadJob: Codable, Sendable {
    let id: String
    let status: String
    let progress: Double
    let fileID: String?
    let filename: String?
    let error: String?
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    let speedBytesPerSecond: Double?

    enum CodingKeys: String, CodingKey {
        case id, status, progress, filename, error
        case fileID = "file_id"
        case downloadedBytes = "downloaded_bytes"
        case totalBytes = "total_bytes"
        case speedBytesPerSecond = "speed_bytes_per_second"
    }
}

enum APIError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case server(String)
    case http(Int, String)
    case network(String)
    case missingResult
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "Địa chỉ backend không hợp lệ."
        case .invalidResponse: return "Backend trả về dữ liệu không hợp lệ."
        case .server(let message): return message
        case .http(_, let message): return message
        case .network(let message): return message
        case .missingResult: return "Job hoàn tất nhưng không có file kết quả."
        case .insufficientStorage: return "Thiết bị không đủ dung lượng trống để lưu file tải xuống."
        }
    }

    var statusCode: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }
}

actor APIClient {
    static let shared = APIClient()
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let logger = Logger(subsystem: "com.personal.OfflineTube", category: "API")

    init(session: URLSession = .shared) {
        self.session = session
    }

    private var baseURL: URL? {
        let value = UserDefaults.standard.string(forKey: "backendURL") ?? "https://offlinetube.cineviet.live"
        return URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let baseURL else { throw APIError.invalidServerURL }
        return baseURL.appendingPathComponent(path)
    }

    private func authorize(_ request: inout URLRequest, admin: Bool = false) {
        if admin, let token = KeychainStore.adminToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return
        }
        if let token = KeychainStore.token(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    private func ensureDeviceToken() async throws {
        guard KeychainStore.token()?.isEmpty != false else { return }
        struct Body: Encodable { let install_id: String; let app_version: String }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        var registration = URLRequest(url: try endpoint("api/auth/register"))
        registration.httpMethod = "POST"
        registration.setValue("application/json", forHTTPHeaderField: "Content-Type")
        registration.timeoutInterval = 30
        registration.httpBody = try encoder.encode(Body(install_id: KeychainStore.installID(), app_version: version))
        let (data, response) = try await performData(for: registration, path: "api/auth/register")
        try validate(response: response, data: data)
        let result = try decoder.decode(DeviceRegistration.self, from: data)
        try KeychainStore.saveDeviceToken(result.accessToken)
    }

    private func performAuthorizedData(for request: URLRequest, path: String) async throws -> (Data, URLResponse) {
        try await ensureDeviceToken()
        var authorized = request
        authorize(&authorized)
        var result = try await performData(for: authorized, path: path)
        if (result.1 as? HTTPURLResponse)?.statusCode == 401 {
            KeychainStore.deleteDeviceToken()
            try await ensureDeviceToken()
            authorize(&authorized)
            result = try await performData(for: authorized, path: path)
        }
        return result
    }

    private func request<T: Decodable, Body: Encodable>(_ path: String, method: String = "POST", body: Body) async throws -> T {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await performAuthorizedData(for: request, path: path)
        try validate(response: response, data: data)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.invalidResponse }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: try endpoint(path))
        let (data, response) = try await performAuthorizedData(for: request, path: path)
        try validate(response: response, data: data)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.invalidResponse }
    }

    private func post<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let (data, response) = try await performAuthorizedData(for: request, path: path)
        try validate(response: response, data: data)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.invalidResponse }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = object["detail"] as? String {
                throw APIError.http(http.statusCode, detail)
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let details = object["detail"] as? [[String: Any]],
               let message = details.first?["msg"] as? String {
                throw APIError.http(http.statusCode, message.replacingOccurrences(of: "Value error, ", with: ""))
            }
            throw APIError.http(http.statusCode, "Backend error (HTTP \(http.statusCode)).")
        }
    }

    private func performData(for request: URLRequest, path: String) async throws -> (Data, URLResponse) {
        var lastError: Error = APIError.invalidResponse
        for attempt in 0..<4 {
            do {
                let result = try await session.data(for: request)
                if let http = result.1 as? HTTPURLResponse,
                   [408, 429, 500, 502, 503, 504].contains(http.statusCode), attempt < 3 {
                    logger.warning("path=\(path, privacy: .public) HTTP=\(http.statusCode) retry=\(attempt + 1)")
                    try await sleepBeforeRetry(attempt: attempt)
                    continue
                }
                return result
            } catch let error as URLError where retryable(error) && attempt < 3 {
                lastError = error
                logger.warning("path=\(path, privacy: .public) network=\(error.code.rawValue) retry=\(attempt + 1)")
                try await sleepBeforeRetry(attempt: attempt)
            } catch {
                logger.error("path=\(path, privacy: .public) failed=\(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        throw APIError.network(lastError.localizedDescription)
    }

    private func retryable(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .resourceUnavailable].contains(error.code)
    }

    private func sleepBeforeRetry(attempt: Int) async throws {
        let seconds = UInt64(1 << min(attempt, 3))
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    }

    func mediaInfo(url: String) async throws -> MediaInfo {
        try await request("api/media/info", body: ["url": url])
    }

    func playlistInfo(url: String) async throws -> PlaylistInfo {
        try await request("api/media/playlist", body: ["url": url])
    }

    func lyrics(title: String, artist: String, duration: Double) async throws -> LyricsResult {
        struct Body: Encodable { let title: String; let artist: String; let duration: Double? }
        return try await request(
            "api/lyrics/search",
            body: Body(title: title, artist: artist, duration: duration > 0 ? duration : nil)
        )
    }

    func createDownload(url: String, mediaType: String, quality: String) async throws -> JobCreated {
        struct Body: Encodable { let url: String; let media_type: String; let quality: String }
        return try await request("api/media/download", body: Body(url: url, media_type: mediaType, quality: quality))
    }

    func job(id: String) async throws -> DownloadJob {
        try await get("api/jobs/\(id)")
    }

    func cancelJob(id: String) async throws -> JobCreated {
        try await post("api/jobs/\(id)/cancel")
    }

    func updateYouTubeCookies(_ contents: String) async throws -> ServerMessage {
        struct Body: Encodable { let cookies: String }
        var request = URLRequest(url: try endpoint("api/admin/youtube-cookies"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(Body(cookies: contents))
        authorize(&request, admin: true)
        let (data, response) = try await performData(for: request, path: "api/admin/youtube-cookies")
        try validate(response: response, data: data)
        return try decoder.decode(ServerMessage.self, from: data)
    }

    func download(fileID: String, filename: String) async throws -> URL {
        try await ensureDeviceToken()
        var request = URLRequest(url: try endpoint("api/files/\(fileID)"))
        authorize(&request)
        var (temporaryURL, response) = try await performDownload(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            try? FileManager.default.removeItem(at: temporaryURL)
            KeychainStore.deleteDeviceToken()
            try await ensureDeviceToken()
            authorize(&request)
            (temporaryURL, response) = try await performDownload(for: request)
        }
        try validate(response: response, data: Data())
        let destination = FileStore.destination(filename: filename)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func performDownload(for request: URLRequest) async throws -> (URL, URLResponse) {
        var lastError: Error = APIError.invalidResponse
        for attempt in 0..<3 {
            do { return try await session.download(for: request) }
            catch let error as URLError where retryable(error) && attempt < 2 {
                lastError = error
                logger.warning("file download network=\(error.code.rawValue) retry=\(attempt + 1)")
                try await sleepBeforeRetry(attempt: attempt)
            } catch { throw error }
        }
        throw APIError.network(lastError.localizedDescription)
    }
}
