import AppKit
import Foundation
import SwiftTreeSitter
@testable import TableProEditorKit
import TableProGrammars
import TableProTestSupport
import TableProTextEngine
import Testing

@MainActor
struct TreeSitterBackgroundParseTests {
    private static let statement = "SELECT id, name FROM users WHERE id = 1;\n"
    // Past `maxSyncEditLength`, so the edit parses off the main thread at any document length.
    private static let largeInsert = String(repeating: "SELECT 1 FROM orders;\n", count: 100)

    private func makeTextView(_ text: String = Self.statement) -> TextView {
        let textView = Mock.textView()
        textView.setText(text)
        return textView
    }

    private func readyClient(for textView: TextView) async throws -> TreeSitterClient {
        let client = Mock.treeSitterClient()
        client.setUp(textView: textView, codeLanguage: .sql)
        try await waitUntil(timeout: .seconds(30)) { client.state != nil }
        return client
    }

    private func replace(
        _ range: NSRange,
        with text: String,
        in textView: TextView,
        client: TreeSitterClient,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void = { _ in }
    ) {
        client.willApplyEdit(textView: textView, range: range)
        textView.replaceString(in: range, with: text)
        let delta = (text as NSString).length - range.length
        client.applyEdit(textView: textView, range: range, delta: delta, completion: completion)
    }

    private func freshSyntax(of text: String) throws -> String? {
        let parser = Parser()
        try parser.setLanguage(try #require(CodeLanguage.sql.language))
        return parser.parse(text)?.rootNode?.sExpressionString
    }

    @Test("A parse reads its snapshot without waiting for the main thread")
    func parseFinishesWhileTheMainThreadIsBlocked() throws {
        let textView = makeTextView()
        let original = textView.createTextSnapshot()
        let state = TreeSitterState(
            codeLanguage: .sql,
            readCallback: original.readCallback,
            readBlock: original.readBlock
        )
        let range = NSRange(location: 0, length: 0)
        let oldEndPoint = try #require(textView.pointForLocation(range.max))
        textView.replaceString(in: range, with: "-- note\n")
        let edit = try #require(InputEdit(range: range, delta: 8, oldEndPoint: oldEndPoint, textView: textView))
        let edited = textView.createTextSnapshot()
        let layer = try #require(state.layers.first)
        nonisolated(unsafe) let unsafeLayer = layer

        let finished = DispatchSemaphore(value: 0)
        // A thread of its own: the run's other suites can hold every worker of a global queue.
        Thread {
            _ = unsafeLayer.findChangedByteRanges(edits: [edit], timeout: 0.05, readBlock: edited.readBlock)
            finished.signal()
        }.start()

        let result = finished.wait(timeout: .now() + 30)
        #expect(result == .success)
    }

    @Test("A snapshot keeps the text it was taken from")
    func snapshotIgnoresLaterEdits() throws {
        let textView = makeTextView("SELECT 1")
        let snapshot = textView.createTextSnapshot()

        textView.replaceString(in: NSRange(location: 0, length: 6), with: "DELETE")

        let data = try #require(snapshot.readBlock(0, .zero))
        #expect(String(data: data, encoding: String.nativeUTF16Encoding) == "SELECT 1")
        #expect(snapshot.readCallback(NSRange(location: 0, length: 6), .zero ..< .zero) == "SELECT")
    }

    @Test("A snapshot reads nothing past the end of the document")
    func snapshotStopsAtTheEnd() {
        let snapshot = makeTextView("SELECT").createTextSnapshot()

        #expect(snapshot.readBlock(12, .zero)?.isEmpty == true)
        #expect(snapshot.readBlock(14, .zero) == nil)
        #expect(snapshot.readCallback(NSRange(location: 4, length: 3), .zero ..< .zero) == nil)
    }

    @Test("Edits that arrive during a parse are all in the tree it ends with")
    func burstEndsWithTheSyntaxOfTheFinalText() async throws {
        let textView = makeTextView()
        let client = try await readyClient(for: textView)
        var finalResult: Result<IndexSet, Error>?

        replace(NSRange(location: 0, length: 0), with: Self.largeInsert, in: textView, client: client)
        replace(NSRange(location: 0, length: 0), with: Self.largeInsert, in: textView, client: client)
        let length = (Self.largeInsert as NSString).length
        replace(NSRange(location: length, length: length), with: "", in: textView, client: client)
        replace(NSRange(location: 0, length: 0), with: Self.largeInsert, in: textView, client: client) {
            finalResult = $0
        }

        try await waitUntil(timeout: .seconds(30)) { finalResult != nil }
        guard case .success = finalResult else {
            Issue.record("The last edit did not commit")
            return
        }
        #expect(client.pendingEdits.value().isEmpty)
        #expect(client.state?.layers.first?.tree?.rootNode?.sExpressionString == (try freshSyntax(of: textView.string)))
    }

    @Test("An edit cancelled by a new set up is not applied to the tree that set up builds")
    func cancelledEditDoesNotOutliveASetUp() async throws {
        let textView = makeTextView()
        let client = try await readyClient(for: textView)
        var cancelled = false

        replace(NSRange(location: 0, length: 0), with: Self.largeInsert, in: textView, client: client) { _ in
            cancelled = true
        }
        client.setUp(textView: textView, codeLanguage: .sql)

        try await waitUntil(timeout: .seconds(30)) { cancelled }
        let expected = try freshSyntax(of: textView.string)
        try await waitUntil(timeout: .seconds(30)) {
            client.state?.layers.first?.tree?.rootNode?.sExpressionString == expected
        }
        #expect(client.pendingEdits.value().isEmpty)
    }
}
