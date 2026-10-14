import AppKit
import SwiftUI
import MemosCore

extension NSAttributedString.Key {
    static let memoCode = NSAttributedString.Key("MemosCodeBlock")
}

/// One text storage for the entire document: selection, copy and find must cross block boundaries.
@MainActor
struct ReadingTextRenderer {
    var width: CGFloat = 640
    var images: [String: NSImage] = [:]
    var baseURL: URL?
    let output = NSMutableAttributedString(string: "")

    func render(_ blocks: [ReadingBlock]) -> NSAttributedString {
        append(blocks)
        return output
    }

    private func paragraph(indent: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        style.paragraphSpacing = 14
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }

    private func inline(_ text: AttributedString, font: NSFont, color: NSColor = .labelColor) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in text.runs {
            let value = String(text[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var face = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) : font
            if intent.contains(.stronglyEmphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: color]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if intent.contains(.code) { attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12) }
            if let url = run.link { attributes[.link] = url }
            result.append(NSAttributedString(string: value, attributes: attributes))
        }
        return result
    }

    private func add(_ text: NSMutableAttributedString, style: NSParagraphStyle) {
        text.append(NSAttributedString(string: "\n"))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        output.append(text)
    }

    private func append(_ blocks: [ReadingBlock], indent: CGFloat = 0, quoted: Bool = false) {
        let font = NSFont.systemFont(ofSize: 15)
        let color: NSColor = quoted ? .secondaryLabelColor : .labelColor
        for block in blocks {
            switch block {
            case .paragraph(let text): add(inline(text, font: font, color: color), style: paragraph(indent: indent))
            case .heading(let level, let text):
                let sizes: [CGFloat] = [28, 23, 19, 17, 16, 15]
                let style = paragraph(indent: indent)
                style.paragraphSpacingBefore = 8
                add(inline(text, font: .systemFont(ofSize: sizes[min(max(level, 1), 6) - 1], weight: .semibold)), style: style)
            case .quote(let children):
                let start = output.length
                append(children, indent: indent + 16, quoted: true)
                let range = NSRange(location: start, length: output.length - start)
                let box = NSTextBlock()
                box.setValue(100, type: .percentageValueType, for: .width)
                box.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                box.setBorderColor(.systemTeal, for: .minX)
                output.enumerateAttribute(.paragraphStyle, in: range) { value, range, _ in
                    let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? paragraph(indent: indent + 16)
                    style.textBlocks = style.textBlocks + [box]
                    output.addAttribute(.paragraphStyle, value: style, range: range)
                }
            case .list(let items):
                for (marker, children) in items {
                    let start = output.length
                    append(children, indent: indent + 26, quoted: quoted)
                    if output.length == start { add(NSMutableAttributedString(string: ""), style: paragraph(indent: indent + 26)) }
                    let style = (output.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? paragraph()
                    style.firstLineHeadIndent = indent
                    style.headIndent = indent + 26
                    style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 26)]
                    let first = (output.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
                    output.addAttribute(.paragraphStyle, value: style, range: first)
                    output.insert(NSAttributedString(string: marker + "\t", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]), at: start)
                }
            case .code(let code, _):
                let text = NSMutableAttributedString(string: code.hasSuffix("\n") ? String(code.dropLast()) : code,
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor, .memoCode: code])
                let style = paragraph(indent: indent)
                style.lineSpacing = 4
                style.paragraphSpacing = 0
                style.lineBreakMode = .byCharWrapping
                let box = NSTextBlock()
                box.setValue(100, type: .percentageValueType, for: .width)
                box.backgroundColor = .quaternaryLabelColor.withAlphaComponent(0.10)
                box.setWidth(12, type: .absoluteValueType, for: .padding)
                style.textBlocks = [box]
                add(text, style: style)
                let gap = NSMutableParagraphStyle()
                gap.minimumLineHeight = 12
                gap.maximumLineHeight = 12
                add(NSMutableAttributedString(string: ""), style: gap)
            case .table(let rows, let alignments):
                let table = NSTextTable()
                table.numberOfColumns = rows.map(\.count).max() ?? 1
                table.layoutAlgorithm = .fixedLayoutAlgorithm
                table.collapsesBorders = true
                table.setValue(100, type: .percentageValueType, for: .width)
                for (rowIndex, row) in rows.enumerated() {
                    for (column, cell) in row.enumerated() {
                        let box = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                        box.setValue(100 / CGFloat(table.numberOfColumns), type: .percentageValueType, for: .width)
                        box.setWidth(9, type: .absoluteValueType, for: .padding)
                        box.setWidth(0.5, type: .absoluteValueType, for: .border)
                        box.setBorderColor(.separatorColor)
                        if rowIndex == 0 { box.backgroundColor = .quaternaryLabelColor.withAlphaComponent(0.10) }
                        let style = paragraph()
                        style.paragraphSpacing = 0
                        if column < alignments.count {
                            switch alignments[column] { case .right: style.alignment = .right; case .center: style.alignment = .center; default: break }
                        }
                        style.textBlocks = [box]
                        add(inline(cell, font: .systemFont(ofSize: 14, weight: rowIndex == 0 ? .semibold : .regular)), style: style)
                    }
                }
                add(NSMutableAttributedString(string: ""), style: paragraph())
            case .image(let source, let label):
                let attachment = NSTextAttachment()
                let image = images[source] ?? NSImage(systemSymbolName: "photo", accessibilityDescription: label)
                attachment.image = image
                let size = image?.size ?? NSSize(width: 80, height: 40)
                let scale = min(1, min(max(80, width - indent) / max(size.width, 1), 420 / max(size.height, 1)))
                attachment.bounds = NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
                add(NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment)), style: paragraph(indent: indent))
                var caption = AttributedString(label.isEmpty ? "查看图片" : label)
                if let url = URL(string: source, relativeTo: baseURL)?.absoluteURL,
                   ReadingDocument.safeLink(url.absoluteString) != nil { caption.link = url }
                add(inline(caption, font: .systemFont(ofSize: 12), color: .secondaryLabelColor), style: paragraph(indent: indent))
            case .rule:
                add(NSMutableAttributedString(string: "────────────", attributes: [.font: font, .foregroundColor: NSColor.separatorColor]), style: paragraph(indent: indent))
            }
        }
    }
}

final class ReadingTextView: NSTextView {
    var active = true
    var copyPasteboard: NSPasteboard = .general
    var markdown = ""
    var copyCode: String?
    var onEscape: () -> Void = {}

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0, let storage = textStorage else { return }
        copyPasteboard.clearContents()
        copyPasteboard.setString((string as NSString).substring(with: selection), forType: .string)
        if let data = try? storage.data(from: selection, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            copyPasteboard.setData(data, forType: .rtf)
        }
    }
    @objc func copyMarkdown(_ sender: Any?) {
        copyPasteboard.clearContents()
        copyPasteboard.setString(markdown, forType: .string)
    }
    @objc func copyCodeBlock(_ sender: Any?) {
        guard let copyCode else { return }
        copyPasteboard.clearContents()
        copyPasteboard.setString(copyCode, forType: .string)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        copyCode = index < (textStorage?.length ?? 0) ? textStorage?.attribute(.memoCode, at: index, effectiveRange: nil) as? String : nil
        menu.addItem(.separator())
        if copyCode != nil { menu.addItem(withTitle: "复制代码块", action: #selector(copyCodeBlock(_:)), keyEquivalent: "").target = self }
        menu.addItem(withTitle: "复制整篇 Markdown", action: #selector(copyMarkdown(_:)), keyEquivalent: "").target = self
        return menu
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard active, !isHiddenOrHasHiddenAncestor else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": selectAll(nil); return true
            case "c": copy(nil); return true
            default: break
            }
        }
        if NativeTextActions.handleFind(event, in: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if enclosingScrollView?.isFindBarVisible == true { NativeTextActions.find(.hideFindInterface, in: self) }
        else { onEscape() }
    }
}

@MainActor
enum NativeTextActions {
    static func find(_ action: NSTextFinder.Action, in view: NSTextView) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        view.performFindPanelAction(item)
    }
    static func handleFind(_ event: NSEvent, in view: NSTextView) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "f" {
            find(.showFindInterface, in: view); return true
        }
        if (modifiers == .command || modifiers == [.command, .shift]) && event.charactersIgnoringModifiers?.lowercased() == "g" {
            find(modifiers.contains(.shift) ? .previousMatch : .nextMatch, in: view); return true
        }
        return false
    }
}

final class ReadingScrollView: NSScrollView {
    var onWidthChange: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = 0
    override func layout() {
        super.layout()
        guard let view = documentView as? ReadingTextView, let container = view.textContainer else { return }
        let viewport = contentSize
        let inset = max(24, (viewport.width - 680) / 2)
        view.textContainerInset = NSSize(width: inset, height: 24)
        view.minSize = NSSize(width: 0, height: viewport.height)
        view.setFrameSize(NSSize(width: viewport.width, height: max(view.frame.height, viewport.height)))
        let width = max(1, viewport.width - 2 * inset)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if abs(lastWidth - width) > 1 { lastWidth = width; onWidthChange?(width) }
        view.layoutManager?.ensureLayout(for: container)
        let height = (view.layoutManager?.usedRect(for: container).height ?? 0) + 48
        view.setFrameSize(NSSize(width: viewport.width, height: max(viewport.height, height)))
    }
}

struct MarkdownPreview: NSViewRepresentable {
    var content: String
    var api: MemosAPI? = nil
    var attachments: [Attachment] = []
    var active = true
    var onEscape: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ReadingScrollView {
        let scroll = ReadingScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.findBarPosition = .aboveContent
        let view = ReadingTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.allowsUndo = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.linkTextAttributes = [.foregroundColor: NSColor.systemBlue, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.setAccessibilityLabel("记录正文")
        scroll.documentView = view
        context.coordinator.view = view
        scroll.onWidthChange = { [weak coordinator = context.coordinator] width in coordinator?.width = width; coordinator?.render() }
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: ReadingScrollView, context: Context) {
        guard let view = scroll.documentView as? ReadingTextView else { return }
        let coordinator = context.coordinator
        view.onEscape = onEscape
        view.active = active
        if !active {
            DispatchQueue.main.async { [weak view] in
                guard let view, !view.active, view.window?.firstResponder === view else { return }
                view.window?.makeFirstResponder(nil)
            }
        }
        if active && (content != coordinator.source || coordinator.account != api?.baseURL.absoluteString || coordinator.attachments != attachments) {
            coordinator.update(content: content, api: api, attachments: attachments)
        }
        if active && !coordinator.wasActive {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.active else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        coordinator.wasActive = active
    }
    static func dismantleNSView(_ scroll: ReadingScrollView, coordinator: Coordinator) { coordinator.task?.cancel() }

    @MainActor final class Coordinator {
        weak var view: ReadingTextView?
        var source: String?
        var account: String?
        var attachments: [Attachment] = []
        var blocks: [ReadingBlock] = []
        var images: [String: NSImage] = [:]
        var width: CGFloat = 640
        var baseURL: URL?
        var task: Task<Void, Never>?
        var wasActive = false
        func update(content: String, api: MemosAPI?, attachments: [Attachment]) {
            task?.cancel()
            source = content; account = api?.baseURL.absoluteString; baseURL = api?.baseURL; self.attachments = attachments
            images = [:]
            blocks = ReadingDocument(content).blocks
            view?.markdown = content
            render()
            let sources = Self.imageSources(blocks)
            task = Task { [weak self] in
                for source in sources {
                    guard !Task.isCancelled else { return }
                    guard let url = URL(string: source, relativeTo: api?.baseURL)?.absoluteURL,
                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { continue }
                    do {
                        let attachment = attachments.first { item in
                            let id = item.name.split(separator: "/").last.map(String.init) ?? ""
                            return !id.isEmpty && url.path.contains("/file/attachments/\(id)/")
                        }
                        let data: Data
                        if let api, let attachment { data = try await api.imageData(attachment) }
                        else {
                            let session = URLSession(configuration: .ephemeral)
                            defer { session.finishTasksAndInvalidate() }
                            let (bytes, response) = try await session.data(from: url)
                            guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count <= 20 * 1024 * 1024 else { continue }
                            data = bytes
                        }
                        guard !Task.isCancelled, let self else { return }
                        if let image = NSImage(data: data) { self.images[source] = image; self.render() }
                    } catch { /* The caption remains an accessible link if loading fails. */ }
                }
            }
        }
        func render() {
            guard let view else { return }
            let selection = view.selectedRange()
            let origin = view.enclosingScrollView?.contentView.bounds.origin
            let text = ReadingTextRenderer(width: width, images: images, baseURL: baseURL).render(blocks)
            view.textStorage?.setAttributedString(text)
            let start = min(selection.location, text.length)
            view.setSelectedRange(NSRange(location: start, length: min(selection.length, text.length - start)))
            view.enclosingScrollView?.needsLayout = true
            if let origin { view.enclosingScrollView?.contentView.scroll(to: origin) }
        }
        static func imageSources(_ blocks: [ReadingBlock]) -> [String] {
            blocks.flatMap { block in
                switch block {
                case .image(let source, _): return [source]
                case .quote(let children): return imageSources(children)
                case .list(let items): return items.flatMap { imageSources($0.1) }
                default: return []
                }
            }
        }
    }
}
