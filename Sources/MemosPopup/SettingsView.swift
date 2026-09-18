import SwiftUI

struct SettingsView: View {
    @ObservedObject var app: AppStore
    @State private var address = ""
    @State private var token = ""
    @State private var error: String?
    @State private var success: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "square.and.pencil").font(.system(size: 30)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("连接你的 Memos").font(.title2.bold())
                    Text("一个安静、随手可用的记录入口。").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("服务地址").font(.headline)
                TextField("https://memos.example.com", text: $address).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Memos 服务地址")
                Text("填写服务首页地址，支持自建服务和子路径部署。").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("API Token").font(.headline)
                SecureField(app.connection == nil ? "粘贴 Personal Access Token" : "留空使用当前服务已保存的 Token", text: $token)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("API Token")
                Text("在 Memos 网页的设置中创建访问令牌。Token 仅存入 macOS 钥匙串。").font(.caption).foregroundStyle(.secondary)
            }
            if let error { ErrorNotice(message: error) }
            if let success { Label(success, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.callout) }
            HStack {
                Text("适配 Memos v0.30.0").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if app.isConnecting { ProgressView().controlSize(.small) }
                Button(app.isConnecting ? "正在连接…" : "验证并保存") {
                    error = nil; success = nil
                    Task {
                        do {
                            try await app.connect(address: address, enteredToken: token)
                            token = ""; address = app.connection?.address ?? address
                            success = "已连接 · \(app.connection?.user.label ?? "")"
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(app.isConnecting || app.anySaving || address.isEmpty)
            }
            Divider()
            Toggle("使用全局快捷键 ⌃ ⌥ M 唤出记录浮窗", isOn: $app.shortcutEnabled).font(.callout)
            Text("关闭窗口后应用仍留在菜单栏。新记录默认私有，离线时保留草稿，联网后手动保存。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("打开草稿目录") { if let directory = app.drafts?.directory { NSWorkspace.shared.open(directory) } }
                    .buttonStyle(.link).font(.caption)
                Spacer()
                Button("所有记录") { app.onLibrary?() }
            }
        }.padding(30).frame(width: 480).tint(Theme.accent)
        .onAppear { address = app.connection?.address ?? "" }
        .disabled(app.isConnecting)
    }
}
