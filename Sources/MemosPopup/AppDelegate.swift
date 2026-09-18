import AppKit
import SwiftUI
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    static weak var instance: AppDelegate?
    let store = AppStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var library: NSWindow?
    private var settings: NSWindow?
    private var previousApp: NSRunningApplication?
    private var hotkeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.instance = self
        installMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Memos 随手记")
            button.image?.isTemplate = true
            button.toolTip = "Memos · 随手记"
            button.target = self; button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ComposerView(app: store, close: { [weak self] in self?.closePopover(restoreFocus: true) }))
        store.onSettings = { [weak self] in self?.showSettings() }
        store.onLibrary = { [weak self] in self?.showLibrary() }
        store.onCompose = { [weak self] in self?.showPopover() }
        store.onSaved = { [weak self] in self?.closePopover(restoreFocus: true) }
        installHotkeyHandler()
        store.shortcuts.start()
        if store.testing { showLibrary() }
        else if store.api == nil { showSettings() }
    }

    @objc func togglePopover() {
        if popover.isShown { closePopover(restoreFocus: true) } else { showPopover() }
    }
    func showPopover() {
        guard let button = statusItem.button else { return }
        if !popover.isShown { previousApp = NSWorkspace.shared.frontmostApplication }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        focusComposer()
    }
    func popoverDidShow(_ notification: Notification) { focusComposer() }
    func applicationDidBecomeActive(_ notification: Notification) {
        if popover.isShown { focusComposer() }
    }
    private func focusComposer() {
        guard popover.isShown, let root = popover.contentViewController?.view, let window = root.window,
              window.attachedSheet == nil else { return }
        root.layoutSubtreeIfNeeded()
        if let editor = findEditor(root) {
            window.makeKey()
            window.makeFirstResponder(editor)
            editor.needsDisplay = true
            editor.scrollRangeToVisible(editor.selectedRange())
        }
    }
    private func findEditor(_ view: NSView) -> ImageTextView? {
        if let editor = view as? ImageTextView { return editor }
        for child in view.subviews { if let found = findEditor(child) { return found } }
        return nil
    }
    func closePopover(restoreFocus: Bool) {
        guard popover.isShown else { return }
        popover.performClose(nil)
        if restoreFocus, let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [])
        }
        previousApp = nil
    }
    @objc func showLibrary() {
        closePopover(restoreFocus: false)
        NSApp.setActivationPolicy(.regular)
        if library == nil {
            let window = makeWindow(title: "Memos · 所有记录", size: NSSize(width: 960, height: 680))
            window.contentViewController = NSHostingController(rootView: LibraryView(app: store))
            window.setFrameAutosaveName("MemosLibrary")
            library = window
        }
        NSApp.activate(ignoringOtherApps: true)
        library?.makeKeyAndOrderFront(nil)
        Task { await store.refresh() }
    }
    @objc func showSettings() {
        closePopover(restoreFocus: false)
        NSApp.setActivationPolicy(.regular)
        if settings == nil {
            let window = makeWindow(title: "Memos · 连接设置", size: NSSize(width: 480, height: 640), resizable: false)
            window.contentViewController = NSHostingController(rootView: SettingsView(app: store))
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
    private func makeWindow(title: String, size: NSSize, resizable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        let anotherVisible = [library, settings].compactMap { $0 }.contains { $0 !== closing && $0.isVisible }
        if !anotherVisible { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Drafts are written synchronously on every edit. Never quit during a network commit.
        if store.anySaving {
            let alert = NSAlert()
            alert.messageText = "正在保存记录"
            alert.informativeText = "请等待这次保存完成后再退出，避免无法确认提交结果。"
            alert.addButton(withTitle: "继续等待")
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "所有记录", action: #selector(showLibrary), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "连接设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Memos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
    private func installHotkeyHandler() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4D454D4F, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in
                guard let app = AppDelegate.instance, app.store.shortcuts.enabled, !app.store.shortcuts.isRecording else { return }
                app.togglePopover()
            }
            return noErr
        }, 1, &type, nil, &hotkeyHandler)
    }
}
