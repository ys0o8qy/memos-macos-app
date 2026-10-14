import SwiftUI
import MemosCore

/// A stable chronological presentation, independent of server page ordering.
struct JournalSection: Identifiable {
    let month: Date?
    let memos: [Memo]
    var id: Date { month ?? .distantPast }

    static func sections(_ memos: [Memo], calendar: Calendar = .current) -> [JournalSection] {
        let groups = Dictionary(grouping: memos) { memo in
            memo.date.flatMap { calendar.dateInterval(of: .month, for: $0)?.start }
        }
        return groups.map { month, entries in
            JournalSection(month: month, memos: entries.sorted {
                if $0.date == $1.date { return $0.name < $1.name }
                return ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
            })
        }.sorted { $0.id > $1.id }
    }
}

struct LibraryView: View {
    @ObservedObject var app: AppStore
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searching: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 176)
            Divider()
            HSplitView {
                timeline.frame(minWidth: 260, idealWidth: 296, maxWidth: 320)
                detail.frame(minWidth: 410, maxWidth: .infinity, maxHeight: .infinity).background(Theme.paper)
            }
        }.background(Theme.paper).tint(Theme.accent)
        .onChange(of: app.librarySelection) { _, value in if value != nil { app.libraryComposing = false } }
        .onChange(of: app.search) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                await app.refresh()
            }
        }
        .onChange(of: app.lastCreatedMemo?.name) { _, name in
            guard let name else { return }
            searchTask?.cancel()
            app.search = ""
            app.librarySelection = name
            app.libraryComposing = false
        }
        .onChange(of: app.connection?.account) { _, _ in
            searchTask?.cancel()
            app.librarySelection = nil
            app.libraryComposing = false
        }
        .onChange(of: app.memos) { _, _ in selectFirstIfNeeded() }
        .onAppear { selectFirstIfNeeded() }
        .onDisappear { searchTask?.cancel() }
        .frame(minWidth: 960, minHeight: 580)
    }

    private func selectFirstIfNeeded() {
        guard !app.libraryComposing, app.librarySelection == nil else { return }
        app.librarySelection = JournalSection.sections(app.memos).first?.memos.first?.name
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Memos", systemImage: "book.closed.fill")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(height: 62).padding(.horizontal, 18)
            VStack(alignment: .leading, spacing: 6) {
                Text("资料库").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 6)
                navigationButton("所有记录", icon: "tray.full", selected: !app.libraryComposing) {
                    app.libraryComposing = false; selectFirstIfNeeded()
                }
                navigationButton("新建草稿", icon: "square.and.pencil", selected: app.libraryComposing, action: newEntry)
                    .keyboardShortcut("n")
            }.padding(.horizontal, 8).padding(.top, 16)
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                if app.draft.hasContent {
                    Button(action: newEntry) { Label("继续未完成的记录", systemImage: "pencil.line").font(.caption) }.buttonStyle(.plain)
                }
                Divider()
                Button { app.onSettings?() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle").font(.system(size: 22)).foregroundStyle(.secondary)
                        Text(app.connection?.user.label ?? "连接 Memos").font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).help("账号与设置")
            }.padding(16)
        }.frame(maxHeight: .infinity).background(Theme.sidebar)
    }

    private func navigationButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: selected ? .medium : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                .foregroundStyle(selected ? Theme.accent : .primary)
                .background(selected ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var detail: some View {
        if app.libraryComposing {
            ComposerView(app: app, close: { app.libraryComposing = false; selectFirstIfNeeded() }, compact: false)
        } else if let selection = app.librarySelection,
                  let memo = app.memos.first(where: { $0.name == selection }) ?? (app.lastCreatedMemo?.name == selection ? app.lastCreatedMemo : nil) {
            MemoDetail(app: app, editor: app.editor(for: memo)).id(app.connection?.account.appending(selection) ?? selection)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "book.closed").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.accent)
                Text(app.api == nil ? "你的记录，从这里开始" : "写下一个值得留下的片刻").font(.system(size: 20, weight: .medium))
                Text(app.api == nil ? "连接 Memos，或先写一份本地草稿。" : "所有记录会按时间保存在这里。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button("新建记录", action: newEntry).buttonStyle(.borderedProminent).padding(.top, 4)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func newEntry() { app.librarySelection = nil; app.libraryComposing = true }

    private var timeline: some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.search.isEmpty ? "所有记录" : "搜索结果").font(.system(size: 15, weight: .semibold))
                Spacer()
                if app.isLoading { ProgressView().controlSize(.small) }
                Button { Task { await app.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("刷新").disabled(app.isLoading || app.api == nil)
                Button(action: newEntry) { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).help("新建记录")
            }.padding(.horizontal, 16).frame(height: 62)
            HStack {
                Button { searching = true } label: { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }.buttonStyle(.plain).keyboardShortcut("f").help("搜索记录")
                TextField("搜索记录", text: $app.search).textFieldStyle(.plain).focused($searching)
                if !app.search.isEmpty {
                    Button { app.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("清除搜索")
                }
            }.padding(9).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12).padding(.bottom, 12)
            if let error = app.listError { ErrorNotice(message: error).padding(.horizontal, 12) }
            if app.memos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: app.search.isEmpty ? "text.book.closed" : "magnifyingglass").font(.title)
                    Text(app.isLoading ? "正在载入记录…" : app.api == nil ? "连接后查看时间线" : app.search.isEmpty ? "还没有记录" : "没有找到相关记录")
                    if !app.search.isEmpty { Button("清除搜索") { app.search = "" } }
                }.font(.callout).foregroundStyle(.secondary).padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $app.librarySelection) {
                    ForEach(JournalSection.sections(app.memos)) { section in
                        Section {
                            ForEach(section.memos) { memo in
                                JournalRow(memo: memo).tag(memo.name)
                            }
                        } header: {
                            if let month = section.month { Text(month, format: .dateTime.year().month(.wide)) }
                            else { Text("日期未知") }
                        }
                    }
                    if !app.nextPage.isEmpty {
                        Button("加载更早的记录") { Task { await app.refresh(more: true) } }.disabled(app.isLoading)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            Divider()
            Text("已载入 \(app.memos.count) 条\(app.search.isEmpty ? "记录" : "搜索结果")")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }.background(Theme.paper)
    }
}

private struct JournalRow: View {
    let memo: Memo
    private let text: ReadingDocument
    init(memo: Memo) {
        self.memo = memo
        text = ReadingDocument(memo.content)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 2) {
                if let date = memo.date {
                    Text(String(Calendar.current.component(.day, from: date)))
                        .font(.system(size: 25, weight: .light, design: .rounded)).lineLimit(1)
                    Text(date, format: .dateTime.weekday(.abbreviated)).font(.caption2)
                } else { Image(systemName: "calendar") }
            }.foregroundStyle(.secondary).frame(width: 36)
            VStack(alignment: .leading, spacing: 7) {
                Text(text.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !text.summary.isEmpty {
                    Text(text.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let date = memo.date { Text(date, format: .dateTime.hour().minute()) }
                    if let attachments = memo.attachments, !attachments.isEmpty {
                        Label("\(attachments.count)", systemImage: "paperclip")
                    }
                    Spacer()
                    if memo.visibility == "PRIVATE" { Image(systemName: "lock") }
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 12).padding(.horizontal, 6)
    }
}

struct MemoDetail: View {
    @ObservedObject var app: AppStore
    @ObservedObject var editor: EditorModel
    @State var editing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(visibility, systemImage: editor.draft.originalMemo?.visibility == "PRIVATE" ? "lock" : "eye")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(editing ? "预览" : "编辑") { editing.toggle() }
                    .keyboardShortcut("e").disabled(editor.isSaving)
            }.padding(.horizontal, 24).frame(height: 62)
            Divider()
            if editing {
                TaggedMarkdownEditor(text: $editor.draft.content, catalog: app.tagCatalog,
                    enabled: !editor.isSaving && !editor.storageFailed, autofocus: true,
                    onImage: editor.addImage, onError: { editor.error = $0 }, onSubmit: saveChanges)
                    .padding(12).frame(minHeight: 120, maxHeight: .infinity)
                attachments(editable: true).padding(.horizontal, 24)
                LocalImages(images: editor.draft.images, store: app.drafts, remove: editor.removeImage)
                    .padding(.horizontal, 24).disabled(editor.isSaving)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let date = editor.draft.originalMemo?.date {
                            Text(date, format: .dateTime.year().month(.wide).day().weekday(.wide).hour().minute())
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        MarkdownPreview(content: editor.draft.content, api: app.api, attachments: editor.draft.existingAttachments)
                        attachments(editable: false)
                        LocalImages(images: editor.draft.images, store: app.drafts, remove: editor.removeImage).disabled(true)
                    }.padding(32).frame(maxWidth: 744, alignment: .leading).frame(maxWidth: .infinity)
                }.frame(maxHeight: .infinity)
            }
            if let error = editor.error { ErrorNotice(message: error).padding(.horizontal, 20).padding(.bottom, 8) }
            if let conflict = editor.conflict {
                VStack(alignment: .leading, spacing: 8) {
                    Text("服务器上的最新内容").font(.caption.bold())
                    ScrollView { Text(conflict.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 70)
                    Button("已对照，保留我的修改并继续编辑") { editor.acknowledgeConflict() }
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 20).padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 12) {
                if editing {
                    Button { ImageImport.choose(receive: editor.addImage, fail: { editor.error = $0 }) } label: { Image(systemName: "photo") }
                        .buttonStyle(.plain).help("添加图片").disabled(editor.isSaving || editor.storageFailed)
                }
                Text(editor.storageFailed ? "草稿未能保存到本机" : editor.draft.isModified ? "修改已保留在本机" : "已保存到 Memos")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if editor.isSaving { ProgressView().controlSize(.small) }
                if editing || editor.draft.isModified {
                    Button("完成并保存", action: saveChanges).buttonStyle(.borderedProminent).keyboardShortcut("s")
                        .disabled(editor.isSaving || !editor.draft.isModified || !editor.draft.hasContent || editor.conflict != nil || editor.storageFailed || !app.canWrite)
                }
            }.padding(.horizontal, 24).frame(height: 52)
        }.background(Theme.paper)
        .onAppear { if editor.draft.isModified { editing = true } }
        .task { await app.refreshTags() }
    }

    @ViewBuilder private func attachments(editable: Bool) -> some View {
        if !editor.draft.existingAttachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(editor.draft.existingAttachments) { attachment in
                        VStack(alignment: .leading, spacing: 6) {
                            RemoteAttachment(attachment: attachment, api: app.api)
                            if editable {
                                Button("移除") { editor.draft.existingAttachments.removeAll { $0.name == attachment.name } }
                                    .font(.caption).buttonStyle(.link).disabled(editor.isSaving || editor.storageFailed)
                            }
                        }
                    }
                }.padding(.vertical, 8)
            }.frame(height: editable ? 152 : 132)
        }
    }
    private func saveChanges() {
        Task {
            await editor.save()
            if editor.saved { editing = false }
        }
    }
    private var visibility: String {
        switch editor.draft.originalMemo?.visibility {
        case "PRIVATE": return "私人记录"
        case "PROTECTED": return "登录用户可见"
        case "PUBLIC": return "公开记录"
        default: return "保留原可见性"
        }
    }
}
