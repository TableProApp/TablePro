import AppKit
import SwiftUI
@testable import TableProEditorKit
import TableProGrammars
import TableProTestSupport
import Testing

// The SQL editor's coordinator adds a subview to the controller's view, so `loadView` runs inside the controller's init.
@MainActor
private final class ViewLoadingCoordinator: TextViewCoordinator {
    func prepareCoordinator(controller: TextViewController) {
        _ = controller.view
    }
}

@MainActor
struct SourceEditorOpeningTextTests {
    private static let text = "SELECT id, name FROM users WHERE id = 1;\n"

    private func highlights(in controller: TextViewController) async throws -> [HighlightRange] {
        let client = try #require(controller.treeSitterClient)
        try await waitUntil(timeout: .seconds(30)) { client.state != nil }
        return client.queryHighlightsForRange(range: NSRange(location: 0, length: (Self.text as NSString).length))
    }

    @Test("Bound text is highlighted when a coordinator loads the view during init")
    func boundTextIsHighlighted() async throws {
        let editor = SourceEditor(
            .constant(Self.text),
            language: .sql,
            configuration: Mock.config(),
            state: .constant(SourceEditorState()),
            coordinators: [ViewLoadingCoordinator()]
        )
        let controller = editor.makeController(coordinator: editor.makeCoordinator())

        let found = try await highlights(in: controller)
        #expect(controller.textView.string == Self.text)
        #expect(!found.isEmpty)
    }

    @Test("A text storage is highlighted when a coordinator loads the view during init")
    func storageIsHighlighted() async throws {
        let editor = SourceEditor(
            NSTextStorage(string: Self.text),
            language: .sql,
            configuration: Mock.config(),
            state: .constant(SourceEditorState()),
            coordinators: [ViewLoadingCoordinator()]
        )
        let controller = editor.makeController(coordinator: editor.makeCoordinator())

        let found = try await highlights(in: controller)
        #expect(controller.textView.string == Self.text)
        #expect(!found.isEmpty)
    }
}
