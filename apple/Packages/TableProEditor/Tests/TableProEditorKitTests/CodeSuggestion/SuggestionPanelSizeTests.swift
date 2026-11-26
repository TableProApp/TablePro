import AppKit
import SwiftUI
@testable import TableProEditorKit
import Testing

@MainActor
struct SuggestionPanelSizeTests {
    private struct Entry: CodeSuggestionEntry {
        var label: String
        var detail: String?
        var documentation: String?
        var pathComponents: [String]? { nil }
        var targetPosition: CursorPosition? { nil }
        var sourcePreview: String? { nil }
        var image: Image { Image(systemName: "tablecells") }
        var imageColor: Color { .blue }
        var deprecated: Bool { false }
    }

    private static let lists: [[Entry]] = [
        [Entry(label: "SELECT")],
        (0..<3).map { Entry(label: "orders_\($0)", detail: "Table") },
        (0..<40).map { Entry(label: "customer_order_line_\($0)", detail: "public") },
        [Entry(label: "COUNT", detail: "Function", documentation: "Counts the rows"), Entry(label: "COALESCE")],
        [Entry(label: String(repeating: "wide_", count: 30), detail: "Table")]
    ]

    private func contentSize(of window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    @Test("the panel takes its final size in the turn its items are set, before anything orders it front")
    func sizedInTheTurnItemsAreSet() throws {
        let controller = SuggestionController()
        let window = try #require(controller.window)
        let hostingView = try #require(window.contentView as? NSHostingView<SuggestionContentView>)

        for items in Self.lists {
            controller.model.items = items

            hostingView.layoutSubtreeIfNeeded()
            let fitting = hostingView.fittingSize
            #expect(!window.isVisible)
            #expect(contentSize(of: window) == NSSize(width: max(fitting.width, 256), height: fitting.height))
        }
    }

    @Test("moving the selection onto a row with a preview grows the panel by the preview, and back")
    func previewChangesTheHeight() throws {
        let controller = SuggestionController()
        let window = try #require(controller.window)
        let hostingView = try #require(window.contentView as? NSHostingView<SuggestionContentView>)
        controller.model.items = [Entry(label: "COALESCE"), Entry(label: "COUNT", documentation: "Counts the rows")]
        let withoutPreview = contentSize(of: window)

        controller.model.moveDown()
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize

        #expect(contentSize(of: window).height == fitting.height)
        #expect(contentSize(of: window).height > withoutPreview.height)
        controller.model.moveUp()
        #expect(contentSize(of: window) == withoutPreview)
    }

    @Test("a re-ranked list keeps each row's identity, and repeats of one row stay distinct")
    func rowIdentityFollowsTheEntry() {
        let before = SuggestionRowID.ids(for: [Entry(label: "a"), Entry(label: "b"), Entry(label: "a", detail: "x")])
        let after = SuggestionRowID.ids(for: [Entry(label: "b"), Entry(label: "a"), Entry(label: "b")])

        #expect(before[1] == after[0])
        #expect(before[0] == after[1])
        #expect(after[0] != after[2])
        #expect(Set(before).count == before.count)
    }
}
