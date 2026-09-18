import AppKit
import SwiftUI

struct TagQuery: Equatable {
    var range: NSRange
    var prefix: String
    private static let pattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_/#\\])#([\p{L}\p{M}\p{N}_/\-]*)"#)

    static func at(_ selection: NSRange, in text: String) -> TagQuery? {
        let string = text as NSString
        guard selection.length == 0, selection.location > 0, selection.location <= string.length else { return nil }
        let before = string.substring(to: selection.location)
        // Keep suggestions out of code, escaped hashes, URL fragments and Markdown headings.
        let fences = before.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("~~~")
        }.count
        guard fences % 2 == 0, (before.components(separatedBy: "\n").last ?? "").filter({ $0 == "`" }).count % 2 == 0 else { return nil }
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let body = match.range(at: 1)
            if selection.location >= body.location && selection.location <= NSMaxRange(body) {
                return TagQuery(range: match.range, prefix: string.substring(with:
                    NSRange(location: body.location, length: selection.location - body.location)))
            }
        }
        return nil
    }
}

@MainActor
final class TagCompletionController: ObservableObject {
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var selected = 0
    var tags: [String] = []
    private weak var editor: ImageTextView?
    private var query: TagQuery?
    private var dismissed: TagQuery?

    func update(in editor: ImageTextView) {
        self.editor = editor
        guard editor.isEditable, !editor.hasMarkedText(),
              let next = TagQuery.at(editor.selectedRange(), in: editor.string) else {
            hide(); dismissed = nil; return
        }
        guard next != dismissed else { return }
        let matches = Array(tags.filter { next.prefix.isEmpty || $0.localizedLowercase.hasPrefix(next.prefix.localizedLowercase) }.prefix(5))
        if next != query || suggestions != matches {
            query = next; suggestions = matches; selected = 0; dismissed = nil
        }
    }
    func hide() {
        if !suggestions.isEmpty { suggestions = [] }
        query = nil
        if selected != 0 { selected = 0 }
    }
    func dismiss() { dismissed = query; hide() }
    func choose(_ index: Int) {
        guard let editor, editor.isEditable, !editor.hasMarkedText(), suggestions.indices.contains(index),
              let query, query == TagQuery.at(editor.selectedRange(), in: editor.string) else { hide(); return }
        let tag = suggestions[index]
        hide()
        editor.window?.makeFirstResponder(editor)
        let string = editor.string as NSString
        let end = NSMaxRange(query.range)
        let hasFollowingSpace = end < string.length && UnicodeScalar(string.character(at: end)).map { CharacterSet.whitespacesAndNewlines.contains($0) } == true
        editor.insertText("#" + tag + (hasFollowingSpace ? "" : " "), replacementRange: query.range)
        dismissed = TagQuery.at(editor.selectedRange(), in: editor.string)
        hide()
    }
    func handle(_ event: NSEvent, in editor: ImageTextView) -> Bool {
        guard editor.isEditable, !editor.hasMarkedText(), !suggestions.isEmpty,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 125: selected = (selected + 1) % suggestions.count
        case 126: selected = (selected + suggestions.count - 1) % suggestions.count
        case 36, 48: choose(selected)
        case 53: dismiss()
        default: return false
        }
        return true
    }
}

struct TagSuggestions: View {
    @ObservedObject var controller: TagCompletionController
    var body: some View {
        if !controller.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(controller.suggestions.enumerated()), id: \.offset) { index, tag in
                    Button { controller.choose(index) } label: {
                        Text("#" + tag).font(.callout).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(index == controller.selected ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).accessibilityLabel("补全标签 " + tag)
                }
                Text("↑ ↓ 选择 · Enter / Tab 补全 · Esc 关闭候选").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 3)
            }
        }
    }
}

struct TaggedMarkdownEditor: View {
    @Binding var text: String
    @ObservedObject var catalog: TagCatalog
    var enabled = true
    var autofocus = false
    var height: CGFloat? = nil
    var onImage: (Data, String, String) -> Void
    var onError: (String) -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void = {}
    @StateObject private var completion = TagCompletionController()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownEditor(text: $text, enabled: enabled, autofocus: autofocus,
                completion: completion, tags: catalog.tags, onImage: onImage, onError: onError,
                onSubmit: onSubmit, onEscape: onEscape)
                .frame(height: height)
            TagSuggestions(controller: completion)
        }.onDisappear { completion.dismiss() }
    }
}
