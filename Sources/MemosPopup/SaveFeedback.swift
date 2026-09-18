import AppKit
import MemosCore

struct SaveFailure: Equatable {
    enum Action { case retry, settings, library }
    var message: String
    var action: Action

    static func describe(_ error: Error, uploading: Bool, remoteSaved: Bool) -> SaveFailure {
        if remoteSaved {
            return Self(message: "已保存到 Memos，但本地草稿清理失败。内容仍保留，请先在所有记录中确认。", action: .library)
        }
        if (error as? MemosError) == .http(401) {
            return Self(message: "登录凭证已失效，草稿已保留。请更新 Token 后重试。", action: .settings)
        }
        if error is URLError {
            return Self(message: "暂时无法连接 Memos，草稿已保留，可稍后重试。", action: .retry)
        }
        let prefix = uploading ? "图片上传失败：" : "保存失败："
        return Self(message: prefix + error.localizedDescription + " 草稿已保留。", action: .retry)
    }
}

final class FeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SaveFeedbackController {
    private(set) var panel: FeedbackPanel?
    private var dismissal: Task<Void, Never>?

    func dismiss() {
        dismissal?.cancel(); dismissal = nil
        panel?.orderOut(nil)
    }

    func show(below button: NSStatusBarButton, message: String = "已保存到 Memos", success: Bool = true) {
        guard let window = button.window, let screen = window.screen else { return }
        dismiss()
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let panel = FeedbackPanel(contentRect: NSRect(x: 0, y: 0, width: 272, height: 44),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .popover; effect.state = .active; effect.blendingMode = .behindWindow
        effect.wantsLayer = true; effect.layer?.cornerRadius = 10; effect.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: (success ? "✓ " : "! ") + message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = success ? .systemGreen : .labelColor
        label.alignment = .center; label.frame = NSRect(x: 10, y: 13, width: 252, height: 18)
        effect.addSubview(label); panel.contentView = effect
        let frame = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        panel.setFrameOrigin(NSPoint(x: min(max(anchor.midX - 136, frame.minX), frame.maxX - 272),
            y: min(max(anchor.minY - 50, frame.minY), frame.maxY - 44)))
        self.panel = panel
        panel.orderFrontRegardless() // Never activate the app or make this panel key.
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(success ? 1.5 : 3))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }
}
