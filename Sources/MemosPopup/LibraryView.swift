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
    @State private var selection: String?
    @State private var composing = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searching: Bool

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                Label("Memos", systemImage: "book.closed.fill")
                    .font(.title2.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.top, 16)
                Button(action: newEntry) {
                    Label(app.draft.hasContent ? "继续写草稿" : "新建记录", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).keyboardShortcut("n")
                VStack(alignment: .leading, spacing: 8) {
                    Text("我的记录").font(.caption).foregroundStyle(.secondary)
                    Button { composing = false } label: {
                        Label("时间线", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(!composing ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                    Button(action: newEntry) {
                        HStack {
                            Label("草稿", systemImage: "pencil.line")
                            Spacer()
                            if app.draft.hasContent { Image(systemName: "circle.fill").font(.system(size: 6)) }
                        }.padding(10)
                            .background(composing ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Divider()
                Button { app.onSettings?() } label: {
                    HStack {
                        Image(systemName: "person.crop.circle").font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.connection?.user.label ?? "连接 Memos").lineLimit(1)
                            Text(app.api == nil ? "尚未连接" : "账号与设置").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "gearshape").foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }.padding(16)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } content: {
            timeline.navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            if composing {
                ComposerView(app: app, close: { composing = false }, compact: false)
            } else if let selection, let memo = app.memos.first(where: { $0.name == selection }) ?? (app.lastCreatedMemo?.name == selection ? app.lastCreatedMemo : nil) {
                MemoDetail(app: app, editor: app.editor(for: memo)).id(app.connection?.account.appending(selection) ?? selection)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "book.pages").font(.system(size: 38, weight: .light)).foregroundStyle(Theme.accent)
                    Text(app.api == nil ? "把生活，记在这里" : "每一条记录，都值得回看").font(.title2.weight(.medium))
                    Text(app.api == nil ? "连接你的 Memos，或先写一份本地草稿。" : "从时间线选择记录，或写下新的片刻。")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("写一条记录", action: newEntry).buttonStyle(.borderedProminent)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(Theme.accent)
        .toolbar {
            ToolbarItemGroup {
                Button { searching = true } label: { Image(systemName: "magnifyingglass") }
                    .help("搜索记录（⌘F）").keyboardShortcut("f")
                Button { Task { await app.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新").disabled(app.isLoading || app.api == nil)
            }
        }
        .onChange(of: selection) { _, value in if value != nil { composing = false } }
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
            selection = name
            composing = false
        }
        .onChange(of: app.connection?.account) { _, _ in
            searchTask?.cancel()
            selection = nil
            composing = false
        }
        .onDisappear { searchTask?.cancel() }
        .frame(minWidth: 960, minHeight: 580)
    }

    private func newEntry() { selection = nil; composing = true }

    private var timeline: some View {
        VStack(spacing: 0) {
            HStack {
                Text("时间线").font(.title2.weight(.semibold))
                Spacer()
                if app.isLoading { ProgressView().controlSize(.small) }
            }.padding(16)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
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
                List(selection: $selection) {
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
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
            Divider()
            Text("已载入 \(app.memos.count) 条\(app.search.isEmpty ? "记录" : "搜索结果")")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct JournalRow: View {
    let memo: Memo
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
                Text(memo.content.isEmpty ? "图片记录" : memo.content)
                    .font(.system(size: 13)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if let date = memo.date { Text(date, format: .dateTime.hour().minute()) }
                    if let attachments = memo.attachments, !attachments.isEmpty {
                        Label("\(attachments.count)", systemImage: "paperclip")
                    }
                    Spacer()
                    if memo.visibility == "PRIVATE" { Image(systemName: "lock") }
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 10)
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
                    if let date = editor.draft.originalMemo?.date {
                        Text(date, format: .dateTime.month(.wide).day()).font(.system(size: 28, weight: .medium))
                    } else { Text("记录").font(.title2.weight(.semibold)) }
                    if let date = editor.draft.originalMemo?.date { Text(date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Label(visibility, systemImage: editor.draft.originalMemo?.visibility == "PRIVATE" ? "lock" : "eye")
                    .font(.caption).foregroundStyle(.secondary)
                Button(editing ? "阅读" : "编辑") { editing.toggle() }.keyboardShortcut("e").disabled(editor.isSaving)
            }
            Divider()
            if editing {
                TaggedMarkdownEditor(text: $editor.draft.content, catalog: app.tagCatalog, enabled: !editor.isSaving && !editor.storageFailed,
                    autofocus: true, onImage: editor.addImage, onError: { editor.error = $0 },
                    onSubmit: saveChanges)
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
                Text(editor.storageFailed ? "草稿未能保存到本机" : editor.saved ? "已保存到 Memos" : editor.draft.isModified ? "修改已保留为本地草稿" : "已保存到 Memos")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if editor.isSaving { ProgressView().controlSize(.small) }
                if editing || editor.draft.isModified {
                    Button("完成并保存", action: saveChanges).buttonStyle(.borderedProminent)
                        .keyboardShortcut("s").disabled(editor.isSaving || !editor.draft.isModified || !editor.draft.hasContent || editor.conflict != nil || editor.storageFailed || !app.canWrite)
                }
            }
        }.padding(30)
        .onAppear { if editor.draft.isModified { editing = true } }
        .task { await app.refreshTags() }
    }
    private func saveChanges() {
        Task {
            await editor.save()
            if editor.saved { editing = false }
        }
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
