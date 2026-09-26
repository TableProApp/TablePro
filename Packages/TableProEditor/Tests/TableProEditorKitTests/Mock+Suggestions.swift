import AppKit
import SwiftUI
@testable import TableProEditorKit

/// The SwiftPM test runner is not a foreground app, so no window it makes can become key and the
/// presentation guard in `showCompletions` is otherwise unreachable from a test.
final class AlwaysKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

struct StubSuggestionEntry: CodeSuggestionEntry {
    var label: String
    var detail: String? { nil }
    var documentation: String? { nil }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { nil }
    var image: Image { Image(systemName: "circle") }
    var imageColor: Color { .gray }
    var deprecated: Bool { false }
}

extension CodeSuggestionResponse {
    static func answeringAnEmptyPrefix(
        _ items: [CodeSuggestionEntry],
        at cursorPosition: CursorPosition
    ) -> CodeSuggestionResponse {
        CodeSuggestionResponse(
            items: items,
            windowPosition: cursorPosition,
            prefix: CodeSuggestionPrefix(range: NSRange(location: cursorPosition.range.location, length: 0), text: "")
        )
    }
}

extension Mock {
    @MainActor
    static func keyWindowedTextViewController(text: String = "") -> (NSWindow, TextViewController) {
        let controller = textViewController(theme: theme())
        let window = AlwaysKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFrontRegardless()
        controller.textView.setText(text)
        controller.view.layoutSubtreeIfNeeded()
        let end = (text as NSString).length
        controller.setCursorPositions([CursorPosition(range: NSRange(location: end, length: 0))])
        _ = window.makeFirstResponder(controller.textView)
        return (window, controller)
    }
}
