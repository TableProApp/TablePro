import Foundation
import TableProWeaviateClient
import TableProWeaviateCore
import Testing

struct WeaviateStatementGeneratorTests {
    private static let uuid = "36ddd591-2dee-4e7e-a3cc-eb86d30a4303"

    private static func request(_ kind: WeaviateTrackedChange.Kind) -> WeaviateWriteRequest? {
        let change = WeaviateTrackedChange(
            kind: kind,
            uuid: uuid,
            values: ["title": "A"],
            cellChanges: [WeaviateCellChange(column: "title", newText: "B")]
        )
        return WeaviateStatementGenerator.generate(
            collection: "Article",
            columns: ["title"],
            typeNames: ["text"],
            changes: [change]
        ).requests.first
    }

    // `/v1/objects/{id}` deletes the id in every collection that holds it.
    @Test("A row's delete and update name its collection in the route")
    func rowChangesNameTheCollection() throws {
        let delete = try #require(Self.request(.delete))
        #expect(delete.method == "DELETE")
        #expect(delete.path == "/v1/objects/Article/\(Self.uuid)")
        #expect(delete.query.isEmpty)

        let update = try #require(Self.request(.update))
        #expect(update.method == "PATCH")
        #expect(update.path == "/v1/objects/Article/\(Self.uuid)")
        #expect(update.query.isEmpty)
    }
}
