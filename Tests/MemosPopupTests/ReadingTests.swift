import XCTest
import SwiftUI
import MemosCore
@testable import MemosPopup

final class ReadingTests: XCTestCase {
    static let sample = """
    # 周末的阅读笔记

    让记录更清楚，也更容易回看。支持 **重点**、*强调*、~~删除线~~ 和 `inline code`。
    这是同一段的下一行。

    > 不必记下所有事情。
    > 留下真正想记住的部分。
    >
    > 第二段引用。

    ## 今天完成了什么

    - [x] 整理阅读笔记
    - [ ] 留一点时间散步
      - 不带耳机，听听周围
      - 拍一张照片

    3. 先记录
    4. 再回看

    ```swift
    let thought = "Hello, Memos"
    print(thought)
    // # 代码中的标题不会被误解析
    ```

    | 内容 | 状态 |
    | :--- | ---: |
    | 阅读 | 完成 |
    | 散步 | 待办 |

    ---

    [阅读更多](https://example.com) · #日常
    """

    func testDocumentPreservesCodeQuotesNestedListsAndTable() {
        let blocks = ReadingDocument(Self.sample).blocks
        guard case .heading(1, let title) = blocks[0] else { return XCTFail("Missing heading") }
        XCTAssertEqual(String(title.characters), "周末的阅读笔记")
        guard case .paragraph(let paragraph) = blocks[1] else { return XCTFail("Missing paragraph") }
        XCTAssertTrue(String(paragraph.characters).contains("这是同一段"))
        XCTAssertFalse(String(paragraph.characters).contains("**"))
        XCTAssertTrue(paragraph.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        guard case .quote(let quote) = blocks[2] else { return XCTFail("Missing quote") }
        XCTAssertEqual(quote.count, 2)
        guard case .list(let tasks) = blocks[4] else { return XCTFail("Missing tasks") }
        XCTAssertEqual(tasks.map(\.0), ["☑", "☐"])
        guard case .list(let nested) = tasks[1].1[1] else { return XCTFail("Lost nested list") }
        XCTAssertEqual(nested.count, 2)
        guard case .list(let ordered) = blocks[5] else { return XCTFail("Missing ordered list") }
        XCTAssertEqual(ordered.map(\.0), ["3.", "4."])
        guard case .code(let code, let language) = blocks[6] else { return XCTFail("Missing code fence") }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(code.contains("// # 代码中的标题"))
        guard case .table(let rows, _) = blocks[7] else { return XCTFail("Missing table") }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(String(rows[1][0].characters), "阅读")
    }

    func testHardBreakAndSoftBreakHaveDifferentReadingSemantics() {
        guard case .paragraph(let text) = ReadingDocument("第一行\n第二行  \n第三行").blocks.first else { return XCTFail() }
        XCTAssertEqual(String(text.characters), "第一行 第二行\n第三行")
    }

    func testSummaryRemovesMarkdownAndUnsafeLinksAreNotInteractive() {
        let doc = ReadingDocument("# **周末**\n\n读一段 `code` 和 [链接](https://example.com)")
        XCTAssertEqual(doc.title, "周末")
        XCTAssertEqual(doc.summary, "读一段 code 和 链接")
        for url in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,test", "https://user:password@example.com"] {
            XCTAssertNil(ReadingDocument.safeLink(url))
        }
        XCTAssertNotNil(ReadingDocument.safeLink("https://example.com"))
        guard case .code(let html, _) = ReadingDocument("<script>alert('x')</script>").blocks.first else { return XCTFail("HTML should remain literal") }
        XCTAssertTrue(html.contains("<script>"))
    }

    func testImagesRemainInDocumentOrder() {
        let blocks = ReadingDocument("说明 ![示意图](https://example.com/image.png) 结束").blocks
        XCTAssertEqual(blocks.count, 3)
        guard case .image(let source, let label) = blocks[1] else { return XCTFail() }
        XCTAssertEqual(source, "https://example.com/image.png")
        XCTAssertEqual(label, "示意图")
    }

    @MainActor func testPopupOpenContinuesSameDraftWithoutSubmitting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppStore(testRoot: root)
        app.draft.content = "# 在主窗口继续\n\n尚未提交"
        let original = app.draft
        app.librarySelection = "memos/previous"
        var opened = false
        app.onLibrary = { opened = true }
        app.continueDraftInLibrary()
        XCTAssertTrue(opened)
        XCTAssertTrue(app.libraryComposing)
        XCTAssertNil(app.librarySelection)
        XCTAssertEqual(app.draft, original)
        XCTAssertEqual(try app.drafts?.load(key: "new"), original)
        XCTAssertNil(app.lastCreatedMemo)
    }
}
