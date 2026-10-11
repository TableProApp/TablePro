import AppKit
import Carbon.HIToolbox
import SwiftUI
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
private final class ControllerCapture: TextViewCoordinator {
    weak var controller: TextViewController?

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
    }
}

@MainActor
private final class EditorHostModel: ObservableObject {
    @Published var text: String
    /// Invalidates the host only on a real change, the way the query editor's `@State` does.
    var state = SourceEditorState() {
        willSet {
            guard newValue != state else { return }
            objectWillChange.send()
        }
    }
    @Published var followedCursor: [CursorPosition] = []

    init(text: String) {
        self.text = text
    }
}

/// Hosts the editor the way the query editor does: the host copies every cursor change into state of its own, so each
/// caret move re-renders the host and drives a second representable update after the one the move itself caused.
private struct EditorHost: View {
    @ObservedObject var model: EditorHostModel
    let capture: ControllerCapture

    var body: some View {
        VStack(spacing: 0) {
            SourceEditor(
                $model.text,
                language: .default,
                configuration: Mock.config(),
                state: $model.state,
                highlightProviders: [],
                coordinators: [capture]
            )
            Text("\(model.followedCursor.first?.range.location ?? 0)")
        }
        .onChange(of: model.state.cursorPositions) { newValue in
            model.followedCursor = newValue ?? []
        }
    }
}

/// The editor writes its scroll position and find state back to the binding a run-loop turn late, and the display
/// cycle can lay the host out before that, so an update pass reads the value from before the change (#3239).
@Suite("Source editor state sync", .serialized)
@MainActor
struct SourceEditorStateSyncTests {
    private static let document = (0..<3_000)
        .map { "SELECT \($0), 'value \($0)' AS label FROM some_table WHERE id = \($0);" }
        .joined(separator: "\n")
    private let model: EditorHostModel
    private var document: String { Self.document }
    private let capture = ControllerCapture()
    private let window: NSWindow

    init() {
        model = EditorHostModel(text: Self.document)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorHost(model: model, capture: capture))
    }

    private func loadedController(caretAt offset: Int = 0) throws -> TextViewController {
        window.orderFront(nil)
        settle()
        let controller = try #require(capture.controller)
        _ = window.makeFirstResponder(controller.textView)
        controller.setCursorPositions([CursorPosition(range: NSRange(location: offset, length: 0))], scrollToVisible: true)
        settle()
        return controller
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }

    /// Lays the host out before the editor's deferred write-back runs, which is the order the display cycle uses.
    private func layOutBeforeWriteBack() {
        window.layoutIfNeeded()
        window.layoutIfNeeded()
    }

    private func press(_ keyCode: Int, _ functionKey: Int, modifiers: NSEvent.ModifierFlags) throws {
        let character = try #require(UnicodeScalar(functionKey))
        let event = try #require(Mock.keyDown(
            keyCode: keyCode,
            characters: String(Character(character)),
            modifiers: modifiers.union([.numericPad, .function]),
            in: window
        ))
        window.sendEvent(event)
    }

    private func isVisible(offset: Int, in controller: TextViewController) throws -> Bool {
        let rect = try #require(controller.textView.layoutManager.rectForOffset(offset))
        let visible = controller.textView.visibleRect
        return visible.minY...visible.maxY ~= rect.midY
    }

    private func caretIsVisible(in controller: TextViewController) throws -> Bool {
        let caret = try #require(controller.textView.selectionManager.textSelections.first).range.location
        return try isVisible(offset: caret, in: controller)
    }

    @Test("Cmd+Down keeps the end of a long document in view")
    func commandDownFollowsTheCaret() throws {
        let controller = try loadedController()
        defer { window.orderOut(nil) }

        try press(kVK_DownArrow, NSDownArrowFunctionKey, modifiers: .command)
        layOutBeforeWriteBack()
        settle()

        #expect(controller.textView.selectionManager.textSelections.first?.range.location == (document as NSString).length)
        #expect(try caretIsVisible(in: controller), "Scrolled to \(controller.scrollPosition.y)")
    }

    @Test("Cmd+Up from the end of a long document brings the start back into view")
    func commandUpFollowsTheCaret() throws {
        let controller = try loadedController(caretAt: (document as NSString).length)
        defer { window.orderOut(nil) }
        try #require(controller.scrollPosition.y > 0, "The view starts at the end of the document")

        try press(kVK_UpArrow, NSUpArrowFunctionKey, modifiers: .command)
        layOutBeforeWriteBack()
        settle()

        #expect(controller.textView.selectionManager.textSelections.first?.range.location == 0)
        #expect(try caretIsVisible(in: controller), "Scrolled to \(controller.scrollPosition.y)")
    }

    @Test("Cmd+Shift+Down extends the selection and keeps its moving end in view")
    func commandShiftDownFollowsTheMovingEnd() throws {
        let controller = try loadedController()
        defer { window.orderOut(nil) }

        try press(kVK_DownArrow, NSDownArrowFunctionKey, modifiers: [.command, .shift])
        layOutBeforeWriteBack()
        settle()

        let length = (document as NSString).length
        #expect(controller.textView.selectionManager.textSelections.first?.range == NSRange(location: 0, length: length))
        #expect(try isVisible(offset: length, in: controller), "Scrolled to \(controller.scrollPosition.y)")
    }

    @Test("Inserting a long script keeps the caret at its end in view")
    func insertingALongScriptFollowsTheCaret() throws {
        let controller = try loadedController()
        defer { window.orderOut(nil) }

        controller.textView.insertText(document + "\n", replacementRange: NSRange(location: 0, length: 0))
        layOutBeforeWriteBack()
        settle()

        #expect(try caretIsVisible(in: controller), "Scrolled to \(controller.scrollPosition.y)")
    }

    @Test("A scroll position the host sets is still applied")
    func hostScrollPositionIsApplied() throws {
        let controller = try loadedController()
        defer { window.orderOut(nil) }

        model.state.scrollPosition = CGPoint(x: 0, y: 4_000)
        layOutBeforeWriteBack()
        settle()

        #expect(abs(controller.scrollPosition.y - 4_000) <= 0.5)
    }

    @Test("Use Selection for Find keeps its term when the caret moves afterwards")
    func useSelectionForFindSurvivesACaretMove() throws {
        let controller = try loadedController()
        defer { window.orderOut(nil) }
        let viewModel = try #require(controller.findViewController?.viewModel)

        viewModel.findText = "value"
        NotificationCenter.default.post(name: FindPanelViewModel.Notifications.textDidChange, object: controller)
        settle()
        try #require(model.state.findText == "value")

        let secondLine = ((document as NSString).range(of: "\n").location) + 1
        controller.setCursorPositions([CursorPosition(range: NSRange(location: secondLine, length: 6))])
        controller.useSelectionForFind()
        try press(kVK_DownArrow, NSDownArrowFunctionKey, modifiers: [])
        layOutBeforeWriteBack()
        settle()

        #expect(viewModel.findText == "SELECT")
    }

    @Test("A query the host replaces after a caret key that moved nothing reaches the editor")
    func hostTextAfterAnUnmovedCaretIsApplied() throws {
        let controller = try loadedController()
        defer { window.orderOut(nil) }

        try press(kVK_UpArrow, NSUpArrowFunctionKey, modifiers: .command)
        settle()
        model.text = "SELECT 1"
        layOutBeforeWriteBack()
        settle()

        #expect(controller.textView.string == "SELECT 1")
    }
}
