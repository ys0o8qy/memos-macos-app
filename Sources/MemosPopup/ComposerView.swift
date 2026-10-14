import SwiftUI

struct ComposerView: View {
    @ObservedObject var app: AppStore
    var close: () -> Void
    var compact = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil").font(.title3).foregroundStyle(Theme.accent)
                Text(compact ? "随手记" : "新的记录").font(compact ? .headline : .title2.weight(.semibold))
                Spacer()
                Label("仅自己可见", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                if compact { Button { app.onLibrary?() } label: { Image(systemName: "list.bullet.rectangle") }.buttonStyle(.plain).help("所有记录") }
                Menu {
                    Button("连接设置…") { app.onSettings?() }
                    Button("所有记录") { app.onLibrary?() }
                    Divider()
                    Button("退出 Memos") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("更多")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(Date.now, format: .dateTime.year().month(.wide).day().weekday(.wide))
                    .font(compact ? .subheadline : .title.weight(.medium))
                Text(app.draft.hasContent ? "继续记录你的此刻" : "今天，有什么值得记住？")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, compact ? 0 : 12)
            ZStack(alignment: .topLeading) {
                if app.draft.content.isEmpty {
                    Text("此刻有什么想记下来的？")
                        .foregroundStyle(.tertiary).font(.system(size: 15)).padding(.horizontal, 17).padding(.top, 14)
                        .allowsHitTesting(false)
                }
                TaggedMarkdownEditor(text: $app.draft.content, catalog: app.tagCatalog,
                    enabled: !app.isSaving && !app.isConnecting && app.storageError == nil,
                    autofocus: true, height: compact ? 200 : nil, onImage: app.addImage,
                    onError: { app.composerError = $0 }, onSubmit: { Task { await app.submit(showMenuBarFeedback: compact) } }, onEscape: close)
            }.frame(minHeight: compact ? 200 : 140, maxHeight: compact ? 200 : .infinity)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            LocalImages(images: app.draft.images, store: app.drafts, remove: app.removeImage).disabled(app.isSaving)
            if let error = app.storageError ?? app.composerError { ErrorNotice(message: error) }
            if app.storageError == nil, let failure = app.saveFailure, app.composerError == failure.message, !app.isSaving {
                switch failure.action {
                case .settings: Button("打开连接设置") { app.onSettings?() }
                case .library: Button("查看所有记录") { app.onLibrary?() }
                case .retry: Button("重试保存") { Task { await app.submit(showMenuBarFeedback: compact) } }.disabled(!app.canWrite)
                }
            }
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
                Text(app.isSaving ? app.saveStatus : "Markdown · #标签 · 粘贴图片")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if app.isSaving { ProgressView().controlSize(.small) }
                Button(app.isSaving ? "保存中…" : "保存") { Task { await app.submit(showMenuBarFeedback: compact) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!app.canWrite || !app.draft.hasContent || app.isSaving)
            }
            HStack {
                Text(app.storageError != nil ? "草稿保存遇到问题" : app.isSaving ? "正在保存到 Memos" : "草稿自动保留在这台 Mac")
                Spacer()
                Text(compact ? "⌘ ↵ 保存 · esc 收起" : "⌘ ↵ 保存")
            }.font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(compact ? 20 : 30)
            .frame(width: compact ? 440 : nil)
            .frame(maxWidth: compact ? nil : .infinity, maxHeight: compact ? nil : .infinity)
            .tint(Theme.accent)
            .task { await app.refreshTags() }
    }
}
