//
//  MongoSearchIndexTests.swift
//  TableProTests
//

import Foundation
import Testing

/// The listings are the `$listSearchIndexes` output the MongoDB manual documents for Atlas, written
/// in the canonical Extended JSON libmongoc hands back, one host kept from each `statusDetail`. No
/// Atlas cluster was reachable from the live checks, and MongoDB 7.0.43 refuses the stage.
struct MongoSearchIndexTests {
    enum Fixture {
        static let synonymMappings = #"{ "id" : "65240be420da840844a4d077", "name" : "synonym_mappings", "status" : "READY", "#
            + #""queryable" : true, "latestDefinitionVersion" : { "version" : { "$numberInt" : "0" }, "#
            + #""createdAt" : { "$date" : { "$numberLong" : "1696861156305" } } }, "#
            + #""latestDefinition" : { "mappings" : { "dynamic" : true, "fields" : { "fullplot" : { "type" : "string" } } }, "#
            + #""synonyms" : [ { "name" : "synonym_mapping", "analyzer" : "lucene.english", "#
            + #""source" : { "collection" : "synonyms" } } ] }, "synonymMappingStatus" : "READY", "#
            + #""synonymMappingStatusDetail" : [ { "synonym_mapping" : { "status" : "READY", "queryable" : true } } ], "#
            + #""statusDetail" : [ { "hostname" : "atlas-n1cm1j-shard-00-02", "status" : "READY", "queryable" : true, "#
            + #""mainIndex" : { "status" : "READY", "queryable" : true, "definitionVersion" : { "#
            + #""version" : { "$numberInt" : "0" }, "createdAt" : { "$date" : { "$numberLong" : "1696861156000" } } }, "#
            + #""definition" : { "mappings" : { "dynamic" : true, "fields" : { "fullplot" : { "type" : "string", "#
            + #""indexOptions" : "offsets", "store" : true, "norms" : "include" } } }, "#
            + #""synonyms" : [ { "name" : "synonym_mapping", "analyzer" : "lucene.english", "#
            + #""source" : { "collection" : "synonyms" } } ] } } } ] }"#

        static let storedSource = #"{ "id" : "6524096020da840844a4c4a7", "name" : "default", "status" : "BUILDING", "#
            + #""queryable" : true, "latestDefinitionVersion" : { "version" : { "$numberInt" : "2" }, "#
            + #""createdAt" : { "$date" : { "$numberLong" : "1696863117355" } } }, "#
            + #""latestDefinition" : { "mappings" : { "dynamic" : true }, "storedSource" : { "include" : [ "awards.text" ] } }, "#
            + #""statusDetail" : [ { "hostname" : "atlas-n1cm1j-shard-00-02", "status" : "BUILDING", "queryable" : true, "#
            + #""mainIndex" : { "status" : "READY", "queryable" : true, "definitionVersion" : { "#
            + #""version" : { "$numberInt" : "0" }, "createdAt" : { "$date" : { "$numberLong" : "1696860512000" } } }, "#
            + #""definition" : { "mappings" : { "dynamic" : true, "fields" : {  } } } }, "#
            + #""stagedIndex" : { "status" : "PENDING", "queryable" : false, "definitionVersion" : { "#
            + #""version" : { "$numberInt" : "1" }, "createdAt" : { "$date" : { "$numberLong" : "1696863089000" } } }, "#
            + #""definition" : { "mappings" : { "dynamic" : true, "fields" : {  } }, "storedSource" : true } } } ] }"#

        static let vectorSearch = #"{ "id" : "6524096020da840844a4c4b1", "name" : "vector_index", "type" : "vectorSearch", "#
            + #""status" : "READY", "queryable" : true, "latestDefinitionVersion" : { "version" : { "$numberInt" : "0" }, "#
            + #""createdAt" : { "$date" : { "$numberLong" : "1696861156305" } } }, "#
            + #""latestDefinition" : { "fields" : [ { "type" : "vector", "numDimensions" : { "$numberInt" : "1536" }, "#
            + #""path" : "plot_embedding", "similarity" : "dotProduct" }, { "type" : "filter", "path" : "genres" } ] } }"#

        /// An update in progress: the definition the host still serves names `tenant`, the new one
        /// does not yet.
        static let updating = #"{ "id" : "1", "name" : "catalog", "status" : "BUILDING", "queryable" : true, "#
            + #""latestDefinition" : { "mappings" : { "dynamic" : false, "fields" : { "title" : { "type" : "string" } } } }, "#
            + #""statusDetail" : [ { "hostname" : "h", "mainIndex" : { "definition" : { "mappings" : { "dynamic" : false, "#
            + #""fields" : { "title" : { "type" : "string" }, "tenant" : { "type" : "token" } } } } } } ] }"#
    }

    private func index(_ json: String) throws -> MongoSearchIndex {
        try #require(MongoSearchIndex(json: json))
    }

    @Test("A mapping names its field as a key, in the latest definition and in each host's")
    func mappingKeys() throws {
        let synonyms = try index(Fixture.synonymMappings)
        #expect(synonyms.name == "synonym_mappings")
        #expect(synonyms.mentions("fullplot"))
        #expect(!synonyms.mentions("plot"))
        #expect(!synonyms.mentions("full"))
    }

    @Test("A vector index names its fields by path, and storedSource by a list of paths")
    func paths() throws {
        let vector = try index(Fixture.vectorSearch)
        #expect(vector.mentions("plot_embedding"))
        #expect(vector.mentions("genres"))
        #expect(!vector.mentions("plot"))
        let stored = try index(Fixture.storedSource)
        #expect(stored.mentions("awards"))
        #expect(stored.mentions("text"))
        #expect(!stored.mentions("award"))
    }

    @Test("The definition a host still serves counts while a new one is being built")
    func servedDefinitionCounts() throws {
        let updating = try index(Fixture.updating)
        #expect(updating.mentions("tenant"))
        #expect(updating.mentions("title"))
    }

    /// The listing around a definition is status, not definition: `status`, `queryable` and
    /// `hostname` are the server's words about the index. Inside a definition every key and every
    /// string counts, grammar included, because a false refusal costs one save and a missed one
    /// leaves an index on a field that is gone.
    @Test("Only definitions are read, and every key and string inside one counts")
    func onlyDefinitionsCount() throws {
        let synonyms = try index(Fixture.synonymMappings)
        #expect(!synonyms.mentions("status"))
        #expect(!synonyms.mentions("queryable"))
        #expect(!synonyms.mentions("hostname"))
        #expect(!synonyms.mentions("READY"))
        #expect(synonyms.mentions("mappings"))
        #expect(synonyms.mentions("synonyms"))
    }

    /// Measured: `$listSearchIndexes` and `$search` both fail with 6047401 on MongoDB 6.0.28 and
    /// 7.0.43 community, and both with 31082 on 8.2.12 community with no `mongot`. MongoDB 5.0.33
    /// community fails both with 40324, the code for a stage the server does not know.
    @Test("A server with no search says so for every search stage, and has no search index")
    func serverWithoutSearch() {
        #expect(MongoSearchIndex.listingFailure(code: 6_047_401) == .serverWithoutSearch)
        #expect(MongoSearchIndex.listingFailure(code: 31_082) == .serverWithoutSearch)
        for code: UInt32 in [0, 6, 13, 50, 59, 89, 91, 11_600, 13_435] {
            #expect(MongoSearchIndex.listingFailure(code: code) == .unknown, "\(code)")
        }
        #expect(MongoSearchIndex.listingPipelineJson == #"[{"$listSearchIndexes": {}}]"#)
    }

    /// An Atlas cluster older than `$listSearchIndexes` answers it with 40324 and still runs
    /// `$search` over search indexes it cannot list. Reading 40324 as "no indexes" let a rename
    /// leave such an index mapping a field no document has.
    @Test("A server that does not know the listing stage has search indexes unless it does not know $search either")
    func listingStageUnknown() {
        #expect(MongoSearchIndex.listingFailure(code: 40_324) == .listingStageUnknown)
        #expect(MongoSearchIndex.searchIsUnavailable(probeErrorCode: nil) == false)
        #expect(MongoSearchIndex.searchIsUnavailable(probeErrorCode: 40_324))
        #expect(MongoSearchIndex.searchIsUnavailable(probeErrorCode: 6_047_401))
        #expect(MongoSearchIndex.searchIsUnavailable(probeErrorCode: 31_082))
        #expect(MongoSearchIndex.searchIsUnavailable(probeErrorCode: 8) == false)
        #expect(MongoSearchIndex.searchIsUnavailable(probeErrorCode: 13) == false)
        #expect(MongoSearchIndex.searchProbePipelineJson.hasPrefix(#"[{"$search": "#))
    }

    @Test("A listing that is not a document is no index")
    func unreadableListing() {
        #expect(MongoSearchIndex(json: "[]") == nil)
        #expect(MongoSearchIndex(json: "not json") == nil)
    }
}
