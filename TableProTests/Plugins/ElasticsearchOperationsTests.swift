//
//  ElasticsearchOperationsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ElasticsearchOperationsTests {
    @Test("Deleting an index is the native REST request")
    func deleteIndexIsNative() {
        #expect(ElasticsearchOperations.deleteIndex(named: "test_index", objectType: "TABLE") == "DELETE /test_index")
    }

    /// The confirmation dialog shows the statement and the driver then runs it, so a statement the
    /// driver's own parser rejects is exactly the reported bug. Round-tripping is what stops the
    /// two drifting apart again.
    @Test("The generated statement parses as the request it names")
    func generatedStatementRoundTrips() throws {
        let statement = try #require(
            ElasticsearchOperations.deleteIndex(named: "test_index", objectType: "TABLE")
        )
        let request = try #require(ElasticsearchConsoleParser.parse(statement))
        #expect(request.method == "DELETE")
        #expect(request.path == "/test_index")
        #expect(request.body == nil)
    }

    @Test("A name that could match more than one index is refused", arguments: [
        "*", "logs-*", "a,b", "_all", "-old", "with/slash", "with space", "back\\slash", "",
    ])
    func multiTargetNamesRefused(name: String) {
        #expect(ElasticsearchOperations.deleteIndex(named: name, objectType: "TABLE") == nil)
    }

    @Test("A percent-encodable name survives into the path")
    func unicodeNameIsEncoded() throws {
        let statement = try #require(ElasticsearchOperations.deleteIndex(named: "índice", objectType: "TABLE"))
        let request = try #require(ElasticsearchConsoleParser.parse(statement))
        #expect(request.method == "DELETE")
        #expect(request.path.hasPrefix("/"))
    }

    /// Elasticsearch has only indices, so anything the app types differently is not something this
    /// engine drops, and answering with a statement would delete an index of that name instead.
    @Test("Only an index is droppable", arguments: ["VIEW", "MATERIALIZED VIEW", "FOREIGN TABLE"])
    func onlyIndicesAreDroppable(objectType: String) {
        #expect(ElasticsearchOperations.deleteIndex(named: "test_index", objectType: objectType) == nil)
    }

    @Test("A read cannot change a mapping", arguments: ["GET", "HEAD", "get", "head"])
    func readsKeepTheMapping(method: String) {
        #expect(ElasticsearchOperations.changesMapping(method: method) == false)
    }

    @Test("Everything else can change a mapping", arguments: ["PUT", "POST", "DELETE", "PATCH", "put"])
    func writesChangeTheMapping(method: String) {
        #expect(ElasticsearchOperations.changesMapping(method: method))
    }

    /// The statement the sidebar's drop runs is itself a mapping change, so the cache it leaves
    /// behind has to go with it.
    @Test("Dropping an index is a mapping change")
    func dropIsAMappingChange() throws {
        let statement = try #require(ElasticsearchOperations.deleteIndex(named: "test_index", objectType: "TABLE"))
        let request = try #require(ElasticsearchConsoleParser.parse(statement))
        #expect(ElasticsearchOperations.changesMapping(method: request.method))
    }
}
