import SwiftUI

struct ComposerView: View {
    @ObservedObject var app: AppStore
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil").font(.title3).foregroundStyle(Theme.accent)
                Text("随手记").font(.headline)
                Spacer()
                Label("仅自己可见", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                Button { app.onLibrary?() } label: { Image(systemName: "list.bullet.rectangle") }.buttonStyle(.plain).help("所有记录")
                Menu {
                    Button("连接设置…") { app.onSettings?() }
                    Button("所有记录") { app.onLibrary?() }
                    Divider()
                    Button("退出 Memos") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("更多")
            }
            ZStack(alignment: .topLeading) {
                if app.draft.content.isEmpty {
                    Text("此刻有什么想记下来的？")
                        .foregroundStyle(.tertiary).font(.system(size: 15)).padding(.horizontal, 17).padding(.top, 14)
                        .allowsHitTesting(false)
                }
                MarkdownEditor(text: $app.draft.content, enabled: !app.isSaving && !app.isConnecting && app.storageError == nil,
                    autofocus: true, onImage: app.addImage,
                    onError: { app.composerError = $0 }, onSubmit: { Task { await app.submit() } }, onEscape: close)
            }.frame(height: 220).background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            LocalImages(images: app.draft.images, store: app.drafts, remove: app.removeImage).disabled(app.isSaving)
            if let error = app.storageError ?? app.composerError { ErrorNotice(message: error) }
            if app.api == nil {
                HStack {
                    Text("草稿会保留在这台 Mac 上。")
                    Spacer()
                    Button("连接 Memos") { app.onSettings?() }
                }.font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { ImageImport.choose(receive: app.addImage, fail: { app.composerError = $0 }) } label: {
                    Image(systemName: "photo.badge.plus")
                }.buttonStyle(.plain).help("添加图片，也可以直接粘贴或拖入").disabled(app.isSaving)
                Text(app.isSaving ? "正在保存…" : "Markdown · #标签 · 粘贴图片")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if app.isSaving { ProgressView().controlSize(.small) }
                Button("保存") { Task { await app.submit() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!app.canWrite || !app.draft.hasContent || app.isSaving)
            }
            HStack {
                Text(app.isSaving ? "提交成功后自动收起" : "草稿自动保留")
                Spacer()
                Text("⌘ ↵ 保存 · esc 收起")
            }.font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(20).frame(width: 440).tint(Theme.accent)
    }
}
