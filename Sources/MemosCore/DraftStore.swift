import Foundation
import CryptoKit

public final class DraftStore {
    public let directory: URL
    public init(root: URL, scope: String) throws {
        let key = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func url(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).json")
    }
    public func load(key: String) throws -> Draft? {
        let file = url(key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do { return try JSONDecoder().decode(Draft.self, from: Data(contentsOf: file)) }
        catch { throw MemosError.draftCorrupted }
    }
    public func save(_ draft: Draft, key: String) throws {
        try JSONEncoder().encode(draft).write(to: url(key), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(key).path)
    }
    public func remove(key: String) throws {
        if FileManager.default.fileExists(atPath: url(key).path) { try FileManager.default.removeItem(at: url(key)) }
    }
    public func addImage(data: Data, filename: String, mime: String) throws -> LocalImage {
        guard data.count <= 20 * 1024 * 1024 else { throw MemosError.imageTooLarge }
        let id = UUID().uuidString.lowercased()
        let image = LocalImage(id: id, filename: filename, mimeType: mime, storedFilename: id)
        let file = imageURL(image)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return image
    }
    public func imageURL(_ image: LocalImage) -> URL {
        directory.appendingPathComponent("images").appendingPathComponent(URL(fileURLWithPath: image.storedFilename).lastPathComponent)
    }
    public func imageData(_ image: LocalImage) throws -> Data { try Data(contentsOf: imageURL(image)) }
    public func removeImages(_ images: [LocalImage]) {
        for image in images { try? FileManager.default.removeItem(at: imageURL(image)) }
    }
}
