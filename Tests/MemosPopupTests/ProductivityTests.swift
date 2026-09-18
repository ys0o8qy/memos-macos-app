import XCTest
import AppKit
import Combine
import ServiceManagement
import MemosCore
@testable import MemosPopup

private final class FeatureProtocol: URLProtocol {
    static var handle: ((FeatureProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handle?(self) }
    override func stopLoading() {}
    func respond(_ status: Int, _ json: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
}

@MainActor
private final class FakeLoginService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrationResult: SMAppService.Status = .enabled
    var registrations = 0
    var removals = 0
    var shouldFail = false
    func register() throws {
        registrations += 1
        if shouldFail { throw MemosError.busy }
        status = registrationResult
    }
    func unregister() throws {
        removals += 1
        if shouldFail { throw MemosError.busy }
        status = .notRegistered
    }
}

final class ProductivityTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func api() throws -> MemosAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeatureProtocol.self]
        return try MemosAPI(address: "https://fixture.test/sub", token: "synthetic", session: URLSession(configuration: config))
    }
    @MainActor private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @MainActor func testLoginItemTracksApprovalErrorsAndExternalChangesWithoutAutoRegistering() {
        let service = FakeLoginService()
        let controller = LoginItemController(service: service)
        XCTAssertFalse(controller.requested)
        XCTAssertEqual(service.registrations, 0)
        service.registrationResult = .requiresApproval
        controller.setEnabled(true)
        XCTAssertTrue(controller.requested)
        XCTAssertEqual(controller.status, .requiresApproval)
        controller.setEnabled(true)
        XCTAssertEqual(service.registrations, 1)
        service.status = .enabled; controller.refresh()
        XCTAssertEqual(controller.status, .enabled)
        service.shouldFail = true; controller.setEnabled(false)
        XCTAssertTrue(controller.requested)
        XCTAssertNotNil(controller.error)
        service.shouldFail = false; controller.setEnabled(false)
        XCTAssertFalse(controller.requested)
        XCTAssertNil(controller.error)
        service.status = .requiresApproval; controller.refresh()
        XCTAssertEqual(controller.status, .requiresApproval)
        service.status = .notRegistered; controller.refresh()
        XCTAssertFalse(controller.requested)
    }

    func testTagQueryUnderstandsUTF16NestedTagsAndMarkdownBoundaries() {
        let text = "🌱 今天 #工作/设计 接下来"
        let cursor = ("🌱 今天 #工作/设" as NSString).length
        let query = TagQuery.at(NSRange(location: cursor, length: 0), in: text)
        XCTAssertEqual(query?.prefix, "工作/设")
        XCTAssertEqual(query.map { (text as NSString).substring(with: $0.range) }, "#工作/设计")
        for text in ["##标题", "# 标题", "https://test/#frag", "word#tag", "\\#tag", "`#tag", "```swift\n#tag", "~~~\n#tag"] {
            XCTAssertNil(TagQuery.at(NSRange(location: (text as NSString).length, length: 0), in: text), text)
        }
        XCTAssertNil(TagQuery.at(NSRange(location: 1, length: 2), in: "#tag"))
        XCTAssertNotNil(TagQuery.at(NSRange(location: 1, length: 0), in: "#"))
    }

    @MainActor func testNativeTagKeysReplacementUndoAndEscapeDoNotSubmit() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220), styleMask: .titled, backing: .buffered, defer: false)
        let editor = ImageTextView(frame: window.contentView!.bounds)
        editor.isRichText = false; editor.allowsUndo = true
        window.contentView = editor
        window.makeFirstResponder(editor)
        let completion = TagCompletionController()
        completion.tags = ["工作/设计", "工作/开发", "生活"]
        editor.tagCompletion = completion
        editor.string = "🌱 #工作/旧文字 后文"
        editor.setSelectedRange(NSRange(location: ("🌱 #工作/" as NSString).length, length: 0))
        completion.update(in: editor)
        XCTAssertEqual(completion.suggestions.count, 2)
        editor.keyDown(with: key(125))
        XCTAssertEqual(completion.selected, 1)
        editor.keyDown(with: key(48))
        XCTAssertEqual(editor.string, "🌱 #工作/开发 后文")
        completion.update(in: editor)
        XCTAssertTrue(completion.suggestions.isEmpty)
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "🌱 #工作/旧文字 后文")
        editor.string = "#工"; editor.setSelectedRange(NSRange(location: 2, length: 0))
        completion.update(in: editor)
        var escaped = false; editor.onEscape = { escaped = true }
        editor.cancelOperation(nil)
        XCTAssertFalse(escaped)
        completion.update(in: editor)
        XCTAssertTrue(completion.suggestions.isEmpty)
        editor.cancelOperation(nil)
        XCTAssertTrue(escaped)
        XCTAssertFalse(completion.handle(key(36, modifiers: .command), in: editor))
        window.contentView = nil
    }

    @MainActor func testMarkedTextIsNeverConsumedByTagCompletion() {
        _ = NSApplication.shared
        let editor = ImageTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        let completion = TagCompletionController()
        completion.tags = ["工作"]; editor.tagCompletion = completion
        editor.string = "#"; editor.setSelectedRange(NSRange(location: 1, length: 0))
        completion.update(in: editor)
        XCTAssertEqual(completion.suggestions, ["工作"])
        editor.setMarkedText("工", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        for code: UInt16 in [36, 48, 53, 125, 126] { XCTAssertFalse(completion.handle(key(code), in: editor)) }
        completion.update(in: editor)
        XCTAssertTrue(completion.suggestions.isEmpty)
        var submitted = false; editor.onSubmit = { submitted = true }
        XCTAssertTrue(editor.performKeyEquivalent(with: key(36, modifiers: .command)))
        XCTAssertFalse(submitted)
    }

    @MainActor func testTagsUseAccountStatsAndPersistOfflineWithoutCrossAccountLeakage() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try DraftStore(root: root, scope: "server|users/a")
        let second = try DraftStore(root: root, scope: "server|users/b")
        let catalog = TagCatalog(); catalog.use(first)
        FeatureProtocol.handle = { request in
            XCTAssertEqual(request.request.url?.path, "/sub/api/v1/users/a:getStats")
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            request.respond(200, #"{"tagCount":{"工作":3,"生活":8,"空":0}}"#)
        }
        let api = try api()
        await catalog.refresh(api: api, user: "users/a")
        XCTAssertEqual(catalog.tags, ["生活", "工作"])
        let restored = TagCatalog(); restored.use(first)
        FeatureProtocol.handle = { $0.fail() }
        await restored.refresh(api: api, user: "users/a", force: true)
        XCTAssertEqual(restored.tags, ["生活", "工作"])
        restored.use(second)
        XCTAssertTrue(restored.tags.isEmpty)
        restored.use(first)
        XCTAssertEqual(restored.tags, ["生活", "工作"])
    }

    @MainActor func testTagResponseFromPreviousAccountCannotOverwriteNewAccount() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = TagCatalog()
        catalog.use(try DraftStore(root: root, scope: "a"))
        let requested = expectation(description: "stats requested")
        var pending: FeatureProtocol?
        FeatureProtocol.handle = { pending = $0; requested.fulfill() }
        let api = try api()
        let task = Task { await catalog.refresh(api: api, user: "users/a") }
        await fulfillment(of: [requested], timeout: 2)
        catalog.use(try DraftStore(root: root, scope: "b"))
        pending?.respond(200, #"{"tagCount":{"private-a":9}}"#)
        await task.value
        XCTAssertTrue(catalog.tags.isEmpty)
    }

    @MainActor func testSaveFeedbackWaitsForResponseAndPreventsDuplicateSubmission() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppStore(testRoot: root); app.api = try api()
        app.draft.content = "保存反馈"
        let original = app.draft
        let requested = expectation(description: "save requested")
        var pending: FeatureProtocol?
        FeatureProtocol.handle = { pending = $0; requested.fulfill() }
        var successes = 0; app.onSaved = { successes += 1 }
        let task = Task { await app.submit() }
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertTrue(app.isSaving)
        XCTAssertEqual(successes, 0)
        await app.submit()
        pending?.respond(401, "{}")
        await task.value
        XCTAssertEqual(successes, 0)
        XCTAssertEqual(app.draft, original)
        XCTAssertEqual(app.saveFailure?.action, .settings)
        FeatureProtocol.handle = { $0.respond(200, #"{"name":"memos/saved","content":"保存反馈"}"#) }
        await app.submit()
        XCTAssertEqual(successes, 1)
        XCTAssertFalse(app.draft.hasContent)
        XCTAssertNil(app.saveFailure)
    }

    @MainActor func testSavingDuringTagFetchSchedulesAFreshSnapshot() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = TagCatalog(); catalog.use(try DraftStore(root: root, scope: "a"))
        let requested = expectation(description: "first stats requested")
        let updated = expectation(description: "fresh tags applied")
        var pending: FeatureProtocol?
        FeatureProtocol.handle = { pending = $0; requested.fulfill() }
        let api = try api()
        let task = Task { await catalog.refresh(api: api, user: "users/a") }
        await fulfillment(of: [requested], timeout: 2)
        await catalog.refresh(api: api, user: "users/a", force: true)
        let observation = catalog.$tags.sink { if $0 == ["新标签"] { updated.fulfill() } }
        FeatureProtocol.handle = { $0.respond(200, #"{"tagCount":{"新标签":1}}"#) }
        pending?.respond(200, #"{"tagCount":{}}"#)
        await task.value
        await fulfillment(of: [updated], timeout: 2)
        observation.cancel()
    }

    @MainActor func testUploadProgressAndFailureRecovery() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppStore(testRoot: root); app.api = try api()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        app.addImage(data: bitmap.representation(using: .png, properties: [:])!, filename: "tiny.png", mime: "image/png")
        var phases: [String] = []
        let observation = app.$saveStatus.sink { phases.append($0) }
        FeatureProtocol.handle = { $0.respond(413, "{}") }
        await app.submit()
        XCTAssertTrue(phases.contains("正在上传图片 1/1…"))
        XCTAssertEqual(app.draft.images.count, 1)
        XCTAssertTrue(app.saveFailure?.message.contains("图片上传失败") == true)
        XCTAssertFalse(app.isSaving)
        observation.cancel()
        XCTAssertEqual(SaveFailure.describe(URLError(.timedOut), uploading: false, remoteSaved: false).action, .retry)
        XCTAssertEqual(SaveFailure.describe(MemosError.draftCorrupted, uploading: false, remoteSaved: true).action, .library)
    }

    @MainActor func testFeedbackPanelCannotStealKeyboardFocus() {
        _ = NSApplication.shared
        let panel = FeedbackPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    @MainActor func testIdleCompletionDoesNotPublishAnEndlessViewUpdateLoop() {
        let completion = TagCompletionController()
        let editor = ImageTextView(); editor.string = "普通文字"
        var updates = 0
        let observer = completion.objectWillChange.sink { updates += 1 }
        for _ in 0..<10 { completion.update(in: editor) }
        XCTAssertEqual(updates, 0)
        observer.cancel()
    }
}
