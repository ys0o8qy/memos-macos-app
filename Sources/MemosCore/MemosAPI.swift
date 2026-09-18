import Foundation

// Never forward a bearer credential to a redirect destination, including HTTP downgrades.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class MemosAPI: @unchecked Sendable {
    public let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(address: String, token: String, session: URLSession? = nil) throws {
        baseURL = try Self.normalizeURL(address)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        }
    }

    public static func normalizeURL(_ address: String) throws -> URL {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw MemosError.invalidURL }
        parts.scheme = parts.scheme?.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.hasSuffix("/api/v1") { parts.path.removeLast(7) }
        guard let url = parts.url else { throw MemosError.invalidURL }
        return url
    }

    public static func literal(_ string: String) -> String {
        // JSON quoted strings are valid CEL literals; do not concatenate raw user search text.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(data: try! encoder.encode(string), encoding: .utf8)!
    }

    public func request(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var parts = URLComponents(url: baseURL.appendingPathComponent("api/v1").appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MemosError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw MemosError.http(response.statusCode) }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        let response = try await data(for: request)
        do { return try JSONDecoder().decode(type, from: response) }
        catch { throw MemosError.invalidResponse }
    }

    public func currentUser() async throws -> MemosUser {
        struct Response: Decodable { var user: MemosUser }
        return try await decode(Response.self, request(path: "auth/me")).user
    }

    public func list(user: String, search: String = "", pageToken: String = "") async throws -> MemoPage {
        var filter = "creator == \(Self.literal(user))"
        if !search.isEmpty { filter += " && content.contains(\(Self.literal(search)))" }
        return try await decode(MemoPage.self, request(path: "memos", query: [
            .init(name: "pageSize", value: "40"), .init(name: "pageToken", value: pageToken),
            .init(name: "state", value: "NORMAL"), .init(name: "orderBy", value: "create_time desc"),
            .init(name: "filter", value: filter)
        ]))
    }

    public func get(name: String) async throws -> Memo { try await decode(Memo.self, request(path: name)) }

    public func upload(image: LocalImage, data: Data) async throws -> Attachment {
        struct Body: Encodable { var filename: String; var type: String; var content: Data }
        let body = try JSONEncoder().encode(Body(filename: image.filename, type: image.mimeType, content: data))
        do {
            return try await decode(Attachment.self, request(path: "attachments", method: "POST",
                query: [.init(name: "attachmentId", value: image.id)], body: body))
        } catch MemosError.http(409) {
            return try await decode(Attachment.self, request(path: "attachments/\(image.id)"))
        }
    }

    public func create(id: String, content: String, attachments: [Attachment]) async throws -> Memo {
        struct Body: Encodable { var content: String; var visibility = "PRIVATE"; var attachments: [Attachment] }
        let body = try JSONEncoder().encode(Body(content: content, attachments: attachments))
        do {
            return try await decode(Memo.self, request(path: "memos", method: "POST",
                query: [.init(name: "memoId", value: id)], body: body))
        } catch MemosError.http(409) {
            // The previous POST may have committed before its response was lost.
            // Reconcile the same resource, including a partially completed attachment association.
            return try await update(name: "memos/\(id)", content: content, attachments: attachments)
        }
    }

    public func update(name: String, content: String, attachments: [Attachment]) async throws -> Memo {
        struct Body: Encodable { var content: String; var attachments: [Attachment] }
        let body = try JSONEncoder().encode(Body(content: content, attachments: attachments))
        return try await decode(Memo.self, request(path: name, method: "PATCH",
            query: [.init(name: "updateMask", value: "content,attachments")], body: body))
    }

    public func imageData(_ attachment: Attachment) async throws -> Data {
        var request: URLRequest
        if let external = attachment.externalLink, !external.isEmpty {
            guard let url = URL(string: external), ["https", "http"].contains(url.scheme ?? "") else { throw MemosError.invalidURL }
            request = URLRequest(url: url) // Never send the Memos token to external storage.
        } else {
            let uid = attachment.name.split(separator: "/").last.map(String.init) ?? ""
            let url = baseURL.appendingPathComponent("file/attachments").appendingPathComponent(uid).appendingPathComponent(attachment.filename)
            request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await data(for: request)
    }
}
