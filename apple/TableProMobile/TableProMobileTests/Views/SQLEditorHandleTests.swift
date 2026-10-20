import SwiftUI
@testable import TableProMobile
import TableProModels
import TableProQuery
import Testing
import UIKit

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SQLEditorHandleTests {
    private static let script = "SELECT 1 AS a;\nSELECT 2 AS b;\nSELECT 3 AS c;"
    private static let first = NSRange(location: 0, length: 14)
    private static let second = NSRange(location: 15, length: 14)

    @Test("Run reads the caret and the selection from the editor as they stand")
    func runTargetReadsTheLiveEditor() throws {
        let editor = try HostedEditor(text: Self.script)
        defer { editor.tearDown() }

        editor.textView.selectedRange = NSRange(location: 20, length: 0)
        #expect(editor.handle.runTarget() == .statement("SELECT 2 AS b;", range: Self.second))

        editor.textView.selectedRange = Self.first
        #expect(editor.handle.runTarget() == .selection("SELECT 1 AS a;"))
    }

    @Test("Leaving the editor collapses the selection to its start")
    func endingEditingCollapsesTheSelection() throws {
        let editor = try HostedEditor(text: Self.script)
        defer { editor.tearDown() }
        try editor.focus()

        editor.textView.selectedRange = Self.second
        #expect(editor.handle.runTarget() == .selection("SELECT 2 AS b;"))

        editor.textView.resignFirstResponder()
        #expect(editor.textView.selectedRange == NSRange(location: 15, length: 0))
        #expect(editor.handle.runTarget() == .statement("SELECT 2 AS b;", range: Self.second))
    }

    @Test("The menu hears of a selection and of its end")
    func selectionIsPublished() async throws {
        let editor = try HostedEditor(text: Self.script)
        defer { editor.tearDown() }
        try editor.focus()

        editor.textView.selectedRange = Self.first
        await ObservedCondition.wait { editor.handle.hasSelection }

        editor.textView.selectedRange = NSRange(location: 3, length: 0)
        await ObservedCondition.wait { !editor.handle.hasSelection }
    }

    @Test("The band covers the statement at the caret and follows the caret")
    func bandFollowsTheCaret() throws {
        let editor = try HostedEditor(text: Self.script)
        defer { editor.tearDown() }
        try editor.focus()

        editor.textView.selectedRange = NSRange(location: 20, length: 0)
        #expect(editor.bandedRanges() == [Self.second])

        editor.textView.selectedRange = NSRange(location: 3, length: 0)
        #expect(editor.bandedRanges() == [Self.first])
        #expect(editor.textView.textLayoutManager != nil)
    }

    @Test("The band is drawn on the statement the caret moves to, and leaves the one it left")
    func bandIsRedrawnWhenTheCaretMoves() throws {
        let editor = try HostedEditor(text: Self.script)
        defer { editor.tearDown() }
        try editor.focus()

        editor.textView.selectedRange = NSRange(location: 44, length: 0)
        #expect(try editor.isBandDrawn(atCharacter: 38))
        #expect(try !editor.isBandDrawn(atCharacter: 23))

        editor.textView.selectedRange = NSRange(location: 20, length: 0)
        #expect(try editor.isBandDrawn(atCharacter: 23))
        #expect(try !editor.isBandDrawn(atCharacter: 38))
    }

    @Test("A selection hides the band")
    func selectionHidesTheBand() throws {
        let editor = try HostedEditor(text: Self.script)
        defer { editor.tearDown() }
        try editor.focus()

        editor.textView.selectedRange = NSRange(location: 15, length: 6)
        #expect(editor.bandedRanges().isEmpty)
    }

    @Test("Past the length where colouring stops there is no band, and Run still finds the statement")
    func longTextHasNoBand() throws {
        let text = String(repeating: "SELECT 1;\n", count: SQLSyntaxHighlighter.maxHighlightLength / 10 + 1)
        let editor = try HostedEditor(text: text)
        defer { editor.tearDown() }
        try editor.focus()

        editor.textView.selectedRange = NSRange(location: 3, length: 0)
        #expect(editor.bandedRanges().isEmpty)
        #expect(editor.handle.runTarget() == .statement("SELECT 1;", range: NSRange(location: 0, length: 9)))
    }

    @Test("A semicolon typed inside the band leaves no band on the text after it")
    func semicolonInsideTheBandLeavesNoResidue() async throws {
        let editor = try HostedEditor(text: Self.script)
        defer { editor.tearDown() }
        try editor.focus()

        editor.textView.selectedRange = NSRange(location: 23, length: 0)
        #expect(editor.bandedRanges() == [Self.second])

        editor.textView.insertText(";")
        let cut = NSRange(location: 15, length: 9)
        #expect(editor.bandedRanges() == [cut])

        await nextMainQueueTurn()
        editor.textView.layoutIfNeeded()
        #expect(editor.bandedRanges() == [cut])
        #expect(editor.textView.textLayoutManager != nil)
    }

    @Test("Run with nothing at the caret leaves a note that outlasts the resign and goes with the next edit")
    func nothingToRunNoteLastsUntilAnEdit() async throws {
        let editor = try HostedEditor(text: "SELECT 1;\n")
        defer { editor.tearDown() }
        try editor.focus()

        editor.textView.selectedRange = NSRange(location: 10, length: 0)
        #expect(editor.handle.runTarget() == .nothing)
        #expect(editor.bandedRanges().isEmpty)

        editor.handle.noteNothingToRun()
        await ObservedCondition.wait { editor.handle.runNote != nil }

        editor.textView.resignFirstResponder()
        await nextMainQueueTurn()
        #expect(editor.handle.runNote != nil)

        try editor.focus()
        editor.textView.insertText("S")
        await ObservedCondition.wait { editor.handle.runNote == nil }
    }

    @Test("Text set from outside the editor moves the band and drops the note")
    func externalTextMovesTheBand() async throws {
        let editor = try HostedEditor(text: "SELECT 1;\n")
        defer { editor.tearDown() }

        editor.textView.selectedRange = NSRange(location: 10, length: 0)
        editor.handle.noteNothingToRun()
        await ObservedCondition.wait { editor.handle.runNote != nil }

        editor.model.text = "SELECT 9;"
        await ObservedCondition.wait { editor.handle.runNote == nil }
        #expect(editor.bandedRanges() == [NSRange(location: 0, length: 9)])
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
@Observable
private final class EditorModel {
    var text: String
    var isFocused = false

    init(text: String) {
        self.text = text
    }
}

private struct EditorRoot: View {
    let model: EditorModel
    let handle: SQLEditorHandle

    var body: some View {
        @Bindable var model = model
        // Read here so a text set from outside re-renders the editor, as the @State query does in QueryEditorView.
        let _ = model.text
        SQLHighlightTextView(text: $model.text, isFocused: $model.isFocused, handle: handle)
            .frame(height: 320)
    }
}

@MainActor
private struct HostedEditor {
    let window: UIWindow
    let model: EditorModel
    let handle: SQLEditorHandle
    let textView: UITextView

    init(text: String) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let model = EditorModel(text: text)
        let handle = SQLEditorHandle()
        handle.databaseType = .sqlite
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: EditorRoot(model: model, handle: handle))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        self.window = window
        self.model = model
        self.handle = handle
        textView = try #require(handle.textView, "the editor never attached its text view")
        try #require(textView.text == text)
    }

    func focus() throws {
        try #require(textView.becomeFirstResponder(), "the editor did not take first responder")
    }

    func bandedRanges() -> [NSRange] {
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager else { return [] }
        let start = manager.documentRange.location
        var ranges: [NSRange] = []
        manager.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, range in
            guard attributes[.backgroundColor] is UIColor else { return true }
            let location = content.offset(from: start, to: range.location)
            let length = content.offset(from: range.location, to: range.endLocation)
            if let last = ranges.last, NSMaxRange(last) == location {
                ranges[ranges.count - 1].length += length
            } else {
                ranges.append(NSRange(location: location, length: length))
            }
            return true
        }
        return ranges
    }

    // Compares the drawn pixel under a space with one past the end of its line, which the band never reaches.
    func isBandDrawn(atCharacter offset: Int) throws -> Bool {
        let start = try #require(textView.position(from: textView.beginningOfDocument, offset: offset))
        let end = try #require(textView.position(from: start, offset: 1))
        let rect = textView.firstRect(for: try #require(textView.textRange(from: start, to: end)))
        let inside = try pixel(at: textView.convert(CGPoint(x: rect.midX, y: rect.midY), to: window))
        let outside = try pixel(at: textView.convert(CGPoint(x: textView.bounds.maxX - 40, y: rect.midY), to: window))
        return inside != outside
    }

    private func pixel(at point: CGPoint) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let bounds = CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1)
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.cgImage?.dataProvider?.data as Data?)
        return Array(data.prefix(4))
    }

    func tearDown() {
        textView.resignFirstResponder()
        window.isHidden = true
        window.rootViewController = nil
    }
}
