import Foundation

// A client for the ContentMaschine API (contentmaschine.ai).
//
// Shared deliberately: the MCP server drives it, and Compositor's own
// "Generate Layer" panel drives the same code. It has no UI and no AppKit.
//
// Four behaviours here exist because the service requires them:
//  1. An explicit User-Agent. The edge rejects some default agents.
//  2. The Authorization header is dropped when a download redirects to S3,
//     which rejects a request that carries one.
//  3. `resolution` is nested inside `options`. At the top level it is ignored
//     silently and the render comes back at 1024.
//  4. Jobs are submitted one at a time, and a 429 is retried with a backoff.

public struct ContentMaschineCredentials: Sendable {
    public var apiKey: String
    public var baseURL: URL

    public init(apiKey: String, baseURL: URL) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    /// Reads the env-style file the API's own tooling uses.
    /// Environment variables win, so a caller can override it.
    public static func load(
        from file: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/contentmaschine/credentials")
    ) throws -> ContentMaschineCredentials {
        var values: [String: String] = [:]
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let split = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[trimmed.startIndex..<split])
                var value = String(trimmed[trimmed.index(after: split)...])
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                values[key] = value
            }
        }
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["CONTENTMASCHINE_API_KEY"] ?? values["CONTENTMASCHINE_API_KEY"],
              !key.isEmpty else {
            throw ContentMaschineError.noCredentials(file.path)
        }
        let base = environment["CONTENTMASCHINE_BASE_URL"] ?? values["CONTENTMASCHINE_BASE_URL"]
            ?? "https://contentmaschine.ai/api/v1"
        guard let url = URL(string: base) else { throw ContentMaschineError.noCredentials(file.path) }
        return ContentMaschineCredentials(apiKey: key, baseURL: url)
    }
}

public enum ContentMaschineError: LocalizedError {
    case noCredentials(String)
    case http(Int, String)
    case jobFailed(String)
    case timedOut(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .noCredentials(let path):
            return "No ContentMaschine API key. Put CONTENTMASCHINE_API_KEY in \(path), "
                 + "or set it in the environment."
        case .http(let status, let body):
            return "ContentMaschine returned \(status): \(body.prefix(400))"
        case .jobFailed(let reason): return "The ContentMaschine job failed: \(reason)"
        case .timedOut(let what): return "\(what) did not finish in time."
        case .malformed(let what): return "Could not read ContentMaschine's answer: \(what)"
        }
    }
}

public struct UploadedFile: Sendable {
    public let uuid: String
    public let width: Int?
    public let height: Int?
}

public struct GeneratedImage: Sendable {
    public let uuid: String
    public let data: Data
    public let creditsUsed: Double?
}

public struct GalleryEntry: Sendable {
    public let uuid: String
    public let title: String
    public let createdAt: String
    public let creditsUsed: Double?
    public let fileUUID: String?
}

public enum ImageModel: String, CaseIterable, Sendable {
    case standard, lite, pro, flux, seedream, seedream5

    /// Pro preserves existing typography; the cheaper models re-invent it.
    public static let forText = ImageModel.pro
}

/// The service renders reliably at 2048. At 4096 it tiles the background and
/// corrupts type, so it is not offered.
public enum Resolution: Int, CaseIterable, Sendable {
    case r1024 = 1024
    case r2048 = 2048
}

public actor ContentMaschineClient {
    private let credentials: ContentMaschineCredentials
    private let session: URLSession
    private let redirectHandler = RedirectHandler()

    public init(credentials: ContentMaschineCredentials) {
        self.credentials = credentials
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        self.session = URLSession(configuration: configuration, delegate: redirectHandler,
                                  delegateQueue: nil)
    }

    /// S3 rejects a redirected request that still carries our Authorization
    /// header, so it is stripped when the host changes.
    private final class RedirectHandler: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            var forwarded = request
            if request.url?.host != task.originalRequest?.url?.host {
                forwarded.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            completionHandler(forwarded)
        }
    }

    // MARK: - Transport

    private func request(_ path: String, method: String = "GET",
                         query: [URLQueryItem] = [], authorized: Bool = true) -> URLRequest {
        var url = credentials.baseURL.appendingPathComponent(path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // The edge rejects some default agents; send one of our own.
        request.setValue("compositor-mcp/0.2 (+https://github.com/marcushorndt/compositor-mcp)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized { request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Sends a request, retrying a 429 with a widening pause.
    private func send(_ request: URLRequest, attempts: Int = 4) async throws -> (Data, HTTPURLResponse) {
        var wait: UInt64 = 2
        for attempt in 1...attempts {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ContentMaschineError.malformed("no HTTP response")
            }
            if http.statusCode == 429, attempt < attempts {
                try await Task.sleep(nanoseconds: wait * 1_000_000_000)
                wait *= 2
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ContentMaschineError.http(http.statusCode,
                                                String(data: data, encoding: .utf8) ?? "")
            }
            return (data, http)
        }
        throw ContentMaschineError.http(429, "rate limited")
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await send(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContentMaschineError.malformed("expected a JSON object")
        }
        return object
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = self.request(path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await json(request)
    }

    /// Unwraps the `data` envelope the API usually uses.
    private func payload(_ object: [String: Any]) -> [String: Any] {
        object["data"] as? [String: Any] ?? object
    }

    // MARK: - Files

    public func upload(_ data: Data, filename: String) async throws -> UploadedFile {
        let boundary = "cm-\(UUID().uuidString)"
        var request = self.request("files/upload", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ text: String) { body.append(text.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: image/png\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let result = payload(try await json(request))
        guard let uuid = result["file_uuid"] as? String else {
            throw ContentMaschineError.malformed("upload returned no file_uuid")
        }
        return UploadedFile(uuid: uuid,
                            width: (result["width"] as? NSNumber)?.intValue,
                            height: (result["height"] as? NSNumber)?.intValue)
    }

    /// Downloads a stored file. This path hangs off the host root, not the
    /// versioned base, and redirects to S3 unauthenticated.
    public func download(fileUUID: String) async throws -> Data {
        var root = URLComponents(url: credentials.baseURL, resolvingAgainstBaseURL: false)
        root?.path = "/api/files/download/\(fileUUID)"
        root?.queryItems = nil
        guard let url = root?.url else { throw ContentMaschineError.malformed("bad download URL") }
        var request = URLRequest(url: url)
        request.setValue("compositor-mcp/0.2", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await send(request)
        return data
    }

    // MARK: - Jobs

    private func options(_ resolution: Resolution?) -> [String: Any] {
        // Nested on purpose: a top-level resolution is ignored without an error.
        guard let resolution else { return [:] }
        return ["resolution": String(resolution.rawValue)]
    }

    private func submit(_ path: String, _ body: [String: Any]) async throws -> String {
        let result = payload(try await post(path, body: body))
        guard let id = (result["job_id"] ?? result["id"]).map({ "\($0)" }), !id.isEmpty else {
            throw ContentMaschineError.malformed("no job_id in the answer")
        }
        return id
    }

    /// Polls until the job finishes, then downloads what it produced.
    public func awaitJob(_ jobID: String, timeout: TimeInterval = 600) async throws -> GeneratedImage {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = payload(try await json(request("jobs/\(jobID)")))
            let status = (result["status"] as? String ?? "").lowercased()
            if status == "completed" || status == "succeeded" {
                // The finished job puts the file under `result`; `file` is what
                // the gallery uses. Accept either.
                let finished = result["result"] as? [String: Any]
                    ?? result["file"] as? [String: Any] ?? result
                guard let uuid = (finished["file_uuid"] ?? finished["uuid"]) as? String else {
                    throw ContentMaschineError.malformed("a finished job carried no file")
                }
                let credits = (result["credits_used"] as? NSNumber)?.doubleValue
                    ?? (finished["credits_used"] as? NSNumber)?.doubleValue
                return GeneratedImage(uuid: uuid, data: try await download(fileUUID: uuid),
                                      creditsUsed: credits)
            }
            if status == "failed" || status == "error" {
                throw ContentMaschineError.jobFailed(result["error"] as? String ?? "no reason given")
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        throw ContentMaschineError.timedOut("Job \(jobID)")
    }

    public func generate(prompt: String, model: ImageModel = .pro, aspectRatio: String = "1:1",
                         resolution: Resolution? = .r2048) async throws -> GeneratedImage {
        var body: [String: Any] = ["prompt": prompt, "model": model.rawValue,
                                   "aspect_ratio": aspectRatio]
        let extra = options(resolution)
        if !extra.isEmpty { body["options"] = extra }
        return try await awaitJob(try await submit("images/generate", body))
    }

    public func vary(fileUUID: String, prompt: String, model: ImageModel = .pro,
                     aspectRatio: String = "1:1",
                     resolution: Resolution? = .r2048) async throws -> GeneratedImage {
        var body: [String: Any] = ["file_uuid": fileUUID, "prompt": prompt,
                                   "model": model.rawValue, "aspect_ratio": aspectRatio]
        let extra = options(resolution)
        if !extra.isEmpty { body["options"] = extra }
        return try await awaitJob(try await submit("images/vary", body))
    }

    public func fuse(fileUUIDs: [String], prompt: String, model: ImageModel = .pro,
                     aspectRatio: String = "1:1",
                     resolution: Resolution? = .r2048) async throws -> GeneratedImage {
        var body: [String: Any] = ["file_uuids": fileUUIDs, "prompt": prompt,
                                   "model": model.rawValue, "aspect_ratio": aspectRatio]
        let extra = options(resolution)
        if !extra.isEmpty { body["options"] = extra }
        return try await awaitJob(try await submit("images/fuse", body))
    }

    /// Synchronous: it answers with the PNG itself. It always comes back at
    /// 1024 whatever goes in, because the segmenter works at that size.
    public func removeBackground(fileUUID: String, subjectHint: String? = nil) async throws -> Data {
        var request = self.request("images/remove-background", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["file_uuid": fileUUID]
        if let subjectHint { body["subject_hint"] = subjectHint }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await send(request)
        // It answers with JSON naming the cut file, rather than the bytes.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let result = payload(object)
            let finished = result["result"] as? [String: Any] ?? result
            guard let uuid = (finished["file_uuid"] ?? finished["uuid"]) as? String else {
                throw ContentMaschineError.malformed("remove-background returned no image")
            }
            return try await download(fileUUID: uuid)
        }
        return data
    }

    /// Upscaling reports through its own endpoint: it has no job_id, and
    /// /jobs does not know about it.
    public func upscale(fileUUID: String, scale: Int = 2, provider: String = "krea_topaz",
                        timeout: TimeInterval = 900) async throws -> GeneratedImage {
        let result = payload(try await post("images/upscale", body: [
            "file_uuid": fileUUID, "provider": provider, "scale": scale,
        ]))
        guard let kreaID = (result["krea_job_id"]).map({ "\($0)" }),
              let generationID = (result["generation_id"]).map({ "\($0)" }) else {
            throw ContentMaschineError.malformed("upscale returned no krea_job_id")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = payload(try await json(request("images/upscale-status", query: [
                URLQueryItem(name: "krea_job_id", value: kreaID),
                URLQueryItem(name: "generation_id", value: generationID),
                URLQueryItem(name: "provider", value: provider),
                URLQueryItem(name: "scale", value: String(scale)),
            ])))
            let state = (status["status"] as? String ?? "").lowercased()
            if state == "completed" {
                let done = status["result"] as? [String: Any] ?? status
                guard let uuid = (done["file_uuid"] ?? done["uuid"]) as? String else {
                    throw ContentMaschineError.malformed("a finished upscale carried no file")
                }
                return GeneratedImage(uuid: uuid, data: try await download(fileUUID: uuid),
                                      creditsUsed: (status["credits_used"] as? NSNumber)?.doubleValue)

            }
            if state == "failed" || state == "error" {
                throw ContentMaschineError.jobFailed(status["error"] as? String ?? "no reason given")
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        throw ContentMaschineError.timedOut("The upscale")
    }

    // MARK: - Gallery

    /// Every past job, with its output still downloadable. Re-fetching one
    /// costs nothing and returns the original bytes, so it beats regenerating.
    public func gallery(limit: Int = 40) async throws -> [GalleryEntry] {
        let object = try await json(request("gallery", query: [
            URLQueryItem(name: "limit", value: String(limit)),
        ]))
        let rows = (object["data"] as? [[String: Any]])
            ?? ((object["data"] as? [String: Any])?["items"] as? [[String: Any]])
            ?? (object["items"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let uuid = (row["uuid"] ?? row["id"]).map({ "\($0)" }) else { return nil }
            let file = row["file"] as? [String: Any]
            return GalleryEntry(
                uuid: uuid,
                title: row["title"] as? String ?? "(untitled)",
                createdAt: row["created_at"] as? String ?? "",
                creditsUsed: (row["credits_used"] as? NSNumber)?.doubleValue,
                fileUUID: (file?["uuid"] ?? file?["file_uuid"]) as? String)
        }
    }
}
