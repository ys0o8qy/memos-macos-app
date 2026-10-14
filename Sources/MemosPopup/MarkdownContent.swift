import SwiftUI
import Markdown
import MemosCore

/// Parse whole documents so Markdown block boundaries survive wrapping and blank lines.
indirect enum ReadingBlock {
    case paragraph(AttributedString)
    case heading(Int, AttributedString)
    case quote([ReadingBlock])
    case list([(String, [ReadingBlock])])
    case code(String, String?)
    case table([[AttributedString]], [Markdown.Table.ColumnAlignment?])
    case image(String, String)
    case rule
}

struct ReadingDocument {
    let blocks: [ReadingBlock]
    let title: String
    let summary: String

    init(_ source: String) {
        let document = Document(parsing: source)
        blocks = Self.blocks(in: document)
        let lines = document.children.map { Self.plain($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        title = lines.first?.components(separatedBy: .newlines).first ?? "图片记录"
        summary = lines.dropFirst().joined(separator: " ")
    }

    static func plain(_ node: Markup) -> String {
        switch node {
        case let text as Markdown.Text: return text.string
        case let code as InlineCode: return code.code
        case let code as CodeBlock: return code.code
        case is SoftBreak, is LineBreak: return "\n"
        case let html as InlineHTML: return html.rawHTML
        case let html as HTMLBlock: return html.rawHTML
        default:
            let separator = node is ListItemContainer || node is ListItem ? " " : ""
            return node.children.map { plain($0) }.joined(separator: separator)
        }
    }

    static func safeLink(_ destination: String?) -> URL? {
        guard let destination, let url = URL(string: destination),
              ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func inline(_ node: Markup) -> AttributedString {
        var result: AttributedString
        switch node {
        case let text as Markdown.Text: return AttributedString(text.string)
        case let code as InlineCode:
            result = AttributedString(code.code)
            result.font = .system(size: 14, design: .monospaced)
            result.backgroundColor = Color.secondary.opacity(0.10)
            return result
        case is SoftBreak: return AttributedString(" ")
        case is LineBreak: return AttributedString("\n")
        case let html as InlineHTML: return AttributedString(html.rawHTML)
        default: result = node.children.reduce(into: AttributedString()) { $0 += inline($1) }
        }
        if node is Strong || node is Emphasis || node is Strikethrough {
            // Add to existing runs to retain nested bold + italic + strike combinations.
            for run in Array(result.runs) {
                var intent = run.inlinePresentationIntent ?? []
                if node is Strong { intent.insert(.stronglyEmphasized) }
                if node is Emphasis { intent.insert(.emphasized) }
                if node is Strikethrough { intent.insert(.strikethrough) }
                result[run.range].inlinePresentationIntent = intent
            }
        }
        if let link = node as? Markdown.Link, let url = safeLink(link.destination) { result.link = url }
        return result
    }

    private static func blocks(in node: Markup) -> [ReadingBlock] {
        node.children.flatMap { block($0) }
    }
    private static func block(_ node: Markup) -> [ReadingBlock] {
        switch node {
        case let heading as Heading: return [.heading(heading.level, inline(heading))]
        case let paragraph as Paragraph:
            var output: [ReadingBlock] = []
            var text = AttributedString()
            for child in paragraph.children {
                if let image = child as? Markdown.Image {
                    if !text.characters.isEmpty { output.append(.paragraph(text)); text = AttributedString() }
                    output.append(.image(image.source ?? "", plain(image)))
                } else { text += inline(child) }
            }
            if !text.characters.isEmpty { output.append(.paragraph(text)) }
            return output
        case let code as CodeBlock: return [.code(code.code, code.language)]
        case let quote as BlockQuote: return [.quote(blocks(in: quote))]
        case let list as OrderedList: return [.list(items(list, start: Int(list.startIndex)))]
        case let list as UnorderedList: return [.list(items(list, start: nil))]
        case let table as Markdown.Table:
            let rows = [Array(table.head.children).map(inline)] + table.body.children.map { $0.children.map(inline) }
            return [.table(rows, table.columnAlignments)]
        case is ThematicBreak: return [.rule]
        case let html as HTMLBlock: return [.code(html.rawHTML, "HTML")]
        default: return blocks(in: node)
        }
    }
    private static func items(_ list: Markup, start: Int?) -> [(String, [ReadingBlock])] {
        list.children.enumerated().map { index, child in
            let checkbox = (child as? ListItem)?.checkbox
            let marker = checkbox.map { $0 == .checked ? "☑" : "☐" } ?? start.map { "\($0 + index)." } ?? "•"
            return (marker, blocks(in: child))
        }
    }
}

struct MarkdownPreview: View {
    private let document: ReadingDocument
    var api: MemosAPI?
    var attachments: [Attachment]
    init(content: String, api: MemosAPI? = nil, attachments: [Attachment] = []) {
        document = ReadingDocument(content)
        self.api = api
        self.attachments = attachments
    }
    var body: some View {
        ReadingBlocks(blocks: document.blocks, api: api, attachments: attachments)
            .font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).tint(Theme.accent)
    }
}

private struct ReadingBlocks: View {
    let blocks: [ReadingBlock]
    let api: MemosAPI?
    let attachments: [Attachment]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(blocks.indices, id: \.self) { index in block(blocks[index]) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    // Erasure is limited to the recursive document boundary.
    private func block(_ block: ReadingBlock) -> AnyView {
        switch block {
        case .paragraph(let text):
            return AnyView(SwiftUI.Text(text).fixedSize(horizontal: false, vertical: true))
        case .heading(let level, let text):
            return AnyView(SwiftUI.Text(text).font(.system(size: [28.0, 23, 19, 17, 16, 15][min(max(level, 1), 6) - 1], weight: .semibold))
                .lineSpacing(3).padding(.top, 8).fixedSize(horizontal: false, vertical: true))
        case .quote(let children):
            return AnyView(HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.5)).frame(width: 3)
                ReadingBlocks(blocks: children, api: api, attachments: attachments).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4))
        case .list(let items):
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        SwiftUI.Text(items[index].0).foregroundStyle(.secondary).frame(minWidth: 20, alignment: .trailing)
                        ReadingBlocks(blocks: items[index].1, api: api, attachments: attachments)
                    }
                }
            })
        case .code(let code, let language): return AnyView(CodeReadingBlock(code: code, language: language))
        case .table(let rows, let alignments):
            return AnyView(ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { column in
                                SwiftUI.Text(rows[row][column]).fontWeight(row == 0 ? .semibold : .regular)
                                    .frame(minWidth: 100, maxWidth: 220, alignment: alignment(alignments, column))
                                    .padding(12).background(row == 0 ? Theme.field : Theme.paper)
                                    .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
                            }
                        }
                    }
                }.fixedSize(horizontal: true, vertical: false)
            }.clipShape(RoundedRectangle(cornerRadius: 6)))
        case .image(let source, let label):
            return AnyView(MarkdownImage(source: source, label: label, api: api, attachments: attachments))
        case .rule: return AnyView(Divider().padding(.vertical, 8))
        }
    }
    private func alignment(_ values: [Markdown.Table.ColumnAlignment?], _ index: Int) -> Alignment {
        guard index < values.count else { return .leading }
        switch values[index] { case .center: return .center; case .right: return .trailing; default: return .leading }
    }
}

private struct CodeReadingBlock: View {
    let code: String
    let language: String?
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SwiftUI.Text(language?.isEmpty == false ? language! : "代码").foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "已复制" : "复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }.buttonStyle(.plain).accessibilityLabel("复制代码")
            }.font(.caption)
            ScrollView(.horizontal) {
                SwiftUI.Text(code.hasSuffix("\n") ? String(code.dropLast()) : code)
                    .font(.system(size: 13, design: .monospaced)).lineSpacing(4).fixedSize()
            }
        }.padding(16).background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MarkdownImage: View {
    let source: String
    let label: String
    let api: MemosAPI?
    let attachments: [Attachment]
    @State private var image: NSImage?
    @State private var failed = false
    private var url: URL? {
        guard let url = URL(string: source, relativeTo: api?.baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
        return url
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image { SwiftUI.Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 420).clipShape(RoundedRectangle(cornerRadius: 6)) }
            else if failed || url == nil {
                Label(label.isEmpty ? "图片无法加载" : label, systemImage: "photo")
                if let url { Link("在浏览器中查看图片", destination: url).font(.caption) }
            } else { ProgressView().controlSize(.small).frame(height: 80) }
        }.task(id: source) {
            image = nil; failed = false
            guard let url else { return }
            do {
                let attachment = attachments.first { item in
                    let id = item.name.split(separator: "/").last.map(String.init) ?? ""
                    return !id.isEmpty && url.path.contains("/file/attachments/\(id)/")
                }
                let data: Data
                if let attachment, let api { data = try await api.imageData(attachment) }
                else {
                    // External images use an ephemeral, unauthenticated request.
                    let session = URLSession(configuration: .ephemeral)
                    defer { session.finishTasksAndInvalidate() }
                    let (bytes, response) = try await session.data(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count <= 20 * 1024 * 1024 else { throw MemosError.invalidImage }
                    data = bytes
                }
                guard !Task.isCancelled else { return }
                image = NSImage(data: data); failed = image == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
