import SwiftUI
import MemosCore

enum Theme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.38, green: 0.72, blue: 0.90, alpha: 1)
            : NSColor(red: 0.05, green: 0.43, blue: 0.63, alpha: 1)
    })
    static let paper = Color(nsColor: .textBackgroundColor)
    static let sidebar = adaptive(light: 0.965, dark: 0.105)
    static let field = adaptive(light: 0.955, dark: 0.16)
    private static func adaptive(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }
    static let separator = Color(nsColor: .separatorColor)
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
