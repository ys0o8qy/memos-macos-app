import SwiftUI

struct ComposerView: View {
    @ObservedObject var app: AppStore
    var close: () -> Void
    var compact = true
    @State private var previewing = false
    private var canEdit: Bool { !app.isSaving && !app.isConnecting && app.storageError == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if !compact {
                    Text(Date.now, format: .dateTime.month(.wide).day().weekday(.wide))
                        .font(.system(size: 23, weight: .semibold)).padding(.horizontal, 24).padding(.top, 24)
                }
                if previewing {
                    ScrollView {
                        MarkdownPreview(content: app.draft.content).padding(24)
                            .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ZStack(alignment: .topLeading) {
                        if app.draft.content.isEmpty {
                            Text("写下此刻的想法…").font(.system(size: 15)).foregroundStyle(.tertiary)
                                .padding(.leading, 17).padding(.top, 14).allowsHitTesting(false)
                        }
                        TaggedMarkdownEditor(text: $app.draft.content, catalog: app.tagCatalog,
                            enabled: canEdit, autofocus: true, onImage: app.addImage,
                            onError: { app.composerError = $0 }, onSubmit: save, onEscape: close)
                    }.padding(.horizontal, compact ? 8 : 12).padding(.top, compact ? 4 : 14)
                        .frame(minHeight: 120, maxHeight: .infinity)
                }
                if !app.draft.images.isEmpty || app.storageError != nil || app.composerError != nil || app.api == nil {
                    ScrollView {
                        VStack(spacing: 0) {
                            if !app.draft.images.isEmpty {
                                LocalImages(images: app.draft.images, store: app.drafts, remove: app.removeImage)
                                    .padding(.horizontal, 20).disabled(!canEdit || previewing)
                            }
                            feedback.padding(.horizontal, 20)
                        }
                    }.frame(maxHeight: compact ? 150 : 190)
                }
            }.background(Theme.paper)
            Divider()
            footer
        }
        .frame(width: compact ? 440 : nil, height: compact ? 420 : nil)
        .frame(maxWidth: compact ? nil : .infinity, maxHeight: compact ? nil : .infinity)
        .background(Theme.paper).tint(Theme.accent)
        .task { await app.refreshTags() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if compact {
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .help("收起，保留草稿（Esc）").accessibilityLabel("收起快速记录")
                Spacer()
                Text(Date.now, format: .dateTime.month().day().weekday(.abbreviated)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
            } else {
                Label("新记录", systemImage: "square.and.pencil").font(.system(size: 13, weight: .medium))
                Spacer()
            }
            Button { previewing.toggle() } label: { Image(systemName: previewing ? "pencil" : "eye") }
                .buttonStyle(.plain).help(previewing ? "继续编辑" : "预览 Markdown").accessibilityLabel(previewing ? "继续编辑" : "预览 Markdown")
            if compact {
                Button { app.continueDraftInLibrary() } label: { Image(systemName: "rectangle.on.rectangle") }
                    .buttonStyle(.plain).help("在主窗口继续编辑").accessibilityLabel("在主窗口继续编辑")
            }
            Menu {
                Button("打开 Memos") { app.onLibrary?() }
                Button("连接设置…") { app.onSettings?() }
                Divider()
                Button("退出 Memos") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多")
        }.foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 48)
            .background(Theme.paper)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Label("私人记录", systemImage: "book.closed.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                Button { ImageImport.choose(receive: app.addImage, fail: { app.composerError = $0 }) } label: { Image(systemName: "photo") }
                    .buttonStyle(.plain).help("添加图片，也可以粘贴或拖入").disabled(!canEdit)
                Spacer()
                if compact { Button("打开") { app.continueDraftInLibrary() }.help("在主窗口继续，不会提交草稿") }
                if app.isSaving { ProgressView().controlSize(.small) }
                Button(app.isSaving ? "保存中…" : "保存", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!app.canWrite || !app.draft.hasContent || app.isSaving)
            }
            HStack {
                Text(app.storageError != nil ? "草稿保存失败" : app.isSaving ? app.saveStatus : "草稿已保留在本机")
                Spacer()
                Text("⌘ ↵ 保存")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 18).padding(.vertical, 14).background(Theme.paper)
    }

    @ViewBuilder private var feedback: some View {
        if let error = app.storageError ?? app.composerError {
            ScrollView { ErrorNotice(message: error) }.frame(maxHeight: 68).padding(.bottom, 8)
        }
        if app.storageError == nil, let failure = app.saveFailure, app.composerError == failure.message, !app.isSaving {
            switch failure.action {
            case .settings: Button("打开连接设置") { app.onSettings?() }.padding(.bottom, 8)
            case .library: Button("查看所有记录") { app.onLibrary?() }.padding(.bottom, 8)
            case .retry: Button("重试保存", action: save).disabled(!app.canWrite).padding(.bottom, 8)
            }
        }
        if app.api == nil {
            HStack { Text("连接后可保存到 Memos").foregroundStyle(.secondary); Spacer(); Button("连接") { app.onSettings?() } }
                .font(.caption).padding(.bottom, 12)
        }
    }
    private func save() { Task { await app.submit(showMenuBarFeedback: compact) } }
}
