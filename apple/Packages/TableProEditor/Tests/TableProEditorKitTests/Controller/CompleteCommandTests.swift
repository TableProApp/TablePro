import AppKit
import SwiftUI
@testable import TableProEditorKit
import TableProTestSupport
import TableProTextEngine
import Testing

@MainActor
private final class CompleteCapture: TextViewCoordinator {
    weak var controller: TextViewController?

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
    }
}

@MainActor
private final class RecordingCompletionDelegate: CodeSuggestionDelegate {
    private(set) var manualRequests = 0

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> CodeSuggestionResponse? {
        if isManualTrigger { manualRequests += 1 }
        return nil
    }

    func completionOnCursorMove(textView: TextViewController, cursorPosition: CursorPosition) -> [CodeSuggestionEntry]? {
        nil
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) { }
}

private struct CompleteHost: View {
    @State private var text = "SELECT "
    @State private var state = SourceEditorState()
    let capture: CompleteCapture
    let delegate: RecordingCompletionDelegate

    var body: some View {
        SourceEditor(
            $text,
            language: .default,
            configuration: Mock.config(),
            state: $state,
            highlightProviders: [],
            coordinators: [capture],
            completionDelegate: delegate
        )
    }
}

// `Option+Escape` and F5 send `complete:`, which the text view does not answer, so it has to reach the controller
// through the responder chain of an editor hosted the way the app hosts it.
@MainActor
struct CompleteCommandTests {
    @Test("complete: from the text view asks the completion delegate for a manual list")
    func completeReachesTheController() async throws {
        let capture = CompleteCapture()
        let delegate = RecordingCompletionDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CompleteHost(capture: capture, delegate: delegate))
        window.orderFront(nil)
        defer {
            SuggestionController.shared.close()
            SuggestionController.shared.model.activeTextView = nil
            window.orderOut(nil)
        }
        try await waitUntil(timeout: .seconds(5)) { capture.controller?.view.window != nil }
        let controller = try #require(capture.controller)
        _ = window.makeFirstResponder(controller.textView)
        controller.setCursorPositions([CursorPosition(range: NSRange(location: 7, length: 0))])

        controller.textView.doCommand(by: #selector(NSResponder.complete(_:)))

        try await waitUntil(timeout: .seconds(5)) { delegate.manualRequests == 1 }
    }
}
