import XCTest
import CodeEditTextView
@testable import CodeEditSourceEditor

// swiftlint:disable all

final class TreeSitterClientTests: XCTestCase {

    private var maxSyncContentLength: Int = 0

    override func setUp() {
        maxSyncContentLength = TreeSitterClient.Constants.maxSyncContentLength
        TreeSitterClient.Constants.maxSyncContentLength = 0
    }

    override func tearDown() {
        TreeSitterClient.Constants.maxSyncContentLength = maxSyncContentLength
    }

    @MainActor
    func performEdit(
        textView: TextView,
        client: TreeSitterClient,
        string: String,
        range: NSRange,
        completion: @escaping (Result<IndexSet, Error>) -> Void
    ) {
        let delta = string.isEmpty ? -range.length : range.length
        textView.replaceString(in: range, with: string)
        client.applyEdit(textView: textView, range: range, delta: delta, completion: completion)
    }

    @MainActor 
    func test_clientSetup() async {
        let client = Mock.treeSitterClient()
        let textView = Mock.textView()
        client.setUp(textView: textView, codeLanguage: .swift)

        let expectation = XCTestExpectation(description: "Setup occurs")

        Task.detached {
            while client.state == nil {
                try await Task.sleep(for: .seconds(0.5))
            }
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)

        let primaryLanguage = client.state?.primaryLayer.id
        let layerCount = client.state?.layers.count
        XCTAssertEqual(primaryLanguage, .swift, "Client set up incorrect language")
        XCTAssertEqual(layerCount, 1, "Client set up too many layers")
    }

    func resultIsCancel<T>(_ result: Result<T, Error>) -> Bool {
        if case let .failure(error) = result {
            if case HighlightProvidingError.operationCancelled = error {
                return true
            }
        }
        return false
    }

    @MainActor
    func test_editsDuringSetup() {
        let client = Mock.treeSitterClient()
        let textView = Mock.textView()

        client.setUp(textView: textView, codeLanguage: .swift)

        // Perform a highlight query
        let cancelledQuery = XCTestExpectation(description: "Highlight query should be cancelled by edits.")
        client.queryHighlightsFor(textView: textView, range: NSRange(location: 0, length: 10)) { result in
            if self.resultIsCancel(result) {
                cancelledQuery.fulfill()
            } else {
                XCTFail("Highlight query was not cancelled.")
            }
        }

        // Perform an edit
        let cancelledEdit = XCTestExpectation(description: "First edit should be cancelled by second one.")
        performEdit(textView: textView, client: client, string: "func ", range: .zero) { result in
            if self.resultIsCancel(result) {
                cancelledEdit.fulfill()
            } else {
                XCTFail("Edit was not cancelled.")
            }
        }

        // Perform a second edit
        let successEdit = XCTestExpectation(description: "Second edit should succeed.")
        performEdit(textView: textView, client: client, string: "", range: NSRange(location: 0, length: 5)) { result in
            if case let .success(ranges) = result {
                XCTAssertEqual(ranges.count, 0, "Edits, when combined, should produce the original syntax tree.")
                successEdit.fulfill()
            } else {
                XCTFail("Second edit was not successful.")
            }
        }

        wait(for: [cancelledQuery, cancelledEdit, successEdit], timeout: 5.0)
    }

    @MainActor
    func test_multipleSetupsCancelAllOperations() async {
        let client = Mock.treeSitterClient()
        let textView = Mock.textView()

        // First setup, wrong language
        client.setUp(textView: textView, codeLanguage: .c)

        // Perform a highlight query
        let cancelledQuery = XCTestExpectation(description: "Highlight query should be cancelled by second setup.")
        client.queryHighlightsFor(textView: textView, range: NSRange(location: 0, length: 10)) { result in
            if self.resultIsCancel(result) {
                cancelledQuery.fulfill()
            } else {
                XCTFail("Highlight query was not cancelled by the second setup.")
            }
        }

        // Perform an edit
        let cancelledEdit = XCTestExpectation(description: "First edit should be cancelled by second setup.")
        performEdit(textView: textView, client: client, string: "func ", range: .zero) { result in
            if self.resultIsCancel(result) {
                cancelledEdit.fulfill()
            } else {
                XCTFail("Edit was not cancelled by the second setup.")
            }
        }

        // Second setup, which should cancel all previous operations
        client.setUp(textView: textView, codeLanguage: .swift)

        let finalSetupExpectation = XCTestExpectation(description: "Final setup should complete successfully.")

        Task.detached {
            while client.state?.primaryLayer.id != .swift {
                try await Task.sleep(for: .seconds(0.5))
            }
            finalSetupExpectation.fulfill()
        }

        await fulfillment(of: [cancelledQuery, cancelledEdit, finalSetupExpectation], timeout: 5.0)

        // Ensure only the final setup's language is active
        let primaryLanguage = client.state?.primaryLayer.id
        let layerCount = client.state?.layers.count
        XCTAssertEqual(primaryLanguage, .swift, "Client set up incorrect language after re-setup.")
        XCTAssertEqual(layerCount, 1, "Client set up too many layers after re-setup.")
    }

    @MainActor
    func test_cancelAllEditsUntilFinalOne() {
        let client = Mock.treeSitterClient()
        let textView = Mock.textView()
        textView.setText("asadajkfijio;amfjamc;aoijaoajkvarpfjo;sdjlkj")

        client.setUp(textView: textView, codeLanguage: .swift)

        // Set up random edits
        let editExpectations = (0..<10).map { index -> XCTestExpectation in
            let expectation = XCTestExpectation(description: "Edit \(index) should be cancelled.")
            let isDeletion = Int.random(in: 0..<10) < 4
            let editText = isDeletion ? "" : "\(index)"
            let editLocation = Int.random(in: 0..<textView.string.count)
            let editRange = if isDeletion {
                NSRange(location: editLocation, length: 1)
            } else {
                NSRange(location: editLocation, length: 0)
            }
            performEdit(textView: textView, client: client, string: editText, range: editRange) { result in
                if self.resultIsCancel(result) {
                    expectation.fulfill()
                } else {
                    XCTFail("Edit \(index) was not cancelled.")
                }
            }
            return expectation
        }

        // Final edit that should succeed
        let finalEditExpectation = XCTestExpectation(description: "Final edit should succeed.")
        performEdit(textView: textView, client: client, string: "", range: textView.documentRange) { result in
            if case .success(_) = result {
                finalEditExpectation.fulfill()
            } else {
                XCTFail("Final edit did not succeed.")
            }
        }

        wait(for: editExpectations + [finalEditExpectation], timeout: 5.0)
    }
}
// swiftlint:enable all
