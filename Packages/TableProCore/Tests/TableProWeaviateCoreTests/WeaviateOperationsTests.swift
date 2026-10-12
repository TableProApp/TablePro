import Foundation
@testable import TableProWeaviateCore
import Testing

@Suite("Weaviate object operations")
struct WeaviateOperationsTests {
    @Test("Deleting a collection is the native REST request")
    func deleteCollectionIsNative() {
        #expect(WeaviateOperations.deleteCollection(named: "Article", objectType: "TABLE") == "DELETE /v1/schema/Article")
    }

    /// The statement is shown in the confirmation and then run, so one the driver's own parser
    /// rejects is the #2884 defect in another engine.
    @Test("The generated statement parses as the request it names")
    func statementRoundTrips() throws {
        let statement = try #require(WeaviateOperations.deleteCollection(named: "Article", objectType: "TABLE"))
        let request = try #require(WeaviateConsoleParser.parse(statement))
        #expect(request.method == "DELETE")
        #expect(request.path == "/v1/schema/Article")
        #expect(request.body == nil)
    }

    @Test("A name that is not a class name is refused", arguments: [
        "", "1Article", "_Article", "Article/x", "Article Name", "Article,Other", "*",
    ])
    func nonClassNamesRefused(name: String) {
        #expect(WeaviateOperations.deleteCollection(named: name, objectType: "TABLE") == nil)
    }

    @Test("Only a collection is droppable", arguments: ["VIEW", "MATERIALIZED VIEW", "SYSTEM TABLE"])
    func onlyCollectionsAreDroppable(objectType: String) {
        #expect(WeaviateOperations.deleteCollection(named: "Article", objectType: objectType) == nil)
    }
}
