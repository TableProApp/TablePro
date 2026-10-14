//
//  SuggestionPanelNativeColorTests.swift
//  TableProEditorKit
//

import AppKit
@testable import TableProEditorKit
import Testing

/// The panel used to build its background by scaling the editor background's red, green and blue components, which
/// raises for a system color in Light. It now draws a menu material and reads no theme color at all.
@MainActor
struct SuggestionPanelNativeColorTests {
    @Test("Completions open in Light over an editor whose background is a system color")
    func presentsOverASystemColorBackground() async throws {
        let (window, textViewController) = Mock.keyWindowedTextViewController()
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        textViewController.systemAppearance = .aqua
        #expect(textViewController.theme.background.type == .catalog)

        let controller = SuggestionController()
        defer { controller.close() }
        controller.showCompletions(
            textView: textViewController,
            delegate: ImmediateSuggestionDelegate(items: [StubSuggestionEntry(label: "SELECT")]),
            cursorPosition: CursorPosition(range: NSRange(location: 0, length: 0))
        )
        await controller.model.itemsRequestTask?.value

        #expect(controller.model.isPresented)
    }

    @Test("The panel draws a menu material behind its rows")
    func panelDrawsAMenuMaterial() throws {
        let controller = SuggestionController()
        let window = try #require(controller.window)
        controller.model.items = [StubSuggestionEntry(label: "SELECT")]
        window.setContentSize(NSSize(width: 300, height: 200))
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let background = try #require(visualEffectView(in: window.contentView))
        #expect(background.material == .menu)
        #expect(background.blendingMode == .behindWindow)
    }

    @Test("The panel background never takes a click from the tap that dismisses it")
    func backgroundIsNotHitTestable() {
        let view = SuggestionPanelBackground.makeView()
        view.frame = NSRect(x: 0, y: 0, width: 40, height: 40)

        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    private func visualEffectView(in view: NSView?) -> NSVisualEffectView? {
        guard let view else { return nil }
        if let effectView = view as? NSVisualEffectView {
            return effectView
        }
        for subview in view.subviews {
            if let found = visualEffectView(in: subview) {
                return found
            }
        }
        return nil
    }
}

@MainActor
private final class ImmediateSuggestionDelegate: CodeSuggestionDelegate {
    let items: [CodeSuggestionEntry]

    init(items: [CodeSuggestionEntry]) {
        self.items = items
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> CodeSuggestionResponse? {
        .answeringAnEmptyPrefix(items, at: cursorPosition)
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        nil
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {}
}
