import AppKit
@testable import CodeEditSourceEditor
import SwiftUI
import XCTest

final class SuggestionPanelFocusTests: XCTestCase {
    @MainActor
    func test_panel_neverAcceptsKeyOrMainStatus() throws {
        let controller = SuggestionController()
        let window = try XCTUnwrap(controller.window)

        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual((window as? NSPanel)?.becomesKeyOnlyIfNeeded, true)
        XCTAssertEqual(window.tabbingMode, .disallowed)
    }

    @MainActor
    func test_contentViewHierarchy_containsNoFocusableTableView() throws {
        let controller = SuggestionController()
        let window = try XCTUnwrap(controller.window)

        controller.model.items = [PanelStubEntry(label: "SELECT"), PanelStubEntry(label: "SET")]
        window.setContentSize(NSSize(width: 300, height: 200))
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let contentView = try XCTUnwrap(window.contentView)
        XCTAssertNil(firstFocusableTableView(in: contentView))
    }

    @MainActor
    func test_showWindowAttachedTo_preservesParentFirstResponder() throws {
        let (parentWindow, textViewController) = Mock.windowedTextViewController(theme: Mock.theme())
        let controller = SuggestionController()
        defer {
            controller.close()
            parentWindow.close()
        }

        parentWindow.orderFrontRegardless()
        let textView = try XCTUnwrap(textViewController.textView)
        XCTAssertTrue(parentWindow.makeFirstResponder(textView))

        controller.model.items = [PanelStubEntry(label: "SELECT")]
        controller.showWindow(attachedTo: parentWindow)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertTrue(parentWindow.firstResponder === textView)
    }

    @MainActor
    func test_showWindowAttachedTo_reattachesFromPreviousParent() throws {
        let (firstParent, _) = Mock.windowedTextViewController(theme: Mock.theme())
        let (secondParent, _) = Mock.windowedTextViewController(theme: Mock.theme())
        let controller = SuggestionController()
        let window = try XCTUnwrap(controller.window)
        defer {
            controller.close()
            firstParent.close()
            secondParent.close()
        }

        controller.showWindow(attachedTo: firstParent)
        XCTAssertTrue(window.parent === firstParent)

        controller.showWindow(attachedTo: secondParent)
        XCTAssertTrue(window.parent === secondParent)
        XCTAssertFalse(firstParent.childWindows?.contains(window) ?? false)
    }

    @MainActor
    func test_close_detachesPanelFromParent() throws {
        let (parentWindow, _) = Mock.windowedTextViewController(theme: Mock.theme())
        let controller = SuggestionController()
        let window = try XCTUnwrap(controller.window)
        defer { parentWindow.close() }

        controller.showWindow(attachedTo: parentWindow)
        XCTAssertTrue(window.parent === parentWindow)

        controller.close()

        XCTAssertNil(window.parent)
        XCTAssertFalse(parentWindow.childWindows?.contains(window) ?? false)
    }

    @MainActor
    private func firstFocusableTableView(in view: NSView) -> NSTableView? {
        if let tableView = view as? NSTableView {
            return tableView
        }
        for subview in view.subviews {
            if let found = firstFocusableTableView(in: subview) {
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
