//
//  FindAndReplaceEntryTests.swift
//  TableProEditorKitTests
//
//  The panel used to reset itself to `.find` every time it opened, which put Replace behind the
//  popup in the panel itself and threw away the replacement text on the way past.
//

import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
@Suite("Find and replace entry points")
struct FindAndReplaceEntryTests {
    private final class Target: FindPanelTarget {
        var emphasisManager: EmphasisManager?
        var findPanelTargetView: NSView
        var cursorPositions: [CursorPosition] = []
        var textView: TextView!

        init(text: String) {
            findPanelTargetView = NSView()
            textView = TextView(string: text)
        }

        func setCursorPositions(_ positions: [CursorPosition], scrollToVisible: Bool) {
            cursorPositions = positions
        }
        func updateCursorPosition() { }
        func findPanelWillShow(panelHeight: CGFloat) { }
        func findPanelWillHide(panelHeight: CGFloat) { }
        func findPanelModeDidChange(to mode: FindPanelMode) { }
    }

    private static func controller(text: String = "") -> FindViewController {
        let controller = FindViewController(target: Target(text: text), childView: NSView())
        controller.loadView()
        return controller
    }

    @Test("Opening with no mode named keeps the mode the panel was left in")
    func openKeepsTheModeItWasLeftIn() {
        let controller = Self.controller()

        controller.showFindPanel(mode: .replace)
        controller.hideFindPanel(animated: false)
        controller.showFindPanel()

        #expect(controller.viewModel.mode == .replace)
    }

    @Test("Opening in replace mode shows the replacement field")
    func openInReplaceMode() {
        let controller = Self.controller()

        controller.showFindPanel(mode: .replace)

        #expect(controller.viewModel.mode == .replace)
        #expect(controller.viewModel.panelHeight == 54)
    }

    @Test("Naming a mode switches a panel that is already open")
    func namingAModeSwitchesAnOpenPanel() {
        let controller = Self.controller()

        controller.showFindPanel(mode: .find)
        controller.showFindPanel(mode: .replace)

        #expect(controller.viewModel.mode == .replace)
        #expect(controller.viewModel.isShowingFindPanel)
    }

    @Test("Replacement text survives closing and reopening the panel")
    func replacementTextSurvivesAReopen() {
        let controller = Self.controller()
        controller.showFindPanel(mode: .replace)
        controller.viewModel.findText = "alpha"
        controller.viewModel.replaceText = "beta"

        controller.hideFindPanel(animated: false)
        controller.showFindPanel()

        #expect(controller.viewModel.replaceText == "beta")
        #expect(controller.viewModel.mode == .replace)
    }
}

@MainActor
@Suite("Use selection for find")
struct UseSelectionForFindTests {
    private static func controller(_ text: String) -> TextViewController {
        let controller = TextViewController(
            string: text,
            language: .default,
            configuration: Mock.config(),
            cursorPositions: [],
            highlightProviders: []
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    @Test("An empty caret offers nothing to search for")
    func emptyCaretHasNoSelection() {
        let controller = Self.controller("SELECT name FROM users")
        controller.setCursorPositions([CursorPosition(range: NSRange(location: 3, length: 0))])

        #expect(!controller.hasSelectionForFind)
    }

    @Test("The selected text becomes the search term")
    func selectionBecomesTheSearchTerm() throws {
        let controller = Self.controller("SELECT name FROM name_map")
        controller.setCursorPositions([CursorPosition(range: NSRange(location: 7, length: 4))])
        try #require(controller.hasSelectionForFind)

        controller.useSelectionForFind()

        let viewModel = try #require(controller.findViewController?.viewModel)
        #expect(viewModel.findText == "name")
        #expect(viewModel.findMatches.count == 2)
    }

    @Test("It leaves the panel shut and the caret where it was")
    func panelStaysShutAndCaretStays() throws {
        let controller = Self.controller("SELECT name FROM name_map")
        let selection = NSRange(location: 7, length: 4)
        controller.setCursorPositions([CursorPosition(range: selection)])

        controller.useSelectionForFind()

        let viewModel = try #require(controller.findViewController?.viewModel)
        #expect(!viewModel.isShowingFindPanel)
        #expect(controller.cursorPositions.first?.range == selection)
    }

    @Test("With nothing selected the search term is left alone")
    func emptySelectionLeavesTheTermAlone() throws {
        let controller = Self.controller("SELECT name FROM users")
        let viewModel = try #require(controller.findViewController?.viewModel)
        viewModel.findText = "users"
        controller.setCursorPositions([CursorPosition(range: NSRange(location: 3, length: 0))])

        controller.useSelectionForFind()

        #expect(viewModel.findText == "users")
    }
}
