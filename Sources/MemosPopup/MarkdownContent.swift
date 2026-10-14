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
            result.inlinePresentationIntent = .code
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
