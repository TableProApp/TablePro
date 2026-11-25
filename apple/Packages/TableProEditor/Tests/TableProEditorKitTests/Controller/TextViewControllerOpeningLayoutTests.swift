import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
struct TextViewControllerOpeningLayoutTests {
    private let script = (0..<20_000)
        .map { "SELECT * FROM table_\($0) WHERE id = \($0);" }
        .joined(separator: "\n")

    private func lineFragmentViews(of controller: TextViewController) -> [LineFragmentView] {
        controller.textView.subviews.compactMap { $0 as? LineFragmentView }
    }

    private func linesInBand(of textView: TextView) -> Int {
        guard let manager = textView.layoutManager else { return 0 }
        let visible = textView.visibleRect
        let minY = max(visible.minY - manager.verticalLayoutPadding, 0)
        let maxY = visible.maxY + manager.verticalLayoutPadding
        return manager.linesStartingAt(minY, until: maxY).filter { $0.yPos < maxY }.count
    }

    // SQLEditorCoordinator loads the view inside the controller's init, before any frame is set.
    @Test
    func loadingAroundALongScriptLaysOutOnlyTheFirstScreen() {
        let controller = TextViewController(
            string: script,
            language: .sql,
            configuration: Mock.config(),
            cursorPositions: [],
            highlightProviders: []
        )

        controller.loadView()

        #expect(lineFragmentViews(of: controller).count < 100)
    }

    @Test
    func sizingTheLoadedEditorKeepsViewsToTheBand() {
        let controller = TextViewController(
            string: script,
            language: .sql,
            configuration: Mock.config(),
            cursorPositions: [],
            highlightProviders: []
        )
        controller.loadView()

        controller.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        controller.view.layoutSubtreeIfNeeded()

        let bandLines = linesInBand(of: controller.textView)
        #expect(bandLines > 0)
        #expect(lineFragmentViews(of: controller).count <= bandLines * 2)
    }
}
