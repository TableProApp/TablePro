import Testing
import AppKit
import CodeEditTextView
@testable import CodeEditSourceEditor

@MainActor
struct FindPanelTests {
    class MockPanelTarget: FindPanelTarget {
        var emphasisManager: EmphasisManager?
        var findPanelTargetView: NSView
        var cursorPositions: [CursorPosition] = []
        var textView: TextView!
        var findPanelWillShowCalled = false
        var findPanelWillHideCalled = false
        var findPanelModeDidChangeCalled = false
        var lastMode: FindPanelMode?

        @MainActor init(text: String = "") {
            findPanelTargetView = NSView()
            textView = TextView(string: text)
        }

        func setCursorPositions(_ positions: [CursorPosition], scrollToVisible: Bool) { }
        func updateCursorPosition() { }
        func findPanelWillShow(panelHeight: CGFloat) {
            findPanelWillShowCalled = true
        }
        func findPanelWillHide(panelHeight: CGFloat) {
            findPanelWillHideCalled = true
        }
        func findPanelModeDidChange(to mode: FindPanelMode) {
            findPanelModeDidChangeCalled = true
            lastMode = mode
        }
    }

    let target = MockPanelTarget()
    let viewModel: FindPanelViewModel
    let viewController: FindViewController

    init() {
        viewController = FindViewController(target: target, childView: NSView())
        viewModel = viewController.viewModel
        viewController.loadView()
    }

    @Test func viewModelHeightUpdates() async throws {
        let model = FindPanelViewModel(target: MockPanelTarget())
        model.mode = .find
        #expect(model.panelHeight == 28)

        model.mode = .replace
        #expect(model.panelHeight == 54)
    }

    @Test func findPanelShowsOnCommandF() async throws {
        // Show find panel
        viewController.showFindPanel()

        // Verify panel is shown
        #expect(viewModel.isShowingFindPanel == true)
        #expect(target.findPanelWillShowCalled == true)

        // Hide find panel
        viewController.hideFindPanel()

        // Verify panel is hidden
        #expect(viewModel.isShowingFindPanel == false)
        #expect(target.findPanelWillHideCalled == true)
    }

    @Test func replaceFieldShowsWhenReplaceModeSelected() async throws {
        // Switch to replace mode
        viewModel.mode = .replace

        // Verify mode change
        #expect(viewModel.mode == .replace)
        #expect(target.findPanelModeDidChangeCalled == true)
        #expect(target.lastMode == .replace)
        #expect(viewModel.panelHeight == 54) // Height should be larger in replace mode

        // Switch back to find mode
        viewModel.mode = .find

        // Verify mode change
        #expect(viewModel.mode == .find)
        #expect(viewModel.panelHeight == 28) // Height should be smaller in find mode
    }

    @Test func wrapAroundEnabled() async throws {
        target.textView.string = "test1\ntest2\ntest3"
        viewModel.findText = "test"
        viewModel.wrapAround = true

        // Perform initial find
        viewModel.find()
        #expect(viewModel.findMatches.count == 3)

        // Move to last match
        viewModel.currentFindMatchIndex = 2

        // Move to next (should wrap to first)
        viewModel.moveToNextMatch()
        #expect(viewModel.currentFindMatchIndex == 0)

        // Move to previous (should wrap to last)
        viewModel.moveToPreviousMatch()
        #expect(viewModel.currentFindMatchIndex == 2)
    }

    @Test func wrapAroundDisabled() async throws {
        target.textView.string = "test1\ntest2\ntest3"
        viewModel.findText = "test"
        viewModel.wrapAround = false

        // Perform initial find
        viewModel.find()
        #expect(viewModel.findMatches.count == 3)

        // Move to last match
        viewModel.currentFindMatchIndex = 2

        // Move to next (should stay at last)
        viewModel.moveToNextMatch()
        #expect(viewModel.currentFindMatchIndex == 2)

        // Move to first match
        viewModel.currentFindMatchIndex = 0

        // Move to previous (should stay at first)
        viewModel.moveToPreviousMatch()
        #expect(viewModel.currentFindMatchIndex == 0)
    }

    @Test func findMatches() async throws {
        target.textView.string = "test1\ntest2\ntest3"
        viewModel.findText = "test"

        viewModel.find()

        #expect(viewModel.findMatches.count == 3)
        #expect(viewModel.findMatches[0].location == 0)
        #expect(viewModel.findMatches[1].location == 6)
        #expect(viewModel.findMatches[2].location == 12)
    }

    @Test func noMatchesFound() async throws {
        target.textView.string = "test1\ntest2\ntest3"
        viewModel.findText = "nonexistent"

        viewModel.find()

        #expect(viewModel.findMatches.isEmpty)
        #expect(viewModel.currentFindMatchIndex == nil)
    }

    @Test func matchCaseToggle() async throws {
        target.textView.string = "Test1\ntest2\nTEST3"

        // Test case-sensitive
        viewModel.matchCase = true
        viewModel.findText = "Test"
        viewModel.find()
        #expect(viewModel.findMatches.count == 1)

        // Test case-insensitive
        viewModel.matchCase = false
        viewModel.find()
        #expect(viewModel.findMatches.count == 3)
    }

    @Test func findMethodPickerOptions() async throws {
        target.textView.string = "test1 test2 test3"

        // Test contains
        viewModel.findMethod = .contains
        viewModel.findText = "test"
        viewModel.find()
        #expect(viewModel.findMatches.count == 3)

        // Test matchesWord
        viewModel.findMethod = .matchesWord
        viewModel.findText = "test1"
        viewModel.find()
        #expect(viewModel.findMatches.count == 1)

        // Test startsWith
        viewModel.findMethod = .startsWith
        viewModel.findText = "test"
        viewModel.find()
        #expect(viewModel.findMatches.count == 3)

        // Test endsWith
        viewModel.findMethod = .endsWith
        viewModel.findText = "3"
        viewModel.find()
        #expect(viewModel.findMatches.count == 1)

        // Test regularExpression
        viewModel.findMethod = .regularExpression
        viewModel.findText = "test\\d"
        viewModel.find()
        #expect(viewModel.findMatches.count == 3)
    }

    @Test func findMethodPickerOptionsWithComplexText() async throws {
        target.textView.string = "test1 test2 test3\nprefix_test test_suffix\nword_test_word"

        // Test contains with partial matches
        viewModel.findMethod = .contains
        viewModel.findText = "test"
        viewModel.find()
        #expect(viewModel.findMatches.count == 6)

        // Test matchesWord with word boundaries
        viewModel.findMethod = .matchesWord
        viewModel.findText = "test1"
        viewModel.find()
        #expect(viewModel.findMatches.count == 1)

        // Test startsWith with prefixes
        viewModel.findMethod = .startsWith
        viewModel.findText = "prefix"
        viewModel.find()
        #expect(viewModel.findMatches.count == 1)

        // Test endsWith with suffixes
        viewModel.findMethod = .endsWith
        viewModel.findText = "suffix"
        viewModel.find()
        #expect(viewModel.findMatches.count == 1)

        // Test regularExpression with complex pattern
        viewModel.findMethod = .regularExpression
        viewModel.findText = "test\\d"
        viewModel.find()
        #expect(viewModel.findMatches.count == 3)
    }
}
