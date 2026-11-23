import AppKit
import SwiftUI
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct JsonFieldEditorTests {
    @MainActor
    private final class Counts: ObservableObject {
        @Published var tick = 0
        var bodies = 0
        var editors = 0
    }

    private struct Parent: View {
        @ObservedObject var counts: Counts

        var body: some View {
            counts.bodies += 1
            return JsonEditorView(
                context: FieldEditorContext(
                    columnName: "meta",
                    columnType: .json(rawType: "JSON"),
                    isLongText: true,
                    value: .constant(#"{"row": 1}"#),
                    originalValue: #"{"row": 1}"#,
                    valueState: .value(#"{"row": 1}"#),
                    isReadOnly: false,
                    documentID: Parent.document
                ),
                makeEditor: { [counts] value, documentID in
                    counts.editors += 1
                    return JsonFieldEditor(storedValue: value, documentID: documentID)
                }
            )
        }

        static let document = UUID()
    }

    @Test("Evaluating the parent's body again builds no second model")
    func parentBodyBuildsOneModel() async throws {
        let counts = Counts()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Parent(counts: counts))
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        try await waitUntil { counts.bodies >= 1 }

        counts.tick += 1
        try await waitUntil {
            window.layoutIfNeeded()
            return counts.bodies >= 2
        }
        counts.tick += 1
        try await waitUntil {
            window.layoutIfNeeded()
            return counts.bodies >= 3
        }

        #expect(counts.editors == 1)
    }

    @Test("Another document reseeds the model once and gives the editor a new history")
    func newDocumentReseedsOnce() {
        let editor = JsonFieldEditor(storedValue: #"{"a":1}"#, documentID: UUID())
        let next = UUID()

        editor.sync(documentID: next, value: #"{"b":2}"#)
        #expect(editor.replacements == 1)
        #expect(editor.model.displayText == JsonReindenter.reindent(#"{"b":2}"#))

        editor.sync(documentID: next, value: #"{"b":2}"#)
        #expect(editor.replacements == 1)
    }

    @Test("The editor's own text coming back is refused and keeps the history")
    func ownTextIsRefused() throws {
        let document = UUID()
        let editor = JsonFieldEditor(storedValue: #"{"a":1}"#, documentID: document)
        let typed = "{\n  \"a\": 2\n}"
        let published = try #require(editor.typed(typed))

        editor.sync(documentID: document, value: published)

        #expect(editor.replacements == 0)
        #expect(editor.model.displayText == typed)
    }

    @Test("Set NULL empties the field and starts a new history")
    func setNullIsAdopted() {
        let document = UUID()
        let editor = JsonFieldEditor(storedValue: #"{"a":1}"#, documentID: document)

        editor.sync(documentID: document, value: "")

        #expect(editor.replacements == 1)
        #expect(editor.model.displayText.isEmpty)
    }
}
