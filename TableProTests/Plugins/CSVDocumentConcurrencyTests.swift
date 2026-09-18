import AppKit
import Testing

@MainActor
@Suite("CSVDocument opening concurrency")
struct CSVDocumentConcurrencyTests {
    @Test(
        "Documents stay on the main actor while opening",
        arguments: [
            "public.comma-separated-values-text",
            "public.tab-separated-values-text"
        ]
    )
    func documentOpeningIsNotConcurrent(typeName: String) {
        #expect(!CSVDocument.canConcurrentlyReadDocuments(ofType: typeName))
    }
}
