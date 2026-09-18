import SwiftUI
import MemosCore

struct LibraryView: View {
    @ObservedObject var app: AppStore
    @State private var selection: String?
    @State private var searchTask: Task<Void, Never>?
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索自己的记录", text: $app.search).textFieldStyle(.plain)
                    if !app.search.isEmpty { Button { app.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8)).padding(12)
                if let error = app.listError { ErrorNotice(message: error).padding(.horizontal, 12).padding(.bottom, 8) }
                List(selection: $selection) {
                    ForEach(app.memos) { memo in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                if let date = memo.date { Text(date, format: .dateTime.month().day().hour().minute()) }
                                Spacer()
                                if memo.visibility == "PRIVATE" { Image(systemName: "lock").font(.system(size: 10)) }
                            }.font(.caption).foregroundStyle(.secondary)
                            Text(memo.content.isEmpty ? "图片记录" : memo.content).font(.system(size: 13)).lineLimit(3)
                            if let attachments = memo.attachments, !attachments.isEmpty {
                                Label("\(attachments.count) 个附件", systemImage: "photo").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 7).tag(memo.name)
                    }
                    if !app.nextPage.isEmpty {
                        Button("加载更多") { Task { await app.refresh(more: true) } }.disabled(app.isLoading)
                    }
                }.listStyle(.sidebar)
                if app.isLoading { ProgressView().controlSize(.small).padding(10) }
                HStack {
                    Circle().fill(app.api == nil ? .gray : Theme.accent).frame(width: 6, height: 6)
                    Text(app.connection?.user.label ?? "尚未连接")
                    Spacer()
                    Text("\(app.memos.count) 条")
                }.font(.caption).foregroundStyle(.secondary).padding(14)
            }.navigationTitle("所有记录").navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            if let selection, let memo = app.memos.first(where: { $0.name == selection }) {
                MemoDetail(app: app, editor: app.editor(for: memo)).id(app.connection?.account.appending(selection) ?? selection)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "text.book.closed").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.accent)
                    Text(app.api == nil ? "把你的 Memos 带到桌面" : app.memos.isEmpty ? "从一条小记录开始" : "留住那些值得记下的瞬间").font(.title2.weight(.medium))
                    Text(app.api == nil ? "连接服务后，在菜单栏随时记录。" : app.memos.isEmpty ? "点击菜单栏图标，写下此刻的想法。" : "选择左侧记录查看或编辑。")
                        .foregroundStyle(.secondary)
                    Button(app.api == nil ? "连接 Memos" : "写一条记录") { if app.api == nil { app.onSettings?() } else { app.onCompose?() } }
                        .buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.tint(Theme.accent)
        .toolbar {
            ToolbarItemGroup {
                Button { app.onSettings?() } label: { Image(systemName: "gearshape") }.help("连接设置")
                Button { Task { await app.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("刷新").disabled(app.isLoading || app.api == nil)
                Button { app.onCompose?() } label: { Label("新建记录", systemImage: "square.and.pencil") }.keyboardShortcut("n")
            }
        }
        .onChange(of: app.search) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                await app.refresh()
            }
        }
        .onChange(of: app.connection?.account) { _, _ in selection = nil }
        .frame(minWidth: 820, minHeight: 540)
    }
}

struct MemoDetail: View {
    @ObservedObject var app: AppStore
    @ObservedObject var editor: EditorModel
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("记录").font(.title2.weight(.semibold))
                    if let date = editor.draft.originalMemo?.date { Text(date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Label(visibility, systemImage: editor.draft.originalMemo?.visibility == "PRIVATE" ? "lock" : "eye")
                    .font(.caption).foregroundStyle(.secondary)
                Button(editing ? "预览" : "编辑") { editing.toggle() }.disabled(editor.isSaving)
            }
            Divider()
            if editing {
                MarkdownEditor(text: $editor.draft.content, enabled: !editor.isSaving && !editor.storageFailed,
                    autofocus: true, onImage: editor.addImage, onError: { editor.error = $0 },
                    onSubmit: { Task { await editor.save() } })
                    .frame(minHeight: 180).background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView { MarkdownPreview(content: editor.draft.content).padding(.vertical, 8) }.frame(maxHeight: .infinity)
            }
            if !editor.draft.existingAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(editor.draft.existingAttachments) { attachment in
                            VStack(alignment: .leading) {
                                RemoteAttachment(attachment: attachment, api: app.api)
                                if editing {
                                    Button("从记录中移除") { editor.draft.existingAttachments.removeAll { $0.name == attachment.name } }
                                        .font(.caption).buttonStyle(.link).disabled(editor.isSaving)
                                }
                            }
                        }
                    }
                }.frame(height: editing ? 154 : 128)
            }
            LocalImages(images: editor.draft.images, store: app.drafts, remove: editor.removeImage).disabled(editor.isSaving || !editing)
            if let error = editor.error { ErrorNotice(message: error) }
            if let conflict = editor.conflict {
                VStack(alignment: .leading, spacing: 8) {
                    Text("服务器上的最新内容").font(.caption.bold())
                    ScrollView { Text(conflict.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
                    Button("已对照，保留我的修改并继续编辑") { editor.acknowledgeConflict() }
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                if editing {
                    Button { ImageImport.choose(receive: editor.addImage, fail: { editor.error = $0 }) } label: { Label("添加图片", systemImage: "photo.badge.plus") }.disabled(editor.isSaving)
                }
                Text(editor.saved ? "已保存到 Memos" : editor.draft.isModified ? "修改已保留为本地草稿" : "")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if editor.isSaving { ProgressView().controlSize(.small) }
                if editing || editor.draft.isModified {
                    Button("保存修改") { Task { await editor.save() } }.buttonStyle(.borderedProminent)
                        .keyboardShortcut("s").disabled(editor.isSaving || !editor.draft.isModified || !editor.draft.hasContent || editor.conflict != nil || editor.storageFailed || !app.canWrite)
                }
            }
        }.padding(26)
        .onAppear { if editor.draft.isModified { editing = true } }
    }
    private var visibility: String {
        switch editor.draft.originalMemo?.visibility {
        case "PRIVATE": return "仅自己可见"
        case "PROTECTED": return "登录用户可见"
        case "PUBLIC": return "公开"
        default: return "保留原可见性"
        }
    }
}
