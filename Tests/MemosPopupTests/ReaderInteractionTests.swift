import XCTest
import SwiftUI
@testable import MemosPopup

final class ReaderInteractionTests: XCTestCase {
    @MainActor private func host<V: View>(_ root: V, size: NSSize = NSSize(width: 540, height: 360)) -> (NSWindow, NSHostingView<V>) {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: root)
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        settle(view)
        return (window, view)
    }

    @MainActor private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        view.layoutSubtreeIfNeeded()
    }

    @MainActor private func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
    }

    @MainActor private func key(_ characters: String, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    @MainActor func testSelectionAndCopyCrossHeadingsListsCodeAndTables() throws {
        let (window, host) = host(MarkdownPreview(content: ReadingTests.sample))
        defer { window.contentView = nil }
        let readers = descendants(host, ReadingTextView.self)
        XCTAssertEqual(readers.count, 1)
        let reader = try XCTUnwrap(readers.first)
        XCTAssertTrue(window.makeFirstResponder(reader))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        reader.copyPasteboard = board
        let text = reader.string as NSString
        let start = text.range(of: "阅读笔记").location
        let end = NSMaxRange(text.range(of: "待办"))
        let selection = NSRange(location: start, length: end - start)
        reader.setSelectedRange(selection)
        XCTAssertTrue(reader.performKeyEquivalent(with: key("c")))
        XCTAssertEqual(board.string(forType: .string), text.substring(with: selection))
        XCTAssertTrue(board.string(forType: .string)?.contains("print(thought)") == true)
        XCTAssertNotNil(board.data(forType: .rtf))
        XCTAssertTrue(reader.performKeyEquivalent(with: key("a")))
        XCTAssertEqual(reader.selectedRange(), NSRange(location: 0, length: text.length))
        XCTAssertTrue(NSApp.sendAction(#selector(NSTextView.copy(_:)), to: window.firstResponder, from: reader))
        XCTAssertEqual(board.string(forType: .string), reader.string)
        XCTAssertFalse(reader.isEditable)
        reader.setSelectedRange(NSRange(location: 0, length: 0))
        for _ in 0..<8 { reader.moveDownAndModifySelection(nil) }
        XCTAssertGreaterThan(reader.selectedRange().length, text.range(of: "让记录").location)
    }

    @MainActor func testReaderFindBarAndEscapeHaveLocalScope() throws {
        var escaped = false
        let (window, host) = host(MarkdownPreview(content: ReadingTests.sample, onEscape: { escaped = true }))
        defer { window.contentView = nil }
        let reader = try XCTUnwrap(descendants(host, ReadingTextView.self).first)
        window.makeFirstResponder(reader)
        XCTAssertTrue(reader.performKeyEquivalent(with: key("f")))
        settle(host)
        XCTAssertEqual(reader.enclosingScrollView?.isFindBarVisible, true)
        reader.cancelOperation(nil)
        XCTAssertEqual(reader.enclosingScrollView?.isFindBarVisible, false)
        XCTAssertFalse(escaped)
        reader.cancelOperation(nil)
        XCTAssertTrue(escaped)
    }

    @MainActor func testCodeAndMarkdownCopyPreserveSource() throws {
        let source = "# 标题\n\n```swift\nlet a = 1\nprint(a)\n```"
        let (window, host) = host(MarkdownPreview(content: source))
        defer { window.contentView = nil }
        let reader = try XCTUnwrap(descendants(host, ReadingTextView.self).first)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        reader.copyPasteboard = board
        reader.copyMarkdown(nil)
        XCTAssertEqual(board.string(forType: .string), source)
        let index = (reader.string as NSString).range(of: "let a").location
        let manager = try XCTUnwrap(reader.layoutManager)
        let container = try XCTUnwrap(reader.textContainer)
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil), in: container)
        let point = reader.convert(NSPoint(x: rect.midX + reader.textContainerOrigin.x, y: rect.midY + reader.textContainerOrigin.y), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(reader.menu(for: event))
        let item = try XCTUnwrap(menu.items.first { $0.title == "复制代码块" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(board.string(forType: .string), "let a = 1\nprint(a)\n")
    }

    @MainActor func testQuoteCodeAndTableHaveUsableWidthAndDocumentScrolls() throws {
        let (window, host) = host(MarkdownPreview(content: ReadingTests.sample), size: NSSize(width: 440, height: 300))
        defer { window.contentView = nil }
        let reader = try XCTUnwrap(descendants(host, ReadingTextView.self).first)
        let manager = try XCTUnwrap(reader.layoutManager)
        let container = try XCTUnwrap(reader.textContainer)
        manager.ensureLayout(for: container)
        for word in ["不必记下", "let thought", "内容"] {
            let range = (reader.string as NSString).range(of: word)
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            XCTAssertGreaterThan(rect.width, word == "内容" ? 80 : 280, word)
        }
        XCTAssertGreaterThan(reader.frame.height, 300)
        reader.scrollRangeToVisible(NSRange(location: (reader.string as NSString).length - 1, length: 0))
        XCTAssertGreaterThan(reader.enclosingScrollView?.contentView.bounds.minY ?? 0, 0)
    }

    @MainActor func testPreviewRoundTripKeepsEditorSelectionScrollAndUndo() throws {
        var text = String(repeating: "一段可编辑的内容\n", count: 40)
        let binding = Binding(get: { text }, set: { text = $0 })
        let catalog = TagCatalog()
        func surface(_ editing: Bool) -> MarkdownSurface {
            MarkdownSurface(text: binding, catalog: catalog, editing: editing,
                onImage: { _, _, _ in }, onError: { _ in }, onSubmit: {})
        }
        let (window, host) = host(surface(true))
        defer { window.contentView = nil }
        let editor = try XCTUnwrap(descendants(host, ImageTextView.self).first)
        window.makeFirstResponder(editor)
        let original = editor.string
        editor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        editor.insertText("末尾修改", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        settle(host)
        editor.scrollRangeToVisible(editor.selectedRange())
        // The user may scroll away from the caret before previewing; preserve that viewport too.
        editor.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 80))
        let selection = editor.selectedRange()
        let origin = editor.enclosingScrollView?.contentView.bounds.origin
        host.rootView = surface(false)
        settle(host)
        let reader = try XCTUnwrap(descendants(host, ReadingTextView.self).first)
        XCTAssertTrue(window.firstResponder === reader)
        XCTAssertFalse(editor.performKeyEquivalent(with: key("v")))
        XCTAssertTrue(reader.string.contains("末尾修改"))
        host.rootView = surface(true)
        settle(host)
        XCTAssertTrue(descendants(host, ImageTextView.self).first === editor)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.enclosingScrollView?.contentView.bounds.origin, origin)
        XCTAssertFalse(reader.performKeyEquivalent(with: key("a")))
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("undo:"), to: window.firstResponder, from: nil))
        XCTAssertEqual(editor.string, original)
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("redo:"), to: window.firstResponder, from: nil))
        XCTAssertEqual(editor.string, original + "末尾修改")
        XCTAssertTrue(editor.performKeyEquivalent(with: key("f")))
        settle(host)
        XCTAssertEqual(editor.enclosingScrollView?.isFindBarVisible, true)
        editor.cancelOperation(nil)
        XCTAssertEqual(editor.enclosingScrollView?.isFindBarVisible, false)
    }

    @MainActor func testImageRefreshPreservesSelectionAcrossAttachment() throws {
        let content = "# 图片记录\n\n前面的段落\n\n![配图](photo.png)\n\n后面的段落"
        let (window, host) = host(MarkdownPreview(content: content))
        defer { window.contentView = nil }
        let reader = try XCTUnwrap(descendants(host, ReadingTextView.self).first)
        reader.selectAll(nil)
        let selection = reader.selectedRange()
        let before = reader.string
        let coordinator = MarkdownPreview.Coordinator()
        coordinator.view = reader
        coordinator.width = reader.textContainer?.containerSize.width ?? 400
        coordinator.blocks = ReadingDocument(content).blocks
        coordinator.images = ["photo.png": NSImage(size: NSSize(width: 1200, height: 800))]
        coordinator.render()
        settle(host)
        XCTAssertEqual(reader.selectedRange(), selection)
        XCTAssertEqual(reader.string, before)
        let range = (reader.string as NSString).range(of: "\u{fffc}")
        let attachment = try XCTUnwrap(reader.textStorage?.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertLessThanOrEqual(attachment.bounds.width, coordinator.width)
        XCTAssertEqual(attachment.bounds.width / attachment.bounds.height, 1.5, accuracy: 0.001)
    }

    @MainActor func testReplacingSubmittedDraftClearsOnlyThatEditorsUndo() {
        let first = ImageTextView()
        let second = ImageTextView()
        for editor in [first, second] {
            editor.allowsUndo = true
            editor.insertText("尚未提交", replacementRange: NSRange(location: 0, length: 0))
            editor.breakUndoCoalescing()
        }
        XCTAssertTrue(first.undoManager?.canUndo == true)
        first.replaceFromModel("")
        XCTAssertFalse(first.undoManager?.canUndo == true)
        XCTAssertEqual(first.string, "")
        XCTAssertTrue(second.undoManager?.canUndo == true)
        second.undoManager?.undo()
        XCTAssertEqual(second.string, "")
    }
}
