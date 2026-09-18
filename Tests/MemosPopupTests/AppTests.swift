import XCTest
import SwiftUI
import MemosCore
@testable import MemosPopup

final class AppStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class AppTests: XCTestCase {
    @MainActor private func app(root: URL) throws -> AppStore {
        let app = AppStore(testRoot: root)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppStub.self]
        app.api = try MemosAPI(address: "http://127.0.0.1:18741", token: "test-token", session: URLSession(configuration: config))
        app.connection = Connection(address: "http://127.0.0.1:18741", user: MemosUser(name: "users/1"))
        return app
    }
    private func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor private func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<40 { for y in 0..<40 { rep.setColor(.systemGreen, atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }

    @MainActor func testOfflineFailureKeepsTextAndImagesThenRetryClearsOnlyAfterSuccess() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try app(root: root)
        app.draft.content = "离线写下的内容 #测试"
        app.addImage(data: png(), filename: "test.png", mime: "image/png")
        let original = app.draft
        AppStub.handler = { _ in throw URLError(.notConnectedToInternet) }
        await app.submit()
        XCTAssertNotNil(app.composerError)
        XCTAssertEqual(app.draft, original)
        XCTAssertEqual(try app.drafts?.load(key: "new"), original)
        XCTAssertFalse(app.isSaving)
        let restored = AppStore(testRoot: root)
        XCTAssertEqual(restored.draft, original)
        var closed = false
        app.onSaved = { closed = true }
        AppStub.handler = { req in
            let path = req.url!.path
            if path.hasSuffix("attachments") {
                return (200, try JSONEncoder().encode(Attachment(name: "attachments/\(original.images[0].id)", filename: "test.png", type: "image/png")))
            }
            if req.httpMethod == "POST" {
                return (200, try JSONEncoder().encode(Memo(name: "memos/\(original.id)", content: original.content)))
            }
            return (200, Data("{\"memos\":[]}".utf8))
        }
        await app.submit()
        XCTAssertTrue(closed)
        XCTAssertNil(app.composerError)
        XCTAssertFalse(app.draft.hasContent)
        XCTAssertNotEqual(app.draft.id, original.id)
        XCTAssertEqual(try app.drafts?.load(key: "new"), app.draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.drafts!.imageURL(original.images[0]).path))
    }

    @MainActor func testImagePasteboardDecodingAndTextFallback() async throws {
        let view = ImageTextView()
        view.isEditable = true
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let bytes = png()
        board.setData(bytes, forType: .png)
        var received: Data?
        let accepted = ImageImport.pasteboard(board, receive: { data, _, mime in received = data; XCTAssertEqual(mime, "image/png") }, fail: { XCTFail($0) })
        XCTAssertTrue(accepted)
        XCTAssertEqual(received, bytes)
        board.clearContents()
        board.setString("plain markdown #tag", forType: .string)
        XCTAssertFalse(ImageImport.pasteboard(board, receive: { _, _, _ in XCTFail("Text must not become an image") }, fail: { XCTFail($0) }))
    }

    @MainActor func testExternalEditConflictDoesNotOverwriteAndKeepsDraft() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try app(root: root)
        let original = Memo(name: "memos/one", content: "before", attachments: [])
        let editor = app.editor(for: original)
        editor.draft.content = "my changes"
        let external = Memo(name: "memos/one", content: "other device changed this", attachments: [])
        var writes = 0
        AppStub.handler = { req in
            if req.httpMethod != "GET" { writes += 1 }
            return (200, try JSONEncoder().encode(external))
        }
        await editor.save()
        XCTAssertEqual(writes, 0)
        XCTAssertNotNil(editor.conflict)
        XCTAssertEqual(editor.draft.content, "my changes")
        XCTAssertEqual(try app.drafts?.load(key: "memos/one")?.content, "my changes")
    }

    @MainActor func testRefreshUpdatesCleanEditorButPreservesUnsavedChanges() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try app(root: root)
        let editor = app.editor(for: Memo(name: "memos/one", content: "before"))
        let latest = Memo(name: "memos/one", content: "after")
        editor.receive(latest)
        XCTAssertEqual(editor.draft.content, "after")
        editor.draft.content = "local unsaved"
        editor.receive(Memo(name: "memos/one", content: "new server version"))
        XCTAssertEqual(editor.draft.content, "local unsaved")
    }

    @MainActor func testNativeViewsRenderAtMinimumSizes() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let app = try app(root: root)
        app.draft.content = "记下一个小小的发现。\n\n支持 Markdown，也可以粘贴图片。 #日常"
        app.addImage(data: png(), filename: "test.png", mime: "image/png")
        app.memos = [Memo(name: "memos/one", content: "# 留住一个好想法\n\n今天的灵感，值得记下来。", createTime: "2026-09-18T02:30:00Z")]
        let output = URL(fileURLWithPath: "/tmp/memos-popup-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try render(ComposerView(app: app, close: {}), size: NSSize(width: 440, height: 460), output: output.appendingPathComponent("composer.png"))
        try render(LibraryView(app: app), size: NSSize(width: 960, height: 640), output: output.appendingPathComponent("library.png"))
        try render(SettingsView(app: app), size: NSSize(width: 480, height: 590), output: output.appendingPathComponent("settings.png"))
    }

    @MainActor private func render<V: View>(_ view: V, size: NSSize, output: URL) throws {
        let host = NSHostingView(rootView: view.background(Theme.canvas))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1000)
        try data.write(to: output)
        window.contentView = nil
    }
}
