import CodeEditTextView
import XCTest
@testable import CodeEditSourceEditor

/// Regression tests for tree-sitter incremental-parse invalidation when an
/// edit creates ERROR / MISSING nodes. Tree-sitter's `changedByteRanges` only
/// flags ranges whose tree structure changed — but error recovery often
/// re-classifies surrounding tokens *without* changing structural identity,
/// so their highlight stays stale.
///
/// User repro from issue #1075: four SQL statements each ending with `;`,
/// remove one `;` at a time then add one back → trailing statements show
/// stale (wrong) highlight colors. The same bug shape exists in any
/// tree-sitter language whose error recovery cascades across statements.
final class ErrorNodeInvalidationTests: XCTestCase {
    private var maxSyncContentLength: Int = 0

    override func setUp() {
        maxSyncContentLength = TreeSitterClient.Constants.maxSyncContentLength
        TreeSitterClient.Constants.maxSyncContentLength = 0
    }

    override func tearDown() {
        TreeSitterClient.Constants.maxSyncContentLength = maxSyncContentLength
    }

    @MainActor
    private func setUpClient(text: String, language: CodeLanguage = .swift) async -> (TreeSitterClient, TextView) {
        let client = Mock.treeSitterClient(forceSync: true)
        let textView = Mock.textView()
        textView.setText(text)
        client.setUp(textView: textView, codeLanguage: language)

        // Wait for setUp to install the parser state.
        for _ in 0..<10 where client.state == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (client, textView)
    }

    @MainActor
    private func performEdit(
        textView: TextView,
        client: TreeSitterClient,
        replacement: String,
        in range: NSRange
    ) async -> IndexSet {
        let delta = replacement.isEmpty ? -range.length : (replacement.utf16.count - range.length)
        textView.replaceString(in: range, with: replacement)
        return await withCheckedContinuation { continuation in
            client.applyEdit(textView: textView, range: range, delta: delta) { result in
                if case .success(let set) = result {
                    continuation.resume(returning: set)
                } else {
                    continuation.resume(returning: IndexSet())
                }
            }
        }
    }

    // MARK: - Direct helper test

    @MainActor
    func test_errorNodeRangesEmptyForCleanParse() async {
        let (client, _) = await setUpClient(text: "let a = 1\nlet b = 2\n")
        let layer = client.state?.primaryLayer
        XCTAssertEqual(LanguageLayer.errorNodeRanges(in: layer?.tree), [])
    }

    @MainActor
    func test_errorNodeRangesNonEmptyForBrokenParse() async {
        // `let a = ` is incomplete — the parser produces a MISSING / ERROR node.
        let (client, _) = await setUpClient(text: "let a = \nlet b = 2\n")
        let layer = client.state?.primaryLayer
        let ranges = LanguageLayer.errorNodeRanges(in: layer?.tree)
        XCTAssertFalse(ranges.isEmpty,
                       "Broken parse should produce at least one ERROR/MISSING range, got none")
    }

    // MARK: - Integration: edit creates errors → invalidation includes error range

    @MainActor
    func test_editIntroducingErrorIncludesErrorRangeInInvalidation() async {
        // Start with a clean buffer.
        let (client, textView) = await setUpClient(text: "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\n")
        XCTAssertNotNil(client.state)

        // Delete the trailing newline + "let d = 4" so the structure is fine, then
        // perform an edit that introduces an error: delete the `=` from line 3.
        // (Line 3 starts at offset 20: "let c = 3\n".)
        let equalsLocation = ("let a = 1\nlet b = 2\nlet c " as NSString).length
        let invalidated = await performEdit(
            textView: textView,
            client: client,
            replacement: "",
            in: NSRange(location: equalsLocation, length: 1) // delete the `=`
        )

        // Without our error-range patch, tree-sitter would flag only the byte
        // around the deleted `=`. With the patch, the surrounding ERROR node
        // (the broken statement) is included.
        let editRange = NSRange(location: equalsLocation, length: 0)
        let invalidatedBeyondEdit = invalidated.subtracting(IndexSet(integersIn: editRange))
        XCTAssertFalse(invalidatedBeyondEdit.isEmpty,
                       "Edit that creates an ERROR node must invalidate beyond the literal edit position")
    }
}
