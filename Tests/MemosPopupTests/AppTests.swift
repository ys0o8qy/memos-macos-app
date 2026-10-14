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
        XCTAssertNil(app.lastCreatedMemo)
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
        XCTAssertEqual(app.lastCreatedMemo?.name, "memos/\(original.id)")
        XCTAssertEqual(app.lastCreatedMemo?.content, original.content)
        XCTAssertNil(app.composerError)
        XCTAssertFalse(app.draft.hasContent)
        XCTAssertNotEqual(app.draft.id, original.id)
        XCTAssertEqual(try app.drafts?.load(key: "new"), app.draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.drafts!.imageURL(original.images[0]).path))
    }

    @MainActor func testWindowSavePublishesEntryWithoutMenuBarFocusFeedback() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try app(root: root)
        app.draft.content = "窗口中的新记录"
        app.onSaved = { XCTFail("Window save must not close or restore focus through the menu bar") }
        AppStub.handler = { request in
            if request.httpMethod == "POST" {
                return (200, try JSONEncoder().encode(Memo(name: "memos/window", content: "窗口中的新记录")))
            }
            return (200, Data("{\"memos\":[]}".utf8))
        }
        await app.submit(showMenuBarFeedback: false)
        XCTAssertEqual(app.lastCreatedMemo?.name, "memos/window")
        XCTAssertFalse(app.draft.hasContent)
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

    @MainActor func testCommandVPastesClipboardImageThroughEditorAndPersistsIt() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try app(root: root)
        app.draft.content = "图片前的文字"
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let bytes = png()
        board.setData(bytes, forType: .png)
        let editor = ImageTextView()
        editor.isEditable = true
        editor.string = app.draft.content
        editor.imagePasteboard = board
        editor.receiveImage = app.addImage
        editor.onError = { XCTFail($0) }
        let commandV = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        XCTAssertTrue(editor.performKeyEquivalent(with: commandV))
        XCTAssertEqual(app.draft.images.count, 1)
        XCTAssertEqual(editor.string, "图片前的文字")
        XCTAssertEqual(try app.drafts?.imageData(app.draft.images[0]), bytes)
        XCTAssertEqual(try app.drafts?.load(key: "new")?.images, app.draft.images)
        editor.isEditable = false
        editor.paste(nil)
        XCTAssertEqual(app.draft.images.count, 1)
    }

    @MainActor func testTIFFAndJPEGClipboardImagesAreAccepted() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let image = NSImage(data: png())!
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        for (type, data) in [(NSPasteboard.PasteboardType.tiff, image.tiffRepresentation!),
                             (NSPasteboard.PasteboardType("public.jpeg"), bitmap.representation(using: .jpeg, properties: [:])!)] {
            board.clearContents(); board.setData(data, forType: type)
            let editor = ImageTextView()
            editor.isEditable = true; editor.imagePasteboard = board
            var received: Data?
            editor.receiveImage = { data, _, mime in received = data; XCTAssertEqual(mime, "image/png") }
            editor.paste(nil)
            XCTAssertNotNil(received)
            XCTAssertNotNil(received.flatMap { NSImage(data: $0) })
        }
    }

    @MainActor func testEmptyEditorHasVisibleInsertionAreaWhenFocused() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220), styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: MarkdownEditor(text: .constant(""), onImage: { _, _, _ in }, onError: { _ in }, onSubmit: {}))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 220)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> EditorScrollView? {
            if let scroll = view as? EditorScrollView { return scroll }
            return view.subviews.compactMap { find($0) }.first
        }
        let scroll = try XCTUnwrap(find(host))
        scroll.layout()
        let editor = try XCTUnwrap(scroll.documentView as? ImageTextView)
        XCTAssertGreaterThan(editor.bounds.height, 30)
        XCTAssertGreaterThanOrEqual(editor.bounds.height, scroll.contentSize.height)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.insertionPointColor, NSColor.controlAccentColor)
        window.contentView = nil
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
        // Keyboard submission must obey the same conflict gate as the disabled button.
        await editor.save()
        XCTAssertEqual(writes, 0)
        XCTAssertNotNil(editor.conflict)
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

    func testTimelineGroupsLocalMonthsAndKeepsUnknownDatesLast() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let entries = [
            Memo(name: "memos/old", content: "旧记录", createTime: "2026-09-30T15:59:00Z"),
            Memo(name: "memos/unknown", content: "无日期", createTime: "invalid"),
            Memo(name: "memos/new", content: "新记录", createTime: "2026-09-30T16:01:00Z"),
            Memo(name: "memos/newer", content: "更新记录", createTime: "2026-10-02T00:00:00Z")
        ]
        let sections = JournalSection.sections(entries, calendar: calendar)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].memos.map(\.name), ["memos/newer", "memos/new"])
        XCTAssertEqual(sections[1].memos.map(\.name), ["memos/old"])
        XCTAssertNil(sections[2].month)
        XCTAssertTrue(JournalSection.sections([]).isEmpty)
    }

    @MainActor func testSwitchingEntriesRestoresIndependentLocalEdits() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try app(root: root)
        let first = Memo(name: "memos/first", content: "原文")
        let second = Memo(name: "memos/second", content: "另一条")
        app.editor(for: first).draft.content = "尚未提交的修改"
        app.editor(for: second).draft.content = "另一份修改"
        app.draft.content = "正在新建的草稿"
        let restored = try self.app(root: root)
        XCTAssertEqual(restored.editor(for: first).draft.content, "尚未提交的修改")
        XCTAssertEqual(restored.editor(for: second).draft.content, "另一份修改")
        XCTAssertEqual(restored.draft.content, "正在新建的草稿")
    }

    @MainActor func testNativeViewsRenderAtMinimumSizes() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let app = try app(root: root)
        app.draft.content = "记下一个小小的发现。\n\n支持 Markdown，也可以粘贴图片。 #日常"
        app.addImage(data: png(), filename: "test.png", mime: "image/png")
        app.memos = [Memo(name: "memos/one", content: "# 留住一个好想法\n\n今天的灵感，值得记下来。", createTime: "2026-09-18T02:30:00Z")]
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent(".build/validation/renders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try render(ComposerView(app: app, close: {}), size: NSSize(width: 440, height: 420), output: output.appendingPathComponent("composer.png"))
        try render(LibraryView(app: app), size: NSSize(width: 960, height: 640), output: output.appendingPathComponent("library.png"))
        try render(ComposerView(app: app, close: {}, compact: false), size: NSSize(width: 480, height: 640), output: output.appendingPathComponent("full-composer.png"))
        try render(MemoDetail(app: app, editor: app.editor(for: app.memos[0])), size: NSSize(width: 480, height: 640), output: output.appendingPathComponent("detail.png"))
        try render(MarkdownPreview(content: ReadingTests.sample).padding(28), size: NSSize(width: 620, height: 1100), output: output.appendingPathComponent("markdown-dark.png"))
        try render(MarkdownPreview(content: ReadingTests.sample).padding(28), size: NSSize(width: 620, height: 1100), output: output.appendingPathComponent("markdown-light.png"), light: true)
        try render(LibraryView(app: app), size: NSSize(width: 1120, height: 720), output: output.appendingPathComponent("library-light.png"), light: true)
        app.composerError = "无法连接服务器，请检查网络后重试。草稿已保留在本机。"
        try render(ComposerView(app: app, close: {}), size: NSSize(width: 440, height: 420), output: output.appendingPathComponent("popup-error-light.png"), light: true)
        try render(SettingsView(app: app), size: NSSize(width: 480, height: 640), output: output.appendingPathComponent("settings.png"))
    }

    @MainActor private func render<V: View>(_ view: V, size: NSSize, output: URL, light: Bool = false) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading).background(Theme.paper).environment(\.colorScheme, light ? .light : .dark))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.size, size, "Render must preserve the requested viewport")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1000)
        try data.write(to: output)
        window.contentView = nil
    }
}
