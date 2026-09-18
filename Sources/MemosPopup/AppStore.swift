import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MemosCore

struct Connection: Codable {
    var address: String
    var user: MemosUser
    var account: String { address + "|" + user.name }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var connection: Connection?
    @Published var draft = Draft() { didSet { persistDraft() } }
    @Published var memos: [Memo] = []
    @Published var listError: String?
    @Published var composerError: String?
    @Published var storageError: String?
    @Published var isSaving = false
    @Published var saveStatus = "正在保存…"
    @Published var saveFailure: SaveFailure?
    @Published var isLoading = false
    @Published var isConnecting = false
    @Published var nextPage = ""
    @Published var search = ""
    let shortcuts: ShortcutController
    let loginItem: LoginItemController
    let tagCatalog = TagCatalog()
    var onSettings: (() -> Void)?
    var onLibrary: (() -> Void)?
    var onCompose: (() -> Void)?
    var onSaved: (() -> Void)?
    var onSaveFailed: (() -> Void)?
    var api: MemosAPI?
    var drafts: DraftStore?
    private var token = ""
    private var readyToPersist = false
    private var listGeneration = 0
    private(set) var editors: [String: EditorModel] = [:]
    private let root: URL
    let testing: Bool
    var canWrite: Bool { api != nil && drafts != nil && storageError == nil && !isConnecting }
    var anySaving: Bool { isSaving || editors.values.contains(where: \.isSaving) }

    init(testRoot: URL? = nil) {
        let args = ProcessInfo.processInfo.arguments
        testing = testRoot != nil || args.contains("--ui-testing")
        shortcuts = ShortcutController(defaults: testing ? nil : .standard)
        loginItem = LoginItemController(testing: testing)
        if testing {
            root = testRoot ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["MEMOS_TEST_DATA"] ?? "/tmp/memos-popup-ui-test", isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MemosPopup/Drafts", isDirectory: true)
        }
        do {
            if testing, let index = args.firstIndex(of: "--test-server"), args.count > index + 1 {
                let address = args[index + 1]
                guard ["localhost", "127.0.0.1", "::1"].contains(URL(string: address)?.host ?? "") else { throw MemosError.invalidURL }
                connection = Connection(address: address, user: MemosUser(name: "users/1", username: "本地测试"))
                token = "test-token"
                api = try MemosAPI(address: address, token: token)
            } else if !testing, let data = UserDefaults.standard.data(forKey: "connection") {
                connection = try JSONDecoder().decode(Connection.self, from: data)
                if let connection, let saved = try Keychain.read(account: connection.account) {
                    token = saved
                    api = try MemosAPI(address: connection.address, token: saved)
                }
            }
        } catch { composerError = error.localizedDescription }
        do {
            drafts = try DraftStore(root: root, scope: connection?.account ?? "unconnected")
            draft = try drafts?.load(key: "new") ?? Draft()
            readyToPersist = true
        } catch { storageError = error.localizedDescription }
        tagCatalog.use(drafts)
    }

    private func persistDraft() {
        guard readyToPersist, let drafts else { return }
        do { try drafts.save(draft, key: "new") }
        catch { storageError = "草稿未能写入磁盘：\(error.localizedDescription)" }
    }

    func connect(address: String, enteredToken: String) async throws {
        guard !anySaving, !isConnecting else { throw MemosError.busy }
        isConnecting = true
        defer { isConnecting = false }
        let normalized = try MemosAPI.normalizeURL(address).absoluteString
        let newToken = enteredToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateToken = newToken.isEmpty && normalized == connection?.address ? token : newToken
        guard !candidateToken.isEmpty else { throw MemosError.unconfigured }
        let candidate = try MemosAPI(address: normalized, token: candidateToken)
        let user = try await candidate.currentUser()
        let settings = Connection(address: normalized, user: user)
        let newStore = try DraftStore(root: root, scope: settings.account)
        var newDraft = try newStore.load(key: "new") ?? Draft()
        // Preserve notes written before the first connection, including local image files.
        if connection == nil, draft.hasContent, !newDraft.hasContent {
            newDraft = draft
            newDraft.images = try draft.images.map { image in
                guard let drafts else { throw MemosError.draftCorrupted }
                return try newStore.addImage(data: drafts.imageData(image), filename: image.filename, mime: image.mimeType)
            }
            try newStore.save(newDraft, key: "new")
        }
        if !testing {
            try Keychain.save(candidateToken, account: settings.account)
            UserDefaults.standard.set(try JSONEncoder().encode(settings), forKey: "connection")
        }
        readyToPersist = false
        connection = settings; token = candidateToken; api = candidate; drafts = newStore; draft = newDraft
        editors = [:]; memos = []; nextPage = ""; storageError = nil; composerError = nil; saveFailure = nil
        tagCatalog.use(newStore)
        readyToPersist = true
        Task { await self.refreshTags(force: true) }
        await refresh()
    }

    func refreshTags(force: Bool = false) async {
        guard let api, let connection else { return }
        await tagCatalog.refresh(api: api, user: connection.user.name, force: force)
    }

    func refresh(more: Bool = false) async {
        guard let api, let connection else { return }
        if more && (isLoading || nextPage.isEmpty) { return }
        listGeneration += 1
        let generation = listGeneration
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageToken = more ? nextPage : ""
        isLoading = true; listError = nil
        defer { if generation == listGeneration { isLoading = false } }
        do {
            let result = try await api.list(user: connection.user.name, search: query, pageToken: pageToken)
            guard generation == listGeneration, !Task.isCancelled else { return }
            let fetched = result.memos ?? []
            for memo in fetched { editors[memo.name]?.receive(memo) }
            if more {
                let ids = Set(memos.map(\.name))
                memos.append(contentsOf: fetched.filter { !ids.contains($0.name) })
            } else { memos = fetched }
            nextPage = result.nextPageToken ?? ""
        } catch {
            guard generation == listGeneration else { return }
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled { listError = error.localizedDescription }
        }
    }

    func addImage(data: Data, filename: String, mime: String) {
        guard !isSaving, !isConnecting, let drafts, storageError == nil else { return }
        do {
            guard NSImage(data: data) != nil else { throw MemosError.invalidImage }
            draft.images.append(try drafts.addImage(data: data, filename: filename, mime: mime))
            composerError = nil
        } catch { composerError = error.localizedDescription }
    }

    func removeImage(_ image: LocalImage) {
        draft.images.removeAll { $0.id == image.id }
        // Keep the file if persisting metadata failed, to avoid losing a recoverable draft.
        if storageError == nil { drafts?.removeImages([image]) }
    }

    func submit() async {
        guard canWrite, !isSaving, draft.hasContent, let api, let drafts else { return }
        isSaving = true; composerError = nil; saveFailure = nil
        let snapshot = draft
        var uploading = false
        var remoteSaved = false
        defer { isSaving = false; saveStatus = "正在保存…" }
        do {
            var attachments: [Attachment] = []
            for (index, image) in snapshot.images.enumerated() {
                uploading = true
                saveStatus = "正在上传图片 \(index + 1)/\(snapshot.images.count)…"
                attachments.append(try await api.upload(image: image, data: drafts.imageData(image)))
            }
            uploading = false; saveStatus = "正在保存…"
            _ = try await api.create(id: snapshot.id, content: snapshot.content, attachments: attachments)
            remoteSaved = true
            // Commit an empty draft before cleaning files or closing the panel.
            let empty = Draft()
            try drafts.save(empty, key: "new")
            draft = empty
            drafts.removeImages(snapshot.images)
            onSaved?()
            Task { await self.refresh() }
            Task { await self.refreshTags(force: true) }
        } catch {
            let failure = SaveFailure.describe(error, uploading: uploading, remoteSaved: remoteSaved)
            saveFailure = failure; composerError = failure.message
            onSaveFailed?()
        }
    }

    func editor(for memo: Memo) -> EditorModel {
        if let existing = editors[memo.name] { return existing }
        let editor = EditorModel(memo: memo, app: self)
        editors[memo.name] = editor
        return editor
    }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var draft: Draft { didSet { persist() } }
    @Published var error: String?
    @Published var isSaving = false
    @Published var saved = false
    @Published var conflict: Memo?
    private var ready = false
    private(set) var storageFailed = false
    unowned let app: AppStore
    let key: String
    init(memo: Memo, app: AppStore) {
        self.app = app; key = memo.name
        draft = Draft(memo: memo)
        do { draft = try app.drafts?.load(key: key) ?? Draft(memo: memo); ready = true }
        catch { self.error = error.localizedDescription; storageFailed = true }
    }
    private func persist() {
        guard ready else { return }
        saved = false
        do { try app.drafts?.save(draft, key: key) }
        catch { self.error = "编辑草稿未能写入磁盘：\(error.localizedDescription)"; storageFailed = true }
    }
    func receive(_ memo: Memo) {
        guard !draft.isModified, !isSaving, !storageFailed else { return }
        ready = false; draft = Draft(memo: memo); ready = true
    }
    func addImage(data: Data, filename: String, mime: String) {
        guard !isSaving, !storageFailed, let store = app.drafts else { return }
        do {
            guard NSImage(data: data) != nil else { throw MemosError.invalidImage }
            draft.images.append(try store.addImage(data: data, filename: filename, mime: mime))
        } catch { self.error = error.localizedDescription }
    }
    func removeImage(_ image: LocalImage) {
        draft.images.removeAll { $0.id == image.id }
        if !storageFailed { app.drafts?.removeImages([image]) }
    }
    func acknowledgeConflict() {
        guard let conflict else { return }
        draft.originalMemo = conflict
        self.conflict = nil; error = nil
    }
    func save() async {
        guard !isSaving, !storageFailed, app.canWrite, let api = app.api, let store = app.drafts else { return }
        isSaving = true; error = nil; saved = false
        let snapshot = draft
        defer { isSaving = false }
        do {
            let latest = try await api.get(name: key)
            if let original = snapshot.originalMemo,
               (latest.content != original.content || latest.attachments != original.attachments) {
                // Accept a prior save whose response was lost, without treating it as an external edit.
                let intendedIDs = Set(snapshot.existingAttachments.map(\.name) + snapshot.images.map { "attachments/\($0.id)" })
                if latest.content != snapshot.content || Set((latest.attachments ?? []).map(\.name)) != intendedIDs {
                    conflict = latest; throw MemosError.concurrentEdit
                }
            }
            var attachments = snapshot.existingAttachments
            for image in snapshot.images { attachments.append(try await api.upload(image: image, data: store.imageData(image))) }
            let memo = try await api.update(name: key, content: snapshot.content, attachments: attachments)
            try store.remove(key: key)
            ready = false; draft = Draft(memo: memo); ready = true
            store.removeImages(snapshot.images)
            saved = true
            Task { await app.refreshTags(force: true) }
            await app.refresh()
        } catch { self.error = error.localizedDescription }
    }
}
