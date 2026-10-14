import AppKit
import SwiftUI
@testable import TableProEditorKit
import TableProTestSupport
import Testing

@MainActor
struct SuggestionPanelFocusTests {
    @MainActor
    @Test func test_panel_neverAcceptsKeyOrMainStatus() throws {
        let controller = SuggestionController()
        let window = try #require(controller.window)

        #expect(!window.canBecomeKey)
        #expect(!window.canBecomeMain)
        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect((window as? NSPanel)?.becomesKeyOnlyIfNeeded == true)
        #expect(window.tabbingMode == .disallowed)
    }

    @MainActor
    @Test func test_contentViewHierarchy_containsNoFocusableTableView() async throws {
        let controller = SuggestionController()
        let window = try #require(controller.window)

        controller.model.items = [PanelStubEntry(label: "SELECT"), PanelStubEntry(label: "SET")]
        window.setContentSize(NSSize(width: 300, height: 200))
        window.orderFrontRegardless()
        defer { window.close() }
        try await waitUntilMounted(window)

        let contentView = try #require(window.contentView)
        #expect(firstFocusableTableView(in: contentView) == nil)
    }

    @MainActor
    @Test func test_showWindowAttachedTo_preservesParentFirstResponder() async throws {
        let (parentWindow, textViewController) = Mock.windowedTextViewController(theme: Mock.theme())
        let controller = SuggestionController()
        defer {
            controller.close()
            parentWindow.close()
        }

        parentWindow.orderFrontRegardless()
        let textView = try #require(textViewController.textView)
        #expect(parentWindow.makeFirstResponder(textView))

        controller.model.items = [PanelStubEntry(label: "SELECT")]
        controller.showWindow(attachedTo: parentWindow)
        try await waitUntilMounted(try #require(controller.window))

        #expect(parentWindow.firstResponder === textView)
    }

    @MainActor
    @Test func test_showWindowAttachedTo_reattachesFromPreviousParent() throws {
        let (firstParent, _) = Mock.windowedTextViewController(theme: Mock.theme())
        let (secondParent, _) = Mock.windowedTextViewController(theme: Mock.theme())
        let controller = SuggestionController()
        let window = try #require(controller.window)
        defer {
            controller.close()
            firstParent.close()
            secondParent.close()
        }

        controller.showWindow(attachedTo: firstParent)
        #expect(window.parent === firstParent)

        controller.showWindow(attachedTo: secondParent)
        #expect(window.parent === secondParent)
        #expect(!(firstParent.childWindows?.contains(window) ?? false))
    }

    @MainActor
    @Test func test_close_detachesPanelFromParent() throws {
        let (parentWindow, _) = Mock.windowedTextViewController(theme: Mock.theme())
        let controller = SuggestionController()
        let window = try #require(controller.window)
        defer { parentWindow.close() }

        controller.showWindow(attachedTo: parentWindow)
        #expect(window.parent === parentWindow)

        controller.close()

        #expect(window.parent == nil)
        #expect(!(parentWindow.childWindows?.contains(window) ?? false))
    }

    // The background mounts in the same SwiftUI pass as the rows, so its view proves the rows are in the hierarchy.
    @MainActor
    private func waitUntilMounted(_ window: NSWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitUntil {
            guard let contentView = window.contentView else { return false }
            return firstView(of: NSVisualEffectView.self, in: contentView) != nil
        }
    }

    @MainActor
    private func firstFocusableTableView(in view: NSView) -> NSTableView? {
        firstView(of: NSTableView.self, in: view)
    }

    @MainActor
    private func firstView<View: NSView>(of type: View.Type, in view: NSView) -> View? {
        if let match = view as? View {
            return match
        }
        for subview in view.subviews {
            if let found = firstView(of: type, in: subview) {
                return found
            }
        }
        return nil
    }
}

private struct PanelStubEntry: CodeSuggestionEntry {
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
