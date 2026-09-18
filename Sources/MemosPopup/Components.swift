import SwiftUI
import MemosCore

enum Theme {
    static let accent = Color(red: 0.21, green: 0.44, blue: 0.35)
    static let canvas = Color(nsColor: .windowBackgroundColor)
}

struct ErrorNotice: View {
    var message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LocalImages: View {
    var images: [LocalImage]
    var store: DraftStore?
    var remove: (LocalImage) -> Void
    var body: some View {
        if !images.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(images) { image in
                        VStack(alignment: .leading, spacing: 5) {
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if let url = store?.imageURL(image), let bitmap = NSImage(contentsOf: url) {
                                        Image(nsImage: bitmap).resizable().scaledToFill()
                                    } else { Image(systemName: "photo.badge.exclamationmark").frame(maxWidth: .infinity, maxHeight: .infinity) }
                                }.frame(width: 88, height: 70).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                                Button { remove(image) } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7))
                                }.buttonStyle(.plain).padding(4).help("移除 \(image.filename)")
                            }
                            Text(image.filename).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 88, alignment: .leading)
                        }
                    }
                }.padding(.vertical, 4)
            }.frame(height: 103)
        }
    }
}

struct RemoteAttachment: View {
    var attachment: Attachment
    var api: MemosAPI?
    @State private var image: NSImage?
    @State private var failed = false
    @State private var preview = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if let image {
                    Button { preview = true } label: {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 132, height: 96).clipped()
                    }.buttonStyle(.plain).help("查看图片")
                } else if !attachment.isImage || failed {
                    Label(attachment.isImage ? "图片加载失败" : "附件", systemImage: attachment.isImage ? "photo" : "doc")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 132, height: 96)
                } else { ProgressView().controlSize(.small).frame(width: 132, height: 96) }
            }.background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(attachment.filename).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 132, alignment: .leading)
        }
        .task(id: attachment.name) {
            guard attachment.isImage, let api else { return }
            do { image = NSImage(data: try await api.imageData(attachment)); failed = image == nil }
            catch { failed = true }
        }
        .sheet(isPresented: $preview) {
            VStack {
                HStack { Text(attachment.filename).font(.headline); Spacer(); Button("完成") { preview = false }.keyboardShortcut(.cancelAction) }
                if let image { Image(nsImage: image).resizable().scaledToFit() }
            }.padding(20).frame(minWidth: 500, idealWidth: 720, minHeight: 400, idealHeight: 600)
        }
    }
}

struct MarkdownPreview: View {
    var content: String
    var body: some View {
        // Block-level Markdown using native text, without executing HTML or fetching remote embeds.
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(content.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("### ") { inline(String(line.dropFirst(4))).font(.headline) }
                else if line.hasPrefix("## ") { inline(String(line.dropFirst(3))).font(.title3.bold()) }
                else if line.hasPrefix("# ") { inline(String(line.dropFirst(2))).font(.title2.bold()) }
                else if line.hasPrefix("- [ ] ") { HStack(alignment: .top) { Image(systemName: "square"); inline(String(line.dropFirst(6))) } }
                else if line.hasPrefix("- [x] ") { HStack(alignment: .top) { Image(systemName: "checkmark.square"); inline(String(line.dropFirst(6))) } }
                else if line.hasPrefix("- ") { HStack(alignment: .top) { Text("•"); inline(String(line.dropFirst(2))) } }
                else { inline(line.isEmpty ? " " : line) }
            }
        }.font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func inline(_ string: String) -> Text {
        Text((try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(string))
    }
}
