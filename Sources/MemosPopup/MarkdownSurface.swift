import SwiftUI
import MemosCore

/// Keep both native text views alive so previewing does not discard selection, scroll or undo.
struct MarkdownSurface: View {
    @Binding var text: String
    var catalog: TagCatalog
    var editing: Bool
    var enabled = true
    var editorInsets = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    var placeholder = ""
    var api: MemosAPI? = nil
    var attachments: [Attachment] = []
    var onImage: (Data, String, String) -> Void
    var onError: (String) -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder).font(.system(size: 15)).foregroundStyle(.tertiary)
                        .padding(.leading, 17).padding(.top, 14).allowsHitTesting(false)
                }
                TaggedMarkdownEditor(text: $text, catalog: catalog, enabled: enabled,
                    autofocus: true, active: editing, onImage: onImage, onError: onError,
                    onSubmit: onSubmit, onEscape: onEscape)
            }.padding(editorInsets)
                .opacity(editing ? 1 : 0).allowsHitTesting(editing).accessibilityHidden(!editing)
            MarkdownPreview(content: text, api: api, attachments: attachments, active: !editing, onEscape: onEscape)
                .opacity(editing ? 0 : 1).allowsHitTesting(!editing).accessibilityHidden(editing)
        }.frame(minHeight: 120, maxHeight: .infinity)
    }
}
