import Foundation

struct MediaInfo: Codable, Sendable {
    let id: String
    let title: String
    let thumbnail: String?
    let channel: String
    let duration: Double
    let webpageURL: String

    enum CodingKeys: String, CodingKey {
        case id, title, thumbnail, channel, duration
        case webpageURL = "webpage_url"
    }
}

struct JobCreated: Codable, Sendable {
    let id: String
    let status: String
}

struct DownloadJob: Codable, Sendable {
    let id: String
    let status: String
    let progress: Double
    let fileID: String?
    let filename: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, status, progress, filename, error
        case fileID = "file_id"
    }
}

enum APIError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case server(String)
    case missingResult

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "Địa chỉ backend không hợp lệ."
        case .invalidResponse: return "Backend trả về dữ liệu không hợp lệ."
        case .server(let message): return message
        case .missingResult: return "Job hoàn tất nhưng không có file kết quả."
        }
    }
}

actor APIClient {
    static let shared = APIClient()
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    private var baseURL: URL? {
        let value = UserDefaults.standard.string(forKey: "backendURL") ?? "http://127.0.0.1:8000"
        return URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let baseURL else { throw APIError.invalidServerURL }
        return baseURL.appendingPathComponent(path)
    }

    private func request<T: Decodable, Body: Encodable>(_ path: String, method: String = "POST", body: Body) async throws -> T {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.invalidResponse }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await session.data(from: try endpoint(path))
        try validate(response: response, data: data)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.invalidResponse }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = object["detail"] as? String {
                throw APIError.server(detail)
            }
            throw APIError.server("Backend error (HTTP \(http.statusCode)).")
        }
    }

    func mediaInfo(url: String) async throws -> MediaInfo {
        try await request("api/media/info", body: ["url": url])
    }

    func createDownload(url: String, mediaType: String, quality: String) async throws -> JobCreated {
        struct Body: Encodable { let url: String; let media_type: String; let quality: String }
        return try await request("api/media/download", body: Body(url: url, media_type: mediaType, quality: quality))
    }

    func job(id: String) async throws -> DownloadJob {
        try await get("api/jobs/\(id)")
    }

    func download(fileID: String, filename: String) async throws -> URL {
        let (temporaryURL, response) = try await session.download(from: try endpoint("api/files/\(fileID)"))
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
}
