import ServiceManagement
import SwiftUI

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
private struct SystemLoginItem: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?
    private let service: (any LoginItemService)?
    var requested: Bool { status == .enabled || status == .requiresApproval }

    init(testing: Bool = false, service: (any LoginItemService)? = nil) {
        self.service = service ?? (testing ? nil : SystemLoginItem())
        refresh()
    }
    func refresh() { status = service?.status ?? .notRegistered }
    func setEnabled(_ enabled: Bool) {
        error = nil
        guard let service else { error = "测试模式不会修改登录项。"; return }
        refresh()
        do {
            if enabled && !requested { try service.register() }
            else if !enabled && requested { try service.unregister() }
        } catch { self.error = "无法更新登录启动：\(error.localizedDescription)" }
        refresh() // The system is the source of truth, including approval and revoked consent.
    }
}

struct LoginItemSettings: View {
    @ObservedObject var controller: LoginItemController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("登录时启动 Memos", isOn: Binding(get: { controller.requested }, set: controller.setEnabled))
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            if controller.status == .requiresApproval {
                Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    .font(.caption)
            }
            if let error = controller.error { ErrorNotice(message: error) }
        }
        .onAppear { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refresh() }
    }
    private var statusText: String {
        switch controller.status {
        case .enabled: return "已启用，下次登录后驻留菜单栏。"
        case .requiresApproval: return "尚未生效，请在系统登录项设置中允许 Memos 启动。"
        case .notFound: return "系统未找到应用，请先将 Memos 安装到应用程序目录后重试。"
        default: return "未启用。开启前请先将 Memos 安装到应用程序目录。"
        }
    }
}
