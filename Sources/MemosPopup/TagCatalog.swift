import Foundation
import MemosCore

@MainActor
final class TagCatalog: ObservableObject {
    @Published private(set) var tags: [String] = []
    private var directory: URL?
    private var generation = UUID()
    private var loading = false
    private var refreshAgain = false
    private var lastAttempt: Date?

    func use(_ store: DraftStore?) {
        generation = UUID(); loading = false; refreshAgain = false; lastAttempt = nil
        directory = store?.directory
        tags = []
        if let file = directory?.appendingPathComponent("tags.json"),
           let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([String].self, from: data) {
            tags = cached
        }
    }

    func refresh(api: MemosAPI, user: String, force: Bool = false) async {
        if loading { if force { refreshAgain = true }; return }
        guard force || lastAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        let requestGeneration = generation
        loading = true; lastAttempt = Date()
        defer {
            if generation == requestGeneration {
                loading = false
                if refreshAgain {
                    refreshAgain = false
                    Task {
                        guard self.generation == requestGeneration else { return }
                        await self.refresh(api: api, user: user, force: true)
                    }
                }
            }
        }
        do {
            let counts = try await api.tagCounts(user: user)
            guard generation == requestGeneration, !Task.isCancelled else { return }
            tags = counts.filter { $0.value > 0 && !$0.key.isEmpty }.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.map(\.key)
            if let file = directory?.appendingPathComponent("tags.json") {
                try JSONEncoder().encode(tags).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        } catch { /* Optional suggestions never block writing; retain the last account-specific cache. */ }
    }
}
