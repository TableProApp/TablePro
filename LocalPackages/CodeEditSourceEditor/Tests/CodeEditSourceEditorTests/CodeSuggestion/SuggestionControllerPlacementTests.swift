import AppKit
@testable import CodeEditSourceEditor
import XCTest

final class SuggestionControllerPlacementTests: XCTestCase {
    @MainActor
    func test_updateWindowSize_reclampsXAfterGrowingPastInitialPlacement() throws {
        let controller = SuggestionController()
        guard let window = controller.window, let screen = window.screen else {
            throw XCTSkip("No screen available in this environment")
        }

        let editorFrame = NSRect(
            x: screen.visibleFrame.minX + 50,
            y: screen.visibleFrame.minY + 50,
            width: 400,
            height: 300
        )
        let cursorRect = NSRect(x: editorFrame.maxX - 30, y: editorFrame.minY + 150, width: 6, height: 16)

        controller.constrainWindowToScreenEdges(
            cursorRect: cursorRect, font: .systemFont(ofSize: 12), editorFrame: editorFrame
        )
        controller.updateWindowSize(newSize: NSSize(width: 280, height: 200))

        XCTAssertLessThanOrEqual(controller.window?.frame.maxX ?? .infinity, editorFrame.maxX)
    }
}
