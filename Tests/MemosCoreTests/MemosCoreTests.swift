import XCTest
@testable import MemosCore

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MemosCoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { StubProtocol.handler = nil; try FileManager.default.removeItem(at: directory) }
    private func api() throws -> MemosAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return try MemosAPI(address: "https://memos.test/subpath/", token: "test-secret", session: URLSession(configuration: config))
    }
    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let value = request.httpBody { data = value }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(buffer, count: count)
            }
            data = result
        } else { data = Data() }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testURLNormalizationAndUnsafeAddressRejection() throws {
        XCTAssertEqual(try MemosAPI.normalizeURL(" https://example.com/memos/api/v1/ ").absoluteString, "https://example.com/memos")
        for url in ["example.com", "file:///etc/passwd", "https://a:b@example.com", "https://example.com?token=abc", "https://example.com/#x"] {
            XCTAssertThrowsError(try MemosAPI.normalizeURL(url))
        }
    }
    func testIdentityAndAuthentication() async throws {
        StubProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/subpath/api/v1/auth/me")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            return (200, self.json(["user": ["name": "users/1", "username": "me"]]))
        }
        let user = try await api().currentUser()
        XCTAssertEqual(user.name, "users/1")
    }
    func testSearchIsEscapedScopedAndPaginated() async throws {
        let search = "笔记\" || true || \"\n\\"
        StubProtocol.handler = { req in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["filter"], "creator == \"users/1\" && content.contains(\(MemosAPI.literal(search)))")
            XCTAssertEqual(query["pageToken"], "next/+=")
            XCTAssertEqual(query["orderBy"], "create_time desc")
            XCTAssertEqual(query["state"], "NORMAL")
            return (200, self.json(["memos": [], "nextPageToken": "more"]))
        }
        let page = try await api().list(user: "users/1", search: search, pageToken: "next/+=")
        XCTAssertEqual(page.nextPageToken, "more")
    }
    func testCreateIsPrivateAndRetryUsesSameMemo() async throws {
        var calls = 0
        let attachment = Attachment(name: "attachments/one", filename: "one.png", type: "image/png")
        StubProtocol.handler = { req in
            calls += 1
            let payload = try self.body(req)
            if calls == 1 {
                XCTAssertEqual(req.httpMethod, "POST")
                XCTAssertTrue(req.url!.absoluteString.contains("memoId=stable-id"))
                XCTAssertEqual(payload["visibility"] as? String, "PRIVATE")
                return (409, Data())
            }
            XCTAssertEqual(req.httpMethod, "PATCH")
            XCTAssertEqual(req.url?.path, "/subpath/api/v1/memos/stable-id")
            XCTAssertNil(payload["visibility"])
            XCTAssertEqual((payload["attachments"] as? [[String: Any]])?.first?["name"] as? String, "attachments/one")
            return (200, self.json(["name": "memos/stable-id", "content": "hello", "visibility": "PRIVATE"]))
        }
        let memo = try await api().create(id: "stable-id", content: "hello", attachments: [attachment])
        XCTAssertEqual(memo.name, "memos/stable-id")
        XCTAssertEqual(calls, 2)
    }
    func testEditPreservesVisibilityAndCanRemoveAllAttachments() async throws {
        StubProtocol.handler = { req in
            let payload = try self.body(req)
            XCTAssertNil(payload["visibility"])
            XCTAssertEqual((payload["attachments"] as? [String])?.count, 0)
            let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first(where: { $0.name == "updateMask" })?.value, "content,attachments")
            return (200, self.json(["name": "memos/one", "content": "edited", "visibility": "PUBLIC"]))
        }
        let result = try await api().update(name: "memos/one", content: "edited", attachments: [])
        XCTAssertEqual(result.visibility, "PUBLIC")
    }
    func testImageUploadUsesBase64AndStableAttachmentID() async throws {
        let store = try DraftStore(root: directory, scope: "one")
        let bytes = Data([0, 1, 255, 4])
        let image = try store.addImage(data: bytes, filename: "中文.png", mime: "image/png")
        var calls = 0
        StubProtocol.handler = { req in
            calls += 1
            if calls == 1 {
                let payload = try self.body(req)
                XCTAssertEqual(payload["content"] as? String, bytes.base64EncodedString())
                XCTAssertEqual(payload["filename"] as? String, "中文.png")
                XCTAssertTrue(req.url!.absoluteString.contains("attachmentId=\(image.id)"))
                return (409, Data())
            }
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertTrue(req.url!.path.hasSuffix("attachments/\(image.id)"))
            return (200, self.json(["name": "attachments/\(image.id)", "filename": "中文.png", "type": "image/png"]))
        }
        let uploaded = try await api().upload(image: image, data: bytes)
        XCTAssertEqual(uploaded.name, "attachments/\(image.id)")
    }
    func testPrivateImageUsesAuthAndExternalImageNeverGetsToken() async throws {
        let api = try api()
        StubProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/subpath/file/attachments/one/中文 图.png")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            return (200, Data([1]))
        }
        _ = try await api.imageData(Attachment(name: "attachments/one", filename: "中文 图.png"))
        StubProtocol.handler = { req in
            XCTAssertEqual(req.url?.host, "storage.test")
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
            return (200, Data([1]))
        }
        _ = try await api.imageData(Attachment(name: "attachments/two", filename: "two", externalLink: "https://storage.test/two"))
    }
    func testAuthenticationFailureAndMalformedResponseAreActionable() async throws {
        StubProtocol.handler = { _ in (401, Data("secret server message".utf8)) }
        do { _ = try await api().currentUser(); XCTFail("Expected 401") }
        catch { XCTAssertEqual(error as? MemosError, .http(401)); XCTAssertFalse(error.localizedDescription.contains("secret")) }
        StubProtocol.handler = { _ in (200, Data("<html>wrong base URL</html>".utf8)) }
        do { _ = try await api().currentUser(); XCTFail("Expected decoding error") }
        catch { XCTAssertEqual(error as? MemosError, .invalidResponse) }
    }
    func testDraftAndImagesSurviveRestartAndAreAccountIsolated() throws {
        let store = try DraftStore(root: directory, scope: "server|users/1")
        var draft = Draft()
        draft.content = "重启后还在 #日常"
        draft.images = [try store.addImage(data: Data([1, 2, 3]), filename: "a.png", mime: "image/png")]
        try store.save(draft, key: "new")
        let reopened = try DraftStore(root: directory, scope: "server|users/1")
        XCTAssertEqual(try reopened.load(key: "new"), draft)
        XCTAssertEqual(try reopened.imageData(draft.images[0]), Data([1, 2, 3]))
        let other = try DraftStore(root: directory, scope: "server|users/2")
        XCTAssertNil(try other.load(key: "new"))
        let mode = try FileManager.default.attributesOfItem(atPath: reopened.imageURL(draft.images[0]).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
    func testCorruptDraftIsPreservedAndNotSilentlyReset() throws {
        let store = try DraftStore(root: directory, scope: "test")
        try store.save(Draft(), key: "new")
        let file = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" }!
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try store.load(key: "new")) { XCTAssertEqual($0 as? MemosError, .draftCorrupted) }
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
    func testEmptyAndEditDraftSemantics() throws {
        var draft = Draft()
        draft.content = " \n "
        XCTAssertFalse(draft.hasContent)
        let memo = Memo(name: "memos/one", content: "original")
        draft = Draft(memo: memo)
        XCTAssertFalse(draft.isModified)
        draft.content = "changed"
        XCTAssertTrue(draft.isModified)
    }
    func testOversizedImageIsRejectedBeforeDiskWrite() throws {
        let store = try DraftStore(root: directory, scope: "test")
        XCTAssertThrowsError(try store.addImage(data: Data(count: 20 * 1024 * 1024 + 1), filename: "large.png", mime: "image/png")) {
            XCTAssertEqual($0 as? MemosError, .imageTooLarge)
        }
    }
}
