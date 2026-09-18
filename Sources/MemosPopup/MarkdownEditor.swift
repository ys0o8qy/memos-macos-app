import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MemosCore

@MainActor
enum ImageImport {
    static func file(_ url: URL, receive: (Data, String, String) -> Void, fail: (String) -> Void) {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20 * 1024 * 1024 else { throw MemosError.imageTooLarge }
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let mime = type.preferredMIMEType else { throw MemosError.invalidImage }
            let data = try Data(contentsOf: url)
            guard NSImage(data: data) != nil else { throw MemosError.invalidImage }
            receive(data, url.lastPathComponent, mime)
        } catch { fail(error.localizedDescription) }
    }

    static func pasteboard(_ board: NSPasteboard, receive: (Data, String, String) -> Void, fail: (String) -> Void) -> Bool {
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            for url in files { file(url, receive: receive, fail: fail) }
            return true
        }
        if let data = board.data(forType: .png) { receive(data, "粘贴图片.png", "image/png"); return true }
        if let data = board.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            receive(png, "粘贴图片.png", "image/png"); return true
        }
        // Some browsers and image apps offer JPEG/HEIC or an NSImage representation,
        // without public.png / public.tiff on the pasteboard.
        if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            receive(png, "粘贴图片.png", "image/png"); return true
        }
        return false
    }

    static func choose(receive: @escaping (Data, String, String) -> Void, fail: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加图片"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { for url in panel.urls { file(url, receive: receive, fail: fail) } }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

final class ImageTextView: NSTextView {
    // Kept injectable so tests exercise the actual paste command using an isolated pasteboard.
    var imagePasteboard: NSPasteboard = .general
    var receiveImage: ((Data, String, String) -> Void)?
    var onError: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    weak var tagCompletion: TagCompletionController?
    override func keyDown(with event: NSEvent) {
        if tagCompletion?.handle(event, in: self) == true { return }
        super.keyDown(with: event)
        tagCompletion?.update(in: self)
    }
    override func didChangeText() {
        super.didChangeText()
        tagCompletion?.update(in: self)
    }
    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if ImageImport.pasteboard(imagePasteboard, receive: { [weak self] in self?.receiveImage?($0, $1, $2) }, fail: { [weak self] in self?.onError?($0) }) { return }
        super.pasteAsPlainText(sender)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(nil)
            return true
        }
        if modifiers == .command && event.keyCode == 36 {
            if !hasMarkedText() { onSubmit?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) }
        else if let tagCompletion, !tagCompletion.suggestions.isEmpty { tagCompletion.dismiss() }
        else { onEscape?() }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        if sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil { return .copy }
        return super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        if ImageImport.pasteboard(sender.draggingPasteboard, receive: { [weak self] in self?.receiveImage?($0, $1, $2) }, fail: { [weak self] in self?.onError?($0) }) { return true }
        return super.performDragOperation(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
}

final class EditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView else { return }
        // An empty NSTextView initialized with .zero can focus but clip its insertion caret.
        // Keep the document at least as tall as the viewport, while allowing longer text to scroll.
        let viewport = contentSize
        editor.minSize = NSSize(width: 0, height: viewport.height)
        if editor.frame.width != viewport.width || editor.frame.height < viewport.height {
            editor.setFrameSize(NSSize(width: viewport.width, height: max(editor.frame.height, viewport.height)))
        }
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var enabled = true
    var autofocus = false
    var completion: TagCompletionController? = nil
    var tags: [String] = []
    var onImage: (Data, String, String) -> Void
    var onError: (String) -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EditorScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = ImageTextView(frame: .zero)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 12, height: 14)
        view.font = .systemFont(ofSize: 15)
        view.textColor = .labelColor
        view.insertionPointColor = .controlAccentColor
        view.isSelectable = true
        view.drawsBackground = false
        view.setAccessibilityLabel("记录内容")
        view.delegate = context.coordinator
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = view
        update(view, context: context)
        if autofocus { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ImageTextView else { return }
        context.coordinator.parent = self
        update(view, context: context)
    }
    private func update(_ view: ImageTextView, context: Context) {
        if view.string != text && !view.hasMarkedText() { view.string = text }
        view.isEditable = enabled
        view.receiveImage = onImage; view.onError = onError; view.onSubmit = onSubmit; view.onEscape = onEscape
        view.tagCompletion = completion
        completion?.tags = tags
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            if view.window?.firstResponder === view { view.tagCompletion?.update(in: view) }
            else { view.tagCompletion?.hide() }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        init(_ parent: MarkdownEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? ImageTextView else { return }
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window?.firstResponder === view else { return }
                view.tagCompletion?.update(in: view)
            }
        }
    }
}
