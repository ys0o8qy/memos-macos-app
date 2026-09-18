import Foundation

public struct MemosUser: Codable, Equatable, Sendable {
    public let name: String
    public var username: String?
    public var displayName: String?
    public var label: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? username ?? name }
    public init(name: String, username: String? = nil, displayName: String? = nil) {
        self.name = name; self.username = username; self.displayName = displayName
    }
}

public struct Attachment: Codable, Identifiable, Equatable, Sendable {
    public var name: String
    public var filename: String
    public var type: String?
    public var externalLink: String?
    public var id: String { name }
    public var isImage: Bool { type?.hasPrefix("image/") == true }
    public init(name: String, filename: String, type: String? = nil, externalLink: String? = nil) {
        self.name = name; self.filename = filename; self.type = type; self.externalLink = externalLink
    }
}

public struct Memo: Codable, Identifiable, Equatable, Sendable {
    public var name: String
    public var content: String
    public var creator: String?
    public var visibility: String?
    public var createTime: String?
    public var updateTime: String?
    public var attachments: [Attachment]?
    public var tags: [String]?
    public var id: String { name }
    public var date: Date? {
        guard let createTime else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: createTime) ?? ISO8601DateFormatter().date(from: createTime)
    }
    public init(name: String, content: String, creator: String? = nil, visibility: String? = "PRIVATE",
                createTime: String? = nil, updateTime: String? = nil, attachments: [Attachment]? = nil) {
        self.name = name; self.content = content; self.creator = creator; self.visibility = visibility
        self.createTime = createTime; self.updateTime = updateTime; self.attachments = attachments
    }
}

public struct MemoPage: Decodable, Sendable {
    public var memos: [Memo]?
    public var nextPageToken: String?
}

public struct LocalImage: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var filename: String
    public var mimeType: String
    public var storedFilename: String
}

public struct Draft: Codable, Equatable, Sendable {
    public var id = UUID().uuidString.lowercased()
    public var content = ""
    public var images: [LocalImage] = []
    public var existingAttachments: [Attachment] = []
    public var originalMemo: Memo?
    public var hasContent: Bool { !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !existingAttachments.isEmpty }
    public var isModified: Bool {
        guard let originalMemo else { return hasContent }
        return content != originalMemo.content || existingAttachments != (originalMemo.attachments ?? []) || !images.isEmpty
    }
    public init(memo: Memo? = nil) {
        originalMemo = memo
        if let memo { content = memo.content; existingAttachments = memo.attachments ?? [] }
    }
}

public enum MemosError: LocalizedError, Equatable {
    case invalidURL, invalidResponse, http(Int), invalidImage, imageTooLarge, unconfigured, draftCorrupted, concurrentEdit, busy
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的 Memos 服务地址，例如 https://memos.example.com。"
        case .invalidResponse: return "服务器返回了无法识别的数据，请确认服务地址和 Memos 版本（支持 v0.30.0）。"
        case .http(401): return "Token 无效或已过期，请到连接设置中更新。"
        case .http(403): return "当前账号没有操作权限。"
        case .http(404): return "记录或接口不存在，请确认服务地址和 Memos 版本。"
        case .http(413): return "图片超过服务器的上传大小限制。"
        case .http(400): return "服务器未接受这次请求，请检查内容长度、图片大小及 Memos 版本。"
        case .http(let code): return "服务器请求失败（HTTP \(code)），内容已保留，可稍后重试。"
        case .invalidImage: return "无法读取这张图片，请使用 PNG、JPEG、GIF、WebP、HEIC 或 TIFF。"
        case .imageTooLarge: return "单张图片不能超过 20 MB。"
        case .unconfigured: return "请先连接你的 Memos 服务。"
        case .busy: return "正在保存或验证连接，请完成后再切换服务。"
        case .draftCorrupted: return "本地草稿无法读取。原文件已保留，请备份草稿目录后检查。"
        case .concurrentEdit: return "这条记录已在其他客户端修改。你的草稿已保留，请对照最新内容后再保存。"
        }
    }
}
