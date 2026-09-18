import AppKit
import Carbon
import SwiftUI

struct GlobalShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    static let standard = GlobalShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey), keyLabel: "M")
    private static let allowedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    var isValid: Bool {
        keyCode <= 127 && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
            && modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
            && modifiers & ~Self.allowedModifiers == 0 && !keyLabel.isEmpty && keyLabel.count <= 12
    }
    var display: String {
        var label = ""
        for (flag, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(flag) != 0 { label += symbol }
        }
        return label + " " + keyLabel
    }
    func sameKeys(as other: Self) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
    init?(event: NSEvent) {
        var modifiers: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)] {
            if event.modifierFlags.contains(flag) { modifiers |= UInt32(carbon) }
        }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 76: "⌤",
            115: "Home", 116: "Page Up", 117: "⌦", 119: "End", 121: "Page Down",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        let label = special[event.keyCode] ?? (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").uppercased()
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        guard isValid else { return nil }
    }
}

@MainActor
protocol HotKeyRegistering: AnyObject {
    // On failure the previous registration must remain intact.
    func replace(with shortcut: GlobalShortcut) throws
    func clear()
}

struct ShortcutRegistrationError: LocalizedError {
    var errorDescription: String? { "此快捷键无法注册，可能已被系统或其他应用占用。请选择其他组合。" }
}

@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    static let signature: OSType = 0x4D454D4F
    private var reference: EventHotKeyRef?
    private var registered: GlobalShortcut?
    func replace(with shortcut: GlobalShortcut) throws {
        if registered?.sameKeys(as: shortcut) == true { return }
        var candidate: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &candidate)
        guard result == noErr, let candidate else { throw ShortcutRegistrationError() }
        clear()
        reference = candidate; registered = shortcut
    }
    func clear() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil; registered = nil
    }
}

@MainActor
final class ShortcutController: ObservableObject {
    @Published private(set) var shortcut: GlobalShortcut
    @Published private(set) var enabled: Bool
    @Published private(set) var isRecording = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults?
    private let registrar: HotKeyRegistering
    private var started = false

    init(defaults: UserDefaults?, registrar: HotKeyRegistering? = nil) {
        self.defaults = defaults
        self.registrar = registrar ?? CarbonHotKeyRegistrar()
        enabled = defaults?.bool(forKey: "shortcutEnabled") ?? false
        if let data = defaults?.data(forKey: "globalShortcut"),
           let saved = try? JSONDecoder().decode(GlobalShortcut.self, from: data), saved.isValid { shortcut = saved }
        else { shortcut = .standard }
    }
    func start() {
        guard !started else { return }
        started = true
        restoreRegistration()
    }
    func setEnabled(_ value: Bool) {
        cancelRecording()
        error = nil
        if value, started {
            do { try registrar.replace(with: shortcut) }
            catch { self.error = error.localizedDescription; return }
        } else { registrar.clear() }
        enabled = value
        defaults?.set(value, forKey: "shortcutEnabled")
    }
    func beginRecording() {
        guard !isRecording else { return }
        error = nil
        registrar.clear() // Let the current global combination reach the recorder as a key event.
        isRecording = true
    }
    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        restoreRegistration()
    }
    func record(_ event: NSEvent) {
        guard isRecording, !event.isARepeat else { return }
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            cancelRecording(); return
        }
        guard let candidate = GlobalShortcut(event: event) else {
            error = "请同时按住 ⌘、⌃ 或 ⌥ 中的至少一个，再按一个按键。"
            return
        }
        setShortcut(candidate)
    }
    func setShortcut(_ candidate: GlobalShortcut) {
        guard candidate.isValid else { return }
        let wasRecording = isRecording
        if enabled, started {
            do { try registrar.replace(with: candidate) }
            catch {
                self.error = "\(candidate.display)：\(error.localizedDescription) 原设置未更改。"
                isRecording = false
                if wasRecording { restoreRegistration() }
                return
            }
        }
        shortcut = candidate
        defaults?.set(try? JSONEncoder().encode(candidate), forKey: "globalShortcut")
        isRecording = false; error = nil
    }
    private func restoreRegistration() {
        guard started, enabled else { return }
        do { try registrar.replace(with: shortcut) }
        catch {
            enabled = false
            defaults?.set(false, forKey: "shortcutEnabled")
            self.error = "\(shortcut.display) 已无法注册，快捷键暂时关闭；已保存的组合仍保留。"
        }
    }
}

struct ShortcutSettings: View {
    @ObservedObject var controller: ShortcutController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("使用全局快捷键唤出记录浮窗", isOn: Binding(get: { controller.enabled }, set: controller.setEnabled))
            HStack {
                ShortcutRecorder(controller: controller).frame(width: 190, height: 30)
                if controller.isRecording {
                    Button("取消") { controller.cancelRecording() }
                } else {
                    Button("恢复默认") { controller.setShortcut(.standard) }
                        .disabled(controller.shortcut.sameKeys(as: .standard))
                }
            }
            Text(controller.isRecording ? "按下新的组合键，Esc 取消。" : "点击快捷键后录入；包含 ⌘、⌃ 或 ⌥，设置立即保存。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = controller.error { ErrorNotice(message: error) }
        }.font(.callout).onDisappear { controller.cancelRecording() }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var controller: ShortcutController
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.controller = controller
        button.bezelStyle = .rounded
        button.target = button; button.action = #selector(RecorderButton.toggleRecording)
        button.sync()
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) { button.sync() }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.stop() }
}

final class RecorderButton: NSButton {
    var controller: ShortcutController!
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    override var acceptsFirstResponder: Bool { true }
    @objc func toggleRecording() {
        if controller.isRecording { controller.cancelRecording() }
        else { window?.makeFirstResponder(self); controller.beginRecording() }
        sync()
    }
    func sync() {
        title = controller.isRecording ? "请按下快捷键…" : controller.shortcut.display
        setAccessibilityLabel("唤起快捷键，\(title)")
        if controller.isRecording && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, self.controller.isRecording else { return event }
                if event.type != .keyDown {
                    if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.stop() }
                    return event
                }
                guard event.window === self.window else { self.stop(); return event }
                self.controller.record(event)
                self.sync()
                return nil // Consume before app menu shortcuts (e.g. Command Q) or text input.
            }
            for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if note.name == NSApplication.didResignActiveNotification || (note.object as? NSWindow) === self.window { self.stop() }
                    }
                })
            }
        } else if !controller.isRecording { removeObservers() }
    }
    func stop() { controller?.cancelRecording(); removeObservers(); if controller != nil { sync() } }
    private func removeObservers() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
    }
    override func resignFirstResponder() -> Bool { stop(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
}
