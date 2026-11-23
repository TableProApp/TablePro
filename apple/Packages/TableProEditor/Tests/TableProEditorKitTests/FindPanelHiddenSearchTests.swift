import AppKit
import Combine
@testable import TableProEditorKit
import TableProTextEngine
import Testing

// A term kept after the panel closes used to search the whole document on every edit and every document swap.
@MainActor
struct FindPanelHiddenSearchTests {
    private final class SearchCounter {
        var count = 0
        private var observation: AnyCancellable?

        init(_ model: FindPanelViewModel) {
            observation = model.$findMatches.dropFirst().sink { [weak self] _ in self?.count += 1 }
        }
    }

    private func editor(_ text: String, find term: String, caret: Int = 0) throws -> (TextViewController, FindPanelViewModel) {
        let controller = Mock.loadedTextViewController(string: text)
        controller.setCursorPositions([CursorPosition(range: NSRange(location: caret, length: 0))])
        let model = try #require(controller.findViewController?.viewModel)
        model.findText = term
        model.find()
        return (controller, model)
    }

    private func append(_ text: String, to controller: TextViewController) {
        let end = (controller.textView.string as NSString).length
        controller.textView.replaceCharacters(in: NSRange(location: end, length: 0), with: text)
    }

    private func selection(_ controller: TextViewController) -> [NSRange] {
        controller.textView.selectionManager.textSelections.map(\.range)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test
    func editsWithThePanelHiddenRunNoSearch() throws {
        let (controller, model) = try editor("a a a", find: "a")
        let searches = SearchCounter(model)

        for _ in 0..<100 {
            append(" a", to: controller)
        }

        #expect(searches.count == 0)

        model.moveToNextMatch()

        #expect(searches.count == 1)
        #expect(model.matchCount == 103)
    }

    @Test
    func undoWithThePanelHiddenRunsNoSearch() throws {
        let (controller, model) = try editor("a a a", find: "a")
        append(" a", to: controller)
        let searches = SearchCounter(model)

        controller.textView.undoManager?.undo()

        #expect(controller.textView.string == "a a a")
        #expect(searches.count == 0)
    }

    // The search a hidden edit skipped picks its current match from the caret that edit left, as it did when it ran
    // on the edit, so a caret moved since then does not change where Find Next goes.
    @Test
    func findNextAfterHiddenEditsGoesOnFromTheCaretTheEditLeft() throws {
        let (controller, model) = try editor("a a a a", find: "a", caret: 0)
        for _ in 0..<10 {
            append(" b", to: controller)
        }
        let end = (controller.textView.string as NSString).length
        controller.setCursorPositions([CursorPosition(range: NSRange(location: end, length: 0))])

        model.moveToNextMatch()

        #expect(model.currentFindMatchIndex == 1)
        #expect(selection(controller) == [NSRange(location: 2, length: 1)])
    }

    @Test
    func showingThePanelAfterHiddenEditsCountsTheTextAsItIs() throws {
        let (controller, model) = try editor("a a a", find: "a")
        for _ in 0..<5 {
            append(" a", to: controller)
        }

        controller.findViewController?.showFindPanel(animated: false)

        #expect(model.matchCount == 8)
    }

    @Test
    func replacingTheDocumentWithThePanelHiddenRunsNoSearch() async throws {
        let (controller, model) = try editor("a a a", find: "a")
        let searches = SearchCounter(model)

        controller.setText("a b a b")
        await drainMainQueue()

        #expect(searches.count == 0)

        controller.findViewController?.showFindPanel(animated: false)

        #expect(model.matchCount == 2)
    }

    @Test
    func editsWithThePanelShownStillSearch() throws {
        let (controller, model) = try editor("a a a", find: "a")
        controller.findViewController?.showFindPanel(animated: false)
        let searches = SearchCounter(model)

        append(" a", to: controller)

        #expect(searches.count == 1)
        #expect(model.matchCount == 4)
    }
}
