//
//  InspectorValueThemeTests.swift
//  TableProTests
//
//  The inspector's value wells and its JSON tab take the editor's background while the theme sets
//  it, and draw exactly what they always did under the default pair.
//

import AppKit
import Combine
import SwiftUI
@testable import TablePro
import TableProTestSupport
import TableProTheme
import Testing

@MainActor
struct InspectorValueThemeTests {
    private static let wellSize = CGSize(width: 240, height: 60)
    private static let paneSize = CGSize(width: 240, height: 300)
    private static let editorBackground = "#FDF6E3"

    private func context(_ value: String, state: FieldValueState? = nil, isReadOnly: Bool = true) -> FieldEditorContext {
        FieldEditorContext(
            columnName: "note",
            columnType: .text(rawType: "TEXT"),
            isLongText: false,
            value: .constant(value),
            originalValue: value,
            valueState: state ?? .value(value),
            isReadOnly: isReadOnly
        )
    }

    private func field(_ value: String, kind: FieldEditorKind, state: FieldValueState? = nil) -> FieldEditorContent {
        FieldEditorContent(context: context(value, state: state), kind: kind)
    }

    private func pixel(of view: some View, size: CGSize, x: Int, fromBottom: Int? = nil) throws -> NSColor {
        let rep = try ThemeTestFixture.bitmap(of: view.frame(width: size.width, height: size.height), colorScheme: .light)
        let y = fromBottom.map { rep.pixelsHigh - 1 - $0 } ?? rep.pixelsHigh / 2
        return try #require(ThemeTestFixture.pixel(rep, x: x, y: y))
    }

    /// Near the trailing edge of a well, clear of its text and inside its border.
    private func wellPixel(_ view: some View) throws -> NSColor {
        try pixel(of: view, size: Self.wellSize, x: Int(Self.wellSize.width) - 12)
    }

    // MARK: - Wells

    @Test("Under the default pair a read-only value and a pending NULL draw the text background they always did")
    func defaultWellsAreNative() throws {
        try ThemeTestFixture.adopting([:], appearance: .light) {
            let native = try ThemeTestFixture.filled(.textBackgroundColor, colorScheme: .light)
            let value = try wellPixel(field("a", kind: .singleLine))
            let pending = try wellPixel(field("", kind: .singleLine, state: .pendingNull))

            #expect(ThemeTestFixture.matches(value, native), "\(value) against \(native)")
            #expect(ThemeTestFixture.matches(pending, native), "\(pending) against \(native)")
        }
    }

    @Test("Under a theme a read-only value and a pending NULL sit on the editor background")
    func themedWellsTakeTheEditorBackground() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground], appearance: .light) {
            let themed = try ThemeTestFixture.filled(hex: Self.editorBackground, colorScheme: .light)
            let value = try wellPixel(field("a", kind: .singleLine))
            let pending = try wellPixel(field("", kind: .singleLine, state: .pendingNull))

            #expect(ThemeTestFixture.matches(value, themed), "\(value) against \(themed)")
            #expect(ThemeTestFixture.matches(pending, themed), "\(pending) against \(themed)")
        }
    }

    // MARK: - Editable values

    private func editableField(_ value: Binding<String>, kind: FieldEditorKind) -> FieldEditorContent {
        let context = FieldEditorContext(
            columnName: "note",
            columnType: .text(rawType: "TEXT"),
            isLongText: false,
            value: value,
            originalValue: value.wrappedValue,
            valueState: .value(value.wrappedValue),
            isReadOnly: false
        )
        return FieldEditorContent(context: context, kind: kind)
    }

    private func editableField(_ value: String, kind: FieldEditorKind = .singleLine) -> FieldEditorContent {
        editableField(.constant(value), kind: kind)
    }

    /// `ImageRenderer` draws a placeholder for an AppKit view, so these render the hosting window.
    private func hostedWellPixel(_ view: some View, size: CGSize = wellSize) throws -> NSColor {
        let window = ThemeTestFixture.host(view, size: NSSize(width: size.width, height: size.height))
        let rep = try #require(ThemeTestFixture.snapshot(window))
        let scale = CGFloat(rep.pixelsWide) / size.width
        let x = rep.pixelsWide - Int((12 * scale).rounded())
        return try #require(ThemeTestFixture.pixel(rep, x: x, y: rep.pixelsHigh / 2))
    }

    private static func valueFields(in view: NSView?) -> [ValueTextFieldView] {
        guard let view else { return [] }
        if let field = view as? ValueTextFieldView { return [field] }
        return view.subviews.flatMap { valueFields(in: $0) }
    }

    private func hostedValueField(_ view: some View) throws -> (NSWindow, ValueTextFieldView) {
        let window = ThemeTestFixture.host(view, size: NSSize(width: Self.wellSize.width, height: Self.wellSize.height))
        return (window, try #require(Self.valueFields(in: window.contentView).first))
    }

    @Test("Under the default pair an editable value sits in the same native well as a read-only one")
    func editableValueDefaultSitsInTheNativeWell() throws {
        try ThemeTestFixture.adopting([:], appearance: .light) {
            let native = try ThemeTestFixture.filled(.textBackgroundColor, colorScheme: .light)
            let drawn = try hostedWellPixel(editableField("a"))
            #expect(ThemeTestFixture.matches(drawn, native), "\(drawn) against \(native)")
        }
    }

    @Test("Under a theme an editable value sits on the editor background, not a system bezel")
    func editableValueTakesTheEditorBackground() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground], appearance: .light) {
            let themed = try ThemeTestFixture.filled(hex: Self.editorBackground, colorScheme: .light)
            let drawn = try hostedWellPixel(editableField("a"))
            #expect(ThemeTestFixture.matches(drawn, themed), "\(drawn) against \(themed)")
        }
    }

    @Test("An editable binary value sits on the editor background under a theme")
    func editableHexTakesTheEditorBackground() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground], appearance: .light) {
            let themed = try ThemeTestFixture.filled(hex: Self.editorBackground, colorScheme: .light)
            let drawn = try hostedWellPixel(editableField("Hello", kind: .blobHex), size: Self.dumpSize)
            #expect(ThemeTestFixture.matches(drawn, themed), "\(drawn) against \(themed)")
        }
    }

    @Test("An editable value draws the system text color under the default pair and the editor text under a theme")
    func editableValueTextFollowsTheTheme() throws {
        try ThemeTestFixture.adopting([:], appearance: .light) {
            let (window, valueField) = try hostedValueField(editableField("a"))
            #expect(ThemeTestFixture.hex(valueField.textColor) == ThemeTestFixture.hex(NSColor.textColor))
            withExtendedLifetime(window) {}
        }
        try ThemeTestFixture.adopting([.editorText: "#657B83"], appearance: .light) {
            let (window, valueField) = try hostedValueField(editableField("a"))
            #expect(ThemeTestFixture.hex(valueField.textColor) == "#657B83")
            withExtendedLifetime(window) {}
        }
    }

    @Test("An editable value edits in a field editor of its own, on the theme's caret and selection, with no substitutions")
    func editableValueHasItsOwnThemedFieldEditor() throws {
        try ThemeTestFixture.adopting([.editorCursor: "#D33682", .editorSelection: "#EEE8D5"], appearance: .light) {
            let (window, valueField) = try hostedValueField(editableField("a"))
            #expect(window.makeFirstResponder(valueField))
            let editor = try #require(valueField.currentEditor() as? NSTextView)

            #expect(editor === valueField.ownFieldEditor)
            #expect(ThemeTestFixture.hex(editor.insertionPointColor) == "#D33682")
            #expect(ThemeTestFixture.hex(editor.selectedTextAttributes[.backgroundColor] as? NSColor) == "#EEE8D5")
            #expect(!editor.isAutomaticTextReplacementEnabled)
            #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
        }
    }

    @Test("The theme's caret stays in the value field: a stock field in the same window keeps the system editor")
    func editableValueCaretDoesNotLeak() throws {
        try ThemeTestFixture.adopting([.editorCursor: "#D33682"], appearance: .light) {
            let (window, valueField) = try hostedValueField(editableField("a"))
            let stock = NSTextField(string: "stock")
            window.contentView?.addSubview(stock)

            #expect(window.makeFirstResponder(valueField))
            #expect(window.makeFirstResponder(stock))
            let stockEditor = try #require(stock.currentEditor() as? NSTextView)
            #expect(stockEditor !== valueField.ownFieldEditor)
            #expect(ThemeTestFixture.hex(stockEditor.insertionPointColor) != "#D33682")
        }
    }

    @Test("Typing in an editable value reaches its binding on every keystroke")
    func editableValueWritesThrough() throws {
        final class Box { var value = "a" }
        let box = Box()
        let binding = Binding(get: { box.value }, set: { box.value = $0 })
        let (window, valueField) = try hostedValueField(editableField(binding, kind: .singleLine))
        #expect(window.makeFirstResponder(valueField))
        let editor = try #require(valueField.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(box.value == "ab")
    }

    @Test("Typing undo lives in the editing session, so the window's undo stack holds nothing once the field lets go")
    func editableValueUndoStaysInTheSession() throws {
        let (window, valueField) = try hostedValueField(editableField("abc"))
        #expect(window.makeFirstResponder(valueField))
        let editor = try #require(valueField.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.insertText("def", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(editor.undoManager !== window.undoManager)
        #expect(editor.undoManager?.canUndo == true)
        #expect(window.makeFirstResponder(nil))
        #expect(window.undoManager?.canUndo != true)
        #expect(editor.undoManager?.canUndo == false)
    }

    @Test("A value replaced from outside while the field is edited drops the typing undo recorded against the old text")
    func externalReplacementDropsTypingUndo() async throws {
        final class Model: ObservableObject { @Published var value = "abc" }
        struct Host: View {
            @ObservedObject var model: Model
            var body: some View {
                ValueTextField(text: $model.value, font: .systemFont(ofSize: 13)).valueWell()
            }
        }
        let model = Model()
        let (window, valueField) = try hostedValueField(Host(model: model))
        #expect(window.makeFirstResponder(valueField))
        let editor = try #require(valueField.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.insertText("def", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.undoManager?.canUndo == true)

        model.value = ""
        try await waitUntil { editor.string.isEmpty }
        #expect(editor.undoManager?.canUndo == false)
        withExtendedLifetime(window) {}
    }

    @Test("An editable value fills its well exactly, so the focus ring and the text inset match the read-only value")
    func editableValueFillsItsWell() throws {
        let (window, valueField) = try hostedValueField(editableField("a"))
        #expect(abs(valueField.frame.width - Self.wellSize.width) < 0.5, "\(valueField.frame)")
        #expect(valueField.frame.minX >= -0.5, "\(valueField.frame)")
        withExtendedLifetime(window) {}
    }

    @Test("A disabled editable value takes no edits")
    func disabledEditableValueIsNotEnabled() throws {
        let (window, valueField) = try hostedValueField(editableField("a").disabled(true))
        #expect(!valueField.isEnabled)
        withExtendedLifetime(window) {}
    }

    @Test("An editable binary value inside the image field's own well draws no second one")
    func editableHexInsideAWellDrawsNone() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground], appearance: .light) {
            let context = FieldEditorContext(
                columnName: "note",
                columnType: .text(rawType: "TEXT"),
                isLongText: false,
                value: .constant("Hello"),
                originalValue: "Hello",
                valueState: .value("Hello"),
                isReadOnly: false
            )
            let drawn = try hostedWellPixel(BlobHexEditorView(context: context, drawsWell: false), size: Self.dumpSize)
            #expect(drawn.alphaComponent < 0.02, "drew \(drawn)")
        }
    }

    /// SwiftUI reads a first responder change on a later pass of the run loop.
    private func nextRunLoopTurn() async throws {
        final class Flag { var isSet = false }
        let flag = Flag()
        DispatchQueue.main.async { flag.isSet = true }
        try await waitUntil { flag.isSet }
    }

    @Test("An edited binary value commits once the field lets go of focus")
    func editableHexCommitsOnBlur() async throws {
        final class Box { var committed: Data? }
        let box = Box()
        let context = FieldEditorContext(
            columnName: "payload",
            columnType: .text(rawType: "TEXT"),
            isLongText: false,
            value: .constant("Hi"),
            originalValue: "Hi",
            valueState: .value("Hi"),
            isReadOnly: false,
            commitBytes: { box.committed = $0 }
        )
        let window = ThemeTestFixture.host(
            BlobHexEditorView(context: context),
            size: NSSize(width: Self.dumpSize.width, height: Self.dumpSize.height)
        )
        let valueField = try #require(Self.valueFields(in: window.contentView).first)

        #expect(window.makeFirstResponder(valueField))
        try await nextRunLoopTurn()
        let editor = try #require(valueField.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("41 42", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await nextRunLoopTurn()

        #expect(box.committed == nil)
        #expect(window.makeFirstResponder(nil))
        try await waitUntil { box.committed == Data([0x41, 0x42]) }
    }

    // MARK: - Multi-line

    private func hostedTextView(_ view: some View) throws -> (NSWindow, NSTextView) {
        let window = ThemeTestFixture.host(view, size: NSSize(width: 240, height: 160))
        return (window, try #require(ThemeTestFixture.textViews(in: window).first))
    }

    @Test("A multi-line value keeps the system text colors under the default pair")
    func multiLineDefaultIsNative() throws {
        try ThemeTestFixture.adopting([:], appearance: .light) {
            let (window, textView) = try hostedTextView(field("line one\nline two", kind: .multiLine))
            #expect(textView.backgroundColor === NSColor.textBackgroundColor)
            #expect(textView.textColor === NSColor.textColor)
            withExtendedLifetime(window) {}
        }
    }

    @Test("A multi-line value takes the editor's background and text while the theme sets them")
    func multiLineFollowsTheTheme() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground, .editorText: "#657B83"], appearance: .light) {
            let (window, textView) = try hostedTextView(field("line one\nline two", kind: .multiLine))
            #expect(ThemeTestFixture.hex(textView.backgroundColor) == Self.editorBackground)
            #expect(ThemeTestFixture.hex(textView.textColor) == "#657B83")
            withExtendedLifetime(window) {}
        }
    }

    // MARK: - JSON tab

    private func jsonTab() -> JSONRowInspectorView {
        JSONRowInspectorView(
            viewModel: JSONRowInspectorViewModel { _, _, _, _ in nil },
            snapshot: JSONRowSnapshot(
                rowIdentity: "tab\u{001F}existing(0)",
                columns: [],
                columnTypes: [],
                values: [],
                foreignKeys: [:],
                scope: DatabaseScope(connectionId: UUID(), database: "main", schema: nil),
                databaseType: .sqlite
            ),
            onOpenReferencedTable: { _, _ in }
        )
    }

    @Test("Under the default pair the JSON tab draws no background of its own, so the inspector shows through")
    func jsonTabDefaultIsClear() throws {
        try ThemeTestFixture.adopting([:], appearance: .light) {
            let corner = try pixel(of: jsonTab(), size: Self.paneSize, x: 4, fromBottom: 4)
            #expect(corner.alphaComponent < 0.02, "\(corner)")
        }
    }

    @Test("Under a theme the JSON tab's tree sits on the editor background")
    func jsonTabTakesTheEditorBackground() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground], appearance: .light) {
            let themed = try ThemeTestFixture.filled(hex: Self.editorBackground, colorScheme: .light)
            let corner = try pixel(of: jsonTab(), size: Self.paneSize, x: 4, fromBottom: 4)
            #expect(ThemeTestFixture.matches(corner, themed), "\(corner) against \(themed)")
        }
    }

    // MARK: - Binary dump

    private static let dumpSize = CGSize(width: 240, height: 120)

    /// Inside the well's margin, left of the dump's own text.
    private func dumpMarginPixel(_ view: some View) throws -> NSColor {
        try pixel(of: view, size: Self.dumpSize, x: 3)
    }

    private func dump(drawsWell: Bool = true) -> BlobHexEditorView {
        BlobHexEditorView(context: context("Hello, world"), drawsWell: drawsWell)
    }

    @Test("Under the default pair a read-only binary dump sits in the native value well, like the values beside it")
    func dumpDefaultSitsInTheNativeWell() throws {
        try ThemeTestFixture.adopting([:], appearance: .light) {
            let native = try ThemeTestFixture.filled(.textBackgroundColor, colorScheme: .light)
            let margin = try dumpMarginPixel(dump())
            #expect(ThemeTestFixture.matches(margin, native), "\(margin) against \(native)")
        }
    }

    @Test("Under a theme a read-only binary dump sits in an editor well like the values beside it")
    func dumpThemedTakesAWell() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground], appearance: .light) {
            let themed = try ThemeTestFixture.filled(hex: Self.editorBackground, colorScheme: .light)
            let margin = try dumpMarginPixel(dump())
            #expect(ThemeTestFixture.matches(margin, themed), "\(margin) against \(themed)")
        }
    }

    @Test("A dump inside the image field's own well draws no second one")
    func dumpInsideAWellDrawsNone() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground], appearance: .light) {
            let margin = try dumpMarginPixel(dump(drawsWell: false))
            #expect(margin.alphaComponent < 0.02, "drew \(margin)")
        }
    }

    // MARK: - Geometry map

    /// The map's well, with no map drawn over it: the state a field is in while the map builds.
    private func mapWellPixel() throws -> NSColor {
        let well = Color.clear.frame(width: 200, height: 100).geometryMapWell()
        let rep = try ThemeTestFixture.bitmap(of: well, colorScheme: .light)
        return try #require(ThemeTestFixture.pixel(rep, x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
    }

    @Test("Under the default pair the geometry map's well keeps the text background it always drew")
    func geometryWellDefaultIsNative() throws {
        try ThemeTestFixture.adopting([:], appearance: .light) {
            let native = try ThemeTestFixture.filled(.textBackgroundColor, colorScheme: .light)
            let drawn = try mapWellPixel()
            #expect(ThemeTestFixture.matches(drawn, native), "\(drawn) against \(native)")
        }
    }

    @Test("Under a theme the geometry map's well takes the editor background while it has no map")
    func geometryWellFollowsTheTheme() throws {
        try ThemeTestFixture.adopting([.editorBackground: Self.editorBackground], appearance: .light) {
            let themed = try ThemeTestFixture.filled(hex: Self.editorBackground, colorScheme: .light)
            let drawn = try mapWellPixel()
            #expect(ThemeTestFixture.matches(drawn, themed), "\(drawn) against \(themed)")
        }
    }
}
