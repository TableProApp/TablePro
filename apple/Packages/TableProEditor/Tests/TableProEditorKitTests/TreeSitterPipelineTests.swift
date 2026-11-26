import AppKit
import Foundation
import SwiftTreeSitter
@testable import TableProEditorKit
import TableProGrammars
import TableProTestSupport
import TableProTextEngine
import Testing

@MainActor
struct TreeSitterPipelineTests {
    private static let statement = "SELECT id, name FROM users WHERE id = 1;\n"
    // Every quote typed before these flips which text is inside a string, so the parse re-lexes all that follows.
    private static let quotedStatement = "SELECT 'a', name FROM users WHERE id = 'b';\n"

    private func makeTextView(_ text: String) -> TextView {
        let textView = Mock.textView()
        textView.setText(text)
        return textView
    }

    private func readyClient(for textView: TextView, forceSync: Bool = false) async throws -> TreeSitterClient {
        let client = Mock.treeSitterClient(forceSync: forceSync)
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

    // Units, not a String: a random edit can split a surrogate pair, which a String would repair.
    private func readAll(_ snapshot: TextSnapshot) -> [UInt16] {
        var data = Data()
        while let chunk = snapshot.readBlock(data.count, .zero), !chunk.isEmpty {
            data.append(chunk)
        }
        return data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    }

    private func units(of string: NSString) -> [UInt16] {
        var units = [UInt16](repeating: 0, count: string.length)
        string.getCharacters(&units, range: NSRange(location: 0, length: string.length))
        return units
    }

    // MARK: - Snapshot

    @Test("Edits keep the snapshot equal to the text, and an earlier copy keeps its own")
    func snapshotFollowsEdits() {
        let storage = NSMutableString(string: String(repeating: Self.statement, count: 400))
        var snapshot = TextSnapshot(string: storage)
        var generator = SystemRandomNumberGenerator()
        var copies: [(TextSnapshot, [UInt16])] = []

        for step in 0..<300 {
            let location = Int.random(in: 0...storage.length, using: &generator)
            let length = Int.random(in: 0...min(storage.length - location, step % 7 == 0 ? 9_000 : 12), using: &generator)
            let insert = step % 11 == 0 ? String(repeating: "x'é😀\n", count: 1_500) : String(repeating: "ab", count: step % 4)
            let range = NSRange(location: location, length: length)
            storage.replaceCharacters(in: range, with: insert)
            snapshot.replace(range, with: storage, in: NSRange(location: location, length: (insert as NSString).length))
            if step % 50 == 0 {
                copies.append((snapshot, units(of: storage)))
            }
        }

        #expect(snapshot.length == storage.length)
        #expect(snapshot.string(in: NSRange(location: 0, length: storage.length)) == storage as String)
        #expect(readAll(snapshot) == units(of: storage))
        for (copy, text) in copies {
            #expect(readAll(copy) == text)
        }
    }

    @Test("Deleting the whole text and typing again leaves exactly the new text")
    func snapshotSurvivesAnEmptyDocument() {
        let storage = NSMutableString(string: Self.statement)
        var snapshot = TextSnapshot(string: storage)

        let all = NSRange(location: 0, length: storage.length)
        storage.replaceCharacters(in: all, with: "")
        snapshot.replace(all, with: storage, in: NSRange(location: 0, length: 0))
        #expect(snapshot.length == 0)
        #expect(snapshot.readBlock(0, .zero)?.isEmpty == true)

        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "SELECT")
        snapshot.replace(NSRange(location: 0, length: 0), with: storage, in: NSRange(location: 0, length: 6))
        #expect(readAll(snapshot) == units(of: "SELECT"))
    }

    // MARK: - Main thread budget

    @Test("A main-thread parse that runs out of budget is finished off the main thread")
    func budgetedParseResumesInTheBackground() async throws {
        let textView = makeTextView(String(repeating: Self.quotedStatement, count: 2_000))
        let client = try await readyClient(for: textView)
        client.syncParseBudget = 1e-6
        var result: Result<IndexSet, Error>?
        var completed = false

        // An opening quote at the top turns the rest of the document into a string, so the parse re-lexes all of it.
        replace(NSRange(location: 0, length: 0), with: "'", in: textView, client: client) {
            result = $0
            completed = true
        }

        #expect(!completed, "The parse finished on the main thread despite its budget")
        try await waitUntil(timeout: .seconds(30)) { result != nil }
        guard case .success = result else {
            Issue.record("The resumed parse did not commit")
            return
        }
        #expect(client.pendingEdits.isEmpty)
        #expect(client.state?.layers.first?.tree?.rootNode?.sExpressionString == (try freshSyntax(of: textView.string)))
    }

    @Test("A parse left unfinished on the main thread is not resumed over text that has changed since")
    func unfinishedParseIsDroppedByTheNextEdit() async throws {
        let textView = makeTextView(String(repeating: Self.quotedStatement, count: 2_000))
        let client = try await readyClient(for: textView)
        client.syncParseBudget = 1e-6
        var finalResult: Result<IndexSet, Error>?

        replace(NSRange(location: 0, length: 0), with: "'", in: textView, client: client)
        replace(NSRange(location: 0, length: 1), with: "-- note\n", in: textView, client: client) { finalResult = $0 }

        try await waitUntil(timeout: .seconds(30)) { finalResult != nil }
        guard case .success = finalResult else {
            Issue.record("The last edit did not commit")
            return
        }
        #expect(client.state?.layers.first?.tree?.rootNode?.sExpressionString == (try freshSyntax(of: textView.string)))
    }

    // MARK: - Changed ranges

    @Test("A comment typed at the top invalidates the text near it, not the rest of the document")
    func changedRangesStayNearTheEdit() async throws {
        let textView = makeTextView(String(repeating: Self.statement, count: 500))
        let client = try await readyClient(for: textView, forceSync: true)
        var invalidated: IndexSet?

        replace(NSRange(location: 0, length: 0), with: "-- note\n", in: textView, client: client) { result in
            if case .success(let set) = result { invalidated = set }
        }

        try await waitUntil(timeout: .seconds(30)) { invalidated != nil }
        let set = try #require(invalidated)
        #expect(set.count < (Self.statement as NSString).length * 2, "Invalidated \(set.count) characters")
    }

    // MARK: - Executor

    @Test("A task cancelled while it waits reports at once, while the task ahead still runs")
    func cancelledWaiterReportsWhileTheHeadRuns() async throws {
        let executor = TreeSitterExecutor()
        let release = DispatchSemaphore(value: 0)
        let started = Atomic(false)
        let cancelled = Atomic(false)
        let finished = Atomic(false)

        executor.execAsync(priority: .reset, operation: {
            started.mutate { $0 = true }
            release.wait()
            finished.mutate { $0 = true }
            return true
        }, onCancel: {})
        try await waitUntil(timeout: .seconds(30)) { started.value() }

        executor.execAsync(priority: .edit, operation: { true }, onCancel: { cancelled.mutate { $0 = true } })
        executor.cancelAll(below: .reset)

        try await waitUntil(timeout: .seconds(30)) { cancelled.value() }
        #expect(!finished.value())
        release.signal()
        try await waitUntil(timeout: .seconds(30)) { finished.value() }
    }

    @Test("Queued tasks run one after another in the order they were queued")
    func queuedTasksRunInOrder() async throws {
        let executor = TreeSitterExecutor()
        let order = Atomic<[Int]>([])

        for index in 0..<20 {
            executor.execAsync(priority: .edit, operation: {
                order.mutate { $0.append(index) }
                return true
            }, onCancel: {})
        }

        try await waitUntil(timeout: .seconds(30)) { order.value().count == 20 }
        #expect(order.value() == Array(0..<20))
    }
}
