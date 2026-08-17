//
//  QueryEditorLargePasteTests.swift
//  TableProTests
//
//  Regression tests for issue #2158: pasting a large block into the query editor crashed the app.
//  A caret paste over `maxSyncEditLength` routes the tree-sitter edit to the async arm, and that arm
//  invoked its `@MainActor` completion straight from the background task. The completion drives
//  `HighlightProviderState`, so highlight state and `NSTextStorage` were touched off the main thread
//  while the main thread was still processing the same edit.
//
//  These live here rather than in `CodeEditSourceEditorTests` because the TablePro scheme does not
//  run that target, so a test there would never gate a regression.
//

import CodeEditLanguages
@testable import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import Testing

private final class CompletionRecorder: @unchecked Sendable {
    private struct Call {
        let ranOnMainThread: Bool
        let succeeded: Bool
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func record(ranOnMainThread: Bool, succeeded: Bool) -> Bool {
        lock.withLock {
            calls.append(Call(ranOnMainThread: ranOnMainThread, succeeded: succeeded))
            return calls.count == 1
        }
    }

    var callCount: Int {
        lock.withLock { calls.count }
    }

    var allRanOnMainThread: Bool {
        lock.withLock { !calls.isEmpty && calls.allSatisfy { $0.ranOnMainThread } }
    }

    var allSucceeded: Bool {
        lock.withLock { !calls.isEmpty && calls.allSatisfy { $0.succeeded } }
    }
}

@MainActor
@Suite("Query editor large paste")
struct QueryEditorLargePasteTests {
    private static let prefix = "select * from t where c like '%"

    private static let pastedBlock = (1...50)
        .map { "line \($0) of text the user did not mean to paste" }
        .joined(separator: "\n")

    // No wait for set-up is needed: `setUp` enqueues a `.reset` task, and a non-`.access` task only
    // runs at the head of the executor queue, so the `.edit` task below cannot start until it ends.
    private func makeClient(textView: TextView) -> TreeSitterClient {
        let client = TreeSitterClient()
        client.setUp(textView: textView, codeLanguage: .sql)
        return client
    }

    @Test("A large caret paste delivers its invalidation on the main thread")
    func largeCaretPasteCompletesOnMainThread() async {
        let paste = Self.pastedBlock
        let delta = paste.utf16.count
        #expect(
            delta > TreeSitterClient.Constants.maxSyncEditLength,
            "The paste must be large enough to take the async arm, or this test proves nothing"
        )

        let textView = TextView(string: Self.prefix)
        let client = makeClient(textView: textView)

        let caret = textView.documentRange.length
        let editRange = NSRange(location: caret, length: 0)
        let recorder = CompletionRecorder()

        client.willApplyEdit(textView: textView, range: editRange)
        textView.insertText(paste, replacementRange: editRange)

        await withCheckedContinuation { continuation in
            client.applyEdit(textView: textView, range: editRange, delta: delta) { result in
                // The executor can deliver a success and a cancellation for one edit, and resuming
                // a continuation twice traps the whole test bundle rather than failing this case.
                let isFirstCall = recorder.record(
                    ranOnMainThread: Thread.isMainThread,
                    succeeded: (try? result.get()) != nil
                )
                if isFirstCall {
                    continuation.resume()
                }
            }

            #expect(
                recorder.callCount == 0,
                "The edit resolved synchronously, so the async arm under test never ran"
            )
        }

        #expect(
            recorder.allSucceeded,
            "The edit was cancelled or invalid, so the success arm under test never ran"
        )
        #expect(recorder.allRanOnMainThread, "The edit completion must run on the main thread")
    }

    @Test("A caret paste routes to the async arm even though it replaces nothing")
    func largePasteAtCaretRunsAsync() {
        #expect(TreeSitterClient.shouldExecuteAsync(editLength: 0, delta: 500_000, documentLength: 500_000))
    }

    @Test("A small edit in a small document stays synchronous")
    func smallEditInSmallDocumentRunsSync() {
        #expect(!TreeSitterClient.shouldExecuteAsync(editLength: 4, delta: 4, documentLength: 1_000))
    }

    @Test("A large document always parses asynchronously")
    func largeDocumentRunsAsync() {
        #expect(TreeSitterClient.shouldExecuteAsync(editLength: 1, delta: 1, documentLength: 2_000_000))
    }

    @Test("A large deletion routes to the async arm")
    func largeDeletionRunsAsync() {
        #expect(TreeSitterClient.shouldExecuteAsync(editLength: 0, delta: -500_000, documentLength: 10))
    }
}
